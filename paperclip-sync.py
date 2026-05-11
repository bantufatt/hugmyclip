#!/usr/bin/env python3
"""
HuggingClip Database Sync - PostgreSQL Backup/Restore to Hugging Face Dataset
Syncs Paperclip's PostgreSQL database to HF Dataset for persistence across restarts.
"""

import os
import sys
import json
import tarfile
import tempfile
import subprocess
import logging
import warnings
from datetime import datetime, timezone
from pathlib import Path

# Suppress huggingface_hub deprecation noise about local_dir_use_symlinks
warnings.filterwarnings('ignore', category=UserWarning, module='huggingface_hub')

from huggingface_hub import HfApi
from huggingface_hub.utils import RepositoryNotFoundError, EntryNotFoundError
import huggingface_hub

# Disable all HF Hub progress bars (they clutter container logs)
huggingface_hub.utils.disable_progress_bars()

# ============================================================================
# Configuration
# ============================================================================

# Logging: WARNING level keeps errors visible, suppresses routine INFO chatter
logging.basicConfig(
    level=logging.WARNING,
    format='[sync] %(message)s'
)
logger = logging.getLogger(__name__)
# Set our own logger to INFO so backup/restore start+finish lines still print
logger.setLevel(logging.INFO)
logging.getLogger("httpx").setLevel(logging.WARNING)
logging.getLogger("huggingface_hub").setLevel(logging.WARNING)

# Environment variables
HF_TOKEN = os.environ.get('HF_TOKEN')
HF_USERNAME = os.environ.get('HF_USERNAME')
DATABASE_URL = os.environ.get('DATABASE_URL', 'postgres://postgres:paperclip@localhost:5432/paperclip')
BACKUP_DATASET_NAME = os.environ.get('BACKUP_DATASET_NAME', 'huggingclip-backup')
SYNC_MAX_FILE_BYTES = int(os.environ.get('SYNC_MAX_FILE_BYTES', '52428800'))  # 50MB
PAPERCLIP_HOME = os.environ.get('PAPERCLIP_HOME', '/paperclip')
# Status file for dashboard
STATUS_FILE = Path('/tmp/sync-status.json')

# ============================================================================
# Helper Functions
# ============================================================================

def parse_db_url(db_url: str) -> dict:
    """Parse PostgreSQL connection URL"""
    # Format: postgres://user:password@host:port/database
    try:
        # Remove protocol
        connection_str = db_url.replace('postgres://', '').replace('postgresql://', '')

        # Parse credentials
        if '@' in connection_str:
            creds, host_db = connection_str.split('@')
            if ':' in creds:
                user, password = creds.split(':', 1)
            else:
                user = creds
                password = ''
        else:
            user = 'postgres'
            password = ''
            host_db = connection_str

        # Parse host and database
        if ':' in host_db and '/' in host_db:
            host_port, database = host_db.rsplit('/', 1)
            if ':' in host_port:
                host, port = host_port.rsplit(':', 1)
            else:
                host = host_port
                port = '5432'
        else:
            host = host_db.split('/')[0]
            port = '5432'
            database = host_db.split('/')[-1] if '/' in host_db else 'paperclip'

        return {
            'user': user,
            'password': password,
            'host': host,
            'port': port,
            'database': database
        }
    except Exception as e:
        logger.error(f'Failed to parse DATABASE_URL: {e}')
        return None

def write_status(status: dict):
    """Write sync status to file for dashboard"""
    try:
        # Ensure compatibility with dashboard fields: `status` and `message`
        try:
            if 'db_status' in status and 'status' not in status:
                status['status'] = status['db_status']
            if 'last_error' in status and 'message' not in status:
                status['message'] = status['last_error']
        except Exception:
            pass
        STATUS_FILE.write_text(json.dumps(status, indent=2))
    except Exception as e:
        logger.error(f'Failed to write status file: {e}')

