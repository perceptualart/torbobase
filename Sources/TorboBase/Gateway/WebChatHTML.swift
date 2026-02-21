// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — Embedded web chat UI — served at /chat endpoint
import Foundation

enum WebChatHTML {
    static let page = """
    <!DOCTYPE html>
    <html lang="en">
    <head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no, viewport-fit=cover">
    <meta name="apple-mobile-web-app-capable" content="yes">
    <meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
    <meta http-equiv="Content-Security-Policy" content="default-src 'self'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'; img-src 'self' data:; font-src 'self'; frame-src 'none'; object-src 'none'; base-uri 'self';">
    <title>Torbo Base</title>
    <link rel="icon" href="data:image/svg+xml,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 100 100'><circle cx='50' cy='50' r='40' fill='%23a855f7'/></svg>">
    <style>
    *{margin:0;padding:0;box-sizing:border-box;-webkit-tap-highlight-color:transparent}
    :root{
        --bg:#09090b;--surface:#111114;--surface2:#18181b;
        --border:rgba(255,255,255,0.06);--border2:rgba(255,255,255,0.1);
        --text:rgba(255,255,255,0.88);--text-dim:rgba(255,255,255,0.4);--text-faint:rgba(255,255,255,0.2);
        --purple:#a855f7;--purple-dim:rgba(168,85,247,0.15);
        --sid:#FF69B4;--ada:#4A9FFF;--mira:#3DDC84;--orion:#A855F7;
        --radius:14px;--radius-sm:8px;
    }
    html,body{height:100%;overflow:hidden}
    body{
        font-family:-apple-system,BlinkMacSystemFont,'SF Pro Text','Helvetica Neue',sans-serif;
        background:var(--bg);color:var(--text);
        display:flex;flex-direction:column;height:100dvh;
    }

    /* ─── Header ─── */
    .header{
        padding:12px 16px;display:flex;align-items:center;gap:12px;
        background:var(--surface);border-bottom:1px solid var(--border);
        flex-shrink:0;z-index:10;
    }
    .logo{
        font-size:15px;font-weight:700;letter-spacing:2.5px;
        background:linear-gradient(135deg,var(--purple),#c084fc);
        -webkit-background-clip:text;-webkit-text-fill-color:transparent;
        white-space:nowrap;
    }
    .conn-dot{
        width:8px;height:8px;border-radius:50%;background:#3DDC84;
        flex-shrink:0;transition:background 0.3s;
    }
    .conn-dot.disconnected{background:#ef4444;animation:pulse-dot 1.5s infinite}
    .conn-dot.reconnecting{background:#f59e0b;animation:pulse-dot 1s infinite}
    @keyframes pulse-dot{0%,100%{opacity:1}50%{opacity:0.3}}
    .spacer{flex:1}

    /* ─── Agent Selector ─── */
    .agent-pills{display:flex;gap:6px;overflow-x:auto;-webkit-overflow-scrolling:touch;scrollbar-width:none;flex-shrink:0}
    .agent-pills::-webkit-scrollbar{display:none}
    .agent-pill{
        padding:5px 12px;border-radius:20px;font-size:12px;font-weight:600;
        border:1.5px solid var(--border2);background:transparent;
        color:var(--text-dim);cursor:pointer;transition:all 0.2s;
        white-space:nowrap;flex-shrink:0;
    }
    .agent-pill:hover{border-color:var(--text-dim)}
    .agent-pill.active{color:#fff}
    .agent-pill[data-agent="sid"].active{border-color:var(--sid);background:rgba(255,105,180,0.12);color:var(--sid)}
    .agent-pill[data-agent="ada"].active{border-color:var(--ada);background:rgba(74,159,255,0.12);color:var(--ada)}
    .agent-pill[data-agent="mira"].active{border-color:var(--mira);background:rgba(61,220,132,0.12);color:var(--mira)}
    .agent-pill[data-agent="orion"].active{border-color:var(--orion);background:rgba(168,85,247,0.12);color:var(--orion)}

    /* ─── Messages ─── */
    .messages{
        flex:1;overflow-y:auto;padding:16px;
        display:flex;flex-direction:column;gap:12px;
        -webkit-overflow-scrolling:touch;
        overscroll-behavior:contain;
    }
    .messages::-webkit-scrollbar{width:4px}
    .messages::-webkit-scrollbar-thumb{background:rgba(255,255,255,0.08);border-radius:2px}

    .msg{display:flex;flex-direction:column;gap:3px;max-width:85%;animation:msg-in 0.2s ease-out}
    .msg.user{align-self:flex-end}
    .msg.assistant{align-self:flex-start}
    @keyframes msg-in{from{opacity:0;transform:translateY(8px)}to{opacity:1;transform:translateY(0)}}

    .msg-agent{
        font-size:11px;font-weight:700;letter-spacing:0.3px;
        padding-left:2px;
    }
    .msg-agent.sid{color:var(--sid)}
    .msg-agent.ada{color:var(--ada)}
    .msg-agent.mira{color:var(--mira)}
    .msg-agent.orion{color:var(--orion)}

    .bubble{
        padding:10px 14px;font-size:14px;line-height:1.55;
        word-wrap:break-word;overflow-wrap:break-word;
    }
    .msg.user .bubble{
        background:rgba(168,85,247,0.1);border:1px solid rgba(168,85,247,0.2);
        border-radius:var(--radius) var(--radius) 4px var(--radius);
        white-space:pre-wrap;
    }
    .msg.assistant .bubble{
        background:var(--surface2);border:1px solid var(--border);
        border-radius:var(--radius) var(--radius) var(--radius) 4px;
    }

    .msg-meta{
        font-size:10px;color:var(--text-faint);
        font-variant-numeric:tabular-nums;padding:0 2px;
    }
    .msg.user .msg-meta{text-align:right}

    /* ─── Markdown in bubbles ─── */
    .bubble pre{
        background:rgba(0,0,0,0.4);border-radius:var(--radius-sm);
        padding:10px 12px;margin:8px 0;overflow-x:auto;
        border:1px solid var(--border);
    }
    .bubble pre code{
        font-family:'SF Mono','Menlo','Consolas',monospace;
        font-size:12px;color:#e0e0e0;background:none;padding:0;
    }
    .bubble code{
        font-family:'SF Mono','Menlo',monospace;font-size:12px;
        background:rgba(168,85,247,0.1);padding:1.5px 5px;
        border-radius:4px;color:#c084fc;
    }
    .bubble strong{color:#fff}
    .bubble em{color:rgba(255,255,255,0.7)}
    .bubble ul,.bubble ol{margin:6px 0 6px 20px}
    .bubble li{margin:2px 0}
    .bubble h1,.bubble h2,.bubble h3{color:#fff;margin:10px 0 4px}
    .bubble h1{font-size:16px} .bubble h2{font-size:14px} .bubble h3{font-size:13px}
    .bubble a{color:var(--purple);text-decoration:none}
    .bubble a:hover{text-decoration:underline}
    .bubble hr{border:none;border-top:1px solid var(--border);margin:8px 0}
    .bubble .cursor{animation:blink 1s step-end infinite;color:var(--purple)}
    @keyframes blink{50%{opacity:0}}
    .token-keyword{color:#c678dd}.token-string{color:#98c379}
    .token-comment{color:#5c6370;font-style:italic}.token-number{color:#d19a66}

    /* ─── Typing Indicator ─── */
    .typing-row{display:none;align-self:flex-start;padding:4px 16px;gap:6px;align-items:center}
    .typing-row.visible{display:flex}
    .typing-label{font-size:11px;font-weight:600;color:var(--text-dim)}
    .typing-dots{display:flex;gap:3px}
    .typing-dots span{
        width:5px;height:5px;border-radius:50%;
        background:var(--purple);opacity:0.3;
        animation:tdot 1.2s infinite;
    }
    .typing-dots span:nth-child(2){animation-delay:0.2s}
    .typing-dots span:nth-child(3){animation-delay:0.4s}
    @keyframes tdot{0%,60%,100%{opacity:0.3;transform:translateY(0)}30%{opacity:1;transform:translateY(-3px)}}

    /* ─── Empty State ─── */
    .empty-state{
        flex:1;display:flex;flex-direction:column;
        align-items:center;justify-content:center;gap:12px;
        color:var(--text-dim);padding:40px 20px;text-align:center;
    }
    .empty-orb{
        width:64px;height:64px;border-radius:50%;
        background:radial-gradient(circle at 35% 35%,#c084fc,var(--purple),#7c3aed);
        opacity:0.6;
    }
    .empty-state p{font-size:14px;line-height:1.5;max-width:300px}

    /* ─── Input Area ─── */
    .input-area{
        padding:10px 12px;padding-bottom:max(10px,env(safe-area-inset-bottom));
        background:var(--surface);border-top:1px solid var(--border);
        display:flex;align-items:flex-end;gap:8px;flex-shrink:0;
    }
    .input-area textarea{
        flex:1;background:var(--surface2);border:1px solid var(--border);
        border-radius:var(--radius);padding:10px 14px;color:var(--text);
        font-size:15px;font-family:inherit;resize:none;
        min-height:42px;max-height:120px;outline:none;
        transition:border-color 0.2s;line-height:1.4;
        -webkit-appearance:none;
    }
    .input-area textarea:focus{border-color:rgba(168,85,247,0.4)}
    .input-area textarea::placeholder{color:var(--text-faint)}
    .send-btn{
        width:42px;height:42px;border-radius:50%;border:none;
        background:var(--purple);color:#fff;cursor:pointer;
        display:flex;align-items:center;justify-content:center;
        transition:all 0.15s;flex-shrink:0;
    }
    .send-btn:hover{background:#9333ea}
    .send-btn:active{transform:scale(0.92)}
    .send-btn:disabled{opacity:0.25;cursor:not-allowed;transform:none}
    .send-btn svg{width:18px;height:18px}

    /* ─── Reconnect Banner ─── */
    .reconnect-banner{
        display:none;padding:8px 16px;background:rgba(239,68,68,0.1);
        border-bottom:1px solid rgba(239,68,68,0.2);
        font-size:12px;color:#fca5a5;text-align:center;flex-shrink:0;
    }
    .reconnect-banner.visible{display:block}

    /* ─── Mobile ─── */
    @media(max-width:480px){
        .header{padding:10px 12px;gap:8px}
        .logo{font-size:13px;letter-spacing:2px}
        .agent-pill{font-size:11px;padding:4px 10px}
        .messages{padding:12px}
        .msg{max-width:90%}
        .bubble{font-size:13px;padding:9px 12px}
        .input-area{padding:8px 10px;padding-bottom:max(8px,env(safe-area-inset-bottom))}
    }
    </style>
    </head>
    <body>

    <div class="header">
        <div class="logo">TORBO BASE</div>
        <div class="conn-dot" id="connDot" title="Connected"></div>
        <div class="spacer"></div>
        <div class="agent-pills" id="agentPills"></div>
    </div>

    <div class="reconnect-banner" id="reconnectBanner">Connection lost. Reconnecting...</div>

    <div class="messages" id="messages">
        <div class="empty-state" id="emptyState">
            <div class="empty-orb"></div>
            <p>Start a conversation with your Torbo agent.</p>
        </div>
    </div>

    <div class="typing-row" id="typingRow">
        <span class="typing-label" id="typingLabel">thinking</span>
        <div class="typing-dots"><span></span><span></span><span></span></div>
    </div>

    <div class="input-area">
        <textarea id="input" placeholder="Message..." rows="1" autocomplete="off" enterkeyhint="send"></textarea>
        <button class="send-btn" id="sendBtn" title="Send">
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><line x1="22" y1="2" x2="11" y2="13"/><polygon points="22 2 15 22 11 13 2 9 22 2"/></svg>
        </button>
    </div>

    <script>
    // ─── Config ───
    const TOKEN = '/*%%TORBO_SESSION_TOKEN%%*/';
    const BASE = window.location.origin;
    const AGENTS = {
        sid:   { name: 'SiD',   color: '#FF69B4' },
        ada:   { name: 'aDa',   color: '#4A9FFF' },
        mira:  { name: 'Mira',  color: '#3DDC84' },
        orion: { name: 'Orion', color: '#A855F7' }
    };
    const STORAGE_KEY = 'torbo_wc_';

    // ─── State ───
    let currentAgent = localStorage.getItem(STORAGE_KEY + 'agent') || 'sid';
    let conversation = []; // [{role, content, agent, time}]
    let isStreaming = false;
    let connected = true;
    let activeController = null;

    // ─── Elements ───
    const messagesEl = document.getElementById('messages');
    const inputEl = document.getElementById('input');
    const sendBtn = document.getElementById('sendBtn');
    const connDot = document.getElementById('connDot');
    const reconnectBanner = document.getElementById('reconnectBanner');
    const typingRow = document.getElementById('typingRow');
    const typingLabel = document.getElementById('typingLabel');
    const agentPills = document.getElementById('agentPills');
    const emptyState = document.getElementById('emptyState');

    // ─── Agent Pills ───
    function renderAgentPills(agents) {
        agentPills.innerHTML = '';
        const ids = agents.length ? agents.map(a => a.id) : Object.keys(AGENTS);
        ids.forEach(id => {
            const info = AGENTS[id] || { name: id, color: '#a855f7' };
            const pill = document.createElement('button');
            pill.className = 'agent-pill' + (id === currentAgent ? ' active' : '');
            pill.dataset.agent = id;
            pill.textContent = info.name;
            pill.onclick = () => selectAgent(id);
            agentPills.appendChild(pill);
        });
    }

    function selectAgent(id) {
        if (isStreaming) return;
        currentAgent = id;
        localStorage.setItem(STORAGE_KEY + 'agent', id);
        document.querySelectorAll('.agent-pill').forEach(p => {
            p.classList.toggle('active', p.dataset.agent === id);
        });
        loadConversation();
        renderMessages();
    }

    // ─── Conversation Persistence ───
    function saveConversation() {
        const key = STORAGE_KEY + 'conv_' + currentAgent;
        const data = conversation.slice(-50);
        try { localStorage.setItem(key, JSON.stringify(data)); } catch(e) {}
    }

    function loadConversation() {
        const key = STORAGE_KEY + 'conv_' + currentAgent;
        try {
            const raw = localStorage.getItem(key);
            conversation = raw ? JSON.parse(raw) : [];
        } catch(e) { conversation = []; }
    }

    // ─── Message Rendering ───
    function renderMessages() {
        messagesEl.innerHTML = '';

        if (conversation.length === 0) {
            const es = document.createElement('div');
            es.className = 'empty-state';
            es.innerHTML = '<div class="empty-orb"></div><p>Start a conversation with your Torbo agent.</p>';
            messagesEl.appendChild(es);
            return;
        }

        conversation.forEach(msg => appendMessageDOM(msg));
        scrollToBottom();
    }

    function appendMessageDOM(msg) {
        // Remove empty state if present
        const es = messagesEl.querySelector('.empty-state');
        if (es) es.remove();

        const div = document.createElement('div');
        div.className = 'msg ' + msg.role;
        const agentID = msg.agent || currentAgent;
        const info = AGENTS[agentID] || { name: agentID, color: '#a855f7' };
        const time = msg.time || '';

        if (msg.role === 'assistant') {
            const label = document.createElement('div');
            label.className = 'msg-agent ' + agentID;
            label.textContent = info.name;
            div.appendChild(label);
        }

        const bubble = document.createElement('div');
        bubble.className = 'bubble';
        if (msg.role === 'user') {
            bubble.textContent = typeof msg.content === 'string' ? msg.content : JSON.stringify(msg.content);
        } else {
            bubble.innerHTML = renderMarkdown(msg.content || '');
        }
        div.appendChild(bubble);

        if (time) {
            const meta = document.createElement('div');
            meta.className = 'msg-meta';
            meta.textContent = time;
            div.appendChild(meta);
        }

        messagesEl.appendChild(div);
        return bubble;
    }

    function scrollToBottom() {
        requestAnimationFrame(() => { messagesEl.scrollTop = messagesEl.scrollHeight; });
    }

    // ─── Typing Indicator ───
    function showTyping() {
        const info = AGENTS[currentAgent] || { name: currentAgent };
        typingLabel.textContent = info.name + ' is thinking';
        typingLabel.style.color = (AGENTS[currentAgent] || {}).color || '#a855f7';
        typingRow.classList.add('visible');
        scrollToBottom();
    }
    function hideTyping() { typingRow.classList.remove('visible'); }

    // ─── Send Message ───
    async function sendMessage() {
        const text = inputEl.value.trim();
        if (!text || isStreaming) return;

        // Add user message
        const time = new Date().toLocaleTimeString([], {hour:'2-digit', minute:'2-digit'});
        const userMsg = { role: 'user', content: text, agent: null, time: time };
        conversation.push(userMsg);
        appendMessageDOM(userMsg);
        scrollToBottom();

        inputEl.value = '';
        inputEl.style.height = 'auto';
        sendBtn.disabled = true;
        isStreaming = true;
        showTyping();

        // Build messages array for API
        const apiMessages = conversation.map(m => ({
            role: m.role,
            content: m.content
        }));

        // Stream response
        let fullContent = '';
        let assistantBubble = null;
        activeController = new AbortController();

        try {
            const res = await fetch(BASE + '/v1/chat/completions', {
                method: 'POST',
                signal: activeController.signal,
                headers: {
                    'Content-Type': 'application/json',
                    'Authorization': 'Bearer ' + TOKEN,
                    'x-torbo-agent-id': currentAgent
                },
                body: JSON.stringify({
                    model: '_default',
                    messages: apiMessages,
                    stream: true
                })
            });

            if (!res.ok) {
                const err = await res.json().catch(() => ({ error: 'Request failed' }));
                const errText = typeof err.error === 'object' ? (err.error.message || JSON.stringify(err.error)) : (err.error || 'Error');
                hideTyping();
                const errMsg = { role: 'assistant', content: errText, agent: currentAgent, time: time };
                conversation.push(errMsg);
                appendMessageDOM(errMsg);
                scrollToBottom();
                saveConversation();
                isStreaming = false;
                sendBtn.disabled = false;
                activeController = null;
                return;
            }

            hideTyping();
            const assistantMsg = { role: 'assistant', content: '', agent: currentAgent, time: new Date().toLocaleTimeString([], {hour:'2-digit', minute:'2-digit'}) };
            conversation.push(assistantMsg);
            assistantBubble = appendMessageDOM(assistantMsg);

            const contentType = res.headers.get('content-type') || '';
            if (contentType.includes('text/event-stream')) {
                const reader = res.body.getReader();
                const decoder = new TextDecoder();
                let buffer = '';

                while (true) {
                    const { done, value } = await reader.read();
                    if (done) break;
                    buffer += decoder.decode(value, { stream: true });
                    const lines = buffer.split('\\n');
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
                                const display = fullContent.replace(/\\[[a-z]+:\\s*[^\\]]*\\]/g, '').trim();
                                assistantBubble.innerHTML = renderMarkdown(display) + '<span class="cursor">\\u2588</span>';
                                scrollToBottom();
                            }
                        } catch(e) {}
                    }
                }
            } else {
                const data = await res.json();
                if (data.choices && data.choices[0]) {
                    fullContent = data.choices[0].message?.content || '';
                }
            }

            // Finalize
            fullContent = fullContent.replace(/\\[[a-z]+:\\s*[^\\]]*\\]/g, '').trim();
            conversation[conversation.length - 1].content = fullContent;
            if (assistantBubble) assistantBubble.innerHTML = renderMarkdown(fullContent);
            scrollToBottom();
            saveConversation();

        } catch(e) {
            hideTyping();
            if (e.name !== 'AbortError') {
                const errMsg = { role: 'assistant', content: 'Connection error. Is Base running?', agent: currentAgent, time: time };
                conversation.push(errMsg);
                appendMessageDOM(errMsg);
                saveConversation();
            }
        } finally {
            isStreaming = false;
            sendBtn.disabled = false;
            activeController = null;
            inputEl.focus();
        }
    }

    // ─── Markdown Renderer ───
    function escapeHtml(s) {
        return s.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
    }

    function renderMarkdown(text) {
        let html = escapeHtml(text);
        html = html.replace(/```(\\w*)\\n([\\s\\S]*?)```/g, (_, lang, code) => {
            const hl = highlightSyntax(code.trim());
            const lbl = lang ? '<div style="font-size:10px;color:rgba(255,255,255,0.2);margin-bottom:4px;font-family:monospace">' + lang + '</div>' : '';
            return '<pre>' + lbl + '<code>' + hl + '</code></pre>';
        });
        html = html.replace(/`([^`]+)`/g, '<code>$1</code>');
        html = html.replace(/^### (.+)$/gm, '<h3>$1</h3>');
        html = html.replace(/^## (.+)$/gm, '<h2>$1</h2>');
        html = html.replace(/^# (.+)$/gm, '<h1>$1</h1>');
        html = html.replace(/\\*\\*\\*(.+?)\\*\\*\\*/g, '<strong><em>$1</em></strong>');
        html = html.replace(/\\*\\*(.+?)\\*\\*/g, '<strong>$1</strong>');
        html = html.replace(/\\*(.+?)\\*/g, '<em>$1</em>');
        html = html.replace(/^[\\-\\*] (.+)$/gm, '<li>$1</li>');
        html = html.replace(/(<li>[\\s\\S]*?<\\/li>)/g, '<ul>$1</ul>');
        html = html.replace(/^\\d+\\. (.+)$/gm, '<li>$1</li>');
        html = html.replace(/\\[([^\\]]+)\\]\\((https?:\\/\\/[^)]+)\\)/g, function(_, t, u) {
            var safeUrl = u.replace(/&quot;/g,'').replace(/&amp;/g,'&').replace(/[\\x00-\\x1f]/g,'');
            return '<a href="' + safeUrl + '" target="_blank" rel="noopener">' + t + '</a>';
        });
        html = html.replace(/^---$/gm, '<hr>');
        html = html.replace(/\\n/g, '<br>');
        html = html.replace(/<\\/(pre|h[123]|ul|ol|li|hr)><br>/g, '</$1>');
        html = html.replace(/<br><(pre|h[123]|ul|ol)/g, '<$1');
        return html;
    }

    function highlightSyntax(code) {
        let h = code;
        h = h.replace(/(\\/\\/.*?(?:<br>|$)|\\/\\*[\\s\\S]*?\\*\\/|#.*?(?:<br>|$))/g, '<span class="token-comment">$1</span>');
        h = h.replace(/(&quot;[^&]*?&quot;|&#x27;[^&]*?&#x27;)/g, '<span class="token-string">$1</span>');
        h = h.replace(/\\b(const|let|var|function|return|if|else|for|while|class|import|export|from|async|await|try|catch|def|self|print|fn|pub|use|mod|struct|impl|enum|match|type|interface)\\b/g, '<span class="token-keyword">$1</span>');
        h = h.replace(/\\b(\\d+\\.?\\d*)\\b/g, '<span class="token-number">$1</span>');
        return h;
    }

    // ─── Connection Health ───
    let healthTimer = null;
    let wasDisconnected = false;

    async function checkHealth() {
        try {
            const res = await fetch(BASE + '/health', {
                signal: AbortSignal.timeout(5000),
                headers: TOKEN ? { 'Authorization': 'Bearer ' + TOKEN } : {}
            });
            if (res.ok) {
                if (wasDisconnected) {
                    wasDisconnected = false;
                    connected = true;
                    connDot.className = 'conn-dot';
                    connDot.title = 'Connected';
                    reconnectBanner.classList.remove('visible');
                }
            } else {
                markDisconnected();
            }
        } catch(e) {
            markDisconnected();
        }
    }

    function markDisconnected() {
        if (!wasDisconnected) {
            wasDisconnected = true;
            connected = false;
            connDot.className = 'conn-dot disconnected';
            connDot.title = 'Disconnected';
            reconnectBanner.classList.add('visible');
        }
    }

    function startHealthCheck() {
        checkHealth();
        healthTimer = setInterval(checkHealth, 8000);
    }

    // ─── Load Server History ───
    async function loadServerHistory() {
        if (!TOKEN) return;
        try {
            const res = await fetch(BASE + '/v1/messages?limit=50', {
                headers: { 'Authorization': 'Bearer ' + TOKEN }
            });
            if (!res.ok) return;
            const data = await res.json();
            if (!data.messages || data.messages.length === 0) return;

            // Only use server history if local is empty for this agent
            if (conversation.length > 0) return;

            const serverMsgs = data.messages
                .filter(m => !m.agentID || m.agentID === currentAgent)
                .slice(-50)
                .map(m => ({
                    role: m.role,
                    content: m.content,
                    agent: m.agentID || currentAgent,
                    time: m.timestamp ? new Date(m.timestamp).toLocaleTimeString([], {hour:'2-digit', minute:'2-digit'}) : ''
                }));

            if (serverMsgs.length > 0) {
                conversation = serverMsgs;
                saveConversation();
                renderMessages();
            }
        } catch(e) {}
    }

    // ─── Load Agents ───
    async function loadAgents() {
        if (!TOKEN) { renderAgentPills([]); return; }
        try {
            const res = await fetch(BASE + '/v1/agents', {
                headers: { 'Authorization': 'Bearer ' + TOKEN }
            });
            if (res.ok) {
                const data = await res.json();
                const agents = data.agents || [];
                agents.forEach(a => {
                    if (!AGENTS[a.id]) {
                        AGENTS[a.id] = { name: a.name || a.id, color: '#a855f7' };
                    } else {
                        AGENTS[a.id].name = a.name || AGENTS[a.id].name;
                    }
                });
                renderAgentPills(agents);
                if (agents.length && !agents.find(a => a.id === currentAgent)) {
                    selectAgent(agents[0].id);
                }
            } else {
                renderAgentPills([]);
            }
        } catch(e) {
            renderAgentPills([]);
        }
    }

    // ─── Input Handlers ───
    inputEl.addEventListener('keydown', e => {
        if (e.key === 'Enter' && !e.shiftKey) {
            e.preventDefault();
            sendMessage();
        }
    });
    inputEl.addEventListener('input', () => {
        inputEl.style.height = 'auto';
        inputEl.style.height = Math.min(inputEl.scrollHeight, 120) + 'px';
    });

    // Cancel stream on page unload
    window.addEventListener('beforeunload', () => {
        if (activeController) activeController.abort();
    });

    // ─── Init ───
    (async function init() {
        await loadAgents();
        loadConversation();
        renderMessages();
        await loadServerHistory();
        startHealthCheck();
        inputEl.focus();
    })();
    </script>
    </body>
    </html>
    """
}
