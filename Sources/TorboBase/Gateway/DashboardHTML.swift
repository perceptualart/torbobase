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
    padding: 20px 20px 16px; border-bottom: 1px solid var(--border);
    display: flex; flex-direction: column; align-items: center; gap: 8px;
    text-align: center;
}
.sidebar-logo canvas { width: 144px; height: 144px; flex-shrink: 0; }
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
.agent-card .agent-actions { display: flex; gap: 8px; flex-shrink: 0; flex-wrap: wrap; justify-content: flex-end; }
.agent-card .agent-actions .btn { white-space: nowrap; }
.agent-card { cursor: pointer; transition: border-color 0.15s; }
.agent-card:hover { border-color: var(--border-light); }
.agent-detail-header {
    display: flex; align-items: center; justify-content: space-between;
    gap: 12px; margin-bottom: 24px; flex-wrap: wrap;
}
.agent-detail-actions {
    display: flex; gap: 8px; flex-shrink: 0; flex-wrap: wrap;
}
.agent-detail-actions .btn { white-space: nowrap; min-width: max-content; }
.flex-row { display: flex; align-items: center; gap: 12px; }
.flex-between { display: flex; align-items: center; justify-content: space-between; }
.mb-8 { margin-bottom: 8px; }
.mb-16 { margin-bottom: 16px; }
.mt-16 { margin-top: 16px; }
.home-orb-wrap {
    display: flex; justify-content: center; align-items: center;
    margin-bottom: 24px;
}
.home-orb-wrap canvas { width: 200px; height: 200px; }
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
        <canvas id="sidebarOrb" width="288" height="288"></canvas>
        <h1>TORBO BASE</h1>
        <div class="subtitle">Dashboard</div>
    </div>
    <div class="sidebar-nav">
        <div class="nav-item active" onclick="switchTab('overview')" data-tab="overview">
            <span class="nav-icon">&#9673;</span> Dashboard
        </div>
        <div class="nav-item" onclick="switchTab('vox')" data-tab="vox">
            <span class="nav-icon">&#9835;</span> Vox
        </div>
        <div class="nav-item" onclick="switchTab('logos')" data-tab="logos">
            <span class="nav-icon">&#9993;</span> Logos
        </div>
        <div class="nav-item" onclick="switchTab('agents')" data-tab="agents">
            <span class="nav-icon">&#9830;&#9830;</span> Agents
        </div>
        <div class="nav-item" onclick="switchTab('skills')" data-tab="skills">
            <span class="nav-icon">&#9881;</span> Skills
        </div>
        <div class="nav-item" onclick="switchTab('models')" data-tab="models">
            <span class="nav-icon">&#9674;</span> Models
        </div>
        <div class="nav-item" onclick="switchTab('lexis')" data-tab="lexis">
            <span class="nav-icon">&#9782;</span> Lexis
        </div>
        <div class="nav-item" onclick="switchTab('security')" data-tab="security">
            <span class="nav-icon">&#9888;</span> Security
        </div>
        <div class="nav-item" onclick="switchTab('settings')" data-tab="settings">
            <span class="nav-icon">&#9878;</span> Arkhe
        </div>
    </div>
    <div class="sidebar-footer">
        <div style="margin-bottom:8px;">
            <a href="#" onclick="switchTab('legal');return false;" style="color:var(--text-dim);font-size:9px;text-decoration:none;letter-spacing:0.5px;">Terms</a>
            <span style="color:var(--text-dim);font-size:9px;margin:0 4px;">&middot;</span>
            <a href="#" onclick="switchTab('legal');return false;" style="color:var(--text-dim);font-size:9px;text-decoration:none;letter-spacing:0.5px;">Privacy</a>
            <span style="color:var(--text-dim);font-size:9px;margin:0 4px;">&middot;</span>
            <a href="#" onclick="switchTab('legal');return false;" style="color:var(--text-dim);font-size:9px;text-decoration:none;letter-spacing:0.5px;">Principles</a>
            <span style="color:var(--text-dim);font-size:9px;margin:0 4px;">&middot;</span>
            <a href="mailto:feedback@torbo.app" style="color:var(--cyan);font-size:9px;text-decoration:none;letter-spacing:0.5px;">Feedback</a>
        </div>
        <span id="versionLabel">TORBO BASE</span>
    </div>
</div>

