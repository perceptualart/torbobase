// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — Governance Web Dashboard (HTML/CSS/JS)
// Self-contained web dashboard for governance & observability.
// Serves on /governance — same design system as DashboardHTML.swift.

import Foundation

enum GovernanceDashboardHTML {
    static let page = """
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<meta http-equiv="Content-Security-Policy" content="default-src 'self'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'; img-src 'self' data:; font-src 'none'; frame-src 'none'; object-src 'none'">
<title>Torbo Base — Governance Dashboard</title>
<link rel="icon" href="data:image/svg+xml,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 100 100'><circle cx='50' cy='50' r='40' fill='%23a855f7'/></svg>">
<style>
:root {
    --bg: #0a0a0d; --surface: #111114; --surface-hover: #18181c;
    --border: rgba(255,255,255,0.06); --border-light: rgba(255,255,255,0.1);
    --text: rgba(255,255,255,0.85); --text-dim: rgba(255,255,255,0.4); --text-bright: #fff;
    --cyan: #00e5ff; --cyan-dim: rgba(0,229,255,0.15);
    --purple: #a855f7; --purple-dim: rgba(168,85,247,0.15);
    --green: #22c55e; --green-dim: rgba(34,197,94,0.15);
    --yellow: #eab308; --yellow-dim: rgba(234,179,8,0.15);
    --orange: #f97316; --orange-dim: rgba(249,115,22,0.15);
    --red: #ef4444; --red-dim: rgba(239,68,68,0.15);
    --gray: rgba(255,255,255,0.2);
}
* { margin: 0; padding: 0; box-sizing: border-box; }
body {
    font-family: 'Futura', 'Futura-Medium', -apple-system, BlinkMacSystemFont, sans-serif;
    background: var(--bg); color: var(--text);
    height: 100vh; display: flex; flex-direction: column; overflow: hidden;
}
.header {
    display: flex; align-items: center; justify-content: space-between;
    padding: 14px 24px; background: var(--surface); border-bottom: 1px solid var(--border);
}
.header-title { font-size: 14px; font-weight: 700; letter-spacing: 3px; color: var(--text-bright); }
.header-sub { font-size: 11px; color: var(--text-dim); margin-top: 2px; }
.header-actions { display: flex; gap: 10px; align-items: center; }
.tab-bar {
    display: flex; gap: 0; background: var(--surface); border-bottom: 1px solid var(--border);
    padding: 0 16px; overflow-x: auto;
}
.tab-item {
    padding: 10px 18px; font-size: 12px; font-weight: 600; cursor: pointer;
    color: var(--text-dim); border-bottom: 2px solid transparent; transition: all 0.15s;
    white-space: nowrap; position: relative;
}
.tab-item:hover { color: var(--text); }
.tab-item.active { color: var(--cyan); border-bottom-color: var(--cyan); }
.tab-badge {
    position: absolute; top: 6px; right: 4px; font-size: 9px; font-weight: 700;
    padding: 1px 5px; border-radius: 8px; color: #000;
}
.tab-badge.orange { background: var(--orange); }
.tab-badge.red { background: var(--red); }
.content { flex: 1; overflow-y: auto; padding: 24px; }
.tab-panel { display: none; }
.tab-panel.active { display: block; }
.card-grid {
    display: grid; grid-template-columns: repeat(auto-fill, minmax(200px, 1fr));
    gap: 14px; margin-bottom: 20px;
}
.stat-card {
    background: var(--surface); border: 1px solid var(--border);
    border-radius: 10px; padding: 16px;
}
.stat-label {
    font-size: 10px; text-transform: uppercase; letter-spacing: 2px;
    font-family: 'SF Mono', 'Menlo', monospace; color: var(--text-dim); margin-bottom: 6px;
}
.stat-value { font-size: 24px; font-weight: 700; }
.stat-cyan { color: var(--cyan); }
.stat-green { color: var(--green); }
.stat-orange { color: var(--orange); }
.stat-red { color: var(--red); }
.stat-yellow { color: var(--yellow); }
.stat-purple { color: var(--purple); }
.section-title {
    font-size: 11px; font-weight: 700; letter-spacing: 2px;
    font-family: 'SF Mono', 'Menlo', monospace; color: var(--text-dim);
    margin: 20px 0 12px 0;
}
.decision-row {
    display: flex; align-items: center; gap: 10px; padding: 8px 12px;
    background: var(--surface); border: 1px solid var(--border); border-radius: 8px;
    margin-bottom: 6px; cursor: pointer; transition: background 0.1s;
}
.decision-row:hover { background: var(--surface-hover); }
.risk-dot { width: 8px; height: 8px; border-radius: 50%; flex-shrink: 0; }
.risk-low { background: var(--green); }
.risk-medium { background: var(--yellow); }
.risk-high { background: var(--orange); }
.risk-critical { background: var(--red); }
.agent-label {
    font-size: 12px; font-weight: 700; font-family: 'SF Mono', 'Menlo', monospace;
    color: var(--cyan); min-width: 60px;
}
.action-label { font-size: 12px; color: var(--text); flex: 1; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.badge {
    display: inline-block; padding: 2px 7px; border-radius: 4px;
    font-size: 9px; font-weight: 700; letter-spacing: 1px;
    font-family: 'SF Mono', 'Menlo', monospace;
}
.badge-allowed { background: var(--green-dim); color: var(--green); }
.badge-flagged { background: var(--yellow-dim); color: var(--yellow); }
.badge-blocked { background: var(--red-dim); color: var(--red); }
.cost-label { font-size: 11px; font-family: 'SF Mono', 'Menlo', monospace; color: var(--green); opacity: 0.7; }
.time-label { font-size: 10px; font-family: 'SF Mono', 'Menlo', monospace; color: var(--text-dim); }
.approval-card {
    background: var(--surface); border: 1px solid rgba(249,115,22,0.2); border-radius: 10px;
    padding: 16px; margin-bottom: 10px;
}
.approval-header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 8px; }
.approval-action { font-size: 13px; color: var(--text); margin-bottom: 4px; }
.approval-reasoning { font-size: 11px; color: var(--text-dim); margin-bottom: 10px; }
.approval-buttons { display: flex; gap: 10px; }
.btn {
    display: inline-flex; align-items: center; gap: 5px; padding: 6px 14px;
    border-radius: 6px; font-size: 12px; font-weight: 600;
    cursor: pointer; border: none; transition: all 0.15s;
}
.btn-approve { background: var(--green-dim); color: var(--green); }
.btn-approve:hover { background: rgba(34,197,94,0.25); }
.btn-reject { background: var(--red-dim); color: var(--red); }
.btn-reject:hover { background: rgba(239,68,68,0.25); }
.btn-primary { background: var(--cyan); color: #000; }
.btn-primary:hover { filter: brightness(1.15); }
.btn-secondary { background: rgba(255,255,255,0.06); color: var(--text); border: 1px solid var(--border); }
.anomaly-card {
    display: flex; align-items: flex-start; gap: 12px; padding: 12px;
    background: var(--surface); border: 1px solid var(--border); border-radius: 8px;
    margin-bottom: 6px;
}
.anomaly-icon { font-size: 18px; flex-shrink: 0; }
.anomaly-type { font-size: 12px; font-weight: 700; color: var(--text); }
.anomaly-desc { font-size: 11px; color: var(--text-dim); margin-top: 2px; }
.policy-card {
    background: var(--surface); border: 1px solid var(--border); border-radius: 8px;
    padding: 14px; margin-bottom: 8px;
}
.policy-header { display: flex; align-items: center; gap: 8px; margin-bottom: 6px; }
.policy-dot { width: 8px; height: 8px; border-radius: 50%; }
.policy-name { font-size: 13px; font-weight: 700; color: var(--text); }
.policy-desc { font-size: 11px; color: var(--text-dim); margin-bottom: 6px; }
.policy-meta { display: flex; gap: 12px; font-size: 10px; font-family: 'SF Mono', 'Menlo', monospace; color: var(--text-dim); }
.empty-state { text-align: center; padding: 40px; color: var(--text-dim); }
.empty-state-icon { font-size: 32px; margin-bottom: 8px; opacity: 0.3; }
.cost-bar-row { display: flex; align-items: center; gap: 10px; margin-bottom: 6px; }
.cost-bar-agent { font-size: 12px; font-weight: 600; color: var(--text); width: 80px; }
.cost-bar-value { font-size: 12px; font-family: 'SF Mono', 'Menlo', monospace; color: var(--green); width: 80px; text-align: right; }
.cost-bar-track { flex: 1; height: 10px; background: rgba(255,255,255,0.04); border-radius: 5px; overflow: hidden; }
.cost-bar-fill { height: 100%; border-radius: 5px; transition: width 0.3s; }
.detail-modal {
    position: fixed; top: 0; left: 0; right: 0; bottom: 0;
    background: rgba(0,0,0,0.7); display: none; align-items: center;
    justify-content: center; z-index: 100;
}
.detail-modal.visible { display: flex; }
.detail-content {
    background: var(--bg); border: 1px solid var(--border); border-radius: 12px;
    padding: 24px; max-width: 600px; width: 90%; max-height: 80vh; overflow-y: auto;
}
.detail-row { display: flex; margin-bottom: 6px; }
.detail-label {
    font-size: 11px; font-weight: 700; font-family: 'SF Mono', 'Menlo', monospace;
    color: var(--text-dim); width: 100px; flex-shrink: 0;
}
.detail-value { font-size: 12px; color: var(--text); word-break: break-word; }
</style>
</head>
<body>

<div class="header">
    <div>
        <div class="header-title">GOVERNANCE</div>
        <div class="header-sub">Observability & Audit Trail</div>
    </div>
    <div class="header-actions">
        <label style="font-size:11px;color:var(--text-dim);display:flex;align-items:center;gap:5px;">
            <input type="checkbox" id="autoRefresh" checked> Auto-refresh
        </label>
        <button class="btn btn-secondary" onclick="refresh()">Refresh</button>
        <button class="btn btn-secondary" onclick="exportAudit('json')">Export JSON</button>
        <button class="btn btn-secondary" onclick="exportAudit('csv')">Export CSV</button>
    </div>
</div>

<div class="tab-bar">
    <div class="tab-item active" data-tab="overview" onclick="switchTab('overview')">Overview</div>
    <div class="tab-item" data-tab="decisions" onclick="switchTab('decisions')">Decisions</div>
    <div class="tab-item" data-tab="approvals" onclick="switchTab('approvals')">
        Approvals <span class="tab-badge orange" id="approvalBadge" style="display:none"></span>
    </div>
    <div class="tab-item" data-tab="costs" onclick="switchTab('costs')">Costs</div>
    <div class="tab-item" data-tab="anomalies" onclick="switchTab('anomalies')">
        Anomalies <span class="tab-badge red" id="anomalyBadge" style="display:none"></span>
    </div>
    <div class="tab-item" data-tab="policies" onclick="switchTab('policies')">Policies</div>
</div>

<div class="content">
    <!-- Overview -->
    <div class="tab-panel active" id="panel-overview">
        <div class="card-grid" id="statsGrid"></div>
        <div class="section-title">RECENT ACTIVITY</div>
        <div id="recentActivity"></div>
    </div>

    <!-- Decisions -->
    <div class="tab-panel" id="panel-decisions">
        <div class="section-title">DECISION LOG</div>
        <div id="decisionList"></div>
    </div>

    <!-- Approvals -->
    <div class="tab-panel" id="panel-approvals">
        <div class="section-title">PENDING APPROVALS</div>
        <div id="approvalList"></div>
    </div>

    <!-- Costs -->
    <div class="tab-panel" id="panel-costs">
        <div class="section-title">COST TRACKING</div>
        <div id="costSection"></div>
    </div>

    <!-- Anomalies -->
    <div class="tab-panel" id="panel-anomalies">
        <div style="display:flex;justify-content:space-between;align-items:center;">
            <div class="section-title" style="margin:0;">ANOMALIES</div>
            <button class="btn btn-secondary" onclick="scanAnomalies()">Scan Now</button>
        </div>
        <div id="anomalyList" style="margin-top:12px;"></div>
    </div>

    <!-- Policies -->
    <div class="tab-panel" id="panel-policies">
        <div class="section-title">GOVERNANCE POLICIES</div>
        <div id="policyList"></div>
    </div>
</div>

<!-- Decision Detail Modal -->
<div class="detail-modal" id="detailModal" onclick="if(event.target===this)closeDetail()">
    <div class="detail-content" id="detailContent"></div>
</div>

<script>
let state = { stats: {}, decisions: [], approvals: [], anomalies: [], policies: [] };
let refreshTimer = null;

function getToken() {
    return localStorage.getItem('torbo_token') || '';
}

async function api(path, method = 'GET', body = null) {
    const opts = { method, headers: { 'Authorization': 'Bearer ' + getToken(), 'Content-Type': 'application/json' } };
    if (body) opts.body = JSON.stringify(body);
    const r = await fetch(path, opts);
    return r.json();
}

async function refresh() {
    try {
        const [stats, decisions, anomalies, policies] = await Promise.all([
            api('/v1/governance/stats'),
            api('/v1/governance/decisions?limit=50'),
            api('/v1/governance/anomalies'),
            api('/v1/governance/policies')
        ]);
        state.stats = stats;
        state.decisions = decisions.decisions || [];
        state.approvals = (stats.pendingApprovals > 0) ? (await api('/v1/governance/decisions?limit=50')).decisions?.filter(d => d.approved === null && d.policyResult === 'flagged') || [] : [];
        state.anomalies = anomalies.anomalies || [];
        state.policies = policies.policies || [];
        render();
    } catch(e) { console.error('Refresh failed:', e); }
}

function render() {
    renderStats();
    renderDecisions();
    renderApprovals();
    renderCosts();
    renderAnomalies();
    renderPolicies();
    updateBadges();
}

function renderStats() {
    const s = state.stats;
    document.getElementById('statsGrid').innerHTML = `
        <div class="stat-card"><div class="stat-label">TOTAL DECISIONS</div><div class="stat-value stat-cyan">${s.totalDecisions || 0}</div></div>
        <div class="stat-card"><div class="stat-label">TOTAL COST</div><div class="stat-value stat-green">$${(s.totalCost || 0).toFixed(2)}</div></div>
        <div class="stat-card"><div class="stat-label">PENDING APPROVALS</div><div class="stat-value stat-orange">${s.pendingApprovals || 0}</div></div>
        <div class="stat-card"><div class="stat-label">BLOCKED ACTIONS</div><div class="stat-value stat-red">${s.blockedActions || 0}</div></div>
        <div class="stat-card"><div class="stat-label">ANOMALIES</div><div class="stat-value stat-yellow">${s.anomalyCount || 0}</div></div>
        <div class="stat-card"><div class="stat-label">AVG CONFIDENCE</div><div class="stat-value stat-purple">${((s.avgConfidence || 0) * 100).toFixed(0)}%</div></div>
    `;
    document.getElementById('recentActivity').innerHTML = state.decisions.slice(0, 10).map(d => decisionRowHTML(d)).join('');
}

function renderDecisions() {
    const list = state.decisions;
    document.getElementById('decisionList').innerHTML = list.length
        ? list.map(d => decisionRowHTML(d)).join('')
        : '<div class="empty-state"><div class="empty-state-icon">&#128269;</div>No decisions logged yet</div>';
}

function renderApprovals() {
    const list = state.approvals;
    document.getElementById('approvalList').innerHTML = list.length
        ? list.map(a => approvalCardHTML(a)).join('')
        : '<div class="empty-state"><div class="empty-state-icon">&#9989;</div>No pending approvals</div>';
}

function renderCosts() {
    const s = state.stats;
    const byAgent = s.costByAgent || {};
    const byDay = s.costByDay || {};
    const maxCost = Math.max(...Object.values(byAgent), 0.01);
    const colors = { sid: 'var(--cyan)', orion: 'var(--orange)', mira: 'var(--purple)', ada: 'var(--green)' };

    let html = `<div class="stat-card" style="margin-bottom:20px;">
        <div class="stat-label">TOTAL SPEND</div>
        <div class="stat-value stat-green">$${(s.totalCost || 0).toFixed(4)}</div>
    </div>`;

    if (Object.keys(byAgent).length) {
        html += '<div class="section-title">BY AGENT</div>';
        for (const [agent, cost] of Object.entries(byAgent).sort((a,b) => b[1]-a[1])) {
            const pct = (cost / maxCost * 100).toFixed(0);
            const c = colors[agent.toLowerCase()] || 'var(--cyan)';
            html += `<div class="cost-bar-row">
                <div class="cost-bar-agent">${agent}</div>
                <div class="cost-bar-value">$${cost.toFixed(4)}</div>
                <div class="cost-bar-track"><div class="cost-bar-fill" style="width:${pct}%;background:${c};"></div></div>
            </div>`;
        }
    }

    if (Object.keys(byDay).length) {
        html += '<div class="section-title" style="margin-top:20px;">BY DAY (LAST 30 DAYS)</div>';
        for (const [day, cost] of Object.entries(byDay).sort((a,b) => b[0].localeCompare(a[0])).slice(0, 14)) {
            html += `<div style="display:flex;justify-content:space-between;padding:4px 0;font-size:12px;">
                <span style="font-family:monospace;color:var(--text-dim);">${day}</span>
                <span style="font-family:monospace;color:var(--cyan);">$${cost.toFixed(4)}</span>
            </div>`;
        }
    }

    document.getElementById('costSection').innerHTML = html;
}

function renderAnomalies() {
    const list = state.anomalies;
    document.getElementById('anomalyList').innerHTML = list.length
        ? list.map(a => {
            const icon = (a.severity === 'HIGH' || a.severity === 'CRITICAL') ? '&#9888;' : '&#9432;';
            const sevClass = 'risk-' + (a.severity || 'low').toLowerCase();
            return `<div class="anomaly-card">
                <div class="anomaly-icon">${icon}</div>
                <div style="flex:1;">
                    <div style="display:flex;gap:8px;align-items:center;">
                        <span class="anomaly-type">${a.type || ''}</span>
                        <span class="agent-label">${a.agentID || ''}</span>
                    </div>
                    <div class="anomaly-desc">${a.description || ''}</div>
                </div>
                <span class="badge badge-${a.severity === 'HIGH' || a.severity === 'CRITICAL' ? 'blocked' : 'flagged'}">${a.severity || 'LOW'}</span>
            </div>`;
        }).join('')
        : '<div class="empty-state"><div class="empty-state-icon">&#128737;</div>No anomalies detected</div>';
}

function renderPolicies() {
    const list = state.policies;
    document.getElementById('policyList').innerHTML = list.length
        ? list.map(p => `<div class="policy-card">
            <div class="policy-header">
                <div class="policy-dot" style="background:${p.enabled ? 'var(--green)' : 'var(--gray)'};"></div>
                <div class="policy-name">${p.name || ''}</div>
                <span class="badge badge-${p.riskLevel === 'HIGH' || p.riskLevel === 'CRITICAL' ? 'blocked' : p.riskLevel === 'MEDIUM' ? 'flagged' : 'allowed'}">${p.riskLevel || 'LOW'}</span>
            </div>
            <div class="policy-desc">${p.description || ''}</div>
            <div class="policy-meta">
                <span>Pattern: ${p.actionPattern || '*'}</span>
                ${p.requireApproval ? '<span style="color:var(--orange);">REQUIRES APPROVAL</span>' : ''}
                ${p.maxCostPerAction > 0 ? `<span style="color:var(--green);">Max: $${p.maxCostPerAction.toFixed(2)}</span>` : ''}
            </div>
        </div>`).join('')
        : '<div class="empty-state"><div class="empty-state-icon">&#128196;</div>No policies configured</div>';
}

function decisionRowHTML(d) {
    const riskClass = 'risk-' + (d.riskLevel || 'low').toLowerCase();
    const badgeClass = 'badge-' + (d.policyResult || 'allowed');
    const cost = d.cost > 0 ? `<span class="cost-label">$${d.cost.toFixed(4)}</span>` : '';
    const ts = d.timestamp ? d.timestamp.substring(11, 19) : '';
    return `<div class="decision-row" onclick="showDetail('${d.id}')">
        <div class="risk-dot ${riskClass}"></div>
        <div class="agent-label">${d.agentID || ''}</div>
        <div class="action-label">${d.action || ''}</div>
        <span class="badge ${badgeClass}">${(d.policyResult || 'ALLOWED').toUpperCase()}</span>
        ${cost}
        <span class="time-label">${ts}</span>
    </div>`;
}

function approvalCardHTML(a) {
    return `<div class="approval-card">
        <div class="approval-header">
            <span class="agent-label">${a.agentID || ''}</span>
            <span class="badge badge-flagged">${a.riskLevel || 'HIGH'}</span>
        </div>
        <div class="approval-action">${a.action || ''}</div>
        <div class="approval-reasoning">${a.reasoning || ''}</div>
        <div class="approval-buttons">
            <button class="btn btn-approve" onclick="approveAction('${a.id}')">&#10003; Approve</button>
            <button class="btn btn-reject" onclick="rejectAction('${a.id}')">&#10007; Reject</button>
            ${a.cost > 0 ? `<span style="font-size:11px;color:var(--text-dim);align-self:center;">Est: $${a.cost.toFixed(4)}</span>` : ''}
        </div>
    </div>`;
}

function updateBadges() {
    const ab = document.getElementById('approvalBadge');
    const nb = document.getElementById('anomalyBadge');
    if (state.stats.pendingApprovals > 0) { ab.textContent = state.stats.pendingApprovals; ab.style.display = ''; }
    else { ab.style.display = 'none'; }
    if (state.anomalies.length > 0) { nb.textContent = state.anomalies.length; nb.style.display = ''; }
    else { nb.style.display = 'none'; }
}

function switchTab(tab) {
    document.querySelectorAll('.tab-item').forEach(t => t.classList.toggle('active', t.dataset.tab === tab));
    document.querySelectorAll('.tab-panel').forEach(p => p.classList.toggle('active', p.id === 'panel-' + tab));
}

async function showDetail(id) {
    const data = await api('/v1/governance/decisions/' + id);
    if (!data || data.error) return;
    const d = data.decision || data;
    let html = `<div style="display:flex;justify-content:space-between;margin-bottom:16px;">
        <span style="font-size:16px;font-weight:700;color:var(--text-bright);">Decision Detail</span>
        <button class="btn btn-secondary" onclick="closeDetail()" style="padding:4px 10px;">Close</button>
    </div>`;
    const fields = [
        ['ID', d.id], ['Agent', d.agentID], ['Action', d.action],
        ['Reasoning', d.reasoning], ['Confidence', ((d.confidence || 0) * 100).toFixed(1) + '%'],
        ['Cost', '$' + (d.cost || 0).toFixed(4)], ['Risk', d.riskLevel],
        ['Policy', d.policyResult], ['Outcome', d.outcome]
    ];
    for (const [label, val] of fields) {
        html += `<div class="detail-row"><div class="detail-label">${label}</div><div class="detail-value">${val || '-'}</div></div>`;
    }
    if (data.policyChecks) {
        html += '<div class="section-title" style="margin-top:14px;">POLICY CHECKS</div>';
        for (const check of data.policyChecks) {
            html += `<div style="font-size:11px;font-family:monospace;color:var(--text-dim);padding:2px 0;">${check}</div>`;
        }
    }
    if (data.relatedDecisions && data.relatedDecisions.length) {
        html += `<div class="section-title" style="margin-top:14px;">RELATED DECISIONS (${data.relatedDecisions.length})</div>`;
        for (const r of data.relatedDecisions.slice(0, 5)) {
            html += `<div style="font-size:11px;color:var(--text-dim);padding:2px 0;">${r.action} — ${r.outcome || ''}</div>`;
        }
    }
    document.getElementById('detailContent').innerHTML = html;
    document.getElementById('detailModal').classList.add('visible');
}

function closeDetail() { document.getElementById('detailModal').classList.remove('visible'); }

async function approveAction(id) {
    await api('/v1/governance/approve/' + id, 'POST');
    await refresh();
}

async function rejectAction(id) {
    await api('/v1/governance/reject/' + id, 'POST');
    await refresh();
}

async function scanAnomalies() {
    await api('/v1/governance/anomalies', 'POST');
    await refresh();
}

async function exportAudit(format) {
    const r = await fetch('/v1/governance/audit/export?format=' + format, {
        headers: { 'Authorization': 'Bearer ' + getToken() }
    });
    const blob = await r.blob();
    const a = document.createElement('a');
    a.href = URL.createObjectURL(blob);
    a.download = 'torbo-governance-export.' + (format === 'csv' ? 'csv' : 'json');
    a.click();
    URL.revokeObjectURL(a.href);
}

// Auto-refresh every 5 seconds
function startAutoRefresh() {
    if (refreshTimer) clearInterval(refreshTimer);
    refreshTimer = setInterval(() => {
        if (document.getElementById('autoRefresh').checked) refresh();
    }, 5000);
}

// Init
refresh();
startAutoRefresh();
</script>
</body>
</html>
"""
}