def read_status() -> dict:
    """Read current sync status"""
    if STATUS_FILE.exists():
        try:
            return json.loads(STATUS_FILE.read_text())
        except Exception as e:
            logger.error(f'Failed to read status file: {e}')

    return {
        'db_status': 'unknown',
        'last_sync_time': None,
        'last_error': None,
        'sync_count': 0
    }

def backup_database() -> tuple[str, bool]:
    """
    Backup PostgreSQL database to SQL dump.
    Returns (filepath, success)
    """
    logger.debug('Starting database backup...')

    db_config = parse_db_url(DATABASE_URL)
    if not db_config:
        return None, False

    temp_dir = tempfile.mkdtemp()
    dump_file = Path(temp_dir) / 'paperclip.sql'

    try:
        # Build pg_dump command
        env = os.environ.copy()
        if db_config['password']:
            env['PGPASSWORD'] = db_config['password']

        cmd = [
            'pg_dump',
            f'--host={db_config["host"]}',
            f'--port={db_config["port"]}',
            f'--username={db_config["user"]}',
            '--format=plain',
            '--verbose',
            db_config['database']
        ]

        # Execute pg_dump
        with open(dump_file, 'w') as f:
            result = subprocess.run(cmd, stdout=f, stderr=subprocess.PIPE, env=env, timeout=300)

        if result.returncode != 0:
            error_msg = result.stderr.decode('utf-8', errors='ignore')
            logger.error(f'pg_dump failed: {error_msg}')
            return None, False

        dump_size = dump_file.stat().st_size
        logger.debug(f'Database dumped ({dump_size / 1024 / 1024:.2f} MB)')

        return str(dump_file), True

    except subprocess.TimeoutExpired:
        logger.error('Database backup timed out (>300s)')
        return None, False
    except Exception as e:
        logger.error(f'Database backup error: {e}')
        return None, False

def create_backup_tarball(dump_file: str) -> tuple[str, bool]:
    """
    Create tarball with database dump and Paperclip data files.
    Returns (tarball_path, success)
    """
    logger.debug('Creating backup tarball...')

    temp_dir = tempfile.mkdtemp()
    tarball_file = Path(temp_dir) / 'paperclip-backup.tar.gz'

    try:
        with tarfile.open(tarball_file, 'w:gz') as tar:
            # Add SQL dump
            tar.add(dump_file, arcname='paperclip.sql')

            # Add Paperclip home directory if it exists
            if Path(PAPERCLIP_HOME).exists():
                tar.add(PAPERCLIP_HOME, arcname='paperclip-data')
            else:
                logger.warning(f'PAPERCLIP_HOME not found: {PAPERCLIP_HOME}')

        tarball_size = tarball_file.stat().st_size
        logger.debug(f'Tarball created ({tarball_size / 1024 / 1024:.2f} MB)')

        # Check size limit
        if tarball_size > SYNC_MAX_FILE_BYTES:
            logger.error(f'Backup too large ({tarball_size / SYNC_MAX_FILE_BYTES * 100:.0f}% of limit)')
            return None, False

        return str(tarball_file), True

    except Exception as e:
        logger.error(f'Failed to create tarball: {e}')
        return None, False

def sync_to_hf(backup_file: str) -> bool:
    """Upload backup tarball to Hugging Face Dataset."""
    if not HF_TOKEN:
        logger.warning('HF_TOKEN not set - skipping backup upload')
        return False

    logger.debug('Uploading backup to Hugging Face...')

    try:
        api = HfApi(token=HF_TOKEN)

        username = HF_USERNAME
        if not username:
            try:
                user_info = api.whoami()
                username = user_info['name']
            except Exception:
                logger.error('Failed to get HF username')
                return False

        dataset_id = f'{username}/{BACKUP_DATASET_NAME}'

        api.create_repo(repo_id=dataset_id, repo_type='dataset', private=True, exist_ok=True)

        api.upload_file(
            path_or_fileobj=backup_file,
            path_in_repo='snapshots/latest.tar.gz',
            repo_id=dataset_id,
            repo_type='dataset'
        )

        logger.debug(f'Backup uploaded to {dataset_id}')
        return True

    except Exception as e:
        logger.error(f'Failed to upload to HF: {e}')
        return False