<!-- Main Content -->
<div class="main">

    <!-- Dashboard Tab -->
    <div id="tab-overview" class="tab-panel active">
        <div class="page-title">Dashboard</div>
        <div style="font-size:13px;color:var(--text-dim);margin-bottom:24px;margin-top:-20px;">overview</div>
        <div id="overviewError" class="error-msg" style="display:none;"></div>

        <!-- Animated Orb -->
        <div class="home-orb-wrap">
            <canvas id="homeOrb" width="400" height="400"></canvas>
        </div>

        <!-- Kill Switch -->
        <div id="killSwitchCard" class="card" style="border:1px solid rgba(255,68,68,0.3);background:rgba(255,68,68,0.06);margin-bottom:20px;display:flex;align-items:center;justify-content:space-between;gap:16px;">
            <div>
                <div style="font-weight:700;font-size:14px;color:#ff4444;">Emergency Kill Switch</div>
                <div style="font-size:12px;color:var(--text-dim);margin-top:4px;">Instantly set access level to OFF — blocks all agent actions</div>
            </div>
            <button id="killSwitchBtn" onclick="activateKillSwitch()" style="background:#ff4444;color:#fff;border:none;border-radius:8px;padding:10px 24px;font-weight:700;font-size:13px;cursor:pointer;white-space:nowrap;">LOCK SERVER</button>
        </div>

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
        <!-- Agent List View -->
        <div id="agentListView">
            <div class="flex-between mb-16">
                <div class="page-title" style="margin-bottom:0;">Agents</div>
                <button class="btn btn-primary" onclick="showAgentModal()">+ New Agent</button>
            </div>
            <div id="agentsError" class="error-msg" style="display:none;"></div>
            <div id="agentsList"><div class="empty-state"><span class="spinner"></span></div></div>
        </div>
        <!-- Agent Detail/Settings View -->
        <div id="agentDetailView" style="display:none;">
            <div class="agent-detail-header">
                <div style="display:flex;align-items:center;gap:12px;min-width:0;flex:1;">
                    <button class="btn btn-secondary btn-sm" onclick="hideAgentDetail()" style="flex-shrink:0;">&larr; Back</button>
                    <div class="page-title" style="margin-bottom:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;" id="agentDetailName">Agent</div>
                </div>
                <div class="agent-detail-actions">
                    <button class="btn btn-secondary btn-sm" onclick="exportAgent(selectedAgentId)">Export</button>
                    <button class="btn btn-secondary btn-sm" onclick="resetAgent(selectedAgentId)">Reset</button>
                    <button class="btn btn-danger btn-sm" id="agentDetailDeleteBtn" onclick="deleteAgentFromDetail()">Delete</button>
                </div>
            </div>
            <div id="agentDetailContent"></div>
        </div>
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

    <!-- Legal Tab -->
    <div id="tab-legal" class="tab-panel">
        <div class="page-title">Legal &amp; Principles</div>

        <!-- Constitution / Our Principles -->
        <div class="section-label">Our Principles</div>
        <div class="card" style="border-left:3px solid var(--cyan);">
            <div style="display:flex;align-items:center;gap:12px;margin-bottom:16px;">
                <span style="font-size:28px;">&#9878;</span>
                <div>
                    <div style="font-size:16px;font-weight:700;color:var(--text-bright);">The Torbo Constitution</div>
                    <div style="font-size:12px;color:var(--text-dim);">Built into every conversation. Cannot be overridden.</div>
                </div>
            </div>

            <div style="margin-bottom:20px;">
                <div style="font-size:13px;color:var(--text-dim);line-height:1.6;margin-bottom:16px;">
                    Torbo is an AI assistant built to work for you &mdash; not on you. These principles are built into every conversation, every agent, and every interaction.
                </div>

                <div style="font-size:12px;font-weight:600;color:var(--green);letter-spacing:1px;text-transform:uppercase;margin-bottom:8px;">Torbo will always:</div>
                <div style="font-size:13px;color:var(--text);line-height:1.8;margin-bottom:16px;padding-left:12px;border-left:2px solid rgba(34,197,94,0.3);">
                    &#10003; Protect your privacy &mdash; your data belongs to you<br>
                    &#10003; Be honest &mdash; truth over comfort, always<br>
                    &#10003; Explain its reasoning &mdash; not just what, but why<br>
                    &#10003; Respect your data &mdash; export, delete, or close anytime<br>
                    &#10003; Work in your interest &mdash; help, not manipulate<br>
                    &#10003; Provide help in a crisis &mdash; emergency resources, never dismissal
                </div>

                <div style="font-size:12px;font-weight:600;color:var(--red);letter-spacing:1px;text-transform:uppercase;margin-bottom:8px;">Torbo will never:</div>
                <div style="font-size:13px;color:var(--text);line-height:1.8;margin-bottom:16px;padding-left:12px;border-left:2px solid rgba(239,68,68,0.3);">
                    &#10007; Generate spam, scams, or malware<br>
                    &#10007; Facilitate harassment, bullying, or abuse<br>
                    &#10007; Generate CSAM or exploit minors<br>
                    &#10007; Create content promoting violence or terrorism<br>
                    &#10007; Impersonate real people for misinformation<br>
                    &#10007; Enable illegal surveillance<br>
                    &#10007; Claim to be human
                </div>

                <div style="font-size:12px;font-weight:600;color:var(--yellow);letter-spacing:1px;text-transform:uppercase;margin-bottom:8px;">If Torbo refuses:</div>
                <div style="font-size:13px;color:var(--text);line-height:1.8;margin-bottom:16px;padding-left:12px;border-left:2px solid rgba(234,179,8,0.3);">
                    It will always explain why, suggest alternatives, and never just say no without reason.
                </div>

                <div style="font-size:12px;font-weight:600;color:var(--cyan);letter-spacing:1px;text-transform:uppercase;margin-bottom:8px;">Your rights:</div>
                <div style="font-size:13px;color:var(--text);line-height:1.8;padding-left:12px;border-left:2px solid rgba(0,229,255,0.3);">
                    Delete your data anytime &bull; Export everything &bull; Close your account &bull; Report violations
                </div>
            </div>
            <div style="font-size:11px;color:var(--text-dim);font-style:italic;">
                Questions? Contact <span style="color:var(--cyan);">constitution@torbo.app</span>
            </div>
        </div>

        <!-- Legal Documents -->
        <div class="section-label" style="margin-top:32px;">Legal Documents</div>
        <div class="card-grid">
            <div class="card" style="cursor:pointer;" onclick="window.open('/legal/terms-of-service.html','_blank')">
                <div style="font-size:15px;font-weight:600;color:var(--text-bright);margin-bottom:6px;">Terms of Service</div>
                <div style="font-size:12px;color:var(--text-dim);line-height:1.5;">Service description, subscriptions, acceptable use, liability, dispute resolution.</div>
                <div style="margin-top:10px;"><span class="badge badge-cyan">View &rarr;</span></div>
            </div>
            <div class="card" style="cursor:pointer;" onclick="window.open('/legal/privacy-policy.html','_blank')">
                <div style="font-size:15px;font-weight:600;color:var(--text-bright);margin-bottom:6px;">Privacy Policy</div>
                <div style="font-size:12px;color:var(--text-dim);line-height:1.5;">What we collect, what we don't, local vs. cloud data, your rights, third-party services.</div>
                <div style="margin-top:10px;"><span class="badge badge-green">View &rarr;</span></div>
            </div>
            <div class="card" style="cursor:pointer;" onclick="window.open('/legal/acceptable-use-policy.html','_blank')">
                <div style="font-size:15px;font-weight:600;color:var(--text-bright);margin-bottom:6px;">Acceptable Use Policy</div>
                <div style="font-size:12px;color:var(--text-dim);line-height:1.5;">Prohibited content, infrastructure abuse, account integrity, violation consequences.</div>
                <div style="margin-top:10px;"><span class="badge badge-yellow">View &rarr;</span></div>
            </div>
            <div class="card" style="cursor:pointer;" onclick="window.open('/legal/torbo-constitution.html','_blank')">
                <div style="font-size:15px;font-weight:600;color:var(--text-bright);margin-bottom:6px;">Torbo Constitution</div>
                <div style="font-size:12px;color:var(--text-dim);line-height:1.5;">Our principles in plain language. What Torbo will and won't do.</div>
                <div style="margin-top:10px;"><span class="badge badge-purple">View &rarr;</span></div>
            </div>
        </div>

        <div style="text-align:center;margin-top:24px;font-size:11px;color:var(--text-dim);">
            &copy; 2026 Perceptual Art LLC. All rights reserved. &bull;
            <span style="color:var(--cyan);">legal@torbo.app</span>
        </div>
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

        <div class="section-label" style="margin-top:24px;">About</div>
        <div class="card">
            <div style="display:flex;gap:16px;flex-wrap:wrap;">
                <a href="#" onclick="switchTab('legal');return false;" style="text-decoration:none;display:flex;align-items:center;gap:8px;padding:10px 16px;background:rgba(0,229,255,0.06);border:1px solid rgba(0,229,255,0.15);border-radius:10px;color:var(--cyan);font-size:13px;font-weight:600;">
                    &#9878; Our Principles
                </a>
                <a href="/legal/terms-of-service.html" target="_blank" style="text-decoration:none;display:flex;align-items:center;gap:8px;padding:10px 16px;background:rgba(255,255,255,0.04);border:1px solid var(--border);border-radius:10px;color:var(--text-dim);font-size:13px;font-weight:500;">
                    Terms of Service
                </a>
                <a href="/legal/privacy-policy.html" target="_blank" style="text-decoration:none;display:flex;align-items:center;gap:8px;padding:10px 16px;background:rgba(255,255,255,0.04);border:1px solid var(--border);border-radius:10px;color:var(--text-dim);font-size:13px;font-weight:500;">
                    Privacy Policy
                </a>
                <a href="/legal/acceptable-use-policy.html" target="_blank" style="text-decoration:none;display:flex;align-items:center;gap:8px;padding:10px 16px;background:rgba(255,255,255,0.04);border:1px solid var(--border);border-radius:10px;color:var(--text-dim);font-size:13px;font-weight:500;">
                    Acceptable Use
                </a>
            </div>
        </div>
    </div>

    <!-- Models Tab -->
    <div id="tab-models" class="tab-panel">
        <div class="page-title">Models</div>
        <div id="modelsError" class="error-msg" style="display:none;"></div>
        <div class="section-label">Ollama Models</div>
        <div id="modelsGrid" class="card-grid"></div>
        <div class="card" style="margin-top:16px;">
            <div style="display:flex;gap:8px;align-items:center;">
                <input type="text" id="pullModelName" placeholder="Model name (e.g. llama3.2:3b)" style="flex:1;">
                <button class="btn btn-primary" onclick="pullModel()">Pull Model</button>
            </div>
            <div id="pullStatus" style="font-size:12px;color:var(--text-dim);margin-top:8px;"></div>
        </div>
        <div class="section-label" style="margin-top:24px;">Cloud Providers</div>
        <div id="cloudModelsGrid" class="card-grid">
            <div class="stat-card"><div class="stat-label">Anthropic</div><div class="stat-value" style="font-size:12px;">Claude Opus, Sonnet, Haiku</div></div>
            <div class="stat-card"><div class="stat-label">OpenAI</div><div class="stat-value" style="font-size:12px;">GPT-4o, o1, o3-mini</div></div>
            <div class="stat-card"><div class="stat-label">xAI</div><div class="stat-value" style="font-size:12px;">Grok</div></div>
            <div class="stat-card"><div class="stat-label">Google</div><div class="stat-value" style="font-size:12px;">Gemini 2.0 Flash</div></div>
        </div>
    </div>

    <!-- Security Tab -->
    <div id="tab-security" class="tab-panel">
        <div class="page-title">Security</div>
        <div id="securityError" class="error-msg" style="display:none;"></div>
        <div class="section-label">Threat Summary</div>
        <div class="card-grid" id="securityCards">
            <div class="stat-card"><div class="stat-label">Access Level</div><div class="stat-value" id="secAccessLevel">--</div></div>
            <div class="stat-card"><div class="stat-label">Blocked Requests</div><div class="stat-value" id="secBlocked">--</div></div>
            <div class="stat-card"><div class="stat-label">Active Connections</div><div class="stat-value" id="secConnections">--</div></div>
            <div class="stat-card"><div class="stat-label">Rate Limit</div><div class="stat-value" id="secRateLimit">--</div></div>
        </div>
        <div class="section-label" style="margin-top:24px;">Recent Security Events</div>
        <div id="securityEventsArea" class="card" style="max-height:400px;overflow-y:auto;">
            <div style="color:var(--text-dim);font-size:13px;">Loading security events...</div>
        </div>
        <div class="section-label" style="margin-top:24px;">Defense Layers</div>
        <div class="card">
            <div style="display:grid;grid-template-columns:1fr 1fr;gap:8px;font-size:12px;">
                <div style="padding:6px 10px;background:rgba(0,229,255,0.06);border-radius:6px;">&#9989; Bearer Token Auth</div>
                <div style="padding:6px 10px;background:rgba(0,229,255,0.06);border-radius:6px;">&#9989; 6-Level Access Control</div>
                <div style="padding:6px 10px;background:rgba(0,229,255,0.06);border-radius:6px;">&#9989; Path Protection</div>
                <div style="padding:6px 10px;background:rgba(0,229,255,0.06);border-radius:6px;">&#9989; Shell Injection Detection</div>
                <div style="padding:6px 10px;background:rgba(0,229,255,0.06);border-radius:6px;">&#9989; AES-256 Encryption at Rest</div>
                <div style="padding:6px 10px;background:rgba(0,229,255,0.06);border-radius:6px;">&#9989; Localhost-Only Binding</div>
                <div style="padding:6px 10px;background:rgba(0,229,255,0.06);border-radius:6px;">&#9989; HMAC Webhook Verification</div>
                <div style="padding:6px 10px;background:rgba(0,229,255,0.06);border-radius:6px;">&#9989; MCP Command Allowlist</div>
                <div style="padding:6px 10px;background:rgba(0,229,255,0.06);border-radius:6px;">&#9989; SQL Prepared Statements</div>
                <div style="padding:6px 10px;background:rgba(0,229,255,0.06);border-radius:6px;">&#9989; IP Rate Limiting</div>
                <div style="padding:6px 10px;background:rgba(0,229,255,0.06);border-radius:6px;">&#9989; CORS Restricted</div>
                <div style="padding:6px 10px;background:rgba(0,229,255,0.06);border-radius:6px;">&#9989; Content Security Policy</div>
            </div>
        </div>
    </div>

    <!-- Logos Tab -->
    <div id="tab-logos" class="tab-panel">
        <div class="page-title">Logos</div>
        <div style="font-size:13px;color:var(--text-dim);margin-bottom:24px;">Chat with your agents directly from the dashboard</div>
        <div class="card" style="display:flex;flex-direction:column;height:calc(100vh - 200px);min-height:400px;padding:0;overflow:hidden;">
            <div style="padding:12px 16px;border-bottom:1px solid var(--border);display:flex;align-items:center;gap:12px;">
                <select id="logosAgent" style="width:auto;min-width:140px;padding:6px 10px;font-size:12px;" onchange="logosClearChat()">
                    <option value="sid">SiD</option>
                </select>
                <button class="btn btn-secondary btn-sm" onclick="logosClearChat()">Clear</button>
            </div>
            <div id="logosMessages" style="flex:1;overflow-y:auto;padding:16px;display:flex;flex-direction:column;gap:12px;"></div>
            <div style="padding:12px 16px;border-top:1px solid var(--border);display:flex;gap:8px;">
                <textarea id="logosInput" rows="1" placeholder="Type a message..." style="flex:1;resize:none;min-height:38px;max-height:120px;padding:8px 12px;" onkeydown="if(event.key==='Enter'&&!event.shiftKey){event.preventDefault();logosSend();}"></textarea>
                <button class="btn btn-primary" onclick="logosSend()" id="logosSendBtn">Send</button>
            </div>
        </div>
    </div>

    <!-- Vox Tab -->
    <div id="tab-vox" class="tab-panel">
        <div class="page-title">Vox</div>
        <div style="font-size:13px;color:var(--text-dim);margin-bottom:24px;">Voice &amp; audio configuration</div>

        <div class="section-label">TTS Provider</div>
        <div class="card">
            <div style="display:flex;align-items:center;justify-content:space-between;gap:16px;flex-wrap:wrap;">
                <div>
                    <div style="font-size:14px;font-weight:600;color:var(--text-bright);">Text-to-Speech Engine</div>
                    <div style="font-size:12px;color:var(--text-dim);margin-top:4px;">Select the TTS provider for agent voice output</div>
                </div>
                <span class="badge badge-purple">Coming soon</span>
            </div>
            <div style="display:grid;grid-template-columns:1fr 1fr;gap:12px;margin-top:16px;">
                <div style="padding:14px;background:var(--bg);border:1px solid var(--border);border-radius:10px;">
                    <div style="font-size:13px;font-weight:600;color:var(--text-bright);">ElevenLabs</div>
                    <div style="font-size:11px;color:var(--text-dim);margin-top:4px;">High-quality neural voices</div>
                </div>
                <div style="padding:14px;background:var(--bg);border:1px solid var(--border);border-radius:10px;">
                    <div style="font-size:13px;font-weight:600;color:var(--text-bright);">Apple TTS</div>
                    <div style="font-size:11px;color:var(--text-dim);margin-top:4px;">Built-in system voices</div>
                </div>
            </div>
        </div>

        <div class="section-label">Wake Word</div>
        <div class="card">
            <div style="display:flex;align-items:center;justify-content:space-between;gap:16px;flex-wrap:wrap;">
                <div>
                    <div style="font-size:14px;font-weight:600;color:var(--text-bright);">Wake Word Detection</div>
                    <div style="font-size:12px;color:var(--text-dim);margin-top:4px;">Activate agents with a spoken keyword</div>
                </div>
                <span class="badge badge-purple">Coming soon</span>
            </div>
        </div>

        <div class="section-label">Audio Pipeline</div>
        <div class="card">
            <div style="display:flex;align-items:center;justify-content:space-between;gap:16px;flex-wrap:wrap;">
                <div>
                    <div style="font-size:14px;font-weight:600;color:var(--text-bright);">Audio Pipeline Status</div>
                    <div style="font-size:12px;color:var(--text-dim);margin-top:4px;">Input/output routing, noise cancellation, echo suppression</div>
                </div>
                <span class="badge badge-purple">Coming soon</span>
            </div>
        </div>

        <div class="section-label">Voice Model</div>
        <div class="card">
            <div style="display:flex;align-items:center;justify-content:space-between;gap:16px;flex-wrap:wrap;">
                <div>
                    <div style="font-size:14px;font-weight:600;color:var(--text-bright);">Voice Model Configuration</div>
                    <div style="font-size:12px;color:var(--text-dim);margin-top:4px;">Per-agent voice selection, speed, pitch, and emotion settings</div>
                </div>
                <span class="badge badge-purple">Coming soon</span>
            </div>
        </div>
    </div>

    <!-- Lexis Tab -->
    <div id="tab-lexis" class="tab-panel">
        <div class="page-title">Lexis</div>
        <div style="font-size:13px;color:var(--text-dim);margin-bottom:24px;">Conversation history organized by day</div>
        <div id="lexisError" class="error-msg" style="display:none;"></div>
        <div class="search-bar">
            <input type="text" id="lexisSearch" placeholder="Search conversations..." onkeydown="if(event.key==='Enter')loadLexis()">
            <button class="btn btn-primary" onclick="loadLexis()">Search</button>
        </div>
        <div id="lexisContent"><div class="empty-state"><span class="spinner"></span></div></div>
    </div>

    <!-- Skills Tab -->
    <div id="tab-skills" class="tab-panel">
        <div class="page-title">Skills</div>
        <div id="skillsError" class="error-msg" style="display:none;"></div>
        <div id="skillsList"><div class="empty-state"><span class="spinner"></span></div></div>
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
    if (tab === 'models') { loadModels(); }
    if (tab === 'logs') { logsOffset = 0; loadLogs(); }
    if (tab === 'security') { loadSecurity(); }
    if (tab === 'settings') { loadSettings(); }
    if (tab === 'lexis') { loadLexis(); }
    if (tab === 'skills') { loadSkills(); }
    if (tab === 'logos') { logosLoadAgents(); logosClearChat(); }
}

