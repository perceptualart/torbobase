// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — Visual Workflow Designer Web UI
// Self-contained HTML/CSS/JS workflow editor served from the gateway.
// Uses SVG for node rendering and Bezier curves for connections.
// Works on Linux where SwiftUI is not available.
import Foundation

// MARK: - Workflow Designer HTML

enum WorkflowDesignerHTML {

    /// Serve the workflow designer web UI
    static func page() -> String {
        """
        <!DOCTYPE html>
        <html lang="en">
        <head>
            <meta charset="UTF-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            <title>Torbo Base — Workflow Designer</title>
            <meta http-equiv="Content-Security-Policy" content="default-src 'self' 'unsafe-inline' 'unsafe-eval'; connect-src 'self' http://127.0.0.1:*;">
            <style>
                \(css)
            </style>
        </head>
        <body>
            <div id="app">
                <div id="sidebar">
                    <div class="sidebar-header">
                        <h2>WORKFLOWS</h2>
                        <button id="btn-new" title="New Workflow">+</button>
                    </div>
                    <div id="template-section">
                        <div class="section-header" onclick="toggleSection('templates')">Templates</div>
                        <div id="templates" class="collapsed"></div>
                    </div>
                    <div id="workflow-list"></div>
                </div>
                <div id="main">
                    <div id="toolbar">
                        <input id="wf-name" placeholder="Workflow Name" />
                        <div class="toolbar-spacer"></div>
                        <button id="btn-palette" class="tool-btn" title="Add Node">Nodes</button>
                        <button id="btn-validate" class="tool-btn" title="Validate">Validate</button>
                        <button id="btn-run" class="tool-btn run" title="Execute">Run</button>
                        <span id="zoom-display">100%</span>
                        <button class="tool-btn small" onclick="zoomCanvas(-0.1)">-</button>
                        <button class="tool-btn small" onclick="zoomCanvas(0.1)">+</button>
                    </div>
                    <div id="canvas-container">
                        <svg id="connections-layer"></svg>
                        <div id="canvas"></div>
                        <div id="node-palette" class="hidden">
                            <div class="palette-title">ADD NODE</div>
                            <div class="palette-item" data-kind="trigger" onclick="addNode('trigger')">
                                <span class="icon trigger">&#9889;</span> Trigger
                            </div>
                            <div class="palette-item" data-kind="agent" onclick="addNode('agent')">
                                <span class="icon agent">&#129504;</span> Agent
                            </div>
                            <div class="palette-item" data-kind="decision" onclick="addNode('decision')">
                                <span class="icon decision">&#8644;</span> Decision
                            </div>
                            <div class="palette-item" data-kind="action" onclick="addNode('action')">
                                <span class="icon action">&#9881;</span> Action
                            </div>
                            <div class="palette-item" data-kind="approval" onclick="addNode('approval')">
                                <span class="icon approval">&#9995;</span> Approval
                            </div>
                        </div>
                    </div>
                </div>
            </div>
            <div id="node-editor" class="modal hidden">
                <div class="modal-content">
                    <div class="modal-header">
                        <h3 id="editor-title">Edit Node</h3>
                        <button onclick="closeEditor()">&#10005;</button>
                    </div>
                    <div id="editor-body"></div>
                    <div class="modal-footer">
                        <button onclick="closeEditor()">Cancel</button>
                        <button class="primary" onclick="saveNode()">Save</button>
                    </div>
                </div>
            </div>
            <script>
                \(javascript)
            </script>
        </body>
        </html>
        """
    }

    // MARK: - CSS