def restore_database(restore_file: str) -> bool:
    """
    Restore PostgreSQL database from SQL dump.
    """
    logger.debug('Restoring database from backup...')

    db_config = parse_db_url(DATABASE_URL)
    if not db_config:
        return False

    try:
        # Ensure database exists
        admin_cmd = [
            'psql',
            f'--host={db_config["host"]}',
            f'--port={db_config["port"]}',
            f'--username={db_config["user"]}',
            '--no-password',
            '-c',
            f'CREATE DATABASE IF NOT EXISTS {db_config["database"]};'
        ]

        env = os.environ.copy()
        if db_config['password']:
            env['PGPASSWORD'] = db_config['password']

        subprocess.run(admin_cmd, env=env, capture_output=True)

        # Restore from dump
        restore_cmd = [
            'psql',
            f'--host={db_config["host"]}',
            f'--port={db_config["port"]}',
            f'--username={db_config["user"]}',
            '--no-password',
            db_config['database']
        ]

        with open(restore_file, 'r') as f:
            result = subprocess.run(
                restore_cmd,
                stdin=f,
                stdout=subprocess.DEVNULL,  # suppress CREATE TABLE / ALTER TABLE / COPY noise
                stderr=subprocess.PIPE,
                env=env,
                timeout=300
            )

        if result.returncode != 0:
            error_msg = result.stderr.decode('utf-8', errors='ignore')
            logger.error(f'Restore failed: {error_msg}')
            return False

        logger.debug('Database restored')
        return True

    except subprocess.TimeoutExpired:
        logger.error('Database restore timed out (>300s)')
        return False
    except Exception as e:
        logger.error(f'Database restore error: {e}')
        return False

def sync_from_hf() -> bool:
    """
    Download backup from Hugging Face and restore database.
    """
    if not HF_TOKEN:
        logger.warning('HF_TOKEN not set - skipping restore')
        return False

    logger.debug('Downloading backup from Hugging Face...')

    try:
        api = HfApi(token=HF_TOKEN)

        # Get username
        username = HF_USERNAME
        if not username:
            try:
                user_info = api.whoami()
                username = user_info['name']
            except Exception:
                logger.warning('Failed to get HF username')
                return False

        dataset_id = f'{username}/{BACKUP_DATASET_NAME}'

        temp_dir = tempfile.mkdtemp()

        try:
            snapshot_path = api.hf_hub_download(
                repo_id=dataset_id,
                repo_type='dataset',
                filename='snapshots/latest.tar.gz',
                local_dir=temp_dir,
                local_dir_use_symlinks=False
            )
        except (RepositoryNotFoundError, EntryNotFoundError):
            logger.info(f'No backup found in {dataset_id} — fresh instance')
            return None  # not an error — just no backup yet

        logger.debug(f'Downloaded backup from {dataset_id}')

        # Extract tarball
        logger.debug('Extracting backup...')
        with tarfile.open(snapshot_path, 'r:gz') as tar:
            tar.extractall(temp_dir, filter='data')

        dump_file = Path(temp_dir) / 'paperclip.sql'
        if not dump_file.exists():
            logger.error('SQL dump not found in backup')
            return False

        # Restore database
        success = restore_database(str(dump_file))

        # Restore Paperclip data files if present
        paperclip_data_dir = Path(temp_dir) / 'paperclip-data'
        if paperclip_data_dir.exists():
            logger.debug('Restoring Paperclip data files...')
            import shutil
            try:
                for item in paperclip_data_dir.iterdir():
                    target = Path(PAPERCLIP_HOME) / item.name
                    if target.exists():
                        shutil.rmtree(target) if target.is_dir() else target.unlink()
                    shutil.copytree(item, target) if item.is_dir() else shutil.copy2(item, target)
                logger.debug('Data files restored')
            except Exception as e:
                logger.error(f'Failed to restore data files: {e}')

        return success

    except Exception as e:
        logger.error(f'Failed to restore from HF: {e}')
        return False