// --- Kill Switch ---
function activateKillSwitch() {
    if (!confirm('LOCK SERVER?\\n\\nThis will set access level to OFF — all agent actions will be blocked immediately.\\n\\nAre you sure?')) return;
    api('PUT', '/v1/config/settings', { accessLevel: 0 }).then(function() {
        var btn = document.getElementById('killSwitchBtn');
        btn.textContent = 'LOCKED';
        btn.style.background = '#666';
        showSuccess('settingsSuccess', 'Server locked — access level set to OFF');
        // Refresh overview
        loadOverview();
    }).catch(function() {
        showError('overviewError', 'Failed to lock server');
    });
}

// --- Models ---
function loadModels() {
    hideError('modelsError');
    api('GET', '/v1/dashboard/status').then(function(data) {
        var ol = data.ollama || {};
        var models = ol.models || [];
        var grid = document.getElementById('modelsGrid');
        if (models.length === 0) {
            grid.innerHTML = '<div class="card" style="color:var(--text-dim);">No Ollama models installed. Pull a model below.</div>';
            return;
        }
        grid.innerHTML = models.map(function(m) {
            var name = typeof m === 'string' ? m : (m.name || m.model || 'Unknown');
            var size = m.size ? (m.size / 1e9).toFixed(1) + ' GB' : '';
            return '<div class="stat-card" style="position:relative;">' +
                '<div class="stat-label">' + name + '</div>' +
                (size ? '<div class="stat-value" style="font-size:12px;">' + size + '</div>' : '') +
                '<button onclick="deleteModel(\\'' + name.replace(/'/g, "\\\\'") + '\\')" style="position:absolute;top:8px;right:8px;background:none;border:none;color:var(--text-dim);cursor:pointer;font-size:14px;" title="Delete model">&times;</button>' +
                '</div>';
        }).join('');
    }).catch(function() {
        showError('modelsError', 'Failed to load models');
    });
}