    private static var css: String {
        """
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body { background: #0a0a0a; color: #e0e0e0; font-family: -apple-system, system-ui, sans-serif; overflow: hidden; }
        #app { display: flex; height: 100vh; }

        /* Sidebar */
        #sidebar { width: 220px; background: #111; border-right: 1px solid #1a1a1a; display: flex; flex-direction: column; }
        .sidebar-header { display: flex; align-items: center; justify-content: space-between; padding: 12px; border-bottom: 1px solid #1a1a1a; }
        .sidebar-header h2 { font-size: 10px; letter-spacing: 2px; color: #666; font-weight: 700; }
        .sidebar-header button { background: none; border: none; color: #666; font-size: 18px; cursor: pointer; }
        .sidebar-header button:hover { color: #fff; }
        .section-header { font-size: 10px; color: #555; padding: 8px 12px; cursor: pointer; user-select: none; }
        .section-header:hover { color: #888; }
        .collapsed { display: none; }
        #workflow-list { flex: 1; overflow-y: auto; padding: 4px 8px; }
        .wf-item { padding: 8px 10px; border-radius: 6px; cursor: pointer; margin-bottom: 2px; display: flex; align-items: center; gap: 8px; }
        .wf-item:hover { background: rgba(255,255,255,0.04); }
        .wf-item.selected { background: rgba(255,255,255,0.08); }
        .wf-dot { width: 6px; height: 6px; border-radius: 50%; flex-shrink: 0; }
        .wf-dot.enabled { background: #10b981; }
        .wf-dot.disabled { background: #555; }
        .wf-info { flex: 1; min-width: 0; }
        .wf-name { font-size: 12px; font-weight: 500; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
        .wf-meta { font-size: 9px; color: #555; }
        .template-item { padding: 6px 12px; cursor: pointer; font-size: 11px; color: #888; }
        .template-item:hover { color: #fff; background: rgba(255,255,255,0.03); }

        /* Toolbar */
        #toolbar { height: 40px; background: #0d0d0d; border-bottom: 1px solid #1a1a1a; display: flex; align-items: center; padding: 0 12px; gap: 8px; }
        #wf-name { background: transparent; border: none; color: #fff; font-size: 14px; font-weight: 600; width: 250px; outline: none; }
        .toolbar-spacer { flex: 1; }
        .tool-btn { background: rgba(255,255,255,0.04); border: 1px solid rgba(255,255,255,0.08); color: #aaa; padding: 4px 10px; border-radius: 5px; font-size: 11px; cursor: pointer; }
        .tool-btn:hover { background: rgba(255,255,255,0.08); color: #fff; }
        .tool-btn.run { background: rgba(16,185,129,0.2); border-color: rgba(16,185,129,0.3); color: #10b981; }
        .tool-btn.run:hover { background: rgba(16,185,129,0.3); }
        .tool-btn.small { padding: 4px 6px; font-size: 10px; }
        #zoom-display { font-size: 10px; color: #555; font-family: monospace; width: 36px; text-align: center; }

        /* Canvas */
        #main { flex: 1; display: flex; flex-direction: column; }
        #canvas-container { flex: 1; position: relative; overflow: hidden; background: #080808; }
        #canvas { position: absolute; top: 0; left: 0; width: 10000px; height: 10000px; transform-origin: 0 0; }
        #connections-layer { position: absolute; top: 0; left: 0; width: 100%; height: 100%; pointer-events: none; z-index: 1; }

        /* Nodes */
        .node { position: absolute; width: 160px; background: #151515; border: 1px solid #222; border-radius: 8px; cursor: grab; user-select: none; z-index: 2; }
        .node:hover { border-color: #333; }
        .node.selected { border-color: #8b5cf6; box-shadow: 0 0 12px rgba(139,92,246,0.2); }
        .node.active { border-color: #10b981; box-shadow: 0 0 12px rgba(16,185,129,0.3); }
        .node-header { padding: 5px 10px; border-radius: 7px 7px 0 0; display: flex; align-items: center; gap: 6px; }
        .node-header span { font-size: 8px; font-weight: 700; letter-spacing: 1px; text-transform: uppercase; }
        .node-body { padding: 8px 10px; }
        .node-label { font-size: 11px; font-weight: 500; }
        .node-detail { font-size: 9px; color: #555; margin-top: 3px; }

        .node[data-kind="trigger"] .node-header { background: rgba(245,158,11,0.15); color: #f59e0b; }
        .node[data-kind="agent"] .node-header { background: rgba(139,92,246,0.15); color: #8b5cf6; }
        .node[data-kind="decision"] .node-header { background: rgba(59,130,246,0.15); color: #3b82f6; }
        .node[data-kind="action"] .node-header { background: rgba(16,185,129,0.15); color: #10b981; }
        .node[data-kind="approval"] .node-header { background: rgba(239,68,68,0.15); color: #ef4444; }

        /* Connection ports */
        .port { position: absolute; width: 10px; height: 10px; border-radius: 50%; background: #333; border: 2px solid #555; cursor: crosshair; z-index: 3; }
        .port:hover { background: #666; border-color: #888; }
        .port.out { right: -5px; top: 50%; transform: translateY(-50%); }
        .port.in { left: -5px; top: 50%; transform: translateY(-50%); }

        /* Node Palette */
        #node-palette { position: absolute; top: 12px; left: 12px; width: 180px; background: #151515; border: 1px solid #222; border-radius: 10px; z-index: 10; box-shadow: 0 8px 24px rgba(0,0,0,0.5); }
        #node-palette.hidden { display: none; }
        .palette-title { font-size: 9px; font-weight: 700; letter-spacing: 2px; color: #555; padding: 10px 12px 6px; }
        .palette-item { padding: 8px 12px; cursor: pointer; font-size: 12px; display: flex; align-items: center; gap: 8px; }
        .palette-item:hover { background: rgba(255,255,255,0.04); }
        .icon { font-size: 14px; }
        .icon.trigger { color: #f59e0b; }
        .icon.agent { color: #8b5cf6; }
        .icon.decision { color: #3b82f6; }
        .icon.action { color: #10b981; }
        .icon.approval { color: #ef4444; }

        /* Modal */
        .modal { position: fixed; top: 0; left: 0; right: 0; bottom: 0; background: rgba(0,0,0,0.7); display: flex; align-items: center; justify-content: center; z-index: 100; }
        .modal.hidden { display: none; }
        .modal-content { background: #1a1a1a; border: 1px solid #333; border-radius: 12px; width: 480px; max-height: 80vh; overflow-y: auto; }
        .modal-header { display: flex; justify-content: space-between; align-items: center; padding: 16px; border-bottom: 1px solid #222; }
        .modal-header h3 { font-size: 14px; font-weight: 600; }
        .modal-header button { background: none; border: none; color: #666; font-size: 16px; cursor: pointer; }
        .modal-footer { display: flex; justify-content: flex-end; gap: 8px; padding: 12px 16px; border-top: 1px solid #222; }
        .modal-footer button { padding: 6px 16px; border-radius: 6px; border: 1px solid #333; background: #222; color: #aaa; cursor: pointer; font-size: 12px; }
        .modal-footer button.primary { background: #3b82f6; border-color: #3b82f6; color: #fff; }
        #editor-body { padding: 16px; }
        #editor-body label { display: block; font-size: 10px; font-weight: 700; letter-spacing: 1px; color: #555; margin-bottom: 4px; margin-top: 12px; }
        #editor-body input, #editor-body select, #editor-body textarea { width: 100%; padding: 8px; background: #111; border: 1px solid #333; border-radius: 6px; color: #ddd; font-size: 12px; outline: none; }
        #editor-body textarea { min-height: 80px; resize: vertical; font-family: monospace; }
        #editor-body select { appearance: auto; }

        /* Empty state */
        .empty-state { display: flex; flex-direction: column; align-items: center; justify-content: center; height: 100%; color: #333; }
        .empty-state .icon { font-size: 48px; margin-bottom: 12px; }
        .empty-state p { font-size: 14px; }

        /* Scrollbar */
        ::-webkit-scrollbar { width: 6px; }
        ::-webkit-scrollbar-track { background: transparent; }
        ::-webkit-scrollbar-thumb { background: #222; border-radius: 3px; }
        """
    }

