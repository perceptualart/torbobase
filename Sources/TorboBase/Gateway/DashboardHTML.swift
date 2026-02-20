// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — Web Dashboard UI
// Self-contained HTML/CSS/JS dashboard served at /dashboard
// No external dependencies — pure inline HTML like WebChatHTML.swift

enum DashboardHTML {
    static let page = """
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<meta http-equiv="Content-Security-Policy" content="default-src 'self'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'; img-src 'self' data:; font-src 'self'; frame-src 'none'; object-src 'none'; base-uri 'self';">
<title>Torbo Base — Dashboard</title>
<link rel="icon" href="data:image/svg+xml,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 100 100'><circle cx='50' cy='50' r='40' fill='%23a855f7'/></svg>">
<style>
* { margin: 0; padding: 0; box-sizing: border-box; }
:root {
    --bg: #0a0a0d; --surface: #111114; --surface-hover: #18181c;
    --border: rgba(255,255,255,0.06); --border-light: rgba(255,255,255,0.1);
    --text: rgba(255,255,255,0.85); --text-dim: rgba(255,255,255,0.4); --text-bright: #fff;
    --cyan: #00e5ff; --cyan-dim: rgba(0,229,255,0.15); --purple: #a855f7; --purple-dim: rgba(168,85,247,0.15);
    --green: #22c55e; --green-dim: rgba(34,197,94,0.15);
    --yellow: #eab308; --yellow-dim: rgba(234,179,8,0.15);
    --orange: #f97316; --orange-dim: rgba(249,115,22,0.15);
    --red: #ef4444; --red-dim: rgba(239,68,68,0.15);
    --gray: rgba(255,255,255,0.2);
}
body {
    font-family: 'Futura', 'Futura-Medium', -apple-system, BlinkMacSystemFont, sans-serif;
    background: var(--bg); color: var(--text);
    height: 100vh; display: flex; overflow: hidden;
}
.sidebar {
    width: 240px; min-width: 240px; background: var(--surface);
    border-right: 1px solid var(--border); display: flex; flex-direction: column;
    height: 100vh;
}
.sidebar-logo {
    padding: 24px 20px 20px; border-bottom: 1px solid var(--border);
    display: flex; align-items: center; gap: 12px;
}
.sidebar-logo svg { width: 36px; height: 36px; flex-shrink: 0; }
.sidebar-logo h1 {
    font-size: 14px; font-weight: 700; letter-spacing: 2.5px; color: var(--text-bright);
}
.sidebar-logo .subtitle {
    font-size: 10px; letter-spacing: 1.5px; color: var(--text-dim);
    text-transform: uppercase; margin-top: 2px;
}
.sidebar-nav { flex: 1; padding: 12px 0; overflow-y: auto; }
.nav-item {
    display: flex; align-items: center; gap: 12px; padding: 10px 20px;
    cursor: pointer; color: var(--text-dim); font-size: 13px; font-weight: 500;
    letter-spacing: 0.5px; transition: all 0.15s; border-left: 3px solid transparent;
    user-select: none;
}
.nav-item:hover { color: var(--text); background: rgba(255,255,255,0.03); }
.nav-item.active {
    color: var(--cyan); background: var(--cyan-dim);
    border-left-color: var(--cyan);
}
.nav-item .nav-icon { width: 18px; text-align: center; font-size: 15px; flex-shrink: 0; }
.sidebar-footer {
    padding: 16px 20px; border-top: 1px solid var(--border);
    font-family: 'SF Mono', 'Menlo', monospace; font-size: 10px;
    color: var(--text-dim); letter-spacing: 0.5px;
}
.main { flex: 1; overflow-y: auto; padding: 32px; }
.tab-panel { display: none; }
.tab-panel.active { display: block; }
.page-title {
    font-size: 22px; font-weight: 700; letter-spacing: 1px; margin-bottom: 24px;
    color: var(--text-bright);
}
.section-label {
    font-size: 11px; text-transform: uppercase; letter-spacing: 2px;
    font-family: 'SF Mono', 'Menlo', monospace; color: var(--text-dim);
    margin-bottom: 12px; margin-top: 24px;
}
.section-label:first-child { margin-top: 0; }
.card {
    background: var(--surface); border: 1px solid var(--border);
    border-radius: 12px; padding: 20px; margin-bottom: 16px;
}
.card-grid {
    display: grid; grid-template-columns: repeat(auto-fill, minmax(220px, 1fr));
    gap: 16px; margin-bottom: 16px;
}
.stat-card {
    background: var(--surface); border: 1px solid var(--border);
    border-radius: 12px; padding: 20px;
}
.stat-card .stat-label {
    font-size: 11px; text-transform: uppercase; letter-spacing: 2px;
    font-family: 'SF Mono', 'Menlo', monospace; color: var(--text-dim);
    margin-bottom: 8px;
}
.stat-card .stat-value {
    font-size: 28px; font-weight: 700; color: var(--text-bright);
}
.stat-card .stat-sub { font-size: 12px; color: var(--text-dim); margin-top: 4px; }
.status-dot {
    display: inline-block; width: 8px; height: 8px; border-radius: 50%;
    margin-right: 6px; vertical-align: middle;
}
.status-dot.green { background: var(--green); box-shadow: 0 0 6px var(--green); }
.status-dot.red { background: var(--red); box-shadow: 0 0 6px var(--red); }
.status-dot.gray { background: var(--gray); }
.bridge-grid {
    display: grid; grid-template-columns: repeat(5, 1fr); gap: 12px; margin-top: 12px;
}
.bridge-item {
    background: var(--surface); border: 1px solid var(--border); border-radius: 10px;
    padding: 14px; text-align: center;
}
.bridge-item .bridge-name {
    font-size: 11px; text-transform: uppercase; letter-spacing: 1.5px;
    font-family: 'SF Mono', 'Menlo', monospace; color: var(--text-dim); margin-top: 8px;
}
.btn {
    display: inline-flex; align-items: center; justify-content: center; gap: 6px;
    padding: 8px 16px; border-radius: 8px; font-size: 13px; font-weight: 600;
    cursor: pointer; border: none; transition: all 0.15s;
    font-family: 'Futura', 'Futura-Medium', -apple-system, sans-serif;
    letter-spacing: 0.5px;
}
.btn-primary { background: var(--cyan); color: #000; }
.btn-primary:hover { filter: brightness(1.15); }
.btn-secondary { background: rgba(255,255,255,0.06); color: var(--text); border: 1px solid var(--border); }
.btn-secondary:hover { background: rgba(255,255,255,0.1); }
.btn-danger { background: var(--red-dim); color: var(--red); border: 1px solid rgba(239,68,68,0.2); }
.btn-danger:hover { background: rgba(239,68,68,0.25); }
.btn-sm { padding: 5px 12px; font-size: 12px; }
input[type="text"], input[type="password"], input[type="number"], textarea, select {
    background: var(--bg); border: 1px solid var(--border); border-radius: 8px;
    padding: 10px 14px; color: var(--text); font-size: 13px; width: 100%;
    font-family: 'SF Mono', 'Menlo', monospace; outline: none; transition: border 0.15s;
}
input:focus, textarea:focus, select:focus { border-color: var(--cyan); }
textarea { resize: vertical; min-height: 80px; }
select { cursor: pointer; }
.form-group { margin-bottom: 16px; }
.form-group label {
    display: block; font-size: 12px; font-weight: 600; letter-spacing: 0.5px;
    margin-bottom: 6px; color: var(--text-dim);
}
.table-wrap { overflow-x: auto; }
table { width: 100%; border-collapse: collapse; font-size: 13px; }
th {
    text-align: left; padding: 10px 14px; border-bottom: 1px solid var(--border);
    font-size: 11px; text-transform: uppercase; letter-spacing: 2px;
    font-family: 'SF Mono', 'Menlo', monospace; color: var(--text-dim); font-weight: 500;
}
td {
    padding: 10px 14px; border-bottom: 1px solid var(--border);
    font-family: 'SF Mono', 'Menlo', monospace; font-size: 12px;
}
tr:hover { background: rgba(255,255,255,0.02); }
.badge {
    display: inline-block; padding: 3px 8px; border-radius: 6px;
    font-size: 10px; font-weight: 600; letter-spacing: 1px;
    text-transform: uppercase; font-family: 'SF Mono', 'Menlo', monospace;
}
.badge-cyan { background: var(--cyan-dim); color: var(--cyan); }
.badge-green { background: var(--green-dim); color: var(--green); }
.badge-yellow { background: var(--yellow-dim); color: var(--yellow); }
.badge-orange { background: var(--orange-dim); color: var(--orange); }
.badge-red { background: var(--red-dim); color: var(--red); }
.badge-purple { background: var(--purple-dim); color: var(--purple); }
.badge-gray { background: rgba(255,255,255,0.06); color: var(--text-dim); }
.level-selector { display: flex; gap: 8px; margin: 16px 0; flex-wrap: wrap; }
.level-step {
    flex: 1; min-width: 100px; padding: 14px; border-radius: 10px; cursor: pointer;
    border: 2px solid var(--border); text-align: center; transition: all 0.2s;
}
.level-step:hover { border-color: var(--border-light); background: var(--surface-hover); }
.level-step.active { border-color: var(--cyan); }
.level-step .level-num {
    font-size: 22px; font-weight: 700; margin-bottom: 4px;
}
.level-step .level-name {
    font-size: 11px; text-transform: uppercase; letter-spacing: 1.5px;
    font-family: 'SF Mono', 'Menlo', monospace;
}
.search-bar {
    display: flex; gap: 10px; margin-bottom: 16px;
}
.search-bar input { flex: 1; }
.memory-card {
    background: var(--surface); border: 1px solid var(--border); border-radius: 10px;
    padding: 16px; margin-bottom: 10px;
}
.memory-card .mem-text { font-size: 13px; line-height: 1.5; margin-bottom: 8px; }
.memory-card .mem-meta {
    display: flex; gap: 10px; flex-wrap: wrap; align-items: center;
    font-size: 11px; font-family: 'SF Mono', 'Menlo', monospace; color: var(--text-dim);
}
.toggle {
    position: relative; width: 44px; height: 24px; cursor: pointer;
    display: inline-block; vertical-align: middle;
}
.toggle input { opacity: 0; width: 0; height: 0; }
.toggle .slider {
    position: absolute; top: 0; left: 0; right: 0; bottom: 0;
    background: rgba(255,255,255,0.1); border-radius: 12px; transition: 0.2s;
}
.toggle .slider:before {
    content: ''; position: absolute; height: 18px; width: 18px;
    left: 3px; bottom: 3px; background: var(--text-dim);
    border-radius: 50%; transition: 0.2s;
}
.toggle input:checked + .slider { background: var(--cyan); }
.toggle input:checked + .slider:before { transform: translateX(20px); background: #000; }
.modal-overlay {
    position: fixed; top: 0; left: 0; right: 0; bottom: 0;
    background: rgba(0,0,0,0.7); display: flex; align-items: center;
    justify-content: center; z-index: 1000; backdrop-filter: blur(4px);
}
.modal-overlay.hidden { display: none; }
.modal {
    background: var(--surface); border: 1px solid var(--border); border-radius: 16px;
    padding: 32px; width: 420px; max-width: 90vw; max-height: 85vh; overflow-y: auto;
}
.modal h2 {
    font-size: 18px; font-weight: 700; letter-spacing: 1px;
    margin-bottom: 20px; color: var(--text-bright);
}
.spinner {
    display: inline-block; width: 16px; height: 16px;
    border: 2px solid var(--border); border-top-color: var(--cyan);
    border-radius: 50%; animation: spin 0.6s linear infinite;
}
@keyframes spin { to { transform: rotate(360deg); } }
.error-msg {
    background: var(--red-dim); color: var(--red); padding: 10px 14px;
    border-radius: 8px; font-size: 12px; margin-bottom: 12px;
    font-family: 'SF Mono', 'Menlo', monospace;
}
.success-msg {
    background: var(--green-dim); color: var(--green); padding: 10px 14px;
    border-radius: 8px; font-size: 12px; margin-bottom: 12px;
    font-family: 'SF Mono', 'Menlo', monospace;
}
.empty-state {
    text-align: center; padding: 48px 24px; color: var(--text-dim);
    font-size: 14px;
}
.pagination {
    display: flex; align-items: center; justify-content: center;
    gap: 12px; margin-top: 16px; font-size: 13px;
}
.agent-card {
    background: var(--surface); border: 1px solid var(--border);
    border-radius: 12px; padding: 20px; margin-bottom: 12px;
    display: flex; align-items: flex-start; gap: 16px;
}
.agent-card .agent-info { flex: 1; }
.agent-card .agent-name {
    font-size: 16px; font-weight: 700; color: var(--text-bright); margin-bottom: 4px;
}
.agent-card .agent-role {
    font-size: 12px; color: var(--text-dim); margin-bottom: 8px;
    line-height: 1.4; max-height: 36px; overflow: hidden;
}
.agent-card .agent-actions { display: flex; gap: 8px; flex-shrink: 0; }
.flex-row { display: flex; align-items: center; gap: 12px; }
.flex-between { display: flex; align-items: center; justify-content: space-between; }
.mb-8 { margin-bottom: 8px; }
.mb-16 { margin-bottom: 16px; }
.mt-16 { margin-top: 16px; }
@media (max-width: 768px) {
    .sidebar { display: none; }
    .main { padding: 16px; }
    .card-grid { grid-template-columns: 1fr; }
    .bridge-grid { grid-template-columns: repeat(3, 1fr); }
    .level-selector { flex-direction: column; }
}
</style>
</head>
<body>

<!-- Auth Modal -->
<div id="authModal" class="modal-overlay">
    <div class="modal">
        <h2>Torbo Base</h2>
        <p style="color:var(--text-dim);font-size:13px;margin-bottom:20px;">Enter your server token to continue.</p>
        <div id="authError" class="error-msg" style="display:none;"></div>
        <div class="form-group">
            <label>Token</label>
            <input type="password" id="authTokenInput" placeholder="Bearer token..." onkeydown="if(event.key==='Enter')doAuth()">
        </div>
        <button class="btn btn-primary" style="width:100%" onclick="doAuth()">Authenticate</button>
    </div>
</div>

<!-- Sidebar -->
<div class="sidebar">
    <div class="sidebar-logo">
        <svg viewBox="0 0 36 36" fill="none">
            <circle cx="18" cy="18" r="16" stroke="#a855f7" stroke-width="2" fill="rgba(168,85,247,0.1)"/>
            <circle cx="18" cy="18" r="6" fill="#a855f7" opacity="0.8"/>
            <circle cx="18" cy="18" r="11" stroke="#00e5ff" stroke-width="1" opacity="0.4"/>
        </svg>
        <div>
            <h1>TORBO BASE</h1>
            <div class="subtitle">Dashboard</div>
        </div>
    </div>
    <div class="sidebar-nav">
        <div class="nav-item active" onclick="switchTab('overview')" data-tab="overview">
            <span class="nav-icon">&#9673;</span> Overview
        </div>
        <div class="nav-item" onclick="switchTab('apikeys')" data-tab="apikeys">
            <span class="nav-icon">&#9919;</span> API Keys
        </div>
        <div class="nav-item" onclick="switchTab('access')" data-tab="access">
            <span class="nav-icon">&#9737;</span> Access Control
        </div>
        <div class="nav-item" onclick="switchTab('agents')" data-tab="agents">
            <span class="nav-icon">&#9830;&#9830;</span> Agents
        </div>
        <div class="nav-item" onclick="switchTab('library')" data-tab="library">
            <span class="nav-icon">&#9782;</span> Library
        </div>
        <div class="nav-item" onclick="switchTab('logs')" data-tab="logs">
            <span class="nav-icon">&#9776;</span> Logs
        </div>
        <div class="nav-item" onclick="switchTab('settings')" data-tab="settings">
            <span class="nav-icon">&#9881;</span> Arkhe
        </div>
    </div>
    <div class="sidebar-footer">
        <span id="versionLabel">TORBO BASE</span>
    </div>
</div>

<!-- Main Content -->
<div class="main">

    <!-- Overview Tab -->
    <div id="tab-overview" class="tab-panel active">
        <div class="page-title">Overview</div>
        <div id="overviewError" class="error-msg" style="display:none;"></div>
        <div class="section-label">Server</div>
        <div class="card-grid" id="overviewCards">
            <div class="stat-card">
                <div class="stat-label">Status</div>
                <div class="stat-value" id="ovServerStatus"><span class="spinner"></span></div>
            </div>
            <div class="stat-card">
                <div class="stat-label">Uptime</div>
                <div class="stat-value" id="ovUptime">--</div>
            </div>
            <div class="stat-card">
                <div class="stat-label">Ollama</div>
                <div class="stat-value" id="ovOllama">--</div>
                <div class="stat-sub" id="ovOllamaModels"></div>
            </div>
            <div class="stat-card">
                <div class="stat-label">Connections</div>
                <div class="stat-value" id="ovConnections">--</div>
            </div>
            <div class="stat-card">
                <div class="stat-label">Requests</div>
                <div class="stat-value" id="ovRequests">--</div>
                <div class="stat-sub" id="ovBlocked"></div>
            </div>
            <div class="stat-card">
                <div class="stat-label">LoA Scrolls</div>
                <div class="stat-value" id="ovScrolls">--</div>
                <div class="stat-sub" id="ovEntities"></div>
            </div>
            <div class="stat-card">
                <div class="stat-label">Access Level</div>
                <div class="stat-value" id="ovAccessLevel">--</div>
                <div class="stat-sub" id="ovAccessName"></div>
            </div>
        </div>
        <div class="section-label">Bridges</div>
        <div class="bridge-grid" id="bridgeGrid">
            <div class="bridge-item"><span class="status-dot gray" id="bridgeTelegram"></span><div class="bridge-name">Telegram</div></div>
            <div class="bridge-item"><span class="status-dot gray" id="bridgeDiscord"></span><div class="bridge-name">Discord</div></div>
            <div class="bridge-item"><span class="status-dot gray" id="bridgeSlack"></span><div class="bridge-name">Slack</div></div>
            <div class="bridge-item"><span class="status-dot gray" id="bridgeSignal"></span><div class="bridge-name">Signal</div></div>
            <div class="bridge-item"><span class="status-dot gray" id="bridgeWhatsapp"></span><div class="bridge-name">WhatsApp</div></div>
        </div>
    </div>

    <!-- API Keys Tab -->
    <div id="tab-apikeys" class="tab-panel">
        <div class="page-title">API Keys</div>
        <div id="apikeysError" class="error-msg" style="display:none;"></div>
        <div id="apikeysSuccess" class="success-msg" style="display:none;"></div>
        <div class="card">
            <div class="table-wrap">
                <table>
                    <thead>
                        <tr><th>Provider</th><th>Status</th><th>Key</th><th></th></tr>
                    </thead>
                    <tbody id="apikeysBody">
                        <tr><td colspan="4" style="text-align:center;"><span class="spinner"></span></td></tr>
                    </tbody>
                </table>
            </div>
        </div>
    </div>

    <!-- Access Control Tab -->
    <div id="tab-access" class="tab-panel">
        <div class="page-title">Access Control</div>
        <div id="accessError" class="error-msg" style="display:none;"></div>
        <div id="accessSuccess" class="success-msg" style="display:none;"></div>
        <div class="card">
            <div class="section-label" style="margin-top:0;">Current Level</div>
            <div style="font-size:32px;font-weight:700;margin-bottom:4px;" id="accessCurrentNum">--</div>
            <div style="font-size:14px;color:var(--text-dim);" id="accessCurrentName">Loading...</div>
        </div>
        <div class="section-label">Select Level</div>
        <div class="level-selector" id="levelSelector"></div>
        <div class="card" id="levelDescription" style="margin-top:16px;">
            <div style="font-size:13px;line-height:1.6;color:var(--text-dim);" id="levelDescText">Select a level above to see its description.</div>
        </div>
    </div>

    <!-- Agents Tab -->
    <div id="tab-agents" class="tab-panel">
        <div class="flex-between mb-16">
            <div class="page-title" style="margin-bottom:0;">Agents</div>
            <button class="btn btn-primary" onclick="showAgentModal()">+ New Agent</button>
        </div>
        <div id="agentsError" class="error-msg" style="display:none;"></div>
        <div id="agentsList"><div class="empty-state"><span class="spinner"></span></div></div>
    </div>

    <!-- Library Tab -->
    <div id="tab-library" class="tab-panel">
        <div class="page-title">Library of Alexandria</div>
        <div id="libraryError" class="error-msg" style="display:none;"></div>
        <div class="card-grid" id="loaStats">
            <div class="stat-card">
                <div class="stat-label">Scrolls</div>
                <div class="stat-value" id="loaScrollCount">--</div>
            </div>
            <div class="stat-card">
                <div class="stat-label">Entities</div>
                <div class="stat-value" id="loaEntityCount">--</div>
            </div>
            <div class="stat-card">
                <div class="stat-label">Categories</div>
                <div class="stat-value" id="loaCatCount">--</div>
            </div>
        </div>
        <div class="section-label">Search</div>
        <div class="search-bar">
            <input type="text" id="loaSearchInput" placeholder="Search the library..." onkeydown="if(event.key==='Enter')loaSearch()">
            <button class="btn btn-primary" onclick="loaSearch()">Recall</button>
            <button class="btn btn-secondary" onclick="loaBrowse(0)">Browse All</button>
        </div>
        <div id="loaResults"></div>
        <div class="section-label mt-16">Teach the Library</div>
        <div class="card">
            <div class="form-group">
                <label>Text</label>
                <textarea id="loaTeachText" placeholder="Teach the library something new..."></textarea>
            </div>
            <div style="display:flex;gap:12px;">
                <div class="form-group" style="flex:1;">
                    <label>Category</label>
                    <select id="loaTeachCat">
                        <option value="fact">Fact</option>
                        <option value="preference">Preference</option>
                        <option value="episode">Episode</option>
                        <option value="project">Project</option>
                        <option value="technical">Technical</option>
                        <option value="personal">Personal</option>
                        <option value="identity">Identity</option>
                    </select>
                </div>
                <div class="form-group" style="flex:1;">
                    <label>Importance: <span id="loaImpVal">0.5</span></label>
                    <input type="range" min="0" max="1" step="0.05" value="0.5" id="loaTeachImp"
                           oninput="document.getElementById('loaImpVal').textContent=this.value"
                           style="background:transparent;border:none;padding:0;">
                </div>
            </div>
            <button class="btn btn-primary" onclick="loaTeach()">Teach</button>
        </div>
        <div class="section-label mt-16">Entities</div>
        <div id="loaEntitiesWrap"><div class="empty-state"><span class="spinner"></span></div></div>
    </div>

    <!-- Logs Tab -->
    <div id="tab-logs" class="tab-panel">
        <div class="page-title">Audit Log</div>
        <div id="logsError" class="error-msg" style="display:none;"></div>
        <div style="display:flex;gap:12px;margin-bottom:16px;align-items:center;">
            <input type="text" id="logFilterPath" placeholder="Filter by path..." style="flex:1;" onkeydown="if(event.key==='Enter')loadLogs()">
            <label style="display:flex;align-items:center;gap:6px;font-size:12px;color:var(--text-dim);cursor:pointer;white-space:nowrap;">
                <input type="checkbox" id="logFilterGranted" style="width:auto;" onchange="loadLogs()"> Granted only
            </label>
            <button class="btn btn-secondary btn-sm" onclick="loadLogs()">Filter</button>
        </div>
        <div class="card">
            <div class="table-wrap">
                <table>
                    <thead>
                        <tr><th>Time</th><th>IP</th><th>Method</th><th>Path</th><th>Level</th><th>Result</th></tr>
                    </thead>
                    <tbody id="logsBody">
                        <tr><td colspan="6" style="text-align:center;"><span class="spinner"></span></td></tr>
                    </tbody>
                </table>
            </div>
        </div>
        <div class="pagination" id="logsPagination"></div>
    </div>

    <!-- Settings Tab -->
    <div id="tab-settings" class="tab-panel">
        <div class="page-title">Settings</div>
        <div id="settingsError" class="error-msg" style="display:none;"></div>
        <div id="settingsSuccess" class="success-msg" style="display:none;"></div>
        <div class="card">
            <div style="display:grid;grid-template-columns:1fr 1fr;gap:16px;">
                <div class="form-group">
                    <label>Log Level</label>
                    <select id="setLogLevel">
                        <option value="debug">Debug</option>
                        <option value="info">Info</option>
                        <option value="warn">Warn</option>
                        <option value="error">Error</option>
                    </select>
                </div>
                <div class="form-group">
                    <label>Rate Limit (req/min)</label>
                    <input type="number" id="setRateLimit" min="1" max="1000" value="60">
                </div>
                <div class="form-group">
                    <label>Max Concurrent Tasks: <span id="setTasksVal">3</span></label>
                    <input type="range" min="1" max="10" value="3" id="setMaxTasks"
                           oninput="document.getElementById('setTasksVal').textContent=this.value"
                           style="background:transparent;border:none;padding:0;">
                </div>
                <div class="form-group">
                    <label>LAN Access</label>
                    <div style="margin-top:6px;">
                        <label class="toggle">
                            <input type="checkbox" id="setLanAccess">
                            <span class="slider"></span>
                        </label>
                    </div>
                </div>
            </div>
            <div class="form-group" style="margin-top:8px;">
                <label style="display:flex;align-items:center;gap:8px;">
                    System Prompt
                    <label class="toggle" style="margin-left:auto;">
                        <input type="checkbox" id="setSysPromptEnabled">
                        <span class="slider"></span>
                    </label>
                </label>
                <textarea id="setSysPrompt" rows="4" placeholder="Custom system prompt..." style="margin-top:8px;"></textarea>
            </div>
            <button class="btn btn-primary" onclick="saveSettings()">Save Settings</button>
        </div>
    </div>

</div>

<!-- Agent Create Modal -->
<div id="agentModal" class="modal-overlay hidden">
    <div class="modal">
        <h2>New Agent</h2>
        <div id="agentModalError" class="error-msg" style="display:none;"></div>
        <div class="form-group">
            <label>Name</label>
            <input type="text" id="agentName" placeholder="e.g. Research Assistant">
        </div>
        <div class="form-group">
            <label>Role</label>
            <input type="text" id="agentRole" placeholder="e.g. You are a research assistant...">
        </div>
        <div class="form-group">
            <label>Personality</label>
            <textarea id="agentPersonality" placeholder="Describe personality traits..."></textarea>
        </div>
        <div style="display:flex;gap:12px;justify-content:flex-end;">
            <button class="btn btn-secondary" onclick="hideAgentModal()">Cancel</button>
            <button class="btn btn-primary" onclick="createAgent()">Create</button>
        </div>
    </div>
</div>

<script>
var TOKEN = '';
var currentTab = 'overview';
var overviewTimer = null;
var logsOffset = 0;
var logsTotal = 0;
var loaBrowseOffset = 0;

var LEVELS = [
    {num: 0, name: 'Off', color: 'gray', desc: 'Server is completely locked. No requests processed.'},
    {num: 1, name: 'Chat', color: 'green', desc: 'Chat-only access. Agents can converse but cannot read or modify files.'},
    {num: 2, name: 'Read', color: 'cyan', desc: 'Agents can read files within allowed directory scopes.'},
    {num: 3, name: 'Write', color: 'yellow', desc: 'Agents can read and write files within allowed directory scopes.'},
    {num: 4, name: 'Execute', color: 'orange', desc: 'Agents can execute shell commands and code within sandboxes.'},
    {num: 5, name: 'Full', color: 'red', desc: 'Full system access. Agents can perform any operation without restrictions.'}
];

// --- API Helper ---
function api(method, path, body) {
    var opts = {
        method: method,
        headers: {'Content-Type': 'application/json'}
    };
    if (TOKEN) {
        opts.headers['Authorization'] = 'Bearer ' + TOKEN;
    }
    if (body) {
        opts.body = JSON.stringify(body);
    }
    return fetch(path, opts).then(function(r) {
        if (r.status === 401) {
            TOKEN = '';
            localStorage.removeItem('torbo_dashboard_token');
            showAuth();
            return Promise.reject(new Error('Unauthorized'));
        }
        return r.json().then(function(data) {
            if (!r.ok) {
                return Promise.reject(new Error(data.error || data.message || ('HTTP ' + r.status)));
            }
            return data;
        });
    });
}

function showError(id, msg) {
    var el = document.getElementById(id);
    if (el) { el.textContent = msg; el.style.display = 'block'; }
}
function hideError(id) {
    var el = document.getElementById(id);
    if (el) { el.style.display = 'none'; }
}
function showSuccess(id, msg) {
    var el = document.getElementById(id);
    if (el) { el.textContent = msg; el.style.display = 'block'; setTimeout(function() { el.style.display = 'none'; }, 3000); }
}
function esc(s) {
    if (!s) return '';
    var d = document.createElement('div');
    d.appendChild(document.createTextNode(s));
    return d.innerHTML;
}
function shortTime(iso) {
    try {
        var d = new Date(iso);
        return d.toLocaleString();
    } catch(e) { return iso || '--'; }
}

// --- Auth ---
function showAuth() {
    document.getElementById('authModal').classList.remove('hidden');
}
function hideAuth() {
    document.getElementById('authModal').classList.add('hidden');
}
function doAuth() {
    var input = document.getElementById('authTokenInput');
    var t = input.value.trim();
    if (!t) { showError('authError', 'Token is required.'); return; }
    hideError('authError');
    TOKEN = t;
    fetch('/v1/dashboard/status', {
        headers: {'Authorization': 'Bearer ' + t}
    }).then(function(r) {
        if (r.ok) {
            localStorage.setItem('torbo_dashboard_token', t);
            hideAuth();
            loadOverview();
        } else {
            TOKEN = '';
            showError('authError', 'Invalid token. Server returned ' + r.status + '.');
        }
    }).catch(function(e) {
        TOKEN = '';
        showError('authError', 'Connection failed: ' + e.message);
    });
}

// --- Tab Switching ---
function switchTab(tab) {
    currentTab = tab;
    var panels = document.querySelectorAll('.tab-panel');
    for (var i = 0; i < panels.length; i++) {
        panels[i].classList.remove('active');
    }
    document.getElementById('tab-' + tab).classList.add('active');
    var navs = document.querySelectorAll('.nav-item');
    for (var j = 0; j < navs.length; j++) {
        navs[j].classList.toggle('active', navs[j].getAttribute('data-tab') === tab);
    }
    if (overviewTimer) { clearInterval(overviewTimer); overviewTimer = null; }
    if (tab === 'overview') { loadOverview(); overviewTimer = setInterval(loadOverview, 30000); }
    if (tab === 'apikeys') { loadApiKeys(); }
    if (tab === 'access') { loadAccess(); }
    if (tab === 'agents') { loadAgents(); }
    if (tab === 'library') { loadLibrary(); }
    if (tab === 'logs') { logsOffset = 0; loadLogs(); }
    if (tab === 'settings') { loadSettings(); }
}

// --- Overview ---
function loadOverview() {
    hideError('overviewError');
    api('GET', '/v1/dashboard/status').then(function(data) {
        var srv = data.server || {};
        var running = srv.running;
        document.getElementById('ovServerStatus').innerHTML =
            '<span class="status-dot ' + (running ? 'green' : 'red') + '"></span>' +
            (running ? 'Running' : 'Stopped');
        document.getElementById('ovUptime').textContent = srv.uptime || '--';
        document.getElementById('versionLabel').textContent = 'TORBO BASE v' + (srv.version || '?');

        var ol = data.ollama || {};
        document.getElementById('ovOllama').innerHTML =
            '<span class="status-dot ' + (ol.running ? 'green' : 'red') + '"></span>' +
            (ol.running ? 'Running' : 'Stopped');
        var models = ol.models || [];
        document.getElementById('ovOllamaModels').textContent = models.length + ' model' + (models.length !== 1 ? 's' : '');

        var conn = data.connections || {};
        document.getElementById('ovConnections').textContent = conn.active || 0;
        document.getElementById('ovRequests').textContent = conn.totalRequests || 0;
        document.getElementById('ovBlocked').textContent = (conn.blockedRequests || 0) + ' blocked';

        var loa = data.loa || {};
        document.getElementById('ovScrolls').textContent = loa.totalScrolls || 0;
        document.getElementById('ovEntities').textContent = (loa.entityCount || 0) + ' entities';

        var al = data.accessLevel || {};
        document.getElementById('ovAccessLevel').textContent = al.current != null ? al.current : '--';
        document.getElementById('ovAccessName').textContent = al.name || '';

        var br = data.bridges || {};
        setBridgeDot('bridgeTelegram', br.telegram);
        setBridgeDot('bridgeDiscord', br.discord);
        setBridgeDot('bridgeSlack', br.slack);
        setBridgeDot('bridgeSignal', br.signal);
        setBridgeDot('bridgeWhatsapp', br.whatsapp);
    }).catch(function(e) {
        if (e.message !== 'Unauthorized') showError('overviewError', 'Failed to load status: ' + e.message);
    });
}

function setBridgeDot(id, active) {
    var el = document.getElementById(id);
    if (el) {
        el.className = 'status-dot ' + (active ? 'green' : 'gray');
    }
}

// --- API Keys ---
var apiKeysData = [];
function loadApiKeys() {
    hideError('apikeysError');
    api('GET', '/v1/config/apikeys').then(function(data) {
        apiKeysData = data.keys || [];
        renderApiKeys();
    }).catch(function(e) {
        if (e.message !== 'Unauthorized') showError('apikeysError', 'Failed to load API keys: ' + e.message);
    });
}

function renderApiKeys() {
    var tb = document.getElementById('apikeysBody');
    if (!apiKeysData.length) {
        tb.innerHTML = '<tr><td colspan="4" class="empty-state">No API key providers found.</td></tr>';
        return;
    }
    var html = '';
    for (var i = 0; i < apiKeysData.length; i++) {
        var k = apiKeysData[i];
        var statusBadge = k.configured
            ? '<span class="badge badge-green">Configured</span>'
            : '<span class="badge badge-gray">Not Set</span>';
        html += '<tr>';
        html += '<td style="color:var(--text-bright);font-weight:600;">' + esc(k.provider) + '</td>';
        html += '<td>' + statusBadge + '</td>';
        html += '<td id="keyDisplay-' + i + '">';
        html += '<span style="color:var(--text-dim);">' + esc(k.masked || '--') + '</span>';
        html += '</td>';
        html += '<td>';
        html += '<div id="keyView-' + i + '">';
        html += '<button class="btn btn-secondary btn-sm" onclick="editApiKey(' + i + ')">Edit</button>';
        html += '</div>';
        html += '<div id="keyEdit-' + i + '" style="display:none;">';
        html += '<div style="display:flex;gap:6px;">';
        html += '<input type="text" id="keyInput-' + i + '" placeholder="Paste API key..." style="font-size:11px;padding:5px 8px;">';
        html += '<button class="btn btn-primary btn-sm" onclick="saveApiKey(' + i + ')">Save</button>';
        html += '<button class="btn btn-secondary btn-sm" onclick="cancelApiKey(' + i + ')">X</button>';
        html += '</div>';
        html += '</div>';
        html += '</td>';
        html += '</tr>';
    }
    tb.innerHTML = html;
}

function editApiKey(idx) {
    document.getElementById('keyView-' + idx).style.display = 'none';
    document.getElementById('keyEdit-' + idx).style.display = 'block';
    document.getElementById('keyInput-' + idx).focus();
}

function cancelApiKey(idx) {
    document.getElementById('keyView-' + idx).style.display = 'block';
    document.getElementById('keyEdit-' + idx).style.display = 'none';
    document.getElementById('keyInput-' + idx).value = '';
}

function saveApiKey(idx) {
    var k = apiKeysData[idx];
    var val = document.getElementById('keyInput-' + idx).value.trim();
    if (!val) return;
    hideError('apikeysError');
    var body = {keys: {}};
    body.keys[k.provider] = val;
    api('PUT', '/v1/config/apikeys', body).then(function() {
        showSuccess('apikeysSuccess', 'API key for ' + k.provider + ' updated.');
        loadApiKeys();
    }).catch(function(e) {
        if (e.message !== 'Unauthorized') showError('apikeysError', 'Failed to save key: ' + e.message);
    });
}

// --- Access Control ---
function loadAccess() {
    hideError('accessError');
    api('GET', '/v1/config/settings').then(function(data) {
        var level = data.accessLevel != null ? data.accessLevel : 0;
        renderAccessLevel(level);
    }).catch(function(e) {
        if (e.message !== 'Unauthorized') showError('accessError', 'Failed to load access level: ' + e.message);
    });
}

function renderAccessLevel(current) {
    document.getElementById('accessCurrentNum').textContent = current;
    document.getElementById('accessCurrentName').textContent = LEVELS[current] ? LEVELS[current].name : 'Unknown';
    var sel = document.getElementById('levelSelector');
    var html = '';
    for (var i = 0; i < LEVELS.length; i++) {
        var lv = LEVELS[i];
        var colorVar = 'var(--' + lv.color + ')';
        var isActive = i === current;
        html += '<div class="level-step' + (isActive ? ' active' : '') + '" ';
        html += 'onclick="setAccessLevel(' + i + ')" ';
        html += 'style="' + (isActive ? 'border-color:' + colorVar + ';background:var(--' + lv.color + '-dim);' : '') + '">';
        html += '<div class="level-num" style="color:' + colorVar + ';">' + lv.num + '</div>';
        html += '<div class="level-name" style="color:' + (isActive ? colorVar : 'var(--text-dim)') + ';">' + esc(lv.name) + '</div>';
        html += '</div>';
    }
    sel.innerHTML = html;
    document.getElementById('levelDescText').textContent = LEVELS[current] ? LEVELS[current].desc : '';
}

function setAccessLevel(level) {
    hideError('accessError');
    api('PUT', '/v1/config/settings', {accessLevel: level}).then(function() {
        renderAccessLevel(level);
        showSuccess('accessSuccess', 'Access level changed to ' + level + ' (' + LEVELS[level].name + ')');
    }).catch(function(e) {
        if (e.message !== 'Unauthorized') showError('accessError', 'Failed to set level: ' + e.message);
    });
}

// --- Agents ---
function loadAgents() {
    hideError('agentsError');
    api('GET', '/v1/agents').then(function(data) {
        var agents = data.agents || data || [];
        if (!Array.isArray(agents)) agents = [];
        renderAgents(agents);
    }).catch(function(e) {
        if (e.message !== 'Unauthorized') showError('agentsError', 'Failed to load agents: ' + e.message);
    });
}

function renderAgents(agents) {
    var wrap = document.getElementById('agentsList');
    if (!agents.length) {
        wrap.innerHTML = '<div class="empty-state">No agents configured.</div>';
        return;
    }
    var html = '';
    for (var i = 0; i < agents.length; i++) {
        var a = agents[i];
        var lvl = a.accessLevel != null ? a.accessLevel : 0;
        var lv = LEVELS[lvl] || LEVELS[0];
        var badgeClass = 'badge-' + lv.color;
        html += '<div class="agent-card">';
        html += '<div class="agent-info">';
        html += '<div class="agent-name">' + esc(a.name || a.id) + ' ';
        if (a.isBuiltIn) html += '<span class="badge badge-purple">Built-in</span>';
        html += '</div>';
        html += '<div class="agent-role">' + esc(a.role || a.personality || '') + '</div>';
        html += '<span class="badge ' + badgeClass + '">Level ' + lvl + ' - ' + esc(lv.name) + '</span>';
        html += '</div>';
        html += '<div class="agent-actions">';
        if (!a.isBuiltIn) {
            html += '<button class="btn btn-danger btn-sm" onclick="deleteAgent(\'' + esc(a.id) + '\')">Delete</button>';
        }
        html += '</div>';
        html += '</div>';
    }
    wrap.innerHTML = html;
}

function showAgentModal() {
    document.getElementById('agentModal').classList.remove('hidden');
    hideError('agentModalError');
    document.getElementById('agentName').value = '';
    document.getElementById('agentRole').value = '';
    document.getElementById('agentPersonality').value = '';
    document.getElementById('agentName').focus();
}

function hideAgentModal() {
    document.getElementById('agentModal').classList.add('hidden');
}

function createAgent() {
    var name = document.getElementById('agentName').value.trim();
    var role = document.getElementById('agentRole').value.trim();
    var personality = document.getElementById('agentPersonality').value.trim();
    if (!name) { showError('agentModalError', 'Name is required.'); return; }
    hideError('agentModalError');
    api('POST', '/v1/agents', {name: name, role: role, personality: personality}).then(function() {
        hideAgentModal();
        loadAgents();
    }).catch(function(e) {
        if (e.message !== 'Unauthorized') showError('agentModalError', 'Failed to create agent: ' + e.message);
    });
}

function deleteAgent(id) {
    if (!confirm('Delete agent "' + id + '"? This cannot be undone.')) return;
    api('DELETE', '/v1/agents/' + encodeURIComponent(id)).then(function() {
        loadAgents();
    }).catch(function(e) {
        if (e.message !== 'Unauthorized') showError('agentsError', 'Failed to delete agent: ' + e.message);
    });
}

// --- Library ---
function loadLibrary() {
    hideError('libraryError');
    api('GET', '/v1/dashboard/status').then(function(data) {
        var loa = data.loa || {};
        document.getElementById('loaScrollCount').textContent = loa.totalScrolls || 0;
        document.getElementById('loaEntityCount').textContent = loa.entityCount || 0;
        var cats = loa.categories || {};
        var catCount = 0;
        for (var c in cats) { if (cats.hasOwnProperty(c)) catCount++; }
        document.getElementById('loaCatCount').textContent = catCount;
    }).catch(function(e) {
        if (e.message !== 'Unauthorized') showError('libraryError', 'Failed to load LoA stats: ' + e.message);
    });
    loadEntities();
}

function loaSearch() {
    var q = document.getElementById('loaSearchInput').value.trim();
    if (!q) return;
    hideError('libraryError');
    var wrap = document.getElementById('loaResults');
    wrap.innerHTML = '<div class="empty-state"><span class="spinner"></span> Searching...</div>';
    api('GET', '/v1/loa/recall?q=' + encodeURIComponent(q)).then(function(data) {
        var results = data.results || data.memories || [];
        if (!results.length) {
            wrap.innerHTML = '<div class="empty-state">No results found.</div>';
            return;
        }
        renderMemories(wrap, results);
    }).catch(function(e) {
        if (e.message !== 'Unauthorized') {
            wrap.innerHTML = '';
            showError('libraryError', 'Search failed: ' + e.message);
        }
    });
}

function loaBrowse(offset) {
    loaBrowseOffset = offset || 0;
    hideError('libraryError');
    var wrap = document.getElementById('loaResults');
    wrap.innerHTML = '<div class="empty-state"><span class="spinner"></span> Loading...</div>';
    api('GET', '/v1/loa/browse?page=' + (Math.floor(loaBrowseOffset / 20) + 1) + '&sort=newest').then(function(data) {
        var results = data.scrolls || data.results || data.memories || [];
        if (!results.length) {
            wrap.innerHTML = '<div class="empty-state">The library is empty.</div>';
            return;
        }
        renderMemories(wrap, results);
        var total = data.total || results.length;
        if (total > 20) {
            var pag = '<div class="pagination">';
            if (loaBrowseOffset > 0) {
                pag += '<button class="btn btn-secondary btn-sm" onclick="loaBrowse(' + (loaBrowseOffset - 20) + ')">Previous</button>';
            }
            pag += '<span style="color:var(--text-dim);font-size:12px;">' + (loaBrowseOffset + 1) + '-' + Math.min(loaBrowseOffset + 20, total) + ' of ' + total + '</span>';
            if (loaBrowseOffset + 20 < total) {
                pag += '<button class="btn btn-secondary btn-sm" onclick="loaBrowse(' + (loaBrowseOffset + 20) + ')">Next</button>';
            }
            pag += '</div>';
            wrap.innerHTML += pag;
        }
    }).catch(function(e) {
        if (e.message !== 'Unauthorized') {
            wrap.innerHTML = '';
            showError('libraryError', 'Browse failed: ' + e.message);
        }
    });
}

function renderMemories(wrap, mems) {
    var html = '';
    for (var i = 0; i < mems.length; i++) {
        var m = mems[i];
        var catBadge = '<span class="badge badge-cyan">' + esc(m.category || 'unknown') + '</span>';
        var impBadge = '<span class="badge badge-purple">' + (m.importance != null ? m.importance.toFixed(2) : '?') + '</span>';
        html += '<div class="memory-card">';
        html += '<div class="mem-text">' + esc(m.text || m.content || '') + '</div>';
        html += '<div class="mem-meta">';
        html += catBadge + ' ' + impBadge;
        if (m.score != null) html += ' <span>score: ' + m.score.toFixed(3) + '</span>';
        if (m.createdAt || m.created_at || m.timestamp) {
            html += ' <span>' + shortTime(m.createdAt || m.created_at || m.timestamp) + '</span>';
        }
        html += '</div>';
        html += '</div>';
    }
    wrap.innerHTML = html;
}

function loaTeach() {
    var text = document.getElementById('loaTeachText').value.trim();
    if (!text) return;
    var cat = document.getElementById('loaTeachCat').value;
    var imp = parseFloat(document.getElementById('loaTeachImp').value);
    hideError('libraryError');
    api('POST', '/v1/loa/teach', {text: text, category: cat, importance: imp}).then(function() {
        document.getElementById('loaTeachText').value = '';
        loadLibrary();
    }).catch(function(e) {
        if (e.message !== 'Unauthorized') showError('libraryError', 'Teach failed: ' + e.message);
    });
}

function loadEntities() {
    var wrap = document.getElementById('loaEntitiesWrap');
    api('GET', '/v1/loa/entities').then(function(data) {
        var ents = data.entities || [];
        if (!ents.length) {
            wrap.innerHTML = '<div class="empty-state">No entities tracked yet.</div>';
            return;
        }
        var html = '<div style="display:flex;flex-wrap:wrap;gap:8px;">';
        for (var i = 0; i < ents.length; i++) {
            var e = ents[i];
            var name = e.name || e.entity || e;
            var count = e.mentions || e.count || '';
            html += '<span class="badge badge-cyan" style="font-size:11px;padding:5px 10px;">';
            html += esc(typeof name === 'string' ? name : JSON.stringify(name));
            if (count) html += ' (' + count + ')';
            html += '</span>';
        }
        html += '</div>';
        wrap.innerHTML = html;
    }).catch(function(e) {
        if (e.message !== 'Unauthorized') {
            wrap.innerHTML = '<div class="empty-state" style="color:var(--red);">Failed to load entities.</div>';
        }
    });
}

// --- Logs ---
function loadLogs() {
    hideError('logsError');
    var filterPath = document.getElementById('logFilterPath').value.trim();
    var grantedOnly = document.getElementById('logFilterGranted').checked;
    var url = '/v1/audit/log?limit=50&offset=' + logsOffset;
    api('GET', url).then(function(data) {
        var entries = data.entries || [];
        logsTotal = data.total || 0;

        if (filterPath) {
            entries = entries.filter(function(e) {
                return e.path && e.path.indexOf(filterPath) !== -1;
            });
        }
        if (grantedOnly) {
            entries = entries.filter(function(e) { return e.granted; });
        }

        var tb = document.getElementById('logsBody');
        if (!entries.length) {
            tb.innerHTML = '<tr><td colspan="6" class="empty-state">No log entries.</td></tr>';
        } else {
            var html = '';
            for (var i = 0; i < entries.length; i++) {
                var e = entries[i];
                var resultColor = e.granted ? 'var(--green)' : 'var(--red)';
                var resultText = e.granted ? 'Granted' : 'Blocked';
                html += '<tr>';
                html += '<td>' + shortTime(e.timestamp) + '</td>';
                html += '<td>' + esc(e.clientIP) + '</td>';
                html += '<td>' + esc(e.method) + '</td>';
                html += '<td style="max-width:200px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;">' + esc(e.path) + '</td>';
                html += '<td>' + (e.requiredLevel != null ? e.requiredLevel : '-') + '</td>';
                html += '<td style="color:' + resultColor + ';font-weight:600;">' + resultText + '</td>';
                html += '</tr>';
            }
            tb.innerHTML = html;
        }

        var pag = document.getElementById('logsPagination');
        if (logsTotal > 50) {
            var pagHtml = '';
            if (logsOffset > 0) {
                pagHtml += '<button class="btn btn-secondary btn-sm" onclick="logsOffset-=50;loadLogs()">Previous</button>';
            }
            pagHtml += '<span style="color:var(--text-dim);font-size:12px;">';
            pagHtml += (logsOffset + 1) + '-' + Math.min(logsOffset + 50, logsTotal) + ' of ' + logsTotal;
            pagHtml += '</span>';
            if (logsOffset + 50 < logsTotal) {
                pagHtml += '<button class="btn btn-secondary btn-sm" onclick="logsOffset+=50;loadLogs()">Next</button>';
            }
            pag.innerHTML = pagHtml;
        } else {
            pag.innerHTML = '';
        }
    }).catch(function(e) {
        if (e.message !== 'Unauthorized') showError('logsError', 'Failed to load logs: ' + e.message);
    });
}

// --- Settings ---
function loadSettings() {
    hideError('settingsError');
    api('GET', '/v1/config/settings').then(function(data) {
        document.getElementById('setLogLevel').value = data.logLevel || 'info';
        document.getElementById('setRateLimit').value = data.rateLimit || 60;
        document.getElementById('setMaxTasks').value = data.maxConcurrentTasks || 3;
        document.getElementById('setTasksVal').textContent = data.maxConcurrentTasks || 3;
        document.getElementById('setLanAccess').checked = data.lanAccess || false;
        document.getElementById('setSysPromptEnabled').checked = data.systemPromptEnabled || false;
        document.getElementById('setSysPrompt').value = data.systemPrompt || '';
    }).catch(function(e) {
        if (e.message !== 'Unauthorized') showError('settingsError', 'Failed to load settings: ' + e.message);
    });
}

function saveSettings() {
    hideError('settingsError');
    var body = {
        logLevel: document.getElementById('setLogLevel').value,
        rateLimit: parseInt(document.getElementById('setRateLimit').value, 10) || 60,
        maxConcurrentTasks: parseInt(document.getElementById('setMaxTasks').value, 10) || 3,
        lanAccess: document.getElementById('setLanAccess').checked,
        systemPromptEnabled: document.getElementById('setSysPromptEnabled').checked,
        systemPrompt: document.getElementById('setSysPrompt').value
    };
    api('PUT', '/v1/config/settings', body).then(function() {
        showSuccess('settingsSuccess', 'Settings saved.');
    }).catch(function(e) {
        if (e.message !== 'Unauthorized') showError('settingsError', 'Failed to save settings: ' + e.message);
    });
}

// --- Init ---
function initApp() {
    var params = new URLSearchParams(window.location.search);
    var urlToken = params.get('token');
    var storedToken = localStorage.getItem('torbo_dashboard_token');
    var t = urlToken || storedToken || '';
    if (!t) {
        showAuth();
        return;
    }
    TOKEN = t;
    fetch('/v1/dashboard/status', {
        headers: {'Authorization': 'Bearer ' + t}
    }).then(function(r) {
        if (r.ok) {
            localStorage.setItem('torbo_dashboard_token', t);
            hideAuth();
            if (urlToken) {
                window.history.replaceState({}, '', window.location.pathname);
            }
            loadOverview();
            overviewTimer = setInterval(loadOverview, 30000);
        } else {
            TOKEN = '';
            localStorage.removeItem('torbo_dashboard_token');
            showAuth();
        }
    }).catch(function() {
        showAuth();
    });
}

initApp();
</script>
</body>
</html>
"""
}