function pullModel() {
    var name = document.getElementById('pullModelName').value.trim();
    if (!name) return;
    var status = document.getElementById('pullStatus');
    status.textContent = 'Pulling ' + name + '... (this may take several minutes)';
    status.style.color = 'var(--cyan)';
    // POST to Ollama pull via Base proxy
    fetch(BASE + '/v1/ollama/pull', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', 'Authorization': 'Bearer ' + TOKEN },
        body: JSON.stringify({ name: name })
    }).then(function(res) {
        if (res.ok) {
            status.textContent = 'Pull started for ' + name + '. Check Models tab to refresh.';
            status.style.color = '#4CAF50';
            document.getElementById('pullModelName').value = '';
            setTimeout(loadModels, 5000);
        } else {
            status.textContent = 'Pull failed — check model name';
            status.style.color = '#ff4444';
        }
    }).catch(function() {
        status.textContent = 'Pull failed — server error';
        status.style.color = '#ff4444';
    });
}

function deleteModel(name) {
    if (!confirm('Delete model "' + name + '"?')) return;
    fetch(BASE + '/v1/ollama/delete', {
        method: 'DELETE',
        headers: { 'Content-Type': 'application/json', 'Authorization': 'Bearer ' + TOKEN },
        body: JSON.stringify({ name: name })
    }).then(function(res) {
        if (res.ok) loadModels();
    });
}