# ============================================================================
# Main Sync Operations
# ============================================================================

def sync_to_backup() -> bool:
    """Full backup operation: dump DB → create tarball → upload to HF"""
    logger.info('Syncing backup to HF Dataset...')

    status = read_status()

    try:
        # Step 1: Backup database
        dump_file, success = backup_database()
        if not success or not dump_file:
            status['last_error'] = 'Database backup failed'
            status['db_status'] = 'error'
            status['status'] = 'error'
            status['message'] = 'Database backup failed'
            write_status(status)
            return False

        # Step 2: Create tarball
        tarball_file, success = create_backup_tarball(dump_file)
        if not success or not tarball_file:
            status['last_error'] = 'Tarball creation failed'
            status['db_status'] = 'error'
            status['status'] = 'error'
            status['message'] = 'Tarball creation failed'
            write_status(status)
            return False

        # Step 3: Upload to HF
        success = sync_to_hf(tarball_file)

        # Update status
        status['last_sync_time'] = datetime.now(timezone.utc).isoformat().replace('+00:00', 'Z')
        status['db_status'] = 'connected' if success else 'error'
        status['last_error'] = None if success else 'Upload failed'
        status['status'] = 'connected' if success else 'error'
        status['message'] = 'Backup synced OK' if success else 'Backup sync failed'
        status['sync_count'] = status.get('sync_count', 0) + 1

        write_status(status)

        if success:
            logger.info('Backup synced OK')
        else:
            logger.warning('Backup sync failed')

        return success

    except Exception as e:
        logger.error(f'Backup operation failed: {e}')
        status['last_error'] = str(e)
        status['db_status'] = 'error'
        status['status'] = 'error'
        status['message'] = str(e)
        write_status(status)
        return False

def sync_from_backup() -> bool:
    """Full restore operation: download from HF → extract → restore DB"""
    logger.info('Restoring from HF Dataset...')

    status = read_status()

    try:
        success = sync_from_hf()

        if success is None:
            # No backup exists yet (first boot) — not an error
            status['db_status'] = 'connected'
            status['last_error'] = None
            status['status'] = 'connected'
            status['message'] = 'No prior backup — fresh instance'
            write_status(status)
            logger.info('No prior backup — fresh instance')
            return True
        elif success:
            status['db_status'] = 'connected'
            status['last_error'] = None
            status['status'] = 'connected'
            status['message'] = 'Restore OK'
            write_status(status)
            logger.info('Restore OK')
            return True
        else:
            status['db_status'] = 'error'
            status['last_error'] = 'Restore failed'
            status['status'] = 'error'
            status['message'] = 'Restore operation failed'
            write_status(status)
            logger.warning('Restore operation failed')
            return False

    except Exception as e:
        logger.error(f'Restore operation failed: {e}')
        status['last_error'] = str(e)
        status['db_status'] = 'error'
        status['status'] = 'error'
        status['message'] = str(e)
        write_status(status)
        return False

# ============================================================================
# CLI
# ============================================================================

def main():
    if len(sys.argv) < 2:
        print('Usage: python3 paperclip-sync.py <command>')
        print('Commands:')
        print('  sync     - Backup database to HF Dataset')
        print('  restore  - Restore database from HF Dataset backup')
        sys.exit(1)

    command = sys.argv[1]

    if command == 'sync':
        success = sync_to_backup()
        sys.exit(0 if success else 1)
    elif command == 'restore':
        success = sync_from_backup()
        sys.exit(0 if success else 1)
    else:
        print(f'Unknown command: {command}')
        sys.exit(1)

if __name__ == '__main__':
    main()
