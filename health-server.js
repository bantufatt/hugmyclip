// Single public entrypoint for HF Spaces: local dashboard + reverse proxy to Paperclip.
const http = require("http");
const fs = require("fs");
const net = require("net");

const PORT = 7861;
const APP_PORT = 3100;
const APP_HOST = "127.0.0.1";
const startTime = Date.now();
const INVITE_URL_FILE = "/tmp/invite-url.txt";
const SYNC_STATUS_FILE = "/tmp/sync-status.json";
const CLOUDFLARE_KEEPALIVE_STATUS_FILE =
  "/tmp/huggingclip-cloudflare-keepalive-status.json";

function parseRequestUrl(url) {
  try {
    return new URL(url, "http://localhost");
  } catch {
    return new URL("http://localhost/");
  }
}

function getSyncStatus() {
  try {
    if (fs.existsSync(SYNC_STATUS_FILE)) {
      const raw = fs.readFileSync(SYNC_STATUS_FILE, "utf8");
      const parsed = JSON.parse(raw);
      if (!parsed.status && parsed.db_status) parsed.status = parsed.db_status;
      if (!parsed.message) {
        if (parsed.last_error) parsed.message = parsed.last_error;
        else if (parsed.last_sync_time)
          parsed.message = `Last sync: ${parsed.last_sync_time}`;
      }
      return parsed;
    }
  } catch {}
  if (process.env.HF_TOKEN) {
    return {
      status: "configured",
      message: `Backup is enabled. Waiting for sync window (${process.env.SYNC_INTERVAL || 3600}s).`,
    };
  }
  return { status: "disabled", message: "HF_TOKEN not set" };
}

function getKeepaliveStatus() {
  try {
    if (fs.existsSync(CLOUDFLARE_KEEPALIVE_STATUS_FILE)) {
      return JSON.parse(
        fs.readFileSync(CLOUDFLARE_KEEPALIVE_STATUS_FILE, "utf8"),
      );
    }
  } catch {}
  return null;
}

async function getPluginStatus(timeoutMs = 1500) {
  // Try several possible Paperclip API endpoints to list plugins/tools
  const paths = ["/api/plugins", "/api/tools", "/api/plugins/list"];
  for (const p of paths) {
    try {
      const result = await new Promise((resolve) => {
        const req = http.get(
          { hostname: APP_HOST, port: APP_PORT, path: p, timeout: timeoutMs },
          (res) => {
            let body = "";
            res.on("data", (c) => (body += c));
            res.on("end", () => resolve({ statusCode: res.statusCode, body }));
          },
        );
        req.on("timeout", () => {
          req.destroy();
          resolve(null);
        });
        req.on("error", () => resolve(null));
      });

      if (!result || !result.body) continue;
      if (result.statusCode >= 400) continue;

      try {
        const parsed = JSON.parse(result.body);
        let list = [];
        if (Array.isArray(parsed)) list = parsed;
        else if (parsed.plugins && Array.isArray(parsed.plugins))
          list = parsed.plugins;
        else if (parsed.tools && Array.isArray(parsed.tools))
          list = parsed.tools;
        else if (parsed.items && Array.isArray(parsed.items))
          list = parsed.items;

        // Normalize list to array of names/ids
        const names = list.map((it) =>
          typeof it === "string" ? it : it.name || it.id || JSON.stringify(it),
        );
        return { count: names.length, list: names };
      } catch (e) {
        continue;
      }
    } catch (e) {
      continue;
    }
  }
  return null;
}

function getInviteUrl() {
  try {
    if (fs.existsSync(INVITE_URL_FILE)) {
      return fs.readFileSync(INVITE_URL_FILE, "utf8").trim();
    }
  } catch {}
  return null;
}

function probeAppHealth(timeoutMs = 1500) {
  return new Promise((resolve) => {
    const request = http.get(
      {
        hostname: APP_HOST,
        port: APP_PORT,
        path: "/api/health",
        timeout: timeoutMs,
      },
      (response) => {
        response.resume();
        resolve(response.statusCode >= 200 && response.statusCode < 400);
      },
    );
    request.on("timeout", () => {
      request.destroy();
      resolve(false);
    });
    request.on("error", () => resolve(false));
  });
}