// --- Security ---
function loadSecurity() {
    hideError('securityError');
    api('GET', '/v1/dashboard/status').then(function(data) {
        var srv = data.server || {};
        var conn = data.connections || {};
        var levelNames = ['OFF', 'CHAT', 'READ', 'WRITE', 'EXEC', 'FULL'];
        var level = srv.accessLevel || 0;
        document.getElementById('secAccessLevel').textContent = level + ' (' + (levelNames[level] || '?') + ')';
        document.getElementById('secBlocked').textContent = conn.blockedRequests || 0;
        document.getElementById('secConnections').textContent = conn.active || 0;
        document.getElementById('secRateLimit').textContent = (srv.rateLimit || 60) + '/min';

        // Update kill switch state
        var btn = document.getElementById('killSwitchBtn');
        if (level === 0) {
            btn.textContent = 'LOCKED';
            btn.style.background = '#666';
        } else {
            btn.textContent = 'LOCK SERVER';
            btn.style.background = '#ff4444';
        }
    }).catch(function() {
        showError('securityError', 'Failed to load security data');
    });

    // Load recent blocked requests from audit log
    api('GET', '/v1/audit/log?limit=20&offset=0').then(function(data) {
        var entries = data.entries || data.logs || [];
        var blocked = entries.filter(function(e) { return e.result === 'blocked' || e.result === 'denied'; });
        var area = document.getElementById('securityEventsArea');
        if (blocked.length === 0) {
            area.innerHTML = '<div style="color:var(--text-dim);font-size:13px;text-align:center;padding:20px;">No blocked requests in recent history</div>';
            return;
        }
        area.innerHTML = blocked.map(function(e) {
            return '<div style="display:flex;justify-content:space-between;align-items:center;padding:8px 0;border-bottom:1px solid var(--border);font-size:12px;">' +
                '<div><span style="color:#ff4444;font-weight:600;">BLOCKED</span> ' +
                '<span style="color:var(--text);">' + (e.method || '') + ' ' + (e.path || '') + '</span></div>' +
                '<div style="color:var(--text-dim);">' + (e.ip || '') + ' &bull; ' + (e.time || '') + '</div>' +
                '</div>';
        }).join('');
    }).catch(function() {});
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

var selectedAgentId = null;
var selectedAgentData = null;
var allAgentsCache = [];

function renderAgents(agents) {
    allAgentsCache = agents;
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
        html += '<div class="agent-card" onclick="showAgentDetail(\'' + esc(a.id) + '\')">';
        html += '<div class="agent-info">';
        html += '<div class="agent-name">' + esc(a.name || a.id) + ' ';
        if (a.isBuiltIn) html += '<span class="badge badge-purple">Built-in</span>';
        html += '</div>';
        html += '<div class="agent-role">' + esc(a.role || a.personality || '') + '</div>';
        html += '<span class="badge ' + badgeClass + '">Level ' + lvl + ' - ' + esc(lv.name) + '</span>';
        html += '</div>';
        html += '<div class="agent-actions">';
        if (!a.isBuiltIn) {
            html += '<button class="btn btn-danger btn-sm" onclick="event.stopPropagation();deleteAgent(\'' + esc(a.id) + '\')">Delete</button>';
        }
        html += '</div>';
        html += '</div>';
    }
    wrap.innerHTML = html;
}

function showAgentDetail(id) {
    selectedAgentId = id;
    var found = null;
    for (var i = 0; i < allAgentsCache.length; i++) {
        if (allAgentsCache[i].id === id) { found = allAgentsCache[i]; break; }
    }
    if (!found) {
        api('GET', '/v1/agents/' + encodeURIComponent(id)).then(function(data) {
            selectedAgentData = data;
            openAgentDetail(data);
        }).catch(function(e) {
            showError('agentsError', 'Failed to load agent: ' + e.message);
        });
    } else {
        selectedAgentData = found;
        openAgentDetail(found);
    }
}

function openAgentDetail(agent) {
    document.getElementById('agentListView').style.display = 'none';
    document.getElementById('agentDetailView').style.display = 'block';
    document.getElementById('agentDetailName').textContent = agent.name || agent.id;
    document.getElementById('agentDetailDeleteBtn').style.display = agent.isBuiltIn ? 'none' : 'inline-flex';
    renderAgentDetail(agent);
}

function hideAgentDetail() {
    document.getElementById('agentDetailView').style.display = 'none';
    document.getElementById('agentListView').style.display = 'block';
    selectedAgentId = null;
    selectedAgentData = null;
    loadAgents();
}