    // MARK: - JavaScript

    private static var javascript: String {
        """
        // State
        let workflows = [];
        let currentWorkflow = null;
        let selectedNodeId = null;
        let editingNode = null;
        let scale = 1.0;
        let panX = 0, panY = 0;
        let isDragging = false;
        let dragNode = null;
        let dragOffsetX = 0, dragOffsetY = 0;
        let isConnecting = false;
        let connectFromId = null;

        const API = '/v1/visual-workflows';

        // Init
        document.addEventListener('DOMContentLoaded', () => {
            loadWorkflows();
            loadTemplates();
            document.getElementById('btn-new').addEventListener('click', createWorkflow);
            document.getElementById('btn-palette').addEventListener('click', togglePalette);
            document.getElementById('btn-validate').addEventListener('click', validateWorkflow);
            document.getElementById('btn-run').addEventListener('click', runWorkflow);
            document.getElementById('wf-name').addEventListener('change', (e) => {
                if (currentWorkflow) { currentWorkflow.name = e.target.value; saveWorkflow(); }
            });

            // Canvas pan
            const container = document.getElementById('canvas-container');
            let isPanning = false, panStartX, panStartY;
            container.addEventListener('mousedown', (e) => {
                if (e.target === container || e.target.id === 'canvas') {
                    isPanning = true; panStartX = e.clientX - panX; panStartY = e.clientY - panY;
                    selectedNodeId = null; updateNodeSelection();
                }
            });
            container.addEventListener('mousemove', (e) => {
                if (isPanning) { panX = e.clientX - panStartX; panY = e.clientY - panStartY; applyTransform(); }
                if (isDragging && dragNode) {
                    const rect = container.getBoundingClientRect();
                    dragNode.positionX = (e.clientX - rect.left - panX - dragOffsetX) / scale;
                    dragNode.positionY = (e.clientY - rect.top - panY - dragOffsetY) / scale;
                    renderNodes(); renderConnections();
                }
            });
            container.addEventListener('mouseup', () => {
                if (isPanning) isPanning = false;
                if (isDragging) { isDragging = false; dragNode = null; saveWorkflow(); }
            });
        });

        // API calls
        async function api(method, path, body) {
            const opts = { method, headers: { 'Content-Type': 'application/json' } };
            if (body) opts.body = JSON.stringify(body);
            const res = await fetch(API + path, opts);
            return res.json();
        }

        async function loadWorkflows() {
            const data = await api('GET', '');
            workflows = data.workflows || [];
            renderWorkflowList();
        }

        async function loadTemplates() {
            const data = await api('GET', '/templates');
            const container = document.getElementById('templates');
            container.innerHTML = '';
            (data.templates || []).forEach(t => {
                const el = document.createElement('div');
                el.className = 'template-item';
                el.textContent = t.name;
                el.onclick = () => createFromTemplate(t.name);
                container.appendChild(el);
            });
        }

        async function createWorkflow() {
            const data = await api('POST', '', { name: 'New Workflow' });
            await loadWorkflows();
            selectWorkflow(data.id);
        }

        async function createFromTemplate(name) {
            const data = await api('POST', '/from-template/' + encodeURIComponent(name));
            await loadWorkflows();
            selectWorkflow(data.id);
        }

        async function selectWorkflow(id) {
            const res = await fetch(API + '/' + id);
            currentWorkflow = await res.json();
            document.getElementById('wf-name').value = currentWorkflow.name || '';
            selectedNodeId = null;
            renderNodes();
            renderConnections();
            renderWorkflowList();
        }

        async function saveWorkflow() {
            if (!currentWorkflow) return;
            await api('PUT', '/' + currentWorkflow.id, currentWorkflow);
        }

        async function deleteWorkflow(id) {
            await api('DELETE', '/' + id);
            if (currentWorkflow && currentWorkflow.id === id) currentWorkflow = null;
            await loadWorkflows();
            if (!currentWorkflow) { document.getElementById('canvas').innerHTML = ''; }
        }

        // Render
        function renderWorkflowList() {
            const list = document.getElementById('workflow-list');
            list.innerHTML = '';
            workflows.forEach(wf => {
                const el = document.createElement('div');
                el.className = 'wf-item' + (currentWorkflow && currentWorkflow.id === wf.id ? ' selected' : '');
                el.innerHTML = `<div class="wf-dot ${wf.enabled ? 'enabled' : 'disabled'}"></div>
                    <div class="wf-info"><div class="wf-name">${esc(wf.name)}</div>
                    <div class="wf-meta">${wf.node_count} nodes</div></div>`;
                el.onclick = () => selectWorkflow(wf.id);
                el.oncontextmenu = (e) => { e.preventDefault(); if (confirm('Delete ' + wf.name + '?')) deleteWorkflow(wf.id); };
                list.appendChild(el);
            });
        }

        function renderNodes() {
            const canvas = document.getElementById('canvas');
            canvas.innerHTML = '';
            if (!currentWorkflow || !currentWorkflow.nodes) return;
            currentWorkflow.nodes.forEach(node => {
                const el = document.createElement('div');
                el.className = 'node' + (selectedNodeId === node.id ? ' selected' : '');
                el.dataset.kind = node.kind;
                el.dataset.id = node.id;
                el.style.left = node.positionX + 'px';
                el.style.top = node.positionY + 'px';

                const icons = { trigger: '&#9889;', agent: '&#129504;', decision: '&#8644;', action: '&#9881;', approval: '&#9995;' };
                const names = { trigger: 'TRIGGER', agent: 'AGENT', decision: 'DECISION', action: 'ACTION', approval: 'APPROVAL' };

                el.innerHTML = `
                    <div class="node-header"><span>${icons[node.kind] || ''} ${names[node.kind] || ''}</span></div>
                    <div class="node-body">
                        <div class="node-label">${esc(node.label)}</div>
                        <div class="node-detail">${nodeDetail(node)}</div>
                    </div>
                    <div class="port in" data-node="${node.id}" data-dir="in"></div>
                    <div class="port out" data-node="${node.id}" data-dir="out"></div>
                `;

                // Drag
                el.addEventListener('mousedown', (e) => {
                    if (e.target.classList.contains('port')) {
                        // Start connection
                        if (e.target.dataset.dir === 'out') {
                            isConnecting = true;
                            connectFromId = e.target.dataset.node;
                        }
                        return;
                    }
                    isDragging = true;
                    dragNode = node;
                    const rect = el.getBoundingClientRect();
                    dragOffsetX = (e.clientX - rect.left) * scale;
                    dragOffsetY = (e.clientY - rect.top) * scale;
                    e.stopPropagation();
                });

                el.addEventListener('mouseup', (e) => {
                    if (isConnecting && e.target.classList.contains('port') && e.target.dataset.dir === 'in') {
                        const toId = e.target.dataset.node;
                        if (connectFromId && connectFromId !== toId) {
                            addConnection(connectFromId, toId);
                        }
                    }
                    isConnecting = false;
                    connectFromId = null;
                });

                // Select / Edit
                el.addEventListener('click', (e) => {
                    if (e.target.classList.contains('port')) return;
                    selectedNodeId = node.id;
                    updateNodeSelection();
                });
                el.addEventListener('dblclick', () => openEditor(node));

                canvas.appendChild(el);
            });
        }

        function renderConnections() {
            const svg = document.getElementById('connections-layer');
            svg.innerHTML = '';
            if (!currentWorkflow || !currentWorkflow.connections) return;

            currentWorkflow.connections.forEach(conn => {
                const fromNode = currentWorkflow.nodes.find(n => n.id === conn.fromNodeID);
                const toNode = currentWorkflow.nodes.find(n => n.id === conn.toNodeID);
                if (!fromNode || !toNode) return;

                const x1 = (fromNode.positionX + 160) * scale + panX;
                const y1 = (fromNode.positionY + 25) * scale + panY;
                const x2 = toNode.positionX * scale + panX;
                const y2 = (toNode.positionY + 25) * scale + panY;
                const mx = (x1 + x2) / 2;

                const path = document.createElementNS('http://www.w3.org/2000/svg', 'path');
                path.setAttribute('d', `M${x1},${y1} C${mx},${y1} ${mx},${y2} ${x2},${y2}`);
                path.setAttribute('fill', 'none');
                path.setAttribute('stroke', 'rgba(255,255,255,0.15)');
                path.setAttribute('stroke-width', '1.5');
                svg.appendChild(path);

                if (conn.label) {
                    const text = document.createElementNS('http://www.w3.org/2000/svg', 'text');
                    text.setAttribute('x', mx);
                    text.setAttribute('y', (y1 + y2) / 2 - 5);
                    text.setAttribute('fill', conn.label === 'true' ? '#10b981' : '#ef4444');
                    text.setAttribute('font-size', '9');
                    text.setAttribute('font-family', 'monospace');
                    text.setAttribute('text-anchor', 'middle');
                    text.textContent = conn.label;
                    svg.appendChild(text);
                }
            });
        }

        function applyTransform() {
            const canvas = document.getElementById('canvas');
            canvas.style.transform = `translate(${panX}px, ${panY}px) scale(${scale})`;
            renderConnections();
        }

        // Node operations
        function addNode(kind) {
            if (!currentWorkflow) return;
            if (!currentWorkflow.nodes) currentWorkflow.nodes = [];
            const node = {
                id: crypto.randomUUID(),
                kind: kind,
                label: kind.charAt(0).toUpperCase() + kind.slice(1),
                positionX: 200 + currentWorkflow.nodes.length * 200,
                positionY: 150,
                config: { values: {} }
            };
            currentWorkflow.nodes.push(node);
            renderNodes();
            saveWorkflow();
            togglePalette();
        }

        function addConnection(fromId, toId, label) {
            if (!currentWorkflow) return;
            if (!currentWorkflow.connections) currentWorkflow.connections = [];
            // Prevent duplicates
            if (currentWorkflow.connections.find(c => c.fromNodeID === fromId && c.toNodeID === toId)) return;
            currentWorkflow.connections.push({
                id: crypto.randomUUID(),
                fromNodeID: fromId,
                toNodeID: toId,
                label: label || null
            });
            renderConnections();
            saveWorkflow();
        }

        function nodeDetail(node) {
            const v = node.config && node.config.values ? node.config.values : {};
            switch (node.kind) {
                case 'trigger': return v.triggerKind || 'manual';
                case 'agent': return v.agentID ? 'Agent: ' + v.agentID : '';
                case 'decision': return v.condition || '';
                case 'action': return v.actionKind || '';
                case 'approval': return v.timeout ? 'Timeout: ' + v.timeout + 's' : '';
                default: return '';
            }
        }

        // Editor
        function openEditor(node) {
            editingNode = JSON.parse(JSON.stringify(node)); // deep copy
            document.getElementById('editor-title').textContent = 'Edit ' + node.kind.charAt(0).toUpperCase() + node.kind.slice(1);
            const body = document.getElementById('editor-body');
            body.innerHTML = `<label>LABEL</label><input id="ed-label" value="${esc(node.label)}" />`;

            const v = node.config && node.config.values ? node.config.values : {};

            switch (node.kind) {
                case 'trigger':
                    body.innerHTML += `<label>TRIGGER TYPE</label>
                        <select id="ed-triggerKind">
                            <option value="schedule" ${v.triggerKind==='schedule'?'selected':''}>Schedule (Cron)</option>
                            <option value="webhook" ${v.triggerKind==='webhook'?'selected':''}>Webhook</option>
                            <option value="telegram" ${v.triggerKind==='telegram'?'selected':''}>Telegram Message</option>
                            <option value="email" ${v.triggerKind==='email'?'selected':''}>Email</option>
                            <option value="fileChange" ${v.triggerKind==='fileChange'?'selected':''}>File Change</option>
                            <option value="manual" ${v.triggerKind==='manual'?'selected':''}>Manual</option>
                        </select>
                        <label>CRON / PATH / KEYWORD</label><input id="ed-triggerParam" value="${esc(v.cron || v.path || v.keyword || v.filter || '')}" />`;
                    break;
                case 'agent':
                    body.innerHTML += `<label>AGENT ID</label><input id="ed-agentID" value="${esc(v.agentID || 'sid')}" />
                        <label>PROMPT OVERRIDE</label><textarea id="ed-prompt">${esc(v.prompt || '')}</textarea>`;
                    break;
                case 'decision':
                    body.innerHTML += `<label>CONDITION</label><input id="ed-condition" value="${esc(v.condition || 'true')}" />
                        <p style="font-size:9px;color:#555;margin-top:8px">contains('text'), equals('val'), length > N, not_empty, true/false</p>`;
                    break;
                case 'action':
                    body.innerHTML += `<label>ACTION TYPE</label>
                        <select id="ed-actionKind">
                            <option value="sendMessage" ${v.actionKind==='sendMessage'?'selected':''}>Send Message</option>
                            <option value="writeFile" ${v.actionKind==='writeFile'?'selected':''}>Write File</option>
                            <option value="runCommand" ${v.actionKind==='runCommand'?'selected':''}>Run Command</option>
                            <option value="callWebhook" ${v.actionKind==='callWebhook'?'selected':''}>Call Webhook</option>
                            <option value="sendEmail" ${v.actionKind==='sendEmail'?'selected':''}>Send Email</option>
                            <option value="broadcast" ${v.actionKind==='broadcast'?'selected':''}>Broadcast</option>
                        </select>
                        <label>TARGET / PATH / URL</label><input id="ed-actionTarget" value="${esc(v.target || v.path || v.url || v.to || v.channel || '')}" />
                        <label>MESSAGE / CONTENT</label><textarea id="ed-actionContent">${esc(v.message || v.content || v.body || v.command || v.subject || '')}</textarea>`;
                    break;
                case 'approval':
                    body.innerHTML += `<label>APPROVAL MESSAGE</label><textarea id="ed-message">${esc(v.message || 'Approve this step?')}</textarea>
                        <label>TIMEOUT (seconds)</label><input id="ed-timeout" type="number" value="${v.timeout || 300}" />`;
                    break;
            }

            document.getElementById('node-editor').classList.remove('hidden');
        }

        function closeEditor() {
            document.getElementById('node-editor').classList.add('hidden');
            editingNode = null;
        }

        function saveNode() {
            if (!editingNode || !currentWorkflow) return;
            const idx = currentWorkflow.nodes.findIndex(n => n.id === editingNode.id);
            if (idx < 0) return;

            const node = currentWorkflow.nodes[idx];
            node.label = document.getElementById('ed-label').value;
            if (!node.config) node.config = { values: {} };
            const v = node.config.values;

            switch (node.kind) {
                case 'trigger': {
                    const kind = document.getElementById('ed-triggerKind').value;
                    v.triggerKind = kind;
                    const param = document.getElementById('ed-triggerParam').value;
                    if (kind === 'schedule') v.cron = param;
                    else if (kind === 'webhook') v.path = param;
                    else if (kind === 'telegram') v.keyword = param;
                    else if (kind === 'email') v.filter = param;
                    else if (kind === 'fileChange') v.path = param;
                    break;
                }
                case 'agent':
                    v.agentID = document.getElementById('ed-agentID').value;
                    v.prompt = document.getElementById('ed-prompt').value;
                    break;
                case 'decision':
                    v.condition = document.getElementById('ed-condition').value;
                    break;
                case 'action': {
                    const actionKind = document.getElementById('ed-actionKind').value;
                    v.actionKind = actionKind;
                    const target = document.getElementById('ed-actionTarget').value;
                    const content = document.getElementById('ed-actionContent').value;
                    if (actionKind === 'sendMessage') { v.platform = 'telegram'; v.target = target; v.message = content; }
                    else if (actionKind === 'writeFile') { v.path = target; v.content = content; }
                    else if (actionKind === 'runCommand') { v.command = content; }
                    else if (actionKind === 'callWebhook') { v.url = target; v.body = content; v.method = 'POST'; }
                    else if (actionKind === 'sendEmail') { v.to = target; v.subject = content; }
                    else if (actionKind === 'broadcast') { v.channel = target; v.message = content; }
                    break;
                }
                case 'approval':
                    v.message = document.getElementById('ed-message').value;
                    v.timeout = parseFloat(document.getElementById('ed-timeout').value) || 300;
                    break;
            }

            renderNodes();
            saveWorkflow();
            closeEditor();
        }

        // Controls
        function togglePalette() {
            document.getElementById('node-palette').classList.toggle('hidden');
        }

        function toggleSection(id) {
            document.getElementById(id).classList.toggle('collapsed');
        }

        function zoomCanvas(delta) {
            scale = Math.max(0.3, Math.min(3.0, scale + delta));
            document.getElementById('zoom-display').textContent = Math.round(scale * 100) + '%';
            applyTransform();
        }

        function updateNodeSelection() {
            document.querySelectorAll('.node').forEach(el => {
                el.classList.toggle('selected', el.dataset.id === selectedNodeId);
            });
        }

        async function validateWorkflow() {
            if (!currentWorkflow) return;
            // Client-side validation
            const errors = [];
            const triggers = (currentWorkflow.nodes || []).filter(n => n.kind === 'trigger');
            if (triggers.length === 0) errors.push('No trigger node');
            const conns = currentWorkflow.connections || [];
            (currentWorkflow.nodes || []).forEach(n => {
                if (n.kind !== 'trigger' && !conns.find(c => c.toNodeID === n.id)) {
                    errors.push(n.label + ' has no incoming connection');
                }
            });
            alert(errors.length ? 'Errors:\\n' + errors.join('\\n') : 'Workflow is valid!');
        }

        async function runWorkflow() {
            if (!currentWorkflow) return;
            const data = await api('POST', '/' + currentWorkflow.id + '/execute');
            alert('Execution started: ' + data.status + ' (ID: ' + (data.execution_id || '').slice(0, 8) + ')');
        }

        function esc(s) { return String(s || '').replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;'); }
        """
    }
}