function formatUptime(ms) {
  const total = Math.floor(ms / 1000);
  const days = Math.floor(total / 86400);
  const hours = Math.floor((total % 86400) / 3600);
  const minutes = Math.floor((total % 3600) / 60);
  if (days) return `${days}d ${hours}h ${minutes}m`;
  if (hours) return `${hours}h ${minutes}m`;
  return `${minutes}m`;
}

function escapeHtml(value) {
  return String(value)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function toneBadge(label, tone = "neutral") {
  return `<span class="badge ${tone}">${escapeHtml(label)}</span>`;
}

function renderTile({
  title,
  value,
  detail = "",
  tone = "neutral",
  meta = "",
}) {
  return `<article class="tile ${tone}">
    <div class="tile-head">
      <span class="tile-title">${escapeHtml(title)}</span>
      <span class="tile-dot"></span>
    </div>
    <div class="tile-value">${value}</div>
    ${detail ? `<div class="tile-detail">${detail}</div>` : ""}
    ${meta ? `<div class="tile-meta">${meta}</div>` : ""}
  </article>`;
}

function renderDashboard(data) {
  const syncStatus = String(data.sync?.status || "unknown");
  const syncTone = ["success", "restored", "synced", "configured"].includes(
    syncStatus,
  )
    ? "ok"
    : syncStatus === "disabled"
      ? "warn"
      : "neutral";
  const backupDetail = data.sync?.message
    ? escapeHtml(data.sync.message)
    : "No status yet";

  // Show a concise status meta for the Backup tile (last sync time or sync count)
  const backupMeta = (() => {
    if (data.sync?.last_sync_time) {
      return `Last sync: <code>${escapeHtml(data.sync.last_sync_time)}</code>`;
    }
    if (typeof data.sync?.sync_count === "number") {
      return `Syncs: ${String(data.sync.sync_count)}`;
    }
    return "";
  })();

  const keepaliveConfigured = data.keepalive?.configured === true;
  const keepaliveStatus = String(
    data.keepalive?.status ||
      (process.env.CLOUDFLARE_WORKERS_TOKEN ? "pending" : "not configured"),
  );
  const keepAliveTone = keepaliveConfigured
    ? "ok"
    : process.env.CLOUDFLARE_WORKERS_TOKEN
      ? "warn"
      : "neutral";
  const keepAliveDetail = keepaliveConfigured
    ? `Pinging <code>${escapeHtml(data.keepalive.targetUrl || "/health")}</code>`
    : process.env.CLOUDFLARE_WORKERS_TOKEN
      ? "Worker pending or failed"
      : "Not configured";

  const inviteUrl = getInviteUrl();

  const pluginCount = Number(data.plugins?.count || 0);
  const pluginList = Array.isArray(data.plugins?.list) ? data.plugins.list : [];

  const tiles = [
    renderTile({
      title: "Paperclip Core",
      value: toneBadge(
        data.appReady ? "Online" : "Booting",
        data.appReady ? "ok" : "warn",
      ),
      detail: `Backend Port ${APP_PORT}`,
      tone: data.appReady ? "ok" : "warn",
    }),
    renderTile({
      title: "Database",
      value: toneBadge("PostgreSQL", "ok"),
      detail: "Embedded cluster active",
      tone: "ok",
    }),
    renderTile({
      title: "Runtime",
      value: escapeHtml(data.uptimeHuman),
      detail: `Exposed on port ${PORT}`,
      tone: "neutral",
    }),
    renderTile({
      title: "Backup",
      value: toneBadge(syncStatus.toUpperCase(), syncTone),
      detail: backupDetail,
      tone: syncTone,
      meta: data.sync?.timestamp
        ? `${backupMeta} | <span class="local-time" data-iso="${data.sync.timestamp}"></span>`
        : backupMeta,
    }),
    renderTile({
      title: "Plugins",
      value: toneBadge(
        pluginCount ? String(pluginCount) : "0",
        pluginCount ? "ok" : "neutral",
      ),
      detail: pluginCount
        ? escapeHtml(pluginList.slice(0, 6).join(", "))
        : "No plugins loaded",
      meta: pluginCount > 6 ? `+${pluginCount - 6} more` : "",
      tone: pluginCount ? "ok" : "neutral",
    }),
    renderTile({
      title: "Keep Awake",
      value: toneBadge(
        keepaliveConfigured ? "CF Cron" : keepaliveStatus.toUpperCase(),
        keepAliveTone,
      ),
      detail: keepAliveDetail,
      tone: keepAliveTone,
    }),
  ].join("");

  return `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>HuggingClip</title>
  <style>
    :root { color-scheme: dark; --bg:#08080f; --panel:#12111b; --panel2:#151421; --line:#26243a; --text:#f6f4ff; --muted:#7f7a9e; --soft:#b8b3d7; --good:#22c55e; --warn:#f5c542; --bad:#fb7185;}
    * { box-sizing:border-box; }
    body { margin:0; min-height:100vh; font-family:Inter, ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; background:var(--bg); color:var(--text); font-size:13px; }
    main { width:min(720px, calc(100% - 32px)); margin:0 auto; padding:36px 0 44px; }
    header { text-align:center; margin-bottom:22px; }
    h1 { margin:0; font-size:1.65rem; line-height:1; letter-spacing:0; }
    .subtitle { margin-top:12px; color:var(--muted); font-size:.72rem; text-transform:uppercase; letter-spacing:.14em; font-weight:800; }
    .hero-action { display:flex; width:100%; min-height:46px; align-items:center; justify-content:center; border-radius:8px; background:#fff; color:#000; text-decoration:none; font-weight:850; font-size:.98rem; margin:24px 0 20px; transition: opacity 0.15s ease; }
    .hero-action:hover { opacity: 0.9; }
    .invite-banner { background:rgba(245,197,66,.1); border:1px solid rgba(245,197,66,.2); border-radius:8px; padding:12px 16px; margin-bottom:20px; display:flex; flex-direction:column; gap:6px; }
    .invite-banner span { color:var(--warn); font-weight:850; font-size:.75rem; text-transform:uppercase; }
    .invite-banner code { font-size:1rem; padding:8px; margin-top:4px; display:block; overflow-wrap:anywhere; }
    .overview { display:grid; grid-template-columns:repeat(2, minmax(0, 1fr)); gap:10px; margin-bottom:10px; }
    .tile { border:1px solid var(--line); background:var(--panel); border-radius:11px; padding:18px; min-height:124px; display:flex; flex-direction:column; gap:10px; position:relative; }
    .tile.ok { border-color:rgba(34,197,94,.22); }
    .tile.warn { border-color:rgba(245,197,66,.24); }
    .tile.off { border-color:rgba(251,113,133,.28); }
    .tile-head { display:flex; align-items:center; justify-content:space-between; gap:12px; }
    .tile-title { color:var(--muted); font-size:.67rem; letter-spacing:.18em; text-transform:uppercase; font-weight:850; }
    .tile-dot { width:7px; height:7px; border-radius:50%; background:var(--line); }
    .tile.ok .tile-dot { background:var(--good); }
    .tile.warn .tile-dot { background:var(--warn); }
    .tile.off .tile-dot { background:var(--bad); }
    .tile-value { font-size:1.12rem; font-weight:850; overflow-wrap:anywhere; }
    .tile-detail { color:var(--soft); line-height:1.45; font-size:.83rem; }
    .tile-meta { color:var(--muted); line-height:1.4; font-size:.75rem; margin-top:auto; overflow-wrap:anywhere; }

    code { background:#232234; border:1px solid #34324c; border-radius:6px; padding:2px 6px; color:var(--text); font-size:.9em; }
    .badge { display:inline-flex; align-items:center; width:max-content; border:1px solid var(--line); border-radius:999px; padding:5px 10px; font-size:.72rem; font-weight:850; line-height:1; text-transform:uppercase; }
    .badge.ok { color:var(--good); border-color:rgba(34,197,94,.34); background:rgba(34,197,94,.11); }
    .badge.warn { color:var(--warn); border-color:rgba(245,197,66,.34); background:rgba(245,197,66,.11); }
    .badge.off { color:var(--bad); border-color:rgba(251,113,133,.34); background:rgba(251,113,133,.11); }
    .badge.neutral { color:var(--soft); }
    footer { color:var(--muted); text-align:center; font-size:.74rem; margin-top:18px; }
    footer .live { color:var(--good); }
    @media (max-width: 700px) { .overview { grid-template-columns:1fr; } main { width:min(100% - 22px, 720px); padding-top:28px; } }
  </style>
</head>
<body>
  <main>
    <header>
      <h1>HuggingClip</h1>
      <div class="subtitle">Paperclip Orchestrator Dashboard</div>
    </header>
    ${
      inviteUrl
        ? `
    <div class="invite-banner">
      <span>Admin Setup Required</span>
      <code>${escapeHtml(inviteUrl)}</code>
    </div>`
        : ""
    }
    <a class="hero-action" href="/app/" target="_blank" rel="noopener noreferrer">Open Paperclip UI -></a>
    <section class="overview">
      ${tiles}
    </section>
    <footer>Built by <a href="https://github.com/somratpro" target="_blank" rel="noopener noreferrer" style="color: var(--accent); text-decoration: none;">@somratpro</a></footer>
  </main>
  <script>
    document.querySelectorAll('.local-time').forEach(el => {
      const date = new Date(el.getAttribute('data-iso'));
      if (!isNaN(date)) {
        el.textContent = 'At ' + date.toLocaleTimeString();
      }
    });
  </script>
</body>
</html>`;
}

const server = http.createServer(async (req, res) => {
  const url = parseRequestUrl(req.url);
  const pathname = url.pathname;

  if (pathname === "/health") {
    const appReady = await probeAppHealth();
    const plugins = await getPluginStatus();
    res.writeHead(appReady ? 200 : 503, { "Content-Type": "application/json" });
    return res.end(
      JSON.stringify({
        status: appReady ? "ok" : "booting",
        uptime: formatUptime(Date.now() - startTime),
        sync: getSyncStatus(),
        keepalive: getKeepaliveStatus(),
        plugins: plugins,
      }),
    );
  }

  if (pathname === "/" || pathname === "/dashboard") {
    const appReady = await probeAppHealth();
    const plugins = await getPluginStatus();
    res.writeHead(200, { "Content-Type": "text/html" });
    return res.end(
      renderDashboard({
        uptimeHuman: formatUptime(Date.now() - startTime),
        appReady,
        sync: getSyncStatus(),
        keepalive: getKeepaliveStatus(),
        plugins: plugins,
      }),
    );
  }

  // Proxy logic to Paperclip (port 3100)
  const proxyHeaders = {
    ...req.headers,
    host: `${APP_HOST}:${APP_PORT}`,
    "x-forwarded-for": req.socket.remoteAddress,
    "x-forwarded-host": req.headers.host,
    "x-forwarded-proto": "https",
  };

  const proxyReq = http.request(
    {
      hostname: APP_HOST,
      port: APP_PORT,
      path: pathname + url.search,
      method: req.method,
      headers: proxyHeaders,
    },
    (proxyRes) => {
      res.writeHead(proxyRes.statusCode, proxyRes.headers);
      proxyRes.pipe(res);
      proxyRes.on("error", () => res.end());
    },
  );

  req.on("error", () => proxyReq.destroy());
  res.on("error", () => proxyReq.destroy());
  proxyReq.on("error", () => {
    if (!res.headersSent) {
      res.writeHead(503, { "Content-Type": "application/json" });
      res.end(
        JSON.stringify({
          status: "starting",
          message: "Paperclip is booting...",
        }),
      );
    } else {
      res.end();
    }
  });

  req.pipe(proxyReq);
});

server.on("upgrade", (req, socket, head) => {
  const url = parseRequestUrl(req.url);
  const proxyPath = url.pathname;
  const proxySocket = net.connect(APP_PORT, APP_HOST, () => {
    proxySocket.write(
      `${req.method} ${proxyPath}${url.search} HTTP/${req.httpVersion}\r\n`,
    );
    for (let i = 0; i < req.rawHeaders.length; i += 2) {
      proxySocket.write(`${req.rawHeaders[i]}: ${req.rawHeaders[i + 1]}\r\n`);
    }
    proxySocket.write("\r\n");
    if (head && head.length) proxySocket.write(head);
    proxySocket.pipe(socket).pipe(proxySocket);
  });
  proxySocket.on("error", () => socket.destroy());
});

server.timeout = 0;
server.keepAliveTimeout = 65000;
server.listen(PORT, "0.0.0.0", () =>
  console.log(`HuggingClip Dashboard on ${PORT} -> Paperclip on ${APP_PORT}`),
);