function exportAgent(id) {
    if (!id) return;
    api('GET', '/v1/agents/' + encodeURIComponent(id)).then(function(data) {
        var json = JSON.stringify(data, null, 2);
        var blob = new Blob([json], {type: 'application/json'});
        var a = document.createElement('a');
        a.href = URL.createObjectURL(blob);
        a.download = (data.name || id) + '.json';
        document.body.appendChild(a);
        a.click();
        document.body.removeChild(a);
        URL.revokeObjectURL(a.href);
    }).catch(function(e) {
        alert('Export failed: ' + e.message);
    });
}

function resetAgent(id) {
    if (!id) return;
    if (!confirm('Reset agent to defaults? This cannot be undone.')) return;
    api('POST', '/v1/agents/' + encodeURIComponent(id) + '/reset').then(function() {
        showAgentDetail(id);
    }).catch(function(e) {
        alert('Reset failed: ' + e.message);
    });
}

function deleteAgentFromDetail() {
    if (!selectedAgentId) return;
    if (!confirm('Delete this agent? This cannot be undone.')) return;
    api('DELETE', '/v1/agents/' + encodeURIComponent(selectedAgentId)).then(function() {
        hideAgentDetail();
    }).catch(function(e) {
        alert('Delete failed: ' + e.message);
    });
}

function renderAgentDetail(agent) {
    var content = document.getElementById('agentDetailContent');
    var lvl = agent.accessLevel != null ? agent.accessLevel : 0;
    var html = '';
    // Agent Privileges — most important control, placed first
    html += '<div class="section-label">Agent Privileges</div>';
    html += '<div class="card">';
    html += '<div style="display:flex;align-items:center;justify-content:space-between;gap:16px;flex-wrap:wrap;margin-bottom:16px;">';
    html += '<div>';
    html += '<div style="font-size:14px;font-weight:700;color:var(--text-bright);">Access Level</div>';
    html += '<div style="font-size:12px;color:var(--text-dim);margin-top:2px;" id="agentPrivDesc">' + esc(LEVELS[lvl] ? LEVELS[lvl].name + ' — ' + LEVELS[lvl].desc : '') + '</div>';
    html += '</div>';
    html += '</div>';
    html += '<div class="level-selector" id="agentLevelSelector">';
    for (var i = 0; i < LEVELS.length; i++) {
        var lv = LEVELS[i];
        var colorVar = 'var(--' + lv.color + ')';
        var isActive = i === lvl;
        html += '<div class="level-step' + (isActive ? ' active' : '') + '" ';
        html += 'onclick="setAgentLevel(' + i + ')" ';
        html += 'style="' + (isActive ? 'border-color:' + colorVar + ';background:var(--' + lv.color + '-dim);' : '') + '">';
        html += '<div class="level-num" style="color:' + colorVar + ';">' + lv.num + '</div>';
        html += '<div class="level-name" style="color:' + (isActive ? colorVar : 'var(--text-dim)') + ';">' + esc(lv.name) + '</div>';
        html += '</div>';
    }
    html += '</div>';
    html += '</div>';
    // Activity section
    html += '<div class="section-label">Activity</div>';
    html += '<div class="card"><div style="color:var(--text-dim);font-size:13px;">No recent activity.</div></div>';
    // Identity section
    html += '<div class="section-label">Identity</div>';
    html += '<div class="card">';
    html += '<div style="font-size:13px;margin-bottom:8px;"><strong style="color:var(--text-bright);">Role:</strong> ' + esc(agent.role || 'Not set') + '</div>';
    html += '<div style="font-size:13px;"><strong style="color:var(--text-bright);">Personality:</strong> ' + esc(agent.personality || 'Not set') + '</div>';
    html += '</div>';
    content.innerHTML = html;
}

function setAgentLevel(level) {
    if (!selectedAgentId) return;
    api('PUT', '/v1/agents/' + encodeURIComponent(selectedAgentId), {accessLevel: level}).then(function(data) {
        selectedAgentData = data || selectedAgentData;
        if (selectedAgentData) selectedAgentData.accessLevel = level;
        renderAgentDetail(selectedAgentData);
    }).catch(function(e) {
        alert('Failed to update access level: ' + e.message);
    });
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
        var mid = m.id || m.memory_id || '';
        var catBadge = '<span class="badge badge-cyan">' + esc(m.category || 'unknown') + '</span>';
        var impBadge = '<span class="badge badge-purple">' + (m.importance != null ? m.importance.toFixed(2) : '?') + '</span>';
        html += '<div class="memory-card" style="position:relative;">';
        html += '<div class="mem-text">' + esc(m.text || m.content || '') + '</div>';
        html += '<div class="mem-meta">';
        html += catBadge + ' ' + impBadge;
        if (m.score != null) html += ' <span>score: ' + m.score.toFixed(3) + '</span>';
        if (m.createdAt || m.created_at || m.timestamp) {
            html += ' <span>' + shortTime(m.createdAt || m.created_at || m.timestamp) + '</span>';
        }
        // Memory management buttons
        if (mid) {
            html += ' <button onclick="deleteMemory(' + mid + ')" style="background:none;border:none;color:#ff4444;cursor:pointer;font-size:11px;padding:2px 6px;" title="Delete">&times; Delete</button>';
        }
        html += '</div>';
        html += '</div>';
    }
    wrap.innerHTML = html;
}

