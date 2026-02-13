// Torbo Base — by Michael David Murphy & Orion (Claude Opus 4.6, Anthropic)
// Embedded web chat UI — served at /chat endpoint
import Foundation

enum WebChatHTML {
    static let page = """
    <!DOCTYPE html>
    <html lang="en">
    <head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Torbo Base — Chat</title>
    <style>
    * { margin: 0; padding: 0; box-sizing: border-box; }
    :root {
        --bg: #0a0a0d; --surface: #111114; --border: rgba(255,255,255,0.06);
        --text: rgba(255,255,255,0.85); --text-dim: rgba(255,255,255,0.4);
        --cyan: #00e5ff; --purple: #a855f7;
    }
    body {
        font-family: -apple-system, BlinkMacSystemFont, 'SF Pro', sans-serif;
        background: var(--bg); color: var(--text);
        height: 100vh; display: flex; flex-direction: column;
    }
    .header {
        padding: 16px 24px; border-bottom: 1px solid var(--border);
        display: flex; align-items: center; gap: 12px;
        background: var(--surface);
    }
    .torbo-icon { width: 36px; height: 36px; }
    .torbo-icon canvas { width: 100%; height: 100%; }
    .header h1 {
        font-size: 14px; font-weight: 700; letter-spacing: 2px;
        font-family: 'SF Mono', monospace;
    }
    .header .status {
        font-size: 11px; color: var(--text-dim);
        margin-left: auto; font-family: 'SF Mono', monospace;
    }
    .messages {
        flex: 1; overflow-y: auto; padding: 24px;
        display: flex; flex-direction: column; gap: 16px;
    }
    .message { max-width: 75%; display: flex; flex-direction: column; gap: 4px; }
    .message.user { align-self: flex-end; }
    .message.assistant { align-self: flex-start; }
    .message .bubble {
        padding: 10px 14px; border-radius: 12px;
        font-size: 14px; line-height: 1.5;
    }
    .message.user .bubble {
        white-space: pre-wrap;
        background: rgba(0, 229, 255, 0.12);
        border: 1px solid rgba(0, 229, 255, 0.2);
        border-radius: 12px 12px 2px 12px;
    }
    .message.assistant .bubble {
        background: var(--surface);
        border: 1px solid var(--border);
        border-radius: 12px 12px 12px 2px;
    }
    .message .meta {
        font-size: 10px; color: var(--text-dim);
        font-family: 'SF Mono', monospace;
    }
    .message.user .meta { text-align: right; }
    .input-area {
        padding: 16px 24px; border-top: 1px solid var(--border);
        background: var(--surface); display: flex; gap: 10px; align-items: flex-end;
    }
    .input-area textarea {
        flex: 1; background: rgba(255,255,255,0.04); border: 1px solid var(--border);
        border-radius: 8px; padding: 10px 14px; color: var(--text);
        font-size: 14px; font-family: inherit; resize: none;
        min-height: 42px; max-height: 120px; outline: none;
        transition: border-color 0.2s;
    }
    .input-area textarea:focus { border-color: rgba(0, 229, 255, 0.3); }
    .input-area button {
        background: var(--cyan); color: #000; border: none;
        border-radius: 8px; padding: 10px 18px; font-weight: 600;
        font-size: 13px; cursor: pointer; white-space: nowrap;
        transition: opacity 0.2s;
    }
    .input-area button:hover { opacity: 0.85; }
    .input-area button:disabled { opacity: 0.3; cursor: not-allowed; }
    .model-select {
        background: rgba(255,255,255,0.04); border: 1px solid var(--border);
        border-radius: 6px; padding: 6px 10px; color: var(--text-dim);
        font-size: 11px; font-family: 'SF Mono', monospace; outline: none;
    }
    .typing { display: flex; gap: 4px; padding: 4px 0; }
    .typing span {
        width: 6px; height: 6px; border-radius: 50%;
        background: var(--cyan); opacity: 0.3;
        animation: typing 1.2s infinite;
    }
    .typing span:nth-child(2) { animation-delay: 0.2s; }
    .typing span:nth-child(3) { animation-delay: 0.4s; }
    @keyframes typing {
        0%, 60%, 100% { opacity: 0.3; transform: translateY(0); }
        30% { opacity: 1; transform: translateY(-4px); }
    }
    .empty {
        flex: 1; display: flex; flex-direction: column;
        align-items: center; justify-content: center; gap: 16px;
        color: var(--text-dim);
    }
    .empty .torbo-big { width: 120px; height: 120px; }
    .empty .torbo-big canvas { width: 100%; height: 100%; }
    .empty p { font-size: 13px; }
    /* Markdown rendering */
    .bubble pre {
        background: rgba(0,0,0,0.4); border-radius: 6px;
        padding: 12px; margin: 8px 0; overflow-x: auto;
        border: 1px solid rgba(255,255,255,0.06);
    }
    .bubble pre code {
        font-family: 'SF Mono', 'Menlo', 'Consolas', monospace;
        font-size: 12px; color: #e0e0e0; background: none; padding: 0;
    }
    .bubble code {
        font-family: 'SF Mono', 'Menlo', monospace; font-size: 12px;
        background: rgba(0,229,255,0.08); padding: 2px 5px;
        border-radius: 3px; color: var(--cyan);
    }
    .bubble strong { color: #fff; }
    .bubble em { color: rgba(255,255,255,0.7); }
    .bubble ul, .bubble ol { margin: 6px 0 6px 20px; }
    .bubble li { margin: 2px 0; }
    .bubble h1,.bubble h2,.bubble h3 {
        color:#fff; margin: 10px 0 4px 0;
    }
    .bubble h1 { font-size: 16px; }
    .bubble h2 { font-size: 14px; }
    .bubble h3 { font-size: 13px; }
    .bubble a { color: var(--cyan); text-decoration: none; }
    .bubble a:hover { text-decoration: underline; }
    .bubble .cursor {
        animation: blink 1s step-end infinite; color: var(--cyan);
    }
    @keyframes blink { 50% { opacity: 0; } }
    /* Syntax highlighting (basic) */
    .token-keyword { color: #c678dd; }
    .token-string { color: #98c379; }
    .token-comment { color: #5c6370; font-style: italic; }
    .token-number { color: #d19a66; }
    .token-function { color: #61afef; }
    </style>
    </head>
    <body>
    <div class="header">
        <div class="torbo-icon"><canvas id="orbSmall" width="72" height="72"></canvas></div>
        <h1>TORBO BASE</h1>
        <select class="model-select" id="model">
            <option value="qwen2.5:7b">Loading models...</option>
        </select>
        <span class="status" id="status">Connecting...</span>
    </div>
    <div class="messages" id="messages">
        <div class="empty" id="emptyState">
            <div class="torbo-big"><canvas id="orbBig" width="240" height="240"></canvas></div>
            <p>Start a conversation</p>
        </div>
    </div>
    <div class="input-area">
        <textarea id="input" rows="1" placeholder="Type a message..." autofocus></textarea>
        <button id="send" onclick="sendMessage()">Send</button>
    </div>
    <script>
    const TOKEN = new URLSearchParams(window.location.search).get('token') || '';
    const BASE = window.location.origin;
    const messagesEl = document.getElementById('messages');
    const inputEl = document.getElementById('input');
    const modelEl = document.getElementById('model');
    const statusEl = document.getElementById('status');
    const sendBtn = document.getElementById('send');
    let conversationHistory = [];

    async function loadModels() {
        if (!TOKEN) {
            statusEl.textContent = 'No token';
            statusEl.style.color = '#ff4444';
            messagesEl.innerHTML = '<div class="empty"><div class="torbo-big" style="opacity:0.15"><canvas id="orbErr" width="240" height="240"></canvas></div><p style="color:#ff4444">Missing authentication token</p><p style="font-size:11px;color:rgba(255,255,255,0.2);margin-top:6px">Open Web Chat from Torbo Base dashboard<br>or add ?token=YOUR_TOKEN to the URL</p></div>';
            initOrb('orbErr', 240);
            sendBtn.disabled = true;
            return;
        }
        try {
            const res = await fetch(BASE + '/v1/models', {
                headers: { 'Authorization': 'Bearer ' + TOKEN }
            });
            if (res.status === 401) {
                statusEl.textContent = 'Auth failed';
                statusEl.style.color = '#ff4444';
                messagesEl.innerHTML = '<div class="empty"><div class="torbo-big" style="opacity:0.15"><canvas id="orbErr" width="240" height="240"></canvas></div><p style="color:#ff4444">Invalid token</p><p style="font-size:11px;color:rgba(255,255,255,0.2);margin-top:6px">Token may have been regenerated.<br>Open Web Chat from Torbo Base dashboard to get a fresh link.</p></div>';
                initOrb('orbErr', 240);
                sendBtn.disabled = true;
                return;
            }
            const data = await res.json();
            modelEl.innerHTML = '';
            (data.data || []).forEach(m => {
                const opt = document.createElement('option');
                opt.value = m.id; opt.textContent = m.id;
                modelEl.appendChild(opt);
            });
            if (modelEl.options.length === 0) {
                statusEl.textContent = 'No models';
                statusEl.style.color = '#ffaa00';
            } else {
                statusEl.textContent = 'Connected';
                statusEl.style.color = '#00e5ff';
            }
        } catch(e) {
            statusEl.textContent = 'Disconnected';
            statusEl.style.color = '#ff4444';
        }
    }

    function addMessage(role, content, model) {
        const empty = messagesEl.querySelector('.empty');
        if (empty) empty.remove();
        const div = document.createElement('div');
        div.className = 'message ' + role;
        const time = new Date().toLocaleTimeString([], {hour:'2-digit',minute:'2-digit'});
        div.innerHTML = `
            <div class="bubble">${escapeHtml(content)}</div>
            <div class="meta">${role === 'user' ? time : (model || '') + ' · ' + time}</div>
        `;
        messagesEl.appendChild(div);
        messagesEl.scrollTop = messagesEl.scrollHeight;
    }

    function showTyping() {
        const div = document.createElement('div');
        div.className = 'message assistant'; div.id = 'typing';
        div.innerHTML = '<div class="typing"><span></span><span></span><span></span></div>';
        messagesEl.appendChild(div);
        messagesEl.scrollTop = messagesEl.scrollHeight;
    }
    function hideTyping() { const t = document.getElementById('typing'); if(t) t.remove(); }

    async function sendMessage() {
        const text = inputEl.value.trim();
        if (!text) return;
        inputEl.value = '';
        inputEl.style.height = 'auto';
        addMessage('user', text);
        conversationHistory.push({ role: 'user', content: text });
        sendBtn.disabled = true;

        // Create streaming assistant message
        const empty = messagesEl.querySelector('.empty');
        if (empty) empty.remove();
        const div = document.createElement('div');
        div.className = 'message assistant';
        const time = new Date().toLocaleTimeString([], {hour:'2-digit',minute:'2-digit'});
        div.innerHTML = `<div class="bubble streaming"><span class="cursor">▊</span></div><div class="meta">${modelEl.value} · ${time}</div>`;
        messagesEl.appendChild(div);
        const bubble = div.querySelector('.bubble');
        messagesEl.scrollTop = messagesEl.scrollHeight;

        let fullContent = '';
        try {
            const res = await fetch(BASE + '/v1/chat/completions', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json', 'Authorization': 'Bearer ' + TOKEN },
                body: JSON.stringify({ model: modelEl.value, messages: conversationHistory, stream: true })
            });

            if (!res.ok) {
                const err = await res.json().catch(() => ({error:'Request failed'}));
                bubble.innerHTML = '⚠️ ' + (err.error || 'Error');
                bubble.classList.remove('streaming');
                sendBtn.disabled = false;
                return;
            }

            const contentType = res.headers.get('content-type') || '';
            if (contentType.includes('text/event-stream')) {
                // SSE streaming
                const reader = res.body.getReader();
                const decoder = new TextDecoder();
                let buffer = '';
                while (true) {
                    const { done, value } = await reader.read();
                    if (done) break;
                    buffer += decoder.decode(value, { stream: true });
                    const lines = buffer.split('\n');
                    buffer = lines.pop();
                    for (const line of lines) {
                        if (!line.startsWith('data: ')) continue;
                        const payload = line.slice(6).trim();
                        if (payload === '[DONE]') break;
                        try {
                            const chunk = JSON.parse(payload);
                            const delta = chunk.choices?.[0]?.delta?.content || '';
                            if (delta) {
                                fullContent += delta;
                                bubble.innerHTML = renderMarkdown(fullContent) + '<span class="cursor">▊</span>';
                                messagesEl.scrollTop = messagesEl.scrollHeight;
                            }
                        } catch(e) {}
                    }
                }
            } else {
                // Non-streaming JSON response
                const data = await res.json();
                if (data.choices && data.choices[0]) {
                    fullContent = data.choices[0].message.content;
                } else if (data.error) {
                    fullContent = '⚠️ ' + data.error;
                }
            }

            bubble.innerHTML = renderMarkdown(fullContent);
            bubble.classList.remove('streaming');
            if (fullContent) {
                conversationHistory.push({ role: 'assistant', content: fullContent });
            }
        } catch(e) {
            bubble.innerHTML = '⚠️ Connection error';
            bubble.classList.remove('streaming');
        }
        sendBtn.disabled = false;
        inputEl.focus();
    }

    function escapeHtml(s) {
        return s.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
    }

    function renderMarkdown(text) {
        let html = escapeHtml(text);
        // Code blocks with syntax highlighting
        html = html.replace(/```(\\w*)\\n([\\s\\S]*?)```/g, (_, lang, code) => {
            const highlighted = highlightSyntax(code.trim(), lang);
            const langLabel = lang ? `<div style="font-size:10px;color:rgba(255,255,255,0.2);margin-bottom:4px;font-family:monospace">${lang}</div>` : '';
            return `<pre>${langLabel}<code>${highlighted}</code></pre>`;
        });
        // Inline code
        html = html.replace(/`([^`]+)`/g, '<code>$1</code>');
        // Headers
        html = html.replace(/^### (.+)$/gm, '<h3>$1</h3>');
        html = html.replace(/^## (.+)$/gm, '<h2>$1</h2>');
        html = html.replace(/^# (.+)$/gm, '<h1>$1</h1>');
        // Bold + Italic
        html = html.replace(/\\*\\*\\*(.+?)\\*\\*\\*/g, '<strong><em>$1</em></strong>');
        html = html.replace(/\\*\\*(.+?)\\*\\*/g, '<strong>$1</strong>');
        html = html.replace(/\\*(.+?)\\*/g, '<em>$1</em>');
        // Unordered lists
        html = html.replace(/^[\\-\\*] (.+)$/gm, '<li>$1</li>');
        html = html.replace(/(<li>[\\s\\S]*?<\\/li>)/g, '<ul>$1</ul>');
        // Ordered lists
        html = html.replace(/^\\d+\\. (.+)$/gm, '<li>$1</li>');
        // Links
        html = html.replace(/\\[([^\\]]+)\\]\\(([^)]+)\\)/g, '<a href="$2" target="_blank">$1</a>');
        // Horizontal rule
        html = html.replace(/^---$/gm, '<hr style="border:none;border-top:1px solid rgba(255,255,255,0.1);margin:8px 0">');
        // Line breaks (but not inside pre/code)
        html = html.replace(/\\n/g, '<br>');
        // Clean up <br> after block elements
        html = html.replace(/<\\/(pre|h[123]|ul|ol|li|hr)><br>/g, '</$1>');
        html = html.replace(/<br><(pre|h[123]|ul|ol)/g, '<$1');
        return html;
    }

    function highlightSyntax(code, lang) {
        // Basic syntax highlighting without external dependencies
        const keywords = /\\b(const|let|var|function|return|if|else|for|while|class|import|export|from|async|await|try|catch|def|self|print|True|False|None|fn|pub|use|mod|struct|impl|enum|match|type|interface)\\b/g;
        const strings = /(&quot;[^&]*?&quot;|&#x27;[^&]*?&#x27;)/g;
        const comments = /(\\/\\/.*?(?:<br>|$)|\\/\\*[\\s\\S]*?\\*\\/|#.*?(?:<br>|$))/g;
        const numbers = /\\b(\\d+\\.?\\d*)\\b/g;
        const functions = /\\b([a-zA-Z_]\\w*)(?=\\()/g;
        let h = code;
        h = h.replace(comments, '<span class="token-comment">$1</span>');
        h = h.replace(strings, '<span class="token-string">$1</span>');
        h = h.replace(keywords, '<span class="token-keyword">$1</span>');
        h = h.replace(numbers, '<span class="token-number">$1</span>');
        return h;
    }

    inputEl.addEventListener('keydown', e => {
        if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); sendMessage(); }
    });
    inputEl.addEventListener('input', () => {
        inputEl.style.height = 'auto';
        inputEl.style.height = Math.min(inputEl.scrollHeight, 120) + 'px';
    });

    // ─── Aurora Silk Ribbon Orb Renderer ───
    const orbLayers = [
        { hue:306, sat:80, bri:90,  radiusMul:1.15, phase:0.08, wave:0.25, sx:1.1,  sy:0.45, rot:0.015, blur:18, opacity:0.12, phaseOff:0, waveOff:0, rotOff:0 },
        { hue:0,   sat:85, bri:100, radiusMul:1.0,  phase:0.12, wave:0.35, sx:1.0,  sy:0.5,  rot:0.02,  blur:12, opacity:0.18, phaseOff:0, waveOff:0, rotOff:0 },
        { hue:29,  sat:90, bri:100, radiusMul:0.95, phase:0.1,  wave:0.3,  sx:0.85, sy:0.65, rot:0.018, blur:10, opacity:0.2,  phaseOff:1.5, waveOff:2, rotOff:Math.PI*0.3 },
        { hue:187, sat:90, bri:100, radiusMul:0.9,  phase:0.14, wave:0.4,  sx:0.75, sy:0.8,  rot:0.022, blur:8,  opacity:0.22, phaseOff:3, waveOff:1, rotOff:Math.PI*0.7 },
        { hue:216, sat:85, bri:100, radiusMul:0.85, phase:0.09, wave:0.28, sx:0.7,  sy:0.75, rot:0.025, blur:6,  opacity:0.25, phaseOff:2, waveOff:3, rotOff:Math.PI*1.1 },
        { hue:270, sat:80, bri:100, radiusMul:0.75, phase:0.16, wave:0.45, sx:0.6,  sy:0.7,  rot:0.028, blur:4,  opacity:0.28, phaseOff:4, waveOff:2, rotOff:Math.PI*0.5 },
        { hue:331, sat:70, bri:100, radiusMul:0.6,  phase:0.11, wave:0.32, sx:0.55, sy:0.6,  rot:0.03,  blur:3,  opacity:0.3,  phaseOff:1, waveOff:4, rotOff:Math.PI*1.4 }
    ];

    function hslToRgba(h, s, b, a) {
        s /= 100; b /= 100;
        const k = n => (n + h / 30) % 12;
        const f = n => b - b * s * Math.max(Math.min(k(n) - 3, 9 - k(n), 1), -1);
        return `rgba(${Math.round(f(0)*255)},${Math.round(f(8)*255)},${Math.round(f(4)*255)},${a})`;
    }

    function drawAuroraRibbon(ctx, cx, cy, radius, layer, t, intensity) {
        const ph = t * layer.phase + layer.phaseOff;
        const wp = t * layer.wave + layer.waveOff;
        const rot = t * layer.rot + layer.rotOff;
        const r = radius * layer.radiusMul;
        const segments = 64;
        const breatheX = layer.sx * (1.0 + Math.sin(wp * 0.3) * 0.08);
        const breatheY = layer.sy * (1.0 + Math.cos(wp * 0.25) * 0.08);

        ctx.save();
        ctx.globalCompositeOperation = 'lighter';

        // Build path points
        const points = [];
        for (let i = 0; i <= segments; i++) {
            const angle = (i / segments) * Math.PI * 2;
            const wave1 = Math.sin(angle * 2 + ph) * 0.25;
            const wave2 = Math.sin(angle * 3 + wp) * 0.18;
            const wave3 = Math.cos(angle * 4 + ph * 0.8) * 0.12;
            const wave4 = Math.sin(angle * 1.5 + wp * 1.3) * 0.15;
            const audioPulse = Math.sin(angle * 2 + ph * 3) * intensity * 0.35;
            const audioPulse2 = Math.cos(angle * 3 + wp * 2) * intensity * 0.25;
            const audioPulse3 = Math.sin(angle * 5 + ph * 4) * intensity * 0.18;
            const waveSum = wave1 + wave2 + wave3 + wave4 + audioPulse + audioPulse2 + audioPulse3;
            const dist = r * (0.55 + waveSum);
            const x = Math.cos(angle) * dist * breatheX;
            const y = Math.sin(angle) * dist * breatheY;
            const rx = x * Math.cos(rot) - y * Math.sin(rot);
            const ry = x * Math.sin(rot) + y * Math.cos(rot);
            points.push({ x: cx + rx, y: cy + ry });
        }

        // Draw glow layer (more blur, less opacity)
        ctx.filter = `blur(${layer.blur}px)`;
        ctx.beginPath();
        points.forEach((p, i) => i === 0 ? ctx.moveTo(p.x, p.y) : ctx.lineTo(p.x, p.y));
        ctx.closePath();
        ctx.fillStyle = hslToRgba(layer.hue, layer.sat, layer.bri, layer.opacity);
        ctx.fill();

        // Draw core layer (less blur, less opacity)
        ctx.filter = `blur(${layer.blur * 0.4}px)`;
        ctx.beginPath();
        points.forEach((p, i) => i === 0 ? ctx.moveTo(p.x, p.y) : ctx.lineTo(p.x, p.y));
        ctx.closePath();
        ctx.fillStyle = hslToRgba(layer.hue, layer.sat, layer.bri, layer.opacity * 0.49);
        ctx.fill();

        ctx.restore();
    }

    function renderOrb(canvas, size) {
        if (!canvas) return;
        const ctx = canvas.getContext('2d');
        const w = canvas.width;
        const h = canvas.height;
        const cx = w / 2;
        const cy = h / 2;
        const radius = Math.min(w, h) * 0.45;
        const t = performance.now() / 1000;
        const intensity = 0.08; // Idle breathing intensity

        ctx.clearRect(0, 0, w, h);

        for (const layer of orbLayers) {
            drawAuroraRibbon(ctx, cx, cy, radius, layer, t, intensity);
        }
    }

    // Animate all active orb canvases
    const orbCanvases = new Map();
    function initOrb(id, size) {
        const c = document.getElementById(id);
        if (c) orbCanvases.set(id, c);
    }
    function orbLoop() {
        orbCanvases.forEach((canvas, id) => {
            if (canvas.offsetParent !== null) renderOrb(canvas);
        });
        requestAnimationFrame(orbLoop);
    }
    initOrb('orbSmall', 72);
    initOrb('orbBig', 240);
    orbLoop();

    loadModels();
    </script>
    </body>
    </html>
    """
}
