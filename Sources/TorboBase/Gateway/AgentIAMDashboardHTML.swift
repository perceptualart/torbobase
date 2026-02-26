// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — Agent IAM Web Dashboard
// HTML/CSS/JS dashboard served at /v1/iam/dashboard with real-time updates.

import Foundation

enum AgentIAMDashboardHTML {
    static func page() -> String {
        """
        <!DOCTYPE html>
        <html lang="en">
        <head>
            <meta charset="UTF-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            <meta http-equiv="Content-Security-Policy" content="default-src 'self'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self';">
            <title>Torbo Base — Agent IAM</title>
            <style>
                :root {
                    --bg: #0d1117; --surface: #161b22; --border: #30363d;
                    --text: #e6edf3; --dim: #8b949e; --accent: #58a6ff;
                    --green: #3fb950; --red: #f85149; --orange: #d29922;
                    --yellow: #e3b341; --purple: #bc8cff;
                }
                * { margin: 0; padding: 0; box-sizing: border-box; }
                body { font-family: -apple-system, BlinkMacSystemFont, 'SF Pro', sans-serif; background: var(--bg); color: var(--text); font-size: 13px; }
                .header { display: flex; align-items: center; padding: 12px 20px; background: var(--surface); border-bottom: 1px solid var(--border); }
                .header h1 { font-size: 15px; font-weight: 600; margin-right: 24px; }
                .header .stats { display: flex; gap: 16px; font-size: 11px; color: var(--dim); font-family: 'SF Mono', monospace; }
                .header .stat-val { color: var(--accent); font-weight: 600; }
                .tabs { display: flex; gap: 2px; padding: 8px 20px; background: var(--surface); border-bottom: 1px solid var(--border); }
                .tab { padding: 6px 14px; border-radius: 6px; cursor: pointer; font-size: 12px; font-weight: 500; color: var(--dim); transition: all 0.15s; }
                .tab:hover { background: #21262d; color: var(--text); }
                .tab.active { background: rgba(88,166,255,0.15); color: var(--accent); }
                .content { padding: 16px 20px; }
                .panel { display: none; }
                .panel.active { display: block; }
                .card { background: var(--surface); border: 1px solid var(--border); border-radius: 8px; padding: 14px; margin-bottom: 10px; }
                .card-header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 10px; }
                .card-title { font-size: 13px; font-weight: 600; }
                table { width: 100%; border-collapse: collapse; }
                th { text-align: left; padding: 6px 10px; font-size: 11px; font-weight: 600; color: var(--dim); border-bottom: 1px solid var(--border); }
                td { padding: 6px 10px; font-size: 12px; border-bottom: 1px solid var(--border); vertical-align: middle; }
                tr:hover { background: rgba(88,166,255,0.04); }
                .mono { font-family: 'SF Mono', 'Fira Code', monospace; font-size: 11px; }
                .badge { display: inline-block; padding: 2px 6px; border-radius: 4px; font-size: 9px; font-weight: 700; font-family: 'SF Mono', monospace; text-transform: uppercase; }
                .badge-green { background: rgba(63,185,80,0.2); color: var(--green); }
                .badge-red { background: rgba(248,81,73,0.2); color: var(--red); }
                .badge-orange { background: rgba(210,153,34,0.2); color: var(--orange); }
                .badge-yellow { background: rgba(227,179,65,0.2); color: var(--yellow); }
                .badge-blue { background: rgba(88,166,255,0.2); color: var(--accent); }
                .badge-purple { background: rgba(188,140,255,0.2); color: var(--purple); }
                .risk-bar { width: 60px; height: 6px; background: #21262d; border-radius: 3px; overflow: hidden; display: inline-block; vertical-align: middle; margin-right: 6px; }
                .risk-fill { height: 100%; border-radius: 3px; }
                .dot { display: inline-block; width: 8px; height: 8px; border-radius: 50%; margin-right: 6px; }
                .dot-green { background: var(--green); }
                .dot-red { background: var(--red); }
                .search-bar { width: 100%; padding: 8px 12px; background: var(--bg); border: 1px solid var(--border); border-radius: 6px; color: var(--text); font-size: 12px; outline: none; }
                .search-bar:focus { border-color: var(--accent); }
                .btn { padding: 5px 12px; border-radius: 6px; border: 1px solid var(--border); background: var(--surface); color: var(--text); font-size: 11px; cursor: pointer; font-weight: 500; }
                .btn:hover { background: #21262d; }
                .btn-danger { border-color: rgba(248,81,73,0.3); color: var(--red); }
                .btn-danger:hover { background: rgba(248,81,73,0.1); }
                .btn-primary { background: rgba(88,166,255,0.15); border-color: var(--accent); color: var(--accent); }
                .empty { text-align: center; padding: 40px; color: var(--dim); }
                .empty-icon { font-size: 36px; margin-bottom: 8px; opacity: 0.3; }
                .refresh-indicator { animation: spin 1s linear infinite; display: inline-block; }
                @keyframes spin { from { transform: rotate(0deg); } to { transform: rotate(360deg); } }
                .split { display: grid; grid-template-columns: 300px 1fr; gap: 16px; height: calc(100vh - 120px); }
                .list-pane { overflow-y: auto; }
                .detail-pane { overflow-y: auto; }
                .agent-item { padding: 10px 12px; cursor: pointer; border-radius: 6px; margin-bottom: 2px; transition: background 0.1s; }
                .agent-item:hover { background: #21262d; }
                .agent-item.selected { background: rgba(88,166,255,0.1); border: 1px solid rgba(88,166,255,0.2); }
                .perm-row { display: flex; align-items: center; gap: 8px; padding: 6px 10px; background: var(--bg); border-radius: 6px; margin-bottom: 4px; }
                .perm-resource { font-family: 'SF Mono', monospace; font-size: 11px; }
                .perm-actions { display: flex; gap: 4px; }
                .section-title { font-size: 13px; font-weight: 600; margin-bottom: 8px; display: flex; justify-content: space-between; align-items: center; }
                .anomaly-card { padding: 12px; background: var(--bg); border-radius: 6px; margin-bottom: 6px; border-left: 3px solid; }
                .anomaly-critical { border-left-color: var(--red); }
                .anomaly-high { border-left-color: var(--orange); }
                .anomaly-medium { border-left-color: var(--yellow); }
                .anomaly-low { border-left-color: var(--accent); }
            </style>
        </head>
        <body>
            <div class="header">
                <h1>Agent IAM</h1>
                <div class="stats">
                    <span>Agents: <span class="stat-val" id="stat-agents">—</span></span>
                    <span>Permissions: <span class="stat-val" id="stat-perms">—</span></span>
                    <span>Access Logs: <span class="stat-val" id="stat-logs">—</span></span>
                    <span>Denied: <span class="stat-val" id="stat-denied" style="color:var(--red)">—</span></span>
                    <span>Anomalies: <span class="stat-val" id="stat-anomalies" style="color:var(--orange)">—</span></span>
                </div>
                <div style="margin-left:auto">
                    <button class="btn btn-primary" onclick="refreshAll()">Refresh</button>
                </div>
            </div>
            <div class="tabs">
                <div class="tab active" data-tab="agents" onclick="switchTab('agents')">Agents</div>
                <div class="tab" data-tab="log" onclick="switchTab('log')">Access Log</div>
                <div class="tab" data-tab="anomalies" onclick="switchTab('anomalies')">Anomalies</div>
                <div class="tab" data-tab="search" onclick="switchTab('search')">Search</div>
                <div class="tab" data-tab="risk" onclick="switchTab('risk')">Risk Scores</div>
            </div>
            <div class="content">
                <!-- Agents Panel -->
                <div class="panel active" id="panel-agents">
                    <div class="split">
                        <div class="list-pane">
                            <input class="search-bar" placeholder="Filter agents..." oninput="filterAgents(this.value)" style="margin-bottom:10px">
                            <div id="agent-list"></div>
                        </div>
                        <div class="detail-pane card" id="agent-detail">
                            <div class="empty">
                                <div class="empty-icon">&#x1f6e1;</div>
                                <div>Select an agent to view IAM details</div>
                            </div>
                        </div>
                    </div>
                </div>

                <!-- Access Log Panel -->
                <div class="panel" id="panel-log">
                    <div class="card">
                        <div class="card-header">
                            <div class="card-title">Access Log</div>
                            <input class="search-bar" placeholder="Filter by agent or resource..." oninput="filterLogs(this.value)" style="width:300px">
                        </div>
                        <table>
                            <thead>
                                <tr><th></th><th>Agent</th><th>Action</th><th>Resource</th><th>Reason</th><th>Time</th></tr>
                            </thead>
                            <tbody id="log-table"></tbody>
                        </table>
                    </div>
                </div>

                <!-- Anomalies Panel -->
                <div class="panel" id="panel-anomalies">
                    <div class="card">
                        <div class="card-header">
                            <div class="card-title">Anomaly Detection</div>
                            <button class="btn btn-primary" onclick="refreshAnomalies()">Scan Now</button>
                        </div>
                        <div id="anomaly-list"></div>
                    </div>
                </div>

                <!-- Search Panel -->
                <div class="panel" id="panel-search">
                    <div class="card">
                        <div class="card-header">
                            <div class="card-title">Resource Access Search</div>
                        </div>
                        <div style="display:flex;gap:8px;margin-bottom:14px">
                            <input class="search-bar" id="resource-search" placeholder="e.g. file:/Documents/*, tool:web_search, tool:run_command">
                            <button class="btn btn-primary" onclick="searchResource()">Search</button>
                        </div>
                        <div id="search-results"></div>
                    </div>
                </div>

                <!-- Risk Scores Panel -->
                <div class="panel" id="panel-risk">
                    <div class="card">
                        <div class="card-header">
                            <div class="card-title">Agent Risk Scores</div>
                        </div>
                        <table>
                            <thead><tr><th>Agent</th><th>Risk Score</th><th>Level</th></tr></thead>
                            <tbody id="risk-table"></tbody>
                        </table>
                    </div>
                </div>
            </div>

            <script>
                let agents = [], logs = [], anomalies = [], riskScores = {}, selectedAgent = null;

                function api(path) {
                    return fetch(path, { headers: { 'Authorization': 'Bearer ' + (localStorage.getItem('torbo_token') || '') } }).then(r => r.json());
                }
                function apiPost(path, body) {
                    return fetch(path, { method: 'POST', headers: { 'Authorization': 'Bearer ' + (localStorage.getItem('torbo_token') || ''), 'Content-Type': 'application/json' }, body: JSON.stringify(body) }).then(r => r.json());
                }
                function apiDelete(path) {
                    return fetch(path, { method: 'DELETE', headers: { 'Authorization': 'Bearer ' + (localStorage.getItem('torbo_token') || '') } }).then(r => r.json());
                }

                async function refreshAll() {
                    try {
                        const [a, l, an, r, s] = await Promise.all([
                            api('/v1/iam/agents'), api('/v1/iam/access-log?limit=500'),
                            api('/v1/iam/anomalies'), api('/v1/iam/risk-scores'),
                            api('/v1/iam/stats')
                        ]);
                        agents = a.agents || []; logs = l.logs || []; anomalies = an.anomalies || []; riskScores = r.scores || {};
                        document.getElementById('stat-agents').textContent = s.totalAgents || 0;
                        document.getElementById('stat-perms').textContent = s.totalPermissions || 0;
                        document.getElementById('stat-logs').textContent = s.totalAccessLogs || 0;
                        document.getElementById('stat-denied').textContent = s.totalDenied || 0;
                        document.getElementById('stat-anomalies').textContent = s.activeAnomalies || 0;
                        renderAgents(); renderLogs(); renderAnomalies(); renderRiskScores();
                    } catch(e) { console.error('Refresh failed:', e); }
                }

                function switchTab(tab) {
                    document.querySelectorAll('.tab').forEach(t => t.classList.remove('active'));
                    document.querySelectorAll('.panel').forEach(p => p.classList.remove('active'));
                    document.querySelector(`.tab[data-tab="${tab}"]`).classList.add('active');
                    document.getElementById('panel-' + tab).classList.add('active');
                }

                function renderAgents(filter = '') {
                    const filtered = filter ? agents.filter(a => a.id.includes(filter) || (a.owner||'').includes(filter)) : agents;
                    const el = document.getElementById('agent-list');
                    el.innerHTML = filtered.map(a => {
                        const risk = a.riskScore || 0;
                        const color = risk > 0.7 ? 'var(--red)' : risk > 0.4 ? 'var(--orange)' : risk > 0.2 ? 'var(--yellow)' : 'var(--green)';
                        const sel = selectedAgent === a.id ? ' selected' : '';
                        return `<div class="agent-item${sel}" onclick="selectAgent('${a.id}')">
                            <div style="display:flex;align-items:center;justify-content:space-between">
                                <div>
                                    <div class="mono" style="font-weight:600">${a.id}</div>
                                    <div style="font-size:10px;color:var(--dim)">${(a.permissions||[]).length} perms · ${a.owner||'local'}</div>
                                </div>
                                <div style="text-align:right">
                                    <div class="risk-bar"><div class="risk-fill" style="width:${risk*100}%;background:${color}"></div></div>
                                    <span class="mono" style="color:${color}">${Math.round(risk*100)}%</span>
                                </div>
                            </div>
                        </div>`;
                    }).join('');
                }

                function filterAgents(val) { renderAgents(val.toLowerCase()); }

                function selectAgent(id) {
                    selectedAgent = id;
                    renderAgents();
                    const agent = agents.find(a => a.id === id);
                    if (!agent) return;
                    const perms = agent.permissions || [];
                    const agentLogs = logs.filter(l => l.agentID === id).slice(0, 20);
                    const risk = agent.riskScore || 0;
                    const riskColor = risk > 0.7 ? 'var(--red)' : risk > 0.4 ? 'var(--orange)' : risk > 0.2 ? 'var(--yellow)' : 'var(--green)';
                    const el = document.getElementById('agent-detail');
                    el.innerHTML = `
                        <div style="display:flex;justify-content:space-between;align-items:flex-start;margin-bottom:16px">
                            <div>
                                <div class="mono" style="font-size:18px;font-weight:700">${agent.id}</div>
                                <div style="font-size:11px;color:var(--dim);margin-top:4px">${agent.purpose||''}</div>
                                <div style="font-size:10px;color:var(--dim);margin-top:2px">Owner: ${agent.owner||'local'} · Created: ${agent.createdAt||'—'}</div>
                            </div>
                            <div style="text-align:center">
                                <svg width="60" height="60" viewBox="0 0 36 36">
                                    <circle cx="18" cy="18" r="16" fill="none" stroke="#21262d" stroke-width="3"/>
                                    <circle cx="18" cy="18" r="16" fill="none" stroke="${riskColor}" stroke-width="3"
                                        stroke-dasharray="${risk*100} 100" transform="rotate(-90 18 18)" stroke-linecap="round"/>
                                    <text x="18" y="21" text-anchor="middle" fill="${riskColor}" font-size="10" font-weight="bold" font-family="SF Mono,monospace">${Math.round(risk*100)}</text>
                                </svg>
                                <div style="font-size:9px;color:var(--dim)">Risk</div>
                            </div>
                        </div>
                        <div class="section-title">Permissions (${perms.length})
                            <span><button class="btn btn-danger" onclick="revokeAll('${agent.id}')">Revoke All</button></span>
                        </div>
                        ${perms.length === 0 ? '<div style="color:var(--dim);font-size:12px;padding:8px">No permissions granted</div>' :
                        perms.map(p => `<div class="perm-row">
                            <span class="perm-resource">${p.resource}</span>
                            <span class="perm-actions">${(p.actions||[]).sort().map(a => `<span class="badge ${actionBadge(a)}">${a}</span>`).join('')}</span>
                            <span style="flex:1"></span>
                            <span style="font-size:10px;color:var(--dim)">by ${p.grantedBy||'system'}</span>
                            <button class="btn btn-danger" style="padding:2px 6px" onclick="revokePerm('${agent.id}','${p.resource}')">×</button>
                        </div>`).join('')}
                        <div class="section-title" style="margin-top:16px">Recent Access (${agentLogs.length})</div>
                        ${agentLogs.length === 0 ? '<div style="color:var(--dim);font-size:12px;padding:8px">No access history</div>' :
                        `<table><thead><tr><th></th><th>Action</th><th>Resource</th><th>Time</th></tr></thead><tbody>
                        ${agentLogs.map(l => `<tr>
                            <td><span class="dot ${l.allowed ? 'dot-green' : 'dot-red'}"></span></td>
                            <td class="mono">${l.action}</td>
                            <td class="mono" style="color:var(--dim)">${l.resource}</td>
                            <td class="mono" style="font-size:10px;color:var(--dim)">${fmtTime(l.timestamp)}</td>
                        </tr>`).join('')}
                        </tbody></table>`}
                    `;
                }

                function actionBadge(a) {
                    switch(a) {
                        case 'execute': return 'badge-red';
                        case 'write': return 'badge-orange';
                        case 'read': return 'badge-blue';
                        case 'use': return 'badge-green';
                        case '*': return 'badge-purple';
                        default: return '';
                    }
                }

                function renderLogs(filter = '') {
                    const filtered = filter ? logs.filter(l => l.agentID.includes(filter) || l.resource.includes(filter)) : logs;
                    document.getElementById('log-table').innerHTML = filtered.slice(0, 200).map(l => `<tr>
                        <td><span class="dot ${l.allowed ? 'dot-green' : 'dot-red'}"></span></td>
                        <td class="mono" style="font-weight:500">${l.agentID}</td>
                        <td class="mono" style="color:var(--accent)">${l.action}</td>
                        <td class="mono" style="color:var(--dim)">${l.resource}</td>
                        <td style="font-size:10px;color:var(--red)">${l.reason||''}</td>
                        <td class="mono" style="font-size:10px;color:var(--dim)">${fmtTime(l.timestamp)}</td>
                    </tr>`).join('');
                }
                function filterLogs(val) { renderLogs(val.toLowerCase()); }

                function renderAnomalies() {
                    const el = document.getElementById('anomaly-list');
                    if (anomalies.length === 0) {
                        el.innerHTML = '<div class="empty"><div class="empty-icon">&#x2705;</div><div>No anomalies detected</div></div>';
                        return;
                    }
                    el.innerHTML = anomalies.map(a => `<div class="anomaly-card anomaly-${a.severity}">
                        <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:4px">
                            <div><span class="badge badge-${a.severity === 'critical' ? 'red' : a.severity === 'high' ? 'orange' : a.severity === 'medium' ? 'yellow' : 'blue'}">${a.severity}</span>
                            <strong style="margin-left:8px">${a.type.replace(/_/g,' ')}</strong></div>
                            <span class="mono" style="color:var(--accent)">${a.agentID}</span>
                        </div>
                        <div style="font-size:11px;color:var(--dim)">${a.description}</div>
                        <div class="mono" style="font-size:10px;color:var(--dim);margin-top:4px">${fmtTime(a.detectedAt)}</div>
                    </div>`).join('');
                }

                function renderRiskScores() {
                    const entries = Object.entries(riskScores).sort((a,b) => b[1] - a[1]);
                    document.getElementById('risk-table').innerHTML = entries.map(([id, score]) => {
                        const color = score > 0.7 ? 'var(--red)' : score > 0.4 ? 'var(--orange)' : score > 0.2 ? 'var(--yellow)' : 'var(--green)';
                        const level = score > 0.7 ? 'HIGH' : score > 0.4 ? 'MEDIUM' : score > 0.2 ? 'LOW' : 'MINIMAL';
                        return `<tr>
                            <td class="mono" style="font-weight:600">${id}</td>
                            <td><div class="risk-bar"><div class="risk-fill" style="width:${score*100}%;background:${color}"></div></div>
                            <span class="mono" style="color:${color}">${Math.round(score*100)}%</span></td>
                            <td><span class="badge" style="background:${color}22;color:${color}">${level}</span></td>
                        </tr>`;
                    }).join('');
                }

                async function searchResource() {
                    const q = document.getElementById('resource-search').value;
                    if (!q) return;
                    try {
                        const r = await api('/v1/iam/search?resource=' + encodeURIComponent(q));
                        const results = r.agents || [];
                        document.getElementById('search-results').innerHTML = results.length === 0
                            ? `<div class="empty"><div>No agents have access to "${q}"</div></div>`
                            : `<table><thead><tr><th>Agent</th><th>Risk</th><th>Permissions</th></tr></thead><tbody>
                            ${results.map(a => `<tr>
                                <td class="mono" style="font-weight:600">${a.id}</td>
                                <td class="mono">${Math.round((a.riskScore||0)*100)}%</td>
                                <td>${(a.permissions||[]).length}</td>
                            </tr>`).join('')}
                            </tbody></table>`;
                    } catch(e) { console.error(e); }
                }

                async function revokeAll(agentID) {
                    if (!confirm('Revoke ALL permissions for ' + agentID + '?')) return;
                    await apiDelete('/v1/iam/agents/' + agentID + '/permissions');
                    await refreshAll();
                    if (selectedAgent === agentID) selectAgent(agentID);
                }

                async function revokePerm(agentID, resource) {
                    await apiDelete('/v1/iam/agents/' + agentID + '/permissions?resource=' + encodeURIComponent(resource));
                    await refreshAll();
                    if (selectedAgent === agentID) selectAgent(agentID);
                }

                async function refreshAnomalies() {
                    const r = await api('/v1/iam/anomalies');
                    anomalies = r.anomalies || [];
                    renderAnomalies();
                }

                function fmtTime(ts) {
                    if (!ts) return '—';
                    try { return new Date(ts).toLocaleTimeString(); } catch { return ts; }
                }

                // Initial load + auto-refresh every 30s
                refreshAll();
                setInterval(refreshAll, 30000);

                // Enter key in search
                document.getElementById('resource-search').addEventListener('keydown', e => { if(e.key==='Enter') searchResource(); });
            </script>
        </body>
        </html>
        """
    }
}