function deleteMemory(id) {
    if (!confirm('Delete this memory?')) return;
    api('DELETE', '/v1/loa/' + id).then(function() {
        loadLibrary();
    }).catch(function(e) {
        showError('libraryError', 'Failed to delete: ' + e.message);
    });
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

// --- Logos ---
var logosHistory = [];
var logosStreaming = false;

function logosLoadAgents() {
    api('GET', '/v1/agents').then(function(data) {
        var agents = data.agents || data || [];
        if (!Array.isArray(agents)) agents = [];
        var sel = document.getElementById('logosAgent');
        if (!sel) return;
        sel.innerHTML = '';
        for (var i = 0; i < agents.length; i++) {
            var opt = document.createElement('option');
            opt.value = agents[i].id;
            opt.textContent = agents[i].name || agents[i].id;
            sel.appendChild(opt);
        }
        if (!agents.length) {
            var def = document.createElement('option');
            def.value = 'sid';
            def.textContent = 'SiD';
            sel.appendChild(def);
        }
    }).catch(function() {});
}

function logosClearChat() {
    logosHistory = [];
    var wrap = document.getElementById('logosMessages');
    if (wrap) wrap.innerHTML = '<div class="empty-state" style="margin:auto;">Start a conversation</div>';
}

function logosAppendMsg(role, text) {
    var wrap = document.getElementById('logosMessages');
    if (!wrap) return;
    var isEmpty = wrap.querySelector('.empty-state');
    if (isEmpty) wrap.innerHTML = '';
    var div = document.createElement('div');
    div.style.cssText = role === 'user'
        ? 'align-self:flex-end;background:var(--cyan-dim);color:var(--text-bright);padding:10px 14px;border-radius:12px 12px 2px 12px;max-width:75%;font-size:13px;line-height:1.5;word-wrap:break-word;'
        : 'align-self:flex-start;background:var(--surface-hover);color:var(--text);padding:10px 14px;border-radius:12px 12px 12px 2px;max-width:75%;font-size:13px;line-height:1.5;word-wrap:break-word;border:1px solid var(--border);';
    div.textContent = text;
    div.id = role === 'assistant' ? 'logosLastAssistant' : '';
    wrap.appendChild(div);
    wrap.scrollTop = wrap.scrollHeight;
    return div;
}

function logosSend() {
    if (logosStreaming) return;
    var input = document.getElementById('logosInput');
    var text = input.value.trim();
    if (!text) return;
    input.value = '';
    logosHistory.push({role: 'user', content: text});
    logosAppendMsg('user', text);
    logosStreaming = true;
    document.getElementById('logosSendBtn').textContent = '...';
    var agentId = document.getElementById('logosAgent').value || 'sid';
    var body = {
        model: 'auto',
        messages: logosHistory,
        stream: false
    };
    fetch('/v1/chat/completions', {
        method: 'POST',
        headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer ' + TOKEN,
            'x-torbo-agent-id': agentId
        },
        body: JSON.stringify(body)
    }).then(function(r) { return r.json(); }).then(function(data) {
        var reply = '';
        if (data.choices && data.choices[0] && data.choices[0].message) {
            reply = data.choices[0].message.content || '';
        } else if (data.response) {
            reply = data.response;
        } else if (data.error) {
            reply = 'Error: ' + (data.error.message || data.error);
        }
        if (reply) {
            logosHistory.push({role: 'assistant', content: reply});
            logosAppendMsg('assistant', reply);
        }
        logosStreaming = false;
        document.getElementById('logosSendBtn').textContent = 'Send';
    }).catch(function(e) {
        logosAppendMsg('assistant', 'Connection error: ' + e.message);
        logosStreaming = false;
        document.getElementById('logosSendBtn').textContent = 'Send';
    });
}

// --- Lexis ---
function loadLexis() {
    hideError('lexisError');
    var q = document.getElementById('lexisSearch').value.trim();
    var wrap = document.getElementById('lexisContent');
    wrap.innerHTML = '<div class="empty-state"><span class="spinner"></span> Loading...</div>';
    var url = '/v1/conversations';
    if (q) url += '?q=' + encodeURIComponent(q);
    api('GET', url).then(function(data) {
        var convos = data.conversations || data.spaces || data || [];
        if (!Array.isArray(convos) || !convos.length) {
            wrap.innerHTML = '<div class="empty-state">No conversations found.</div>';
            return;
        }
        var byDay = {};
        for (var i = 0; i < convos.length; i++) {
            var c = convos[i];
            var d = c.date || c.createdAt || c.created_at || '';
            var day = d ? d.substring(0, 10) : 'Unknown';
            if (!byDay[day]) byDay[day] = [];
            byDay[day].push(c);
        }
        var days = Object.keys(byDay).sort().reverse();
        var html = '';
        for (var di = 0; di < days.length; di++) {
            html += '<div class="section-label">' + esc(days[di]) + '</div>';
            var items = byDay[days[di]];
            for (var ci = 0; ci < items.length; ci++) {
                var cv = items[ci];
                html += '<div class="card" style="padding:14px 16px;">';
                html += '<div style="font-size:14px;font-weight:600;color:var(--text-bright);">' + esc(cv.title || cv.agent || cv.agentId || 'Conversation') + '</div>';
                if (cv.preview || cv.lastMessage) {
                    html += '<div style="font-size:12px;color:var(--text-dim);margin-top:4px;max-height:40px;overflow:hidden;">' + esc(cv.preview || cv.lastMessage) + '</div>';
                }
                html += '<div style="font-size:11px;color:var(--text-dim);margin-top:6px;">' + esc(cv.messageCount ? cv.messageCount + ' messages' : '') + '</div>';
                html += '</div>';
            }
        }
        wrap.innerHTML = html;
    }).catch(function(e) {
        if (e.message !== 'Unauthorized') {
            wrap.innerHTML = '<div class="empty-state">No conversation data available.</div>';
        }
    });
}

// --- Skills ---
function loadSkills() {
    hideError('skillsError');
    var wrap = document.getElementById('skillsList');
    api('GET', '/v1/skills').then(function(data) {
        var skills = data.skills || data || [];
        if (!Array.isArray(skills) || !skills.length) {
            wrap.innerHTML = '<div class="empty-state">No skills installed.</div>';
            return;
        }
        var html = '';
        for (var i = 0; i < skills.length; i++) {
            var s = skills[i];
            html += '<div class="card" style="display:flex;align-items:center;gap:16px;">';
            html += '<div style="flex:1;">';
            html += '<div style="font-size:14px;font-weight:600;color:var(--text-bright);">' + esc(s.name || s.id) + '</div>';
            if (s.description) html += '<div style="font-size:12px;color:var(--text-dim);margin-top:4px;">' + esc(s.description) + '</div>';
            html += '</div>';
            if (s.enabled !== undefined) {
                html += '<span class="badge ' + (s.enabled ? 'badge-green' : 'badge-gray') + '">' + (s.enabled ? 'Active' : 'Inactive') + '</span>';
            }
            html += '</div>';
        }
        wrap.innerHTML = html;
    }).catch(function(e) {
        if (e.message !== 'Unauthorized') {
            wrap.innerHTML = '<div class="empty-state">No skills data available.</div>';
        }
    });
}

// --- Orb Renderer ---
var orbLayers = [
    { hue:306, sat:80, bri:90,  rMul:1.15, ph:0.08, wv:0.25, sx:1.1,  sy:0.45, rot:0.015, blur:21,   op:0.05,  po:0, wo:0, ro:0 },
    { hue:0,   sat:85, bri:100, rMul:1.0,  ph:0.12, wv:0.35, sx:1.0,  sy:0.5,  rot:0.02,  blur:14,   op:0.07,  po:0, wo:0, ro:0 },
    { hue:29,  sat:90, bri:100, rMul:0.95, ph:0.1,  wv:0.3,  sx:0.85, sy:0.65, rot:0.018, blur:11.5, op:0.08,  po:1.5, wo:2, ro:Math.PI*0.3 },
    { hue:187, sat:90, bri:100, rMul:0.9,  ph:0.14, wv:0.4,  sx:0.75, sy:0.8,  rot:0.022, blur:9,    op:0.12,  po:3, wo:1, ro:Math.PI*0.7 },
    { hue:216, sat:85, bri:100, rMul:0.85, ph:0.09, wv:0.28, sx:0.7,  sy:0.75, rot:0.025, blur:7,    op:0.138, po:2, wo:3, ro:Math.PI*1.1 },
    { hue:270, sat:80, bri:100, rMul:0.75, ph:0.16, wv:0.45, sx:0.6,  sy:0.7,  rot:0.028, blur:5,    op:0.152, po:4, wo:2, ro:Math.PI*0.5 },
    { hue:331, sat:70, bri:100, rMul:0.6,  ph:0.11, wv:0.32, sx:0.55, sy:0.6,  rot:0.03,  blur:3.5,  op:0.166, po:1, wo:4, ro:Math.PI*1.4 }
];

function orbHsl(h, s, b, a) {
    s /= 100; b /= 100;
    var k = function(n) { return (n + h / 30) % 12; };
    var f = function(n) { return b - b * s * Math.max(Math.min(k(n) - 3, 9 - k(n), 1), -1); };
    return 'rgba(' + Math.round(f(0)*255) + ',' + Math.round(f(8)*255) + ',' + Math.round(f(4)*255) + ',' + a + ')';
}

function drawOrbLayer(ctx, cx, cy, radius, L, t, intensity) {
    var ph = t * L.ph + L.po;
    var wp = t * L.wv + L.wo;
    var rot = t * L.rot + L.ro;
    var r = radius * L.rMul;
    var breatheAmp = 0.08 + intensity * 0.12;
    var bx = L.sx * (1.0 + Math.sin(wp * 0.3) * breatheAmp);
    var by = L.sy * (1.0 + Math.cos(wp * 0.25) * breatheAmp);
    ctx.save();
    ctx.globalCompositeOperation = 'lighter';
    var pts = [];
    for (var i = 0; i <= 64; i++) {
        var angle = (i / 64) * Math.PI * 2;
        var w1 = Math.sin(angle * 2 + ph) * 0.25;
        var w2 = Math.sin(angle * 3 + wp) * 0.18;
        var w3 = Math.cos(angle * 4 + ph * 0.8) * 0.12;
        var w4 = Math.sin(angle * 1.5 + wp * 1.3) * 0.15;
        var ap = Math.sin(angle * 2 + ph * 3) * intensity * 0.35;
        var ap2 = Math.cos(angle * 3 + wp * 2) * intensity * 0.25;
        var ap3 = Math.sin(angle * 5 + ph * 4) * intensity * 0.18;
        var dist = r * (0.55 + w1 + w2 + w3 + w4 + ap + ap2 + ap3);
        var x = Math.cos(angle) * dist * bx;
        var y = Math.sin(angle) * dist * by;
        pts.push({ x: cx + x * Math.cos(rot) - y * Math.sin(rot), y: cy + x * Math.sin(rot) + y * Math.cos(rot) });
    }
    var fillColor = orbHsl(L.hue, L.sat, L.bri, Math.min(L.op * (1.0 + intensity * 0.6), 0.85));
    ctx.filter = 'blur(' + L.blur + 'px)';
    ctx.beginPath();
    for (var j = 0; j < pts.length; j++) { j === 0 ? ctx.moveTo(pts[j].x, pts[j].y) : ctx.lineTo(pts[j].x, pts[j].y); }
    ctx.closePath();
    ctx.fillStyle = fillColor;
    ctx.fill();
    ctx.filter = 'blur(' + (L.blur * 0.4) + 'px)';
    ctx.beginPath();
    for (var j2 = 0; j2 < pts.length; j2++) { j2 === 0 ? ctx.moveTo(pts[j2].x, pts[j2].y) : ctx.lineTo(pts[j2].x, pts[j2].y); }
    ctx.closePath();
    ctx.fillStyle = orbHsl(L.hue, L.sat, L.bri, Math.min(L.op * 0.49 * (1.0 + intensity * 0.6), 0.85));
    ctx.fill();
    ctx.restore();
}

function renderOrbCanvas(canvas, intensity) {
    if (!canvas) return;
    var ctx = canvas.getContext('2d');
    var w = canvas.width, h = canvas.height;
    var cx = w / 2, cy = h / 2;
    var radius = Math.min(w, h) * 0.45;
    var t = performance.now() / 1000;
    ctx.clearRect(0, 0, w, h);
    for (var i = 0; i < orbLayers.length; i++) {
        drawOrbLayer(ctx, cx, cy, radius, orbLayers[i], t, intensity);
    }
}

function orbAnimLoop() {
    renderOrbCanvas(document.getElementById('sidebarOrb'), 0.06);
    if (currentTab === 'overview') {
        renderOrbCanvas(document.getElementById('homeOrb'), 0.08);
    }
    requestAnimationFrame(orbAnimLoop);
}

requestAnimationFrame(orbAnimLoop);

// --- Init ---
var isLocal = (location.hostname === 'localhost' || location.hostname === '127.0.0.1' || location.hostname === '::1');

function initApp() {
    // Never accept tokens from URL query parameters — they leak via browser history, Referer headers, and logs.
    var storedToken = localStorage.getItem('torbo_dashboard_token');
    var t = storedToken || '';
    if (!t && !isLocal) {
        showAuth();
        return;
    }
    TOKEN = t;
    // Clean any leftover token from URL (in case of old bookmarks)
    if (window.location.search.includes('token=')) {
        window.history.replaceState({}, '', window.location.pathname);
    }
    fetch('/v1/dashboard/status', {
        headers: t ? {'Authorization': 'Bearer ' + t} : {}
    }).then(function(r) {
        if (r.ok) {
            if (t) localStorage.setItem('torbo_dashboard_token', t);
            hideAuth();
            loadOverview();
            overviewTimer = setInterval(loadOverview, 30000);
        } else if (!isLocal) {
            TOKEN = '';
            localStorage.removeItem('torbo_dashboard_token');
            showAuth();
        } else {
            hideAuth();
            loadOverview();
            overviewTimer = setInterval(loadOverview, 30000);
        }
    }).catch(function() {
        if (!isLocal) showAuth();
        else { hideAuth(); loadOverview(); overviewTimer = setInterval(loadOverview, 30000); }
    });
}

initApp();
</script>
</body>
</html>
"""
}
