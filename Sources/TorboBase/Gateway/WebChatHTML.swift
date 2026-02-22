// Copyright 2026 Perceptual Art LLC. All rights reserved.
// Licensed under Apache 2.0 — see LICENSE file.
// Torbo Base — Embedded web chat UI V2 — served at /chat endpoint
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
    <meta http-equiv="Content-Security-Policy" content="default-src 'self'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'; img-src 'self' data: blob:; font-src 'self'; frame-src 'none'; object-src 'none'; base-uri 'self';">
    <title>Torbo Base</title>
    <link rel="icon" href="data:image/svg+xml,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 100 100'><circle cx='50' cy='50' r='40' fill='%23a855f7'/></svg>">
    <style>
    *{margin:0;padding:0;box-sizing:border-box;-webkit-tap-highlight-color:transparent}
    :root{
        --bg:#0d0d0d;--surface:#171717;--surface2:#2f2f2f;--surface3:#1e1e1e;
        --border:rgba(255,255,255,0.08);--border2:rgba(255,255,255,0.12);
        --text:#ececec;--text-dim:#9b9b9b;--text-faint:rgba(255,255,255,0.2);
        --purple:#a855f7;--purple-dim:rgba(168,85,247,0.15);
        --sid:#FF69B4;--ada:#4A9FFF;--mira:#3DDC84;--orion:#A855F7;
        --radius:16px;--radius-sm:10px;
        --sidebar-w:260px;--msg-max:720px;
    }
    html,body{height:100%;overflow:hidden}
    body{
        font-family:-apple-system,BlinkMacSystemFont,'SF Pro Text','Helvetica Neue',sans-serif;
        background:var(--bg);color:var(--text);height:100dvh;overflow:hidden;
    }

    /* ── App Layout ── */
    .app{display:flex;height:100dvh;overflow:hidden}

    /* ── Sidebar ── */
    .sidebar{
        width:var(--sidebar-w);flex-shrink:0;background:var(--surface);
        display:flex;flex-direction:column;overflow:hidden;z-index:200;
    }
    .sidebar-header{
        padding:14px 16px;display:flex;align-items:center;gap:10px;
        border-bottom:1px solid var(--border);flex-shrink:0;
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
    .sidebar-close{
        display:none;margin-left:auto;background:none;border:none;
        color:var(--text-dim);font-size:20px;cursor:pointer;padding:0 4px;line-height:1;
    }
    .new-chat-btn{
        margin:12px 12px 4px;padding:10px 14px;border-radius:var(--radius-sm);
        border:1px solid var(--border2);background:transparent;
        color:var(--text);font-size:13px;font-weight:600;cursor:pointer;
        transition:all 0.15s;text-align:left;flex-shrink:0;
    }
    .new-chat-btn:hover{background:var(--purple-dim);border-color:var(--purple)}
    .room-list{flex:1;overflow-y:auto;padding:8px 0;scrollbar-width:thin}
    .room-list::-webkit-scrollbar{width:3px}
    .room-list::-webkit-scrollbar-thumb{background:rgba(255,255,255,0.06);border-radius:2px}
    .room-item{
        padding:10px 14px;margin:0 8px;border-radius:var(--radius-sm);cursor:pointer;
        border-left:3px solid transparent;transition:all 0.15s;
        display:flex;align-items:center;gap:8px;position:relative;
    }
    .room-item:hover{background:rgba(255,255,255,0.03)}
    .room-item.active{background:var(--surface2)}
    .room-dots{display:flex;gap:3px;flex-shrink:0}
    .room-dot{width:6px;height:6px;border-radius:50%;flex-shrink:0}
    .room-item-body{flex:1;min-width:0}
    .room-item-title{
        font-size:13px;font-weight:500;color:var(--text);
        white-space:nowrap;overflow:hidden;text-overflow:ellipsis;
    }
    .room-item-meta{
        font-size:11px;color:var(--text-faint);margin-top:2px;
        display:flex;align-items:center;gap:6px;
    }
    .room-item-delete{
        opacity:0;background:none;border:none;color:var(--text-faint);
        font-size:14px;cursor:pointer;padding:2px 4px;line-height:1;
        transition:opacity 0.15s;position:absolute;right:8px;top:8px;
    }
    .room-item:hover .room-item-delete{opacity:1}
    .room-item-delete:hover{color:#ef4444}
    .sidebar-nav{
        padding:8px 12px;border-top:1px solid var(--border);
        display:flex;gap:4px;flex-shrink:0;
    }
    .nav-item{
        flex:1;padding:8px;background:none;border:none;border-radius:var(--radius-sm);
        color:var(--text-dim);font-size:12px;font-weight:600;cursor:pointer;
        text-align:center;transition:all 0.15s;
    }
    .nav-item:hover{color:var(--text);background:rgba(255,255,255,0.03)}
    .nav-item.active{color:var(--purple);background:var(--purple-dim)}
    .sidebar-overlay{
        display:none;position:fixed;inset:0;background:rgba(0,0,0,0.5);z-index:199;
    }
    .sidebar-overlay.visible{display:block}

    /* ── Main Area ── */
    .main{flex:1;display:flex;flex-direction:column;overflow:hidden;min-width:0}

    /* ── Header ── */
    .header{
        padding:10px 16px;display:flex;align-items:center;gap:10px;
        background:var(--surface);border-bottom:1px solid var(--border);
        flex-shrink:0;z-index:10;
    }
    .hamburger{
        display:none;background:none;border:none;color:var(--text);
        font-size:20px;cursor:pointer;padding:2px 4px;flex-shrink:0;
    }
    .spacer{flex:1}
    .conn-dot-mobile{display:none}

    /* ── Agent Pills (multi-select with per-agent model) ── */
    .agent-pills{display:flex;gap:6px;overflow-x:auto;-webkit-overflow-scrolling:touch;scrollbar-width:none;flex-shrink:0;position:relative}
    .agent-pills::-webkit-scrollbar{display:none}
    .agent-pill{
        display:flex;align-items:center;gap:0;
        padding:0;border-radius:20px;font-size:12px;font-weight:600;
        border:1.5px solid var(--border2);background:transparent;
        color:var(--text-dim);cursor:default;transition:all 0.2s;
        white-space:nowrap;flex-shrink:0;overflow:hidden;
    }
    .pill-dot-area{
        display:flex;align-items:center;justify-content:center;
        padding:6px 0 6px 10px;cursor:pointer;
    }
    .pill-dot{width:10px;height:10px;border-radius:50%;transition:all 0.2s;flex-shrink:0}
    .pill-label-area{
        display:flex;align-items:center;gap:4px;
        padding:6px 10px 6px 6px;cursor:pointer;
    }
    .pill-label-area:hover{opacity:0.8}
    .pill-name{font-size:12px;font-weight:600}
    .pill-model{font-size:10px;opacity:0.6;font-weight:500}
    .pill-arrow{font-size:8px;opacity:0.4;margin-left:1px}
    .agent-pill:hover{border-color:var(--text-dim)}
    .agent-pill.active{color:#fff}
    .agent-pill.inactive{opacity:0.5}
    .agent-pill.inactive .pill-dot{background:transparent !important;border:1.5px solid currentColor}
    .agent-pill[data-agent="sid"].active{border-color:var(--sid);background:rgba(255,105,180,0.12);color:var(--sid)}
    .agent-pill[data-agent="ada"].active{border-color:var(--ada);background:rgba(74,159,255,0.12);color:var(--ada)}
    .agent-pill[data-agent="mira"].active{border-color:var(--mira);background:rgba(61,220,132,0.12);color:var(--mira)}
    .agent-pill[data-agent="orion"].active{border-color:var(--orion);background:rgba(168,85,247,0.12);color:var(--orion)}

    /* ── Per-Pill Model Dropdown ── */
    .pill-dropdown{
        position:fixed;
        background:var(--surface);border:1px solid var(--border2);
        border-radius:var(--radius-sm);width:260px;max-height:320px;
        overflow-y:auto;z-index:300;display:none;
        box-shadow:0 8px 30px rgba(0,0,0,0.5);
    }
    .pill-dropdown.visible{display:block}
    .pill-dropdown::-webkit-scrollbar{width:3px}
    .pill-dropdown::-webkit-scrollbar-thumb{background:rgba(255,255,255,0.08);border-radius:2px}
    .pill-dd-header{
        padding:8px 12px;font-size:11px;font-weight:700;
        color:var(--text);border-bottom:1px solid var(--border);
        display:flex;align-items:center;gap:6px;
    }
    .pill-dd-dot{width:8px;height:8px;border-radius:50%;flex-shrink:0}
    .model-group-header{
        padding:8px 12px 4px;font-size:10px;font-weight:700;
        color:var(--text-faint);text-transform:uppercase;letter-spacing:0.5px;
    }
    .model-option{
        padding:7px 12px;font-size:12px;cursor:pointer;color:var(--text-dim);
        transition:all 0.1s;
    }
    .model-option:hover{background:rgba(255,255,255,0.04);color:var(--text)}
    .model-option.selected{color:var(--purple);font-weight:600}

    /* ── Canvas Toggle ── */
    .canvas-toggle{
        background:none;border:1px solid var(--border2);border-radius:6px;
        color:var(--text-dim);cursor:pointer;padding:4px 6px;
        display:flex;align-items:center;justify-content:center;
        transition:all 0.15s;flex-shrink:0;
    }
    .canvas-toggle:hover{border-color:var(--text-dim);color:var(--text)}
    .canvas-toggle.active{border-color:var(--purple);color:var(--purple)}
    .canvas-toggle svg{width:18px;height:18px}

    /* ── Content Row ── */
    .content-row{flex:1;display:flex;overflow:hidden;position:relative}

    /* ── Chat View ── */
    .view-chat{flex:1;display:flex;flex-direction:column;overflow:hidden;min-width:0;transition:flex 0.3s ease}
    .view-conversations{display:none;flex:1;flex-direction:column;overflow:hidden}

    /* ── Messages Scroll + Column ── */
    .chat-scroll{
        flex:1;overflow-y:auto;
        -webkit-overflow-scrolling:touch;overscroll-behavior:contain;
    }
    .chat-scroll::-webkit-scrollbar{width:4px}
    .chat-scroll::-webkit-scrollbar-thumb{background:rgba(255,255,255,0.08);border-radius:2px}
    .msg-col{
        max-width:var(--msg-max);width:100%;margin:0 auto;
        padding:24px 16px;display:flex;flex-direction:column;gap:16px;
        min-height:100%;
    }

    /* ── Messages ── */
    .msg{display:flex;flex-direction:column;gap:4px;max-width:85%;animation:msg-in 0.25s ease-out}
    .msg.user{align-self:flex-end}
    .msg.assistant{align-self:flex-start}
    @keyframes msg-in{from{opacity:0;transform:translateY(6px)}to{opacity:1;transform:translateY(0)}}

    .msg-agent-row{display:flex;align-items:center;gap:6px;padding:0 2px}
    .agent-dot{width:8px;height:8px;border-radius:50%;flex-shrink:0}
    .msg-agent-name{font-size:12px;font-weight:700;letter-spacing:0.3px}

    .bubble{font-size:15px;line-height:1.6;word-wrap:break-word;overflow-wrap:break-word}
    .msg.user .bubble{
        background:var(--surface2);border-radius:18px 18px 4px 18px;
        padding:10px 16px;
    }
    .msg.assistant .bubble{background:transparent;padding:2px 0}
    .msg-text{white-space:pre-wrap;display:block}
    .msg-images{display:flex;flex-wrap:wrap;gap:8px;margin-top:8px}
    .msg-img{max-width:300px;max-height:300px;border-radius:var(--radius-sm);object-fit:cover;cursor:pointer}
    .msg-meta{font-size:10px;color:var(--text-faint);font-variant-numeric:tabular-nums;padding:0 2px}
    .msg.user .msg-meta{text-align:right}

    /* ── Markdown ── */
    .bubble pre{margin:8px 0;padding:0;background:none;border:none;overflow:visible}
    .bubble pre code{
        font-family:'SF Mono','Menlo','Consolas',monospace;
        font-size:13px;color:#e0e0e0;background:none;padding:0;
        display:block;overflow-x:auto;
    }
    .bubble code{
        font-family:'SF Mono','Menlo',monospace;font-size:13px;
        background:rgba(255,255,255,0.06);padding:1.5px 5px;
        border-radius:4px;color:#c084fc;
    }
    .bubble strong{color:#fff}
    .bubble em{color:rgba(255,255,255,0.7)}
    .bubble ul,.bubble ol{margin:6px 0 6px 20px}
    .bubble li{margin:3px 0}
    .bubble h1,.bubble h2,.bubble h3{color:#fff;margin:12px 0 4px}
    .bubble h1{font-size:17px} .bubble h2{font-size:15px} .bubble h3{font-size:14px}
    .bubble a{color:var(--purple);text-decoration:none}
    .bubble a:hover{text-decoration:underline}
    .bubble hr{border:none;border-top:1px solid var(--border);margin:10px 0}
    .bubble p{margin:6px 0}
    .bubble .cursor{animation:blink 1s step-end infinite;color:var(--purple)}
    @keyframes blink{50%{opacity:0}}
    .token-keyword{color:#c678dd}.token-string{color:#98c379}
    .token-comment{color:#5c6370;font-style:italic}.token-number{color:#d19a66}

    /* ── Code Block Wrap ── */
    .code-wrap{
        background:#1a1a1a;border:1px solid var(--border);
        border-radius:var(--radius-sm);margin:8px 0;overflow:hidden;
    }
    .code-header{
        display:flex;align-items:center;justify-content:space-between;
        padding:6px 12px;background:rgba(255,255,255,0.03);
        border-bottom:1px solid var(--border);
    }
    .code-lang{font-size:11px;color:var(--text-faint);font-family:monospace}
    .code-actions{display:flex;gap:4px}
    .code-btn{
        padding:3px 8px;border-radius:4px;border:none;
        background:rgba(255,255,255,0.06);color:var(--text-dim);
        font-size:11px;cursor:pointer;transition:all 0.15s;
    }
    .code-btn:hover{background:rgba(255,255,255,0.1);color:var(--text)}
    .code-wrap pre{margin:0 !important;border:none !important}
    .code-wrap pre code{padding:12px !important}

    /* ── Typing ── */
    .typing-bubble{padding:12px 16px !important}
    .typing-dots{display:flex;gap:4px}
    .typing-dots span{
        width:6px;height:6px;border-radius:50%;opacity:0.4;
        animation:tdot 1.2s infinite;
    }
    .typing-dots span:nth-child(2){animation-delay:0.2s}
    .typing-dots span:nth-child(3){animation-delay:0.4s}
    @keyframes tdot{0%,60%,100%{opacity:0.4;transform:translateY(0)}30%{opacity:1;transform:translateY(-3px)}}

    /* ── Empty State ── */
    .empty-state{
        flex:1;display:flex;flex-direction:column;
        align-items:center;justify-content:center;gap:12px;
        color:var(--text-dim);padding:40px 20px;text-align:center;
    }
    .empty-orb{
        width:64px;height:64px;border-radius:50%;
        background:radial-gradient(circle at 35% 35%,#c084fc,var(--purple),#7c3aed);
        opacity:0.5;
    }
    .empty-state p{font-size:14px;line-height:1.5;max-width:300px}

    /* ── Input Bar ── */
    .input-bar{
        padding:12px 16px;padding-bottom:max(12px,env(safe-area-inset-bottom));
        background:var(--bg);flex-shrink:0;
    }
    .input-inner{max-width:var(--msg-max);margin:0 auto;display:flex;flex-direction:column;gap:8px}
    .attach-preview{
        display:none;gap:8px;flex-wrap:wrap;padding:0 4px;
    }
    .attach-preview.visible{display:flex}
    .attach-thumb{
        position:relative;width:80px;height:80px;border-radius:var(--radius-sm);
        overflow:hidden;border:1px solid var(--border);
    }
    .attach-thumb img{width:100%;height:100%;object-fit:cover}
    .attach-chip{
        display:flex;align-items:center;gap:6px;padding:6px 10px;
        background:var(--surface2);border:1px solid var(--border);
        border-radius:var(--radius-sm);font-size:12px;color:var(--text-dim);
    }
    .attach-icon{font-size:14px}
    .attach-name{max-width:120px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
    .attach-remove{
        position:absolute;top:2px;right:2px;width:20px;height:20px;
        border-radius:50%;border:none;background:rgba(0,0,0,0.7);
        color:#fff;font-size:14px;cursor:pointer;display:flex;
        align-items:center;justify-content:center;line-height:1;
    }
    .attach-chip .attach-remove{
        position:static;width:16px;height:16px;font-size:12px;
        background:rgba(255,255,255,0.1);
    }
    .input-row{
        display:flex;align-items:flex-end;gap:8px;
        background:var(--surface);border:1px solid var(--border);
        border-radius:var(--radius);padding:8px 8px 8px 4px;
        transition:border-color 0.2s;
    }
    .input-row:focus-within{border-color:rgba(168,85,247,0.3)}
    .attach-btn{
        background:none;border:none;color:var(--text-dim);cursor:pointer;
        padding:4px 6px;display:flex;align-items:center;justify-content:center;
        flex-shrink:0;transition:color 0.15s;border-radius:6px;
    }
    .attach-btn:hover{color:var(--text);background:rgba(255,255,255,0.05)}
    .attach-btn svg{width:20px;height:20px}
    .input-row textarea{
        flex:1;background:none;border:none;color:var(--text);
        font-size:15px;font-family:inherit;resize:none;
        min-height:24px;max-height:120px;outline:none;
        line-height:1.5;padding:2px 0;-webkit-appearance:none;
    }
    .input-row textarea::placeholder{color:var(--text-faint)}
    .send-btn{
        width:32px;height:32px;border-radius:50%;border:none;
        background:var(--purple);color:#fff;cursor:pointer;
        display:flex;align-items:center;justify-content:center;
        transition:all 0.15s;flex-shrink:0;
    }
    .send-btn:hover{background:#9333ea}
    .send-btn:active{transform:scale(0.92)}
    .send-btn:disabled{opacity:0.25;cursor:not-allowed;transform:none}
    .send-btn svg{width:16px;height:16px}

    /* ── Drop Zone ── */
    .drop-zone{
        position:fixed;inset:0;background:rgba(168,85,247,0.08);
        border:3px dashed var(--purple);z-index:9999;
        display:none;align-items:center;justify-content:center;
        flex-direction:column;gap:12px;pointer-events:none;
    }
    .drop-zone.visible{display:flex}
    .drop-zone-text{color:var(--purple);font-size:18px;font-weight:600}
    .drop-zone-icon{font-size:48px;opacity:0.6}

    /* ── Canvas Panel ── */
    .canvas-panel{
        flex:0 0 0px;overflow:hidden;
        background:var(--surface);border-left:1px solid var(--border);
        display:flex;flex-direction:column;
        transition:flex-basis 0.3s ease;
    }
    .canvas-panel.open{flex:0 0 45%}
    .canvas-header{
        display:flex;align-items:center;gap:8px;
        padding:10px 14px;border-bottom:1px solid var(--border);flex-shrink:0;
    }
    .canvas-lang{
        font-size:11px;font-weight:700;color:var(--text-dim);
        background:rgba(255,255,255,0.06);padding:3px 8px;border-radius:4px;
        font-family:monospace;
    }
    .canvas-btn{
        padding:4px 10px;border-radius:4px;border:1px solid var(--border2);
        background:transparent;color:var(--text-dim);font-size:11px;
        font-weight:600;cursor:pointer;transition:all 0.15s;
    }
    .canvas-btn:hover{border-color:var(--text-dim);color:var(--text)}
    .canvas-close{
        background:none;border:none;color:var(--text-dim);
        font-size:20px;cursor:pointer;padding:0 4px;line-height:1;
        margin-left:auto;
    }
    .canvas-close:hover{color:var(--text)}
    .canvas-editor{
        flex:1;background:transparent;color:var(--text);
        font-family:'SF Mono','Menlo','Consolas',monospace;
        font-size:13px;line-height:1.6;padding:16px;
        border:none;outline:none;resize:none;
    }
    .canvas-footer{
        padding:8px 14px;border-top:1px solid var(--border);
        display:flex;align-items:center;flex-shrink:0;
    }
    .canvas-include{
        display:flex;align-items:center;gap:6px;
        font-size:12px;color:var(--text-dim);cursor:pointer;
    }
    .canvas-include input{accent-color:var(--purple)}

    /* ── Reconnect Banner ── */
    .reconnect-banner{
        display:none;padding:8px 16px;background:rgba(239,68,68,0.1);
        border-bottom:1px solid rgba(239,68,68,0.2);
        font-size:12px;color:#fca5a5;text-align:center;flex-shrink:0;
    }
    .reconnect-banner.visible{display:block}

    /* ── Conversations View ── */
    .conv-search{padding:16px 16px 8px;flex-shrink:0}
    .conv-search input{
        width:100%;padding:10px 14px;background:var(--surface);
        border:1px solid var(--border);border-radius:var(--radius);
        color:var(--text);font-size:14px;font-family:inherit;outline:none;
        transition:border-color 0.2s;
    }
    .conv-search input:focus{border-color:rgba(168,85,247,0.4)}
    .conv-search input::placeholder{color:var(--text-faint)}
    .conv-filters{
        display:flex;gap:6px;padding:4px 16px 12px;overflow-x:auto;
        scrollbar-width:none;flex-shrink:0;
    }
    .conv-filters::-webkit-scrollbar{display:none}
    .filter-chip{
        padding:5px 12px;border-radius:20px;font-size:12px;font-weight:600;
        border:1.5px solid var(--border2);background:transparent;
        color:var(--text-dim);cursor:pointer;transition:all 0.2s;
        white-space:nowrap;flex-shrink:0;
    }
    .filter-chip:hover{border-color:var(--text-dim)}
    .filter-chip.active{border-color:var(--purple);background:var(--purple-dim);color:var(--purple)}
    .conv-list{flex:1;overflow-y:auto;padding:0 16px 16px}
    .conv-list::-webkit-scrollbar{width:4px}
    .conv-list::-webkit-scrollbar-thumb{background:rgba(255,255,255,0.08);border-radius:2px}
    .session-card{
        padding:14px;background:var(--surface);border:1px solid var(--border);
        border-radius:var(--radius-sm);margin-bottom:8px;cursor:pointer;
        transition:all 0.15s;
    }
    .session-card:hover{border-color:var(--border2);background:var(--surface3)}
    .session-title{font-size:14px;font-weight:600;color:var(--text);margin-bottom:4px}
    .session-meta{
        font-size:11px;color:var(--text-faint);display:flex;align-items:center;
        gap:8px;margin-bottom:6px;flex-wrap:wrap;
    }
    .session-badge{font-size:10px;font-weight:700;padding:1px 6px;border-radius:3px}
    .session-preview{
        font-size:12px;color:var(--text-dim);line-height:1.4;
        display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical;
        overflow:hidden;
    }
    .conv-empty{text-align:center;padding:40px 20px;color:var(--text-faint);font-size:13px}

    /* ── Share Button ── */
    .share-btn{
        background:none;border:1px solid var(--border2);border-radius:6px;
        color:var(--text-dim);cursor:pointer;padding:4px 6px;
        display:flex;align-items:center;justify-content:center;
        transition:all 0.15s;flex-shrink:0;
    }
    .share-btn:hover{border-color:var(--text-dim);color:var(--text)}
    .share-btn svg{width:18px;height:18px}

    /* ── Toast ── */
    .toast{
        position:fixed;bottom:80px;left:50%;transform:translateX(-50%) translateY(20px);
        background:var(--surface2);color:var(--text);
        padding:10px 20px;border-radius:var(--radius-sm);
        font-size:13px;font-weight:600;z-index:9999;
        opacity:0;transition:all 0.3s ease;pointer-events:none;
        box-shadow:0 4px 20px rgba(0,0,0,0.4);border:1px solid var(--border2);
    }
    .toast.visible{opacity:1;transform:translateX(-50%) translateY(0)}

    /* ── Name Prompt Modal ── */
    .name-modal-overlay{
        position:fixed;inset:0;background:rgba(0,0,0,0.6);z-index:500;
        display:none;align-items:center;justify-content:center;
    }
    .name-modal-overlay.visible{display:flex}
    .name-modal{
        background:var(--surface);border:1px solid var(--border2);
        border-radius:var(--radius);padding:24px;width:320px;max-width:90vw;
        box-shadow:0 16px 40px rgba(0,0,0,0.5);
    }
    .name-modal h3{font-size:16px;font-weight:700;color:var(--text);margin-bottom:4px}
    .name-modal p{font-size:13px;color:var(--text-dim);margin-bottom:16px}
    .name-modal input{
        width:100%;padding:10px 14px;background:var(--bg);
        border:1px solid var(--border2);border-radius:var(--radius-sm);
        color:var(--text);font-size:14px;font-family:inherit;outline:none;
        margin-bottom:12px;box-sizing:border-box;
    }
    .name-modal input:focus{border-color:var(--purple)}
    .name-modal-btn{
        width:100%;padding:10px;border-radius:var(--radius-sm);border:none;
        background:var(--purple);color:#fff;font-size:14px;font-weight:600;
        cursor:pointer;transition:background 0.15s;
    }
    .name-modal-btn:hover{background:#9333ea}

    /* ── Human Messages (other participants) ── */
    .msg.human{align-self:flex-start}
    .msg-human-row{display:flex;align-items:center;gap:6px;padding:0 2px}
    .human-avatar{
        width:22px;height:22px;border-radius:50%;
        background:var(--surface2);border:1px solid var(--border2);
        display:flex;align-items:center;justify-content:center;
        font-size:10px;font-weight:700;color:var(--text-dim);flex-shrink:0;
    }
    .msg-human-name{font-size:12px;font-weight:700;color:var(--text-dim);letter-spacing:0.3px}
    .msg.human .bubble{
        background:rgba(255,255,255,0.04);border-radius:18px 18px 18px 4px;padding:10px 16px;
    }

    /* ── Participant Indicator ── */
    .people-badge{
        font-size:11px;font-weight:700;color:var(--text-faint);
        background:rgba(255,255,255,0.06);padding:2px 8px;border-radius:10px;
        flex-shrink:0;display:none;
    }
    .people-badge.visible{display:inline-block}

    /* ── Mobile ── */
    @media(max-width:768px){
        .sidebar{
            position:fixed;left:0;top:0;bottom:0;width:280px;
            transform:translateX(-100%);transition:transform 0.25s ease;z-index:200;
        }
        .sidebar.open{transform:translateX(0)}
        .sidebar-close{display:block}
        .hamburger{display:flex}
        .conn-dot-mobile{display:block}
        .canvas-panel.open{
            flex:none !important;position:absolute;right:0;top:0;bottom:0;
            width:100%;z-index:50;
        }
    }
    @media(max-width:480px){
        .header{padding:8px 12px;gap:6px}
        .agent-pill{font-size:11px}
        .pill-label-area{padding:5px 8px 5px 5px}
        .pill-dot-area{padding:5px 0 5px 8px}
        .msg-col{padding:16px 12px}
        .bubble{font-size:14px}
        .input-bar{padding:8px 10px;padding-bottom:max(8px,env(safe-area-inset-bottom))}
    }
    </style>
    </head>
    <body>

    <div class="app">

    <!-- Sidebar -->
    <div class="sidebar" id="sidebar">
        <div class="sidebar-header">
            <div class="logo">TORBO BASE</div>
            <div class="conn-dot" id="connDot" title="Connected"></div>
            <div style="flex:1"></div>
            <button class="sidebar-close" id="sidebarClose">&times;</button>
        </div>
        <button class="new-chat-btn" id="newChatBtn">+ New Chat</button>
        <div class="room-list" id="roomList"></div>
        <div class="sidebar-nav">
            <button class="nav-item active" data-view="chat" id="navChat">Chat</button>
            <button class="nav-item" data-view="conversations" id="navHistory">History</button>
        </div>
    </div>
    <div class="sidebar-overlay" id="sidebarOverlay"></div>

    <!-- Main Area -->
    <div class="main">
        <div class="header">
            <button class="hamburger" id="hamburger">&#9776;</button>
            <div class="agent-pills" id="agentPills"></div>
            <div class="spacer"></div>
            <button class="share-btn" id="shareBtn" title="Share room">
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M4 12v8a2 2 0 002 2h12a2 2 0 002-2v-8"/><polyline points="16 6 12 2 8 6"/><line x1="12" y1="2" x2="12" y2="15"/></svg>
            </button>
            <span class="people-badge" id="peopleBadge"></span>
            <button class="canvas-toggle" id="canvasToggle" title="Canvas">
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="3" width="18" height="18" rx="2"/><path d="M9 9l3 3-3 3"/><line x1="15" y1="15" x2="18" y2="15"/></svg>
            </button>
            <div class="conn-dot conn-dot-mobile" id="connDotMobile" title="Connected"></div>
        </div>
        <div class="reconnect-banner" id="reconnectBanner">Connection lost. Reconnecting...</div>

        <div class="content-row">
            <!-- Chat View -->
            <div class="view-chat" id="viewChat">
                <div class="chat-scroll" id="chatScroll">
                    <div class="msg-col" id="messages">
                        <div class="empty-state" id="emptyState">
                            <div class="empty-orb"></div>
                            <p>Start a conversation with your Torbo agent.</p>
                        </div>
                    </div>
                </div>
                <div class="input-bar">
                    <div class="input-inner">
                        <div class="attach-preview" id="attachPreview"></div>
                        <div class="input-row">
                            <button class="attach-btn" id="attachBtn" title="Attach file">
                                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M21.44 11.05l-9.19 9.19a6 6 0 01-8.49-8.49l9.19-9.19a4 4 0 015.66 5.66l-9.2 9.19a2 2 0 01-2.83-2.83l8.49-8.48"/></svg>
                            </button>
                            <textarea id="input" placeholder="Message..." rows="1" autocomplete="off" enterkeyhint="send"></textarea>
                            <button class="send-btn" id="sendBtn" title="Send">
                                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><line x1="22" y1="2" x2="11" y2="13"/><polygon points="22 2 15 22 11 13 2 9 22 2"/></svg>
                            </button>
                        </div>
                    </div>
                </div>
            </div>

            <!-- Conversations View -->
            <div class="view-conversations" id="viewConversations">
                <div class="conv-search">
                    <input type="text" id="convSearch" placeholder="Search conversations..." autocomplete="off">
                </div>
                <div class="conv-filters" id="convFilters"></div>
                <div class="conv-list" id="convList"></div>
            </div>

            <!-- Canvas Panel -->
            <div class="canvas-panel" id="canvasPanel">
                <div class="canvas-header">
                    <span class="canvas-lang" id="canvasLang">text</span>
                    <div style="flex:1"></div>
                    <button class="canvas-btn" id="canvasCopy">Copy</button>
                    <button class="canvas-btn" id="canvasDownload">Download</button>
                    <button class="canvas-close" id="canvasClose">&times;</button>
                </div>
                <textarea class="canvas-editor" id="canvasEditor" placeholder="Paste or edit code here..." spellcheck="false"></textarea>
                <div class="canvas-footer">
                    <label class="canvas-include">
                        <input type="checkbox" id="canvasInclude" checked>
                        Include in next message
                    </label>
                </div>
            </div>
        </div>
    </div>
    </div>

    <!-- Drop Zone Overlay -->
    <div class="drop-zone" id="dropZone">
        <div class="drop-zone-icon">&#128206;</div>
        <div class="drop-zone-text">Drop files here</div>
    </div>

    <!-- Toast -->
    <div class="toast" id="toast"></div>

    <!-- Name Prompt Modal -->
    <div class="name-modal-overlay" id="nameModalOverlay">
        <div class="name-modal">
            <h3>Join Room</h3>
            <p>Enter your display name to chat with others.</p>
            <input type="text" id="nameInput" placeholder="Your name..." autocomplete="off" maxlength="30">
            <button class="name-modal-btn" id="nameModalBtn">Join</button>
        </div>
    </div>

    <!-- Hidden file input -->
    <input type="file" id="fileInput" accept="image/*,.txt,.md,.js,.ts,.py,.swift,.json,.csv,.html,.css,.sh,.yml,.yaml,.xml,.sql,.go,.rs,.java,.c,.cpp,.h,.tsx,.jsx,.rb,.toml" multiple style="display:none">

    <script>
    // ─── Config ───
    var TOKEN = '/*%%TORBO_SESSION_TOKEN%%*/';
    var BASE = window.location.origin;
    var AGENTS = {
        sid:   { name: 'SiD',   color: '#FF69B4' },
        ada:   { name: 'aDa',   color: '#4A9FFF' },
        mira:  { name: 'Mira',  color: '#3DDC84' },
        orion: { name: 'Orion', color: '#A855F7' }
    };
    var STORAGE_KEY = 'torbo_wc_';
    var PROVIDER_LABELS = {
        ollama: 'Local', anthropic: 'Anthropic', openai: 'OpenAI',
        google: 'Google', xai: 'xAI', local: 'Local'
    };
    var PROVIDER_ORDER = ['ollama','local','anthropic','openai','google','xai'];
    var TEXT_EXTENSIONS = ['.txt','.md','.js','.ts','.tsx','.jsx','.py','.swift','.json','.csv','.html','.css','.sh','.yml','.yaml','.xml','.sql','.go','.rs','.java','.c','.cpp','.h','.rb','.toml'];

    // ─── State ───
    var state = {
        rooms: [],
        activeRoomID: null,
        roomMessages: {},
        models: [],
        currentView: 'chat',
        sidebarOpen: false,
        isStreaming: false,
        connected: true,
        activeControllers: {},
        activeAgents: ['sid'],
        pendingFiles: [],
        canvas: { open: false, content: '', language: '' },
        convFilter: 'all',
        convQuery: '',
        displayName: '',
        pollTimer: null,
        lastPollTS: 0,
        localMsgKeys: {}
    };

    // ─── Code block store for copy/canvas ───
    var codeBlocks = {};
    var cbCounter = 0;

    // ─── Elements ───
    var sidebar = document.getElementById('sidebar');
    var sidebarOverlay = document.getElementById('sidebarOverlay');
    var roomListEl = document.getElementById('roomList');
    var chatScroll = document.getElementById('chatScroll');
    var messagesEl = document.getElementById('messages');
    var inputEl = document.getElementById('input');
    var sendBtn = document.getElementById('sendBtn');
    var connDot = document.getElementById('connDot');
    var connDotMobile = document.getElementById('connDotMobile');
    var reconnectBanner = document.getElementById('reconnectBanner');
    var agentPills = document.getElementById('agentPills');
    var shareBtn = document.getElementById('shareBtn');
    var peopleBadge = document.getElementById('peopleBadge');
    var toastEl = document.getElementById('toast');
    var nameModalOverlay = document.getElementById('nameModalOverlay');
    var nameInputEl = document.getElementById('nameInput');
    var nameModalBtn = document.getElementById('nameModalBtn');
    var pillDropdownEl = null;
    var pillDropdownAgent = null;
    var viewChat = document.getElementById('viewChat');
    var viewConversations = document.getElementById('viewConversations');
    var convSearchEl = document.getElementById('convSearch');
    var convFiltersEl = document.getElementById('convFilters');
    var convListEl = document.getElementById('convList');
    var navChat = document.getElementById('navChat');
    var navHistory = document.getElementById('navHistory');
    var attachBtn = document.getElementById('attachBtn');
    var attachPreview = document.getElementById('attachPreview');
    var fileInput = document.getElementById('fileInput');
    var canvasPanel = document.getElementById('canvasPanel');
    var canvasEditorEl = document.getElementById('canvasEditor');
    var canvasLangEl = document.getElementById('canvasLang');
    var canvasIncludeEl = document.getElementById('canvasInclude');
    var canvasToggleBtn = document.getElementById('canvasToggle');
    var dropZone = document.getElementById('dropZone');

    // ─── Utilities ───
    function genLocalID() {
        var a = new Uint8Array(4);
        crypto.getRandomValues(a);
        return Array.from(a).map(function(b) { return b.toString(16).padStart(2,'0'); }).join('');
    }

    function relativeTime(ts) {
        var diff = Date.now() - ts;
        if (diff < 60000) return 'now';
        if (diff < 3600000) return Math.floor(diff/60000) + 'm';
        if (diff < 86400000) return Math.floor(diff/3600000) + 'h';
        return Math.floor(diff/86400000) + 'd';
    }

    function authHeaders(extra) {
        var h = { 'Authorization': 'Bearer ' + TOKEN };
        if (extra) Object.assign(h, extra);
        return h;
    }

    function currentRoom() {
        return state.rooms.find(function(r) { return r.id === state.activeRoomID; }) || null;
    }

    function primaryAgent() {
        return state.activeAgents[0] || 'sid';
    }

    function escapeHtml(s) {
        return s.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;');
    }

    function isTextFile(file) {
        if (file.type && file.type.startsWith('text/')) return true;
        var name = file.name.toLowerCase();
        return TEXT_EXTENSIONS.some(function(ext) { return name.endsWith(ext); });
    }

    // ─── Per-Agent Model Storage ───
    function getAgentModel(agentID) {
        try {
            var raw = localStorage.getItem(STORAGE_KEY + 'agentModels');
            if (raw) { var map = JSON.parse(raw); return map[agentID] || null; }
        } catch(e) {}
        return null;
    }

    function setAgentModel(agentID, modelID) {
        try {
            var map = {};
            var raw = localStorage.getItem(STORAGE_KEY + 'agentModels');
            if (raw) map = JSON.parse(raw);
            if (modelID) map[agentID] = modelID;
            else delete map[agentID];
            localStorage.setItem(STORAGE_KEY + 'agentModels', JSON.stringify(map));
        } catch(e) {}
    }

    // ─── Persistence ───
    function persistRooms() {
        try { localStorage.setItem(STORAGE_KEY + 'rooms', JSON.stringify(state.rooms)); } catch(e) {}
    }

    function loadPersistedRooms() {
        try {
            var raw = localStorage.getItem(STORAGE_KEY + 'rooms');
            if (raw) state.rooms = JSON.parse(raw);
        } catch(e) { state.rooms = []; }
    }

    function migrateOldFormat() {
        var agentIDs = Object.keys(AGENTS);
        var migrated = false;
        agentIDs.forEach(function(agentID) {
            var key = STORAGE_KEY + 'conv_' + agentID;
            try {
                var raw = localStorage.getItem(key);
                if (!raw) return;
                var msgs = JSON.parse(raw);
                if (!msgs || msgs.length === 0) { localStorage.removeItem(key); return; }
                var roomID = genLocalID();
                var firstMsg = msgs.find(function(m) { return m.role === 'user'; });
                var title = firstMsg ? firstMsg.content.slice(0,30) + (firstMsg.content.length > 30 ? '...' : '') : (AGENTS[agentID] ? AGENTS[agentID].name : agentID) + ' chat';
                state.rooms.push({
                    id: roomID, title: title, agent: agentID, agents: [agentID], model: null,
                    createdAt: Date.now() - 1000, lastMessageAt: Date.now() - 1000
                });
                state.roomMessages[roomID] = msgs.map(function(m) {
                    return {
                        role: m.role, content: m.content,
                        agent: m.agent || (m.role === 'assistant' ? agentID : null),
                        time: m.time || '', images: null
                    };
                });
                localStorage.removeItem(key);
                migrated = true;
            } catch(e) { localStorage.removeItem(key); }
        });
        localStorage.removeItem(STORAGE_KEY + 'agent');
        // Migrate per-room model to per-agent model
        state.rooms.forEach(function(room) {
            if (room.model && !getAgentModel(room.agent)) {
                setAgentModel(room.agent, room.model);
            }
        });
        if (migrated) persistRooms();
    }

    // ─── Room CRUD ───
    async function createRoom() {
        var agent = primaryAgent();
        var roomID;
        try {
            var res = await fetch(BASE + '/v1/room/create', {
                method: 'POST',
                headers: authHeaders({'Content-Type':'application/json'}),
                body: JSON.stringify({agentID: agent})
            });
            if (res.ok) { var data = await res.json(); roomID = data.room; }
        } catch(e) {}
        if (!roomID) roomID = genLocalID();

        var room = {
            id: roomID, title: 'New Chat', agent: agent,
            agents: state.activeAgents.slice(), model: null,
            createdAt: Date.now(), lastMessageAt: Date.now()
        };
        state.rooms.unshift(room);
        state.roomMessages[roomID] = [];
        persistRooms();
        switchRoom(roomID);
        renderRoomList();
    }

    async function loadRoomMessages(roomID) {
        if (state.roomMessages[roomID] && state.roomMessages[roomID].length > 0) return;
        try {
            var res = await fetch(BASE + '/v1/room/messages?room=' + encodeURIComponent(roomID) + '&since=0', {
                headers: authHeaders()
            });
            if (res.ok) {
                var data = await res.json();
                if (data.messages && data.messages.length > 0) {
                    state.roomMessages[roomID] = data.messages.map(function(m) {
                        return {
                            role: m.role, content: m.content,
                            agent: m.agentID || (m.role === 'assistant' ? primaryAgent() : null),
                            time: m.timestamp ? new Date(m.timestamp).toLocaleTimeString([], {hour:'2-digit', minute:'2-digit'}) : '',
                            images: null
                        };
                    });
                }
            }
        } catch(e) {}
        if (!state.roomMessages[roomID]) state.roomMessages[roomID] = [];
    }

    async function switchRoom(roomID) {
        state.activeRoomID = roomID;
        try { localStorage.setItem(STORAGE_KEY + 'activeRoom', roomID); } catch(e) {}
        await loadRoomMessages(roomID);
        var room = currentRoom();
        if (room) {
            state.activeAgents = room.agents ? room.agents.slice() : [room.agent || 'sid'];
            updateAgentPillSelection();
            updatePillModels();
        }
        renderMessages();
        renderRoomList();
        if (state.currentView !== 'chat') switchView('chat');
        closeSidebar();
    }

    function deleteRoom(roomID) {
        state.rooms = state.rooms.filter(function(r) { return r.id !== roomID; });
        delete state.roomMessages[roomID];
        persistRooms();
        if (state.activeRoomID === roomID) {
            if (state.rooms.length > 0) switchRoom(state.rooms[0].id);
            else createRoom();
        } else {
            renderRoomList();
        }
    }

    // ─── Agent Pills (multi-select with per-agent model) ───
    function renderAgentPills(agents) {
        agentPills.innerHTML = '';
        var ids = agents.length ? agents.map(function(a) { return a.id; }) : Object.keys(AGENTS);
        ids.forEach(function(id) {
            var info = AGENTS[id] || { name: id, color: '#a855f7' };
            var pill = document.createElement('div');
            pill.className = 'agent-pill';
            pill.dataset.agent = id;

            var dotArea = document.createElement('span');
            dotArea.className = 'pill-dot-area';
            var dot = document.createElement('span');
            dot.className = 'pill-dot';
            dot.style.background = info.color;
            dotArea.appendChild(dot);
            dotArea.onclick = function(e) { e.stopPropagation(); toggleAgent(id); };
            pill.appendChild(dotArea);

            var labelArea = document.createElement('span');
            labelArea.className = 'pill-label-area';
            var nameSpan = document.createElement('span');
            nameSpan.className = 'pill-name';
            nameSpan.textContent = info.name;
            labelArea.appendChild(nameSpan);
            var modelSpan = document.createElement('span');
            modelSpan.className = 'pill-model';
            var mid = getAgentModel(id);
            modelSpan.textContent = mid ? '\\u00b7 ' + mid.split('/').pop().split(':')[0] : '';
            labelArea.appendChild(modelSpan);
            var arrow = document.createElement('span');
            arrow.className = 'pill-arrow';
            arrow.textContent = '\\u25be';
            labelArea.appendChild(arrow);
            labelArea.onclick = function(e) { e.stopPropagation(); openAgentModelPicker(id, pill); };
            pill.appendChild(labelArea);

            agentPills.appendChild(pill);
        });
        updateAgentPillSelection();
    }

    function updateAgentPillSelection() {
        document.querySelectorAll('.agent-pill').forEach(function(p) {
            var isActive = state.activeAgents.indexOf(p.dataset.agent) >= 0;
            p.classList.toggle('active', isActive);
            p.classList.toggle('inactive', !isActive);
        });
    }

    function toggleAgent(id) {
        if (state.isStreaming) return;
        var idx = state.activeAgents.indexOf(id);
        if (idx >= 0) {
            if (state.activeAgents.length <= 1) return;
            state.activeAgents.splice(idx, 1);
        } else {
            state.activeAgents.push(id);
        }
        var room = currentRoom();
        if (room) {
            room.agents = state.activeAgents.slice();
            room.agent = state.activeAgents[0];
            persistRooms();
            renderRoomList();
        }
        updateAgentPillSelection();
    }

    // ─── Model Selector (per-agent pill dropdown) ───
    async function loadModels() {
        try {
            var res = await fetch(BASE + '/v1/models', { headers: authHeaders() });
            if (res.ok) { var data = await res.json(); state.models = data.data || []; }
        } catch(e) {}
    }

    function openAgentModelPicker(agentID, anchorEl) {
        if (!pillDropdownEl) {
            pillDropdownEl = document.createElement('div');
            pillDropdownEl.className = 'pill-dropdown';
            document.body.appendChild(pillDropdownEl);
        }
        if (pillDropdownEl.classList.contains('visible') && pillDropdownAgent === agentID) {
            pillDropdownEl.classList.remove('visible');
            return;
        }
        pillDropdownAgent = agentID;
        var info = AGENTS[agentID] || { name: agentID, color: '#a855f7' };
        var selectedModel = getAgentModel(agentID);
        pillDropdownEl.innerHTML = '';

        var ddHeader = document.createElement('div');
        ddHeader.className = 'pill-dd-header';
        ddHeader.innerHTML = '<span class="pill-dd-dot" style="background:' + info.color + '"></span>' + escapeHtml(info.name) + ' model';
        pillDropdownEl.appendChild(ddHeader);

        var autoOpt = document.createElement('div');
        autoOpt.className = 'model-option' + (!selectedModel ? ' selected' : '');
        autoOpt.textContent = 'Auto (default)';
        autoOpt.onclick = function() { selectModelForAgent(agentID, null); };
        pillDropdownEl.appendChild(autoOpt);

        var groups = {};
        state.models.forEach(function(m) {
            var provider = m.owned_by || 'local';
            if (!groups[provider]) groups[provider] = [];
            groups[provider].push(m);
        });
        PROVIDER_ORDER.forEach(function(p) {
            if (!groups[p]) return;
            var header = document.createElement('div');
            header.className = 'model-group-header';
            header.textContent = PROVIDER_LABELS[p] || p;
            pillDropdownEl.appendChild(header);
            groups[p].forEach(function(m) {
                var opt = document.createElement('div');
                opt.className = 'model-option' + (selectedModel === m.id ? ' selected' : '');
                opt.textContent = m.id;
                opt.onclick = function() { selectModelForAgent(agentID, m.id); };
                pillDropdownEl.appendChild(opt);
            });
        });
        Object.keys(groups).forEach(function(p) {
            if (PROVIDER_ORDER.indexOf(p) >= 0) return;
            var header = document.createElement('div');
            header.className = 'model-group-header';
            header.textContent = PROVIDER_LABELS[p] || p;
            pillDropdownEl.appendChild(header);
            groups[p].forEach(function(m) {
                var opt = document.createElement('div');
                opt.className = 'model-option' + (selectedModel === m.id ? ' selected' : '');
                opt.textContent = m.id;
                opt.onclick = function() { selectModelForAgent(agentID, m.id); };
                pillDropdownEl.appendChild(opt);
            });
        });

        var rect = anchorEl.getBoundingClientRect();
        pillDropdownEl.style.top = (rect.bottom + 6) + 'px';
        pillDropdownEl.style.left = rect.left + 'px';
        pillDropdownEl.classList.add('visible');
    }

    function selectModelForAgent(agentID, modelID) {
        setAgentModel(agentID, modelID);
        updatePillModels();
        if (pillDropdownEl) pillDropdownEl.classList.remove('visible');
    }

    function updatePillModels() {
        document.querySelectorAll('.agent-pill').forEach(function(p) {
            var id = p.dataset.agent;
            var modelEl = p.querySelector('.pill-model');
            if (modelEl) {
                var mid = getAgentModel(id);
                modelEl.textContent = mid ? '\\u00b7 ' + mid.split('/').pop().split(':')[0] : '';
            }
        });
    }

    function closePillDropdown() {
        if (pillDropdownEl) pillDropdownEl.classList.remove('visible');
    }

    // ─── File Handling ───
    function processImage(file) {
        return new Promise(function(resolve) {
            var reader = new FileReader();
            reader.onload = function(e) {
                var img = new Image();
                img.onload = function() {
                    var maxDim = 1536;
                    var w = img.width, h = img.height;
                    if (w > maxDim || h > maxDim) {
                        if (w > h) { h = Math.round(h * maxDim / w); w = maxDim; }
                        else { w = Math.round(w * maxDim / h); h = maxDim; }
                    }
                    var c = document.createElement('canvas');
                    c.width = w; c.height = h;
                    c.getContext('2d').drawImage(img, 0, 0, w, h);
                    var dataURL = c.toDataURL('image/jpeg', 0.8);
                    resolve({ type: 'image', name: file.name, dataURL: dataURL, preview: dataURL });
                };
                img.src = e.target.result;
            };
            reader.readAsDataURL(file);
        });
    }

    function processTextFile(file) {
        return new Promise(function(resolve) {
            var reader = new FileReader();
            reader.onload = function(e) {
                resolve({ type: 'text', name: file.name, content: e.target.result });
            };
            reader.readAsText(file);
        });
    }

    async function handleFiles(fileList) {
        var files = Array.from(fileList);
        for (var i = 0; i < files.length; i++) {
            var file = files[i];
            if (file.type && file.type.startsWith('image/')) {
                state.pendingFiles.push(await processImage(file));
            } else if (isTextFile(file)) {
                state.pendingFiles.push(await processTextFile(file));
            }
        }
        renderAttachmentPreview();
    }

    function renderAttachmentPreview() {
        if (state.pendingFiles.length === 0) {
            attachPreview.classList.remove('visible');
            attachPreview.innerHTML = '';
            return;
        }
        attachPreview.classList.add('visible');
        attachPreview.innerHTML = '';
        state.pendingFiles.forEach(function(f, i) {
            if (f.type === 'image') {
                var thumb = document.createElement('div');
                thumb.className = 'attach-thumb';
                thumb.innerHTML = '<img src="' + f.preview + '" alt=""><button class="attach-remove" data-idx="' + i + '">&times;</button>';
                attachPreview.appendChild(thumb);
            } else {
                var chip = document.createElement('div');
                chip.className = 'attach-chip';
                chip.innerHTML = '<span class="attach-icon">&#128196;</span><span class="attach-name">' + escapeHtml(f.name) + '</span><button class="attach-remove" data-idx="' + i + '">&times;</button>';
                attachPreview.appendChild(chip);
            }
        });
    }

    // ─── Canvas ───
    function openCanvas(code, lang) {
        state.canvas = { open: true, content: code, language: lang || '' };
        canvasEditorEl.value = code;
        canvasLangEl.textContent = lang || 'text';
        canvasPanel.classList.add('open');
        canvasToggleBtn.classList.add('active');
    }

    function closeCanvas() {
        state.canvas.open = false;
        canvasPanel.classList.remove('open');
        canvasToggleBtn.classList.remove('active');
    }

    // ─── Message Rendering ───
    function renderMessages() {
        messagesEl.innerHTML = '';
        codeBlocks = {};
        cbCounter = 0;
        var msgs = state.roomMessages[state.activeRoomID] || [];
        if (msgs.length === 0) {
            var es = document.createElement('div');
            es.className = 'empty-state';
            es.innerHTML = '<div class="empty-orb"></div><p>Start a conversation with your Torbo agent.</p>';
            messagesEl.appendChild(es);
            return;
        }
        msgs.forEach(function(msg) { appendMessageDOM(msg); });
        scrollToBottom();
    }

    function appendMessageDOM(msg) {
        var es = messagesEl.querySelector('.empty-state');
        if (es) es.remove();

        // Determine if this is a message from another human
        var isOtherHuman = msg.role === 'user' && msg.sender && msg.sender !== state.displayName && msg.sender !== 'user';

        var div = document.createElement('div');
        div.className = isOtherHuman ? 'msg human' : ('msg ' + msg.role);
        var agentID = msg.agent || primaryAgent();
        var info = AGENTS[agentID] || { name: agentID, color: '#a855f7' };

        if (isOtherHuman) {
            var humanRow = document.createElement('div');
            humanRow.className = 'msg-human-row';
            var avatar = document.createElement('span');
            avatar.className = 'human-avatar';
            avatar.textContent = (msg.sender || '?')[0].toUpperCase();
            humanRow.appendChild(avatar);
            var nameEl = document.createElement('span');
            nameEl.className = 'msg-human-name';
            nameEl.textContent = msg.sender;
            humanRow.appendChild(nameEl);
            div.appendChild(humanRow);
        } else if (msg.role === 'assistant') {
            var agentRow = document.createElement('div');
            agentRow.className = 'msg-agent-row';
            agentRow.innerHTML = '<span class="agent-dot" style="background:' + info.color + '"></span><span class="msg-agent-name" style="color:' + info.color + '">' + escapeHtml(info.name) + '</span>';
            div.appendChild(agentRow);
        }

        var bubble = document.createElement('div');
        bubble.className = 'bubble';

        if (msg.role === 'user') {
            var textContent = typeof msg.content === 'string' ? msg.content : JSON.stringify(msg.content);
            if (textContent) {
                var textSpan = document.createElement('span');
                textSpan.className = 'msg-text';
                textSpan.textContent = textContent;
                bubble.appendChild(textSpan);
            }
            if (msg.images && msg.images.length > 0) {
                var imgRow = document.createElement('div');
                imgRow.className = 'msg-images';
                msg.images.forEach(function(src) {
                    var img = document.createElement('img');
                    img.src = src;
                    img.className = 'msg-img';
                    imgRow.appendChild(img);
                });
                bubble.appendChild(imgRow);
            }
        } else {
            bubble.innerHTML = renderMarkdown(msg.content || '');
        }

        div.appendChild(bubble);

        if (msg.time) {
            var meta = document.createElement('div');
            meta.className = 'msg-meta';
            meta.textContent = msg.time;
            div.appendChild(meta);
        }

        messagesEl.appendChild(div);
        return bubble;
    }

    function createTypingBubble(agentID) {
        var info = AGENTS[agentID] || { name: agentID, color: '#a855f7' };
        var div = document.createElement('div');
        div.className = 'msg assistant';
        div.dataset.typing = agentID;
        div.innerHTML = '<div class="msg-agent-row"><span class="agent-dot" style="background:' + info.color + '"></span><span class="msg-agent-name" style="color:' + info.color + '">' + escapeHtml(info.name) + '</span></div><div class="bubble typing-bubble"><div class="typing-dots"><span style="background:' + info.color + '"></span><span style="background:' + info.color + '"></span><span style="background:' + info.color + '"></span></div></div>';
        return div;
    }

    function scrollToBottom() {
        requestAnimationFrame(function() { chatScroll.scrollTop = chatScroll.scrollHeight; });
    }

    // ─── Markdown Renderer ───
    function renderMarkdown(text) {
        var html = escapeHtml(text);
        html = html.replace(/```(\\w*)\\n([\\s\\S]*?)```/g, function(_, lang, code) {
            var trimmed = code.trim();
            var id = 'cb' + (++cbCounter);
            codeBlocks[id] = { code: trimmed, lang: lang || '' };
            var hl = highlightSyntax(trimmed);
            var langLabel = lang || 'code';
            return '<div class="code-wrap"><div class="code-header"><span class="code-lang">' + langLabel + '</span><div class="code-actions"><button class="code-btn" data-action="canvas" data-cb="' + id + '">Canvas</button><button class="code-btn" data-action="copy" data-cb="' + id + '">Copy</button></div></div><pre><code>' + hl + '</code></pre></div>';
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
        html = html.replace(/<\\/(pre|h[123]|ul|ol|li|hr|div)><br>/g, '</$1>');
        html = html.replace(/<br><(pre|h[123]|ul|ol|div)/g, '<$1');
        return html;
    }

    function highlightSyntax(code) {
        var h = code;
        h = h.replace(/(\\/\\/.*?(?:<br>|$)|\\/\\*[\\s\\S]*?\\*\\/|#.*?(?:<br>|$))/g, '<span class="token-comment">$1</span>');
        h = h.replace(/(&quot;[^&]*?&quot;|&#x27;[^&]*?&#x27;)/g, '<span class="token-string">$1</span>');
        h = h.replace(/\\b(const|let|var|function|return|if|else|for|while|class|import|export|from|async|await|try|catch|def|self|print|fn|pub|use|mod|struct|impl|enum|match|type|interface|func|guard|switch|case|break|continue|throw|throws|static|final|override|private|public|protected|internal|new|delete|typeof|instanceof|in|of|yield|super|this|true|false|null|nil|None|True|False)\\b/g, '<span class="token-keyword">$1</span>');
        h = h.replace(/\\b(\\d+\\.?\\d*)\\b/g, '<span class="token-number">$1</span>');
        return h;
    }

    // ─── Send Message ───
    async function sendMessage() {
        var text = inputEl.value.trim();
        var files = state.pendingFiles.slice();
        if (!text && files.length === 0) return;
        if (state.isStreaming) return;
        if (!state.activeRoomID) await createRoom();

        var room = currentRoom();
        if (!room) return;
        var agents = state.activeAgents.slice();

        // Build text content (prepend text files)
        var textFiles = files.filter(function(f) { return f.type === 'text'; });
        var images = files.filter(function(f) { return f.type === 'image'; });
        var fullText = '';
        textFiles.forEach(function(f) {
            fullText += '[' + f.name + ']\\n' + f.content + '\\n\\n';
        });
        fullText += text;

        // Append canvas content if active and included
        if (state.canvas.open && canvasIncludeEl.checked && canvasEditorEl.value.trim()) {
            fullText += '\\n\\n```' + (state.canvas.language || '') + '\\n' + canvasEditorEl.value + '\\n```';
        }

        // Build multimodal content array if images present
        var contentArray = null;
        if (images.length > 0) {
            contentArray = [{ type: 'text', text: fullText }];
            images.forEach(function(img) {
                contentArray.push({ type: 'image_url', image_url: { url: img.dataURL } });
            });
        }

        var time = new Date().toLocaleTimeString([], {hour:'2-digit', minute:'2-digit'});
        var senderName = state.displayName || 'user';
        var userMsg = {
            role: 'user',
            content: fullText,
            images: images.map(function(f) { return f.preview; }),
            agent: null,
            sender: senderName,
            time: time
        };

        // Track locally sent messages to avoid duplicates during polling
        var msgKey = 'u:' + fullText.slice(0, 80);
        state.localMsgKeys[msgKey] = Date.now();

        if (!state.roomMessages[state.activeRoomID]) state.roomMessages[state.activeRoomID] = [];
        state.roomMessages[state.activeRoomID].push(userMsg);
        appendMessageDOM(userMsg);
        scrollToBottom();

        // Auto-title
        if (room.title === 'New Chat' && text) {
            room.title = text.slice(0, 30) + (text.length > 30 ? '...' : '');
            persistRooms();
            renderRoomList();
        }

        // Post user message to room (text only, no images)
        fetch(BASE + '/v1/room/message', {
            method: 'POST',
            headers: authHeaders({'Content-Type':'application/json'}),
            body: JSON.stringify({ room: state.activeRoomID, sender: senderName, content: fullText, role: 'user', agentID: agents[0] })
        }).catch(function() {});

        // Clear input
        inputEl.value = '';
        inputEl.style.height = 'auto';
        state.pendingFiles = [];
        renderAttachmentPreview();

        // Build API messages
        var roomMsgs = state.roomMessages[state.activeRoomID];
        var apiMessages = roomMsgs.map(function(m, idx) {
            // For the last message (just sent), include images if any
            if (idx === roomMsgs.length - 1 && contentArray) {
                return { role: 'user', content: contentArray };
            }
            return { role: m.role, content: m.content || '' };
        });

        // Stream to each active agent
        state.isStreaming = true;
        sendBtn.disabled = true;
        state.activeControllers = {};

        var streamPromises = agents.map(function(agentID) {
            var ctrl = new AbortController();
            state.activeControllers[agentID] = ctrl;
            return streamToAgent(agentID, apiMessages, state.activeRoomID, ctrl);
        });

        await Promise.allSettled(streamPromises);

        state.isStreaming = false;
        sendBtn.disabled = false;
        state.activeControllers = {};
        room.lastMessageAt = Date.now();
        persistRooms();
        renderRoomList();
        inputEl.focus();
    }

    async function streamToAgent(agentID, apiMessages, roomID, ctrl) {
        var info = AGENTS[agentID] || { name: agentID, color: '#a855f7' };
        var model = getAgentModel(agentID) || '_default';

        var typingDiv = createTypingBubble(agentID);
        messagesEl.appendChild(typingDiv);
        scrollToBottom();

        var fullContent = '';

        try {
            var res = await fetch(BASE + '/v1/chat/completions', {
                method: 'POST',
                signal: ctrl.signal,
                headers: authHeaders({'Content-Type':'application/json', 'x-torbo-agent-id': agentID}),
                body: JSON.stringify({ model: model, messages: apiMessages, stream: true })
            });

            if (!res.ok) {
                var err = await res.json().catch(function() { return { error: 'Request failed' }; });
                var errText = typeof err.error === 'object' ? (err.error.message || JSON.stringify(err.error)) : (err.error || 'Error');
                typingDiv.remove();
                var errMsg = { role: 'assistant', content: errText, agent: agentID, time: new Date().toLocaleTimeString([], {hour:'2-digit', minute:'2-digit'}), images: null };
                state.roomMessages[roomID].push(errMsg);
                appendMessageDOM(errMsg);
                scrollToBottom();
                return;
            }

            typingDiv.remove();
            var assistantMsg = { role: 'assistant', content: '', agent: agentID, time: new Date().toLocaleTimeString([], {hour:'2-digit', minute:'2-digit'}), images: null };
            state.roomMessages[roomID].push(assistantMsg);
            var bubble = appendMessageDOM(assistantMsg);

            var contentType = res.headers.get('content-type') || '';
            if (contentType.indexOf('text/event-stream') >= 0) {
                var reader = res.body.getReader();
                var decoder = new TextDecoder();
                var buffer = '';

                while (true) {
                    var result = await reader.read();
                    if (result.done) break;
                    buffer += decoder.decode(result.value, { stream: true });
                    var lines = buffer.split('\\n');
                    buffer = lines.pop();

                    for (var li = 0; li < lines.length; li++) {
                        var line = lines[li];
                        if (line.indexOf('data: ') !== 0) continue;
                        var payload = line.slice(6).trim();
                        if (payload === '[DONE]') break;
                        try {
                            var chunk = JSON.parse(payload);
                            var delta = chunk.choices && chunk.choices[0] && chunk.choices[0].delta ? (chunk.choices[0].delta.content || '') : '';
                            if (delta) {
                                fullContent += delta;
                                var display = fullContent.replace(/\\[[a-z]+:\\s*[^\\]]*\\]/g, '').trim();
                                bubble.innerHTML = renderMarkdown(display) + '<span class="cursor">\\u2588</span>';
                                scrollToBottom();
                            }
                        } catch(e) {}
                    }
                }
            } else {
                var data = await res.json();
                if (data.choices && data.choices[0]) {
                    fullContent = data.choices[0].message ? (data.choices[0].message.content || '') : '';
                }
            }

            // Finalize
            fullContent = fullContent.replace(/\\[[a-z]+:\\s*[^\\]]*\\]/g, '').trim();
            assistantMsg.content = fullContent;
            if (bubble) bubble.innerHTML = renderMarkdown(fullContent);
            scrollToBottom();

            // Track locally generated AI messages to avoid poll duplicates
            var aKey = 'a:' + agentID + ':' + fullContent.slice(0, 80);
            state.localMsgKeys[aKey] = Date.now();

            // Post assistant message to room
            fetch(BASE + '/v1/room/message', {
                method: 'POST',
                headers: authHeaders({'Content-Type':'application/json'}),
                body: JSON.stringify({ room: roomID, sender: agentID, content: fullContent, role: 'assistant', agentID: agentID })
            }).catch(function() {});

        } catch(e) {
            typingDiv.remove();
            if (e.name !== 'AbortError') {
                var errMsg2 = { role: 'assistant', content: 'Connection error. Is Base running?', agent: agentID, time: new Date().toLocaleTimeString([], {hour:'2-digit', minute:'2-digit'}), images: null };
                state.roomMessages[roomID].push(errMsg2);
                appendMessageDOM(errMsg2);
            }
        }
    }

    // ─── Sidebar ───
    function renderRoomList() {
        roomListEl.innerHTML = '';
        var sorted = state.rooms.slice().sort(function(a,b) { return (b.lastMessageAt||0) - (a.lastMessageAt||0); });
        sorted.forEach(function(room) {
            var div = document.createElement('div');
            div.className = 'room-item' + (room.id === state.activeRoomID ? ' active' : '');

            var roomAgents = room.agents || [room.agent || 'sid'];
            // Active border color from first agent
            if (room.id === state.activeRoomID) {
                div.style.borderLeftColor = (AGENTS[roomAgents[0]] || {}).color || '#a855f7';
            }

            var dotsWrap = document.createElement('div');
            dotsWrap.className = 'room-dots';
            roomAgents.forEach(function(aid) {
                var dot = document.createElement('div');
                dot.className = 'room-dot';
                dot.style.background = (AGENTS[aid] || {}).color || '#a855f7';
                dotsWrap.appendChild(dot);
            });
            div.appendChild(dotsWrap);

            var body = document.createElement('div');
            body.className = 'room-item-body';
            var titleEl = document.createElement('div');
            titleEl.className = 'room-item-title';
            titleEl.textContent = room.title;
            body.appendChild(titleEl);
            var meta = document.createElement('div');
            meta.className = 'room-item-meta';
            var timeSpan = document.createElement('span');
            timeSpan.textContent = relativeTime(room.lastMessageAt || room.createdAt);
            meta.appendChild(timeSpan);
            body.appendChild(meta);
            div.appendChild(body);

            var delBtn = document.createElement('button');
            delBtn.className = 'room-item-delete';
            delBtn.innerHTML = '&times;';
            delBtn.onclick = function(e) { e.stopPropagation(); deleteRoom(room.id); };
            div.appendChild(delBtn);

            div.onclick = function() { switchRoom(room.id); };
            roomListEl.appendChild(div);
        });
    }

    function openSidebar() {
        sidebar.classList.add('open');
        sidebarOverlay.classList.add('visible');
        state.sidebarOpen = true;
    }
    function closeSidebar() {
        sidebar.classList.remove('open');
        sidebarOverlay.classList.remove('visible');
        state.sidebarOpen = false;
    }

    // ─── View Switching ───
    function switchView(view) {
        state.currentView = view;
        viewChat.style.display = view === 'chat' ? 'flex' : 'none';
        viewConversations.style.display = view === 'conversations' ? 'flex' : 'none';
        navChat.classList.toggle('active', view === 'chat');
        navHistory.classList.toggle('active', view === 'conversations');
        if (view === 'conversations') loadConversations();
        if (view === 'chat') inputEl.focus();
    }

    // ─── Conversations / History ───
    function renderConvFilters() {
        convFiltersEl.innerHTML = '';
        var allChip = document.createElement('button');
        allChip.className = 'filter-chip' + (state.convFilter === 'all' ? ' active' : '');
        allChip.textContent = 'All';
        allChip.onclick = function() { state.convFilter = 'all'; renderConvFilters(); loadConversations(); };
        convFiltersEl.appendChild(allChip);
        Object.keys(AGENTS).forEach(function(id) {
            var chip = document.createElement('button');
            chip.className = 'filter-chip' + (state.convFilter === id ? ' active' : '');
            chip.textContent = AGENTS[id].name;
            chip.onclick = function() { state.convFilter = id; renderConvFilters(); loadConversations(); };
            convFiltersEl.appendChild(chip);
        });
    }

    async function loadConversations() {
        var query = state.convQuery.trim().toLowerCase();

        // Build sessions from local rooms
        var sessions = state.rooms.slice().sort(function(a,b) {
            return (b.lastMessageAt || 0) - (a.lastMessageAt || 0);
        }).map(function(room) {
            var roomAgents = room.agents || [room.agent || 'sid'];
            var msgs = state.roomMessages[room.id] || [];
            var lastUserMsg = null;
            for (var i = msgs.length - 1; i >= 0; i--) {
                if (msgs[i].role === 'user') { lastUserMsg = msgs[i]; break; }
            }
            return {
                id: room.id, title: room.title || 'Untitled',
                agentID: roomAgents[0], agent: roomAgents[0],
                agents: roomAgents,
                model: getAgentModel(roomAgents[0]) || null,
                messageCount: msgs.length,
                startedAt: room.createdAt,
                lastMessageAt: room.lastMessageAt,
                preview: lastUserMsg ? lastUserMsg.content.slice(0, 100) : ''
            };
        });

        // Apply agent filter
        if (state.convFilter !== 'all') {
            sessions = sessions.filter(function(s) {
                var agents = s.agents || [s.agentID];
                return agents.indexOf(state.convFilter) >= 0;
            });
        }

        // Apply search query
        if (query) {
            sessions = sessions.filter(function(s) {
                if (s.title && s.title.toLowerCase().indexOf(query) >= 0) return true;
                if (s.preview && s.preview.toLowerCase().indexOf(query) >= 0) return true;
                // Search through messages
                var msgs = state.roomMessages[s.id] || [];
                return msgs.some(function(m) {
                    return m.content && m.content.toLowerCase().indexOf(query) >= 0;
                });
            });
        }

        renderSessions(sessions);
    }

    function renderSessions(sessions) {
        convListEl.innerHTML = '';
        if (sessions.length === 0) {
            convListEl.innerHTML = '<div class="conv-empty">No conversations yet</div>';
            return;
        }
        sessions.forEach(function(s) {
            var card = document.createElement('div');
            card.className = 'session-card';
            if (s.id === state.activeRoomID) card.style.borderColor = 'var(--purple)';
            var title = document.createElement('div');
            title.className = 'session-title';
            title.textContent = s.title || 'Untitled';
            card.appendChild(title);

            var meta = document.createElement('div');
            meta.className = 'session-meta';
            var agents = s.agents || (s.agentID ? [s.agentID] : [s.agent || 'sid']);
            agents.forEach(function(aid) {
                var badge = document.createElement('span');
                badge.className = 'session-badge';
                badge.style.background = ((AGENTS[aid] || {}).color || '#a855f7') + '22';
                badge.style.color = (AGENTS[aid] || {}).color || '#a855f7';
                badge.textContent = (AGENTS[aid] || {}).name || aid;
                meta.appendChild(badge);
            });
            if (s.messageCount) {
                var countSpan = document.createElement('span');
                countSpan.textContent = s.messageCount + ' msgs';
                meta.appendChild(countSpan);
            }
            if (s.lastMessageAt || s.startedAt) {
                var timeSpan = document.createElement('span');
                timeSpan.textContent = relativeTime(s.lastMessageAt || s.startedAt);
                meta.appendChild(timeSpan);
            }
            card.appendChild(meta);

            if (s.preview) {
                var preview = document.createElement('div');
                preview.className = 'session-preview';
                preview.textContent = s.preview;
                card.appendChild(preview);
            }

            card.onclick = function() { openSession(s); };
            convListEl.appendChild(card);
        });
    }

    function renderSearchResults(results) {
        convListEl.innerHTML = '';
        if (results.length === 0) {
            convListEl.innerHTML = '<div class="conv-empty">No results found</div>';
            return;
        }
        results.forEach(function(r) {
            var card = document.createElement('div');
            card.className = 'session-card';
            var title = document.createElement('div');
            title.className = 'session-title';
            title.textContent = r.title || r.sessionTitle || 'Result';
            card.appendChild(title);

            if (r.snippet) {
                var preview = document.createElement('div');
                preview.className = 'session-preview';
                preview.innerHTML = r.snippet;
                card.appendChild(preview);
            }

            var meta = document.createElement('div');
            meta.className = 'session-meta';
            if (r.agentID) {
                var badge = document.createElement('span');
                badge.className = 'session-badge';
                badge.style.background = ((AGENTS[r.agentID] || {}).color || '#a855f7') + '22';
                badge.style.color = (AGENTS[r.agentID] || {}).color || '#a855f7';
                badge.textContent = (AGENTS[r.agentID] || {}).name || r.agentID;
                meta.appendChild(badge);
            }
            if (r.timestamp) {
                var timeSpan = document.createElement('span');
                timeSpan.textContent = new Date(r.timestamp).toLocaleDateString();
                meta.appendChild(timeSpan);
            }
            card.appendChild(meta);

            card.onclick = function() {
                if (r.sessionID || r.id) openSession({ id: r.sessionID || r.id, title: r.title || 'Search result' });
            };
            convListEl.appendChild(card);
        });
    }

    async function openSession(session) {
        var room = state.rooms.find(function(r) { return r.id === session.id; });
        if (!room) {
            room = {
                id: session.id || genLocalID(),
                title: session.title || 'Conversation',
                agent: session.agentID || session.agent || 'sid',
                agents: [session.agentID || session.agent || 'sid'],
                model: session.model || null,
                createdAt: session.startedAt ? new Date(session.startedAt).getTime() : Date.now(),
                lastMessageAt: Date.now()
            };
            state.rooms.unshift(room);
            persistRooms();
        }
        await switchRoom(room.id);
    }

    // ─── Connection Health ───
    var healthTimer = null;
    var wasDisconnected = false;

    async function checkHealth() {
        try {
            var res = await fetch(BASE + '/health', {
                signal: AbortSignal.timeout(5000),
                headers: TOKEN ? authHeaders() : {}
            });
            if (res.ok) {
                if (wasDisconnected) {
                    wasDisconnected = false;
                    state.connected = true;
                    connDot.className = 'conn-dot';
                    connDot.title = 'Connected';
                    connDotMobile.className = 'conn-dot conn-dot-mobile';
                    connDotMobile.title = 'Connected';
                    reconnectBanner.classList.remove('visible');
                }
            } else { markDisconnected(); }
        } catch(e) { markDisconnected(); }
    }

    function markDisconnected() {
        if (!wasDisconnected) {
            wasDisconnected = true;
            state.connected = false;
            connDot.className = 'conn-dot disconnected';
            connDot.title = 'Disconnected';
            connDotMobile.className = 'conn-dot conn-dot-mobile disconnected';
            connDotMobile.title = 'Disconnected';
            reconnectBanner.classList.add('visible');
        }
    }

    function startHealthCheck() {
        checkHealth();
        healthTimer = setInterval(checkHealth, 8000);
    }

    // ─── Load Agents ───
    async function loadAgents() {
        if (!TOKEN) { renderAgentPills([]); return; }
        try {
            var res = await fetch(BASE + '/v1/agents', { headers: authHeaders() });
            if (res.ok) {
                var data = await res.json();
                var agents = data.agents || [];
                agents.forEach(function(a) {
                    if (!AGENTS[a.id]) {
                        AGENTS[a.id] = { name: a.name || a.id, color: '#a855f7' };
                    } else {
                        AGENTS[a.id].name = a.name || AGENTS[a.id].name;
                    }
                });
                renderAgentPills(agents);
            } else { renderAgentPills([]); }
        } catch(e) { renderAgentPills([]); }
    }

    // ─── Toast ───
    var toastTimer = null;
    function showToast(message) {
        toastEl.textContent = message;
        toastEl.classList.add('visible');
        clearTimeout(toastTimer);
        toastTimer = setTimeout(function() { toastEl.classList.remove('visible'); }, 2500);
    }

    // ─── Share Room ───
    function shareRoom() {
        if (!state.activeRoomID) return;
        var url = location.origin + '/chat?room=' + encodeURIComponent(state.activeRoomID);
        navigator.clipboard.writeText(url).then(function() {
            showToast('Link copied!');
        }).catch(function() {
            showToast('Could not copy link');
        });
    }

    // ─── Name Prompt ───
    function ensureDisplayName() {
        return new Promise(function(resolve) {
            var stored = localStorage.getItem('torbo_wc_displayName');
            if (stored) {
                state.displayName = stored;
                resolve(stored);
                return;
            }
            nameModalOverlay.classList.add('visible');
            nameInputEl.focus();
            var onSubmit = function() {
                var name = nameInputEl.value.trim();
                if (!name) return;
                state.displayName = name;
                localStorage.setItem('torbo_wc_displayName', name);
                nameModalOverlay.classList.remove('visible');
                showToast('Joined as ' + name);
                resolve(name);
            };
            nameModalBtn.onclick = onSubmit;
            nameInputEl.onkeydown = function(e) {
                if (e.key === 'Enter') { e.preventDefault(); onSubmit(); }
            };
        });
    }

    // ─── Message Polling (for multi-user rooms) ───
    function startPolling() {
        stopPolling();
        state.pollTimer = setInterval(pollMessages, 2000);
    }

    function stopPolling() {
        if (state.pollTimer) { clearInterval(state.pollTimer); state.pollTimer = null; }
    }

    async function pollMessages() {
        if (!state.activeRoomID) return;
        try {
            var url = BASE + '/v1/room/messages?room=' + encodeURIComponent(state.activeRoomID) + '&since=' + state.lastPollTS;
            var res = await fetch(url, { headers: authHeaders() });
            if (!res.ok) return;
            var data = await res.json();
            var messages = data.messages || [];
            if (messages.length === 0) return;

            var added = false;
            messages.forEach(function(m) {
                // Build a dedup key matching what we track locally
                var key;
                if (m.role === 'user') {
                    key = 'u:' + (m.content || '').slice(0, 80);
                } else {
                    key = 'a:' + (m.agentID || '') + ':' + (m.content || '').slice(0, 80);
                }

                // Skip if this message was generated locally
                if (state.localMsgKeys[key]) return;

                var msg = {
                    role: m.role,
                    content: m.content || '',
                    agent: m.agentID || (m.role === 'assistant' ? primaryAgent() : null),
                    sender: m.sender || null,
                    time: m.timestamp ? new Date(m.timestamp).toLocaleTimeString([], {hour:'2-digit', minute:'2-digit'}) : '',
                    images: null
                };

                if (!state.roomMessages[state.activeRoomID]) state.roomMessages[state.activeRoomID] = [];
                state.roomMessages[state.activeRoomID].push(msg);
                appendMessageDOM(msg);
                added = true;

                // Update poll timestamp
                if (m.timestamp) {
                    var ts = typeof m.timestamp === 'number' ? m.timestamp : new Date(m.timestamp).getTime();
                    if (ts > state.lastPollTS) state.lastPollTS = ts;
                }
            });

            if (added) scrollToBottom();

            // Clean up old local msg keys (older than 60s)
            var now = Date.now();
            Object.keys(state.localMsgKeys).forEach(function(k) {
                if (now - state.localMsgKeys[k] > 60000) delete state.localMsgKeys[k];
            });
        } catch(e) {}
    }

    // ─── URL Parameter Handling ───
    async function handleRoomParam() {
        var params = new URLSearchParams(location.search);
        var roomParam = params.get('room');
        if (!roomParam) return false;

        await ensureDisplayName();

        // Check if room exists on server
        try {
            var res = await fetch(BASE + '/v1/room/exists?room=' + encodeURIComponent(roomParam), {
                headers: authHeaders()
            });
            if (res.ok) {
                var data = await res.json();
                if (!data.exists) {
                    showToast('Room not found');
                    return false;
                }
            }
        } catch(e) {
            // Server might not support exists endpoint — proceed anyway
        }

        // Add room to local list if not already there
        var existing = state.rooms.find(function(r) { return r.id === roomParam; });
        if (!existing) {
            var room = {
                id: roomParam, title: 'Shared Room',
                agent: primaryAgent(), agents: state.activeAgents.slice(),
                model: null, createdAt: Date.now(), lastMessageAt: Date.now()
            };
            state.rooms.unshift(room);
            persistRooms();
        }

        await switchRoom(roomParam);
        showToast('Joined room');
        return true;
    }

    // ─── Event Handlers ───
    inputEl.addEventListener('keydown', function(e) {
        if (e.key === 'Enter' && !e.shiftKey) {
            e.preventDefault();
            sendMessage();
        }
    });
    inputEl.addEventListener('input', function() {
        inputEl.style.height = 'auto';
        inputEl.style.height = Math.min(inputEl.scrollHeight, 120) + 'px';
    });

    document.getElementById('hamburger').onclick = function() {
        state.sidebarOpen ? closeSidebar() : openSidebar();
    };
    document.getElementById('sidebarClose').onclick = closeSidebar;
    sidebarOverlay.onclick = closeSidebar;
    document.getElementById('newChatBtn').onclick = createRoom;

    navChat.onclick = function() { switchView('chat'); };
    navHistory.onclick = function() { switchView('conversations'); };

    shareBtn.onclick = shareRoom;
    document.addEventListener('click', function(e) {
        if (pillDropdownEl && !e.target.closest('.pill-dropdown') && !e.target.closest('.pill-label-area')) {
            closePillDropdown();
        }
    });

    // Attach button
    attachBtn.onclick = function() { fileInput.click(); };
    fileInput.onchange = function(e) {
        handleFiles(e.target.files);
        fileInput.value = '';
    };

    // Attachment remove (event delegation)
    attachPreview.addEventListener('click', function(e) {
        var btn = e.target.closest('.attach-remove');
        if (!btn) return;
        var idx = parseInt(btn.dataset.idx);
        state.pendingFiles.splice(idx, 1);
        renderAttachmentPreview();
    });

    // Drag and drop
    var dragCounter = 0;
    ['dragenter','dragover','dragleave','drop'].forEach(function(evt) {
        document.body.addEventListener(evt, function(e) { e.preventDefault(); e.stopPropagation(); });
    });
    document.body.addEventListener('dragenter', function() {
        dragCounter++;
        dropZone.classList.add('visible');
    });
    document.body.addEventListener('dragleave', function() {
        dragCounter--;
        if (dragCounter <= 0) { dragCounter = 0; dropZone.classList.remove('visible'); }
    });
    document.body.addEventListener('drop', function(e) {
        dragCounter = 0;
        dropZone.classList.remove('visible');
        if (e.dataTransfer && e.dataTransfer.files && e.dataTransfer.files.length > 0) {
            handleFiles(e.dataTransfer.files);
        }
    });

    // Code block buttons (event delegation)
    chatScroll.addEventListener('click', function(e) {
        var btn = e.target.closest('.code-btn');
        if (!btn) return;
        var id = btn.dataset.cb;
        var block = codeBlocks[id];
        if (!block) return;
        if (btn.dataset.action === 'copy') {
            navigator.clipboard.writeText(block.code).then(function() {
                btn.textContent = 'Copied!';
                setTimeout(function() { btn.textContent = 'Copy'; }, 2000);
            });
        } else if (btn.dataset.action === 'canvas') {
            openCanvas(block.code, block.lang);
        }
    });

    // Canvas controls
    canvasToggleBtn.onclick = function() {
        if (state.canvas.open) closeCanvas();
        else openCanvas('', '');
    };
    document.getElementById('canvasClose').onclick = closeCanvas;
    document.getElementById('canvasCopy').onclick = function() {
        navigator.clipboard.writeText(canvasEditorEl.value).then(function() {
            var btn = document.getElementById('canvasCopy');
            btn.textContent = 'Copied!';
            setTimeout(function() { btn.textContent = 'Copy'; }, 2000);
        });
    };
    document.getElementById('canvasDownload').onclick = function() {
        var blob = new Blob([canvasEditorEl.value], { type: 'text/plain' });
        var url = URL.createObjectURL(blob);
        var a = document.createElement('a');
        a.href = url;
        a.download = 'code.' + (state.canvas.language || 'txt');
        document.body.appendChild(a);
        a.click();
        document.body.removeChild(a);
        URL.revokeObjectURL(url);
    };

    // Conversation search
    var convSearchTimer = null;
    convSearchEl.addEventListener('input', function() {
        clearTimeout(convSearchTimer);
        convSearchTimer = setTimeout(function() {
            state.convQuery = convSearchEl.value;
            loadConversations();
        }, 300);
    });

    window.addEventListener('beforeunload', function() {
        Object.values(state.activeControllers).forEach(function(c) { c.abort(); });
    });

    // ─── Init ───
    (async function init() {
        // Load persisted display name
        var storedName = localStorage.getItem('torbo_wc_displayName');
        if (storedName) state.displayName = storedName;

        loadPersistedRooms();
        if (state.rooms.length === 0) migrateOldFormat();

        await Promise.all([loadAgents(), loadModels()]);
        renderConvFilters();

        // Check for ?room= URL parameter (shared room link)
        var joinedViaParam = await handleRoomParam();

        if (!joinedViaParam) {
            if (state.rooms.length === 0) {
                await createRoom();
            } else {
                var lastActive = localStorage.getItem(STORAGE_KEY + 'activeRoom');
                var target = state.rooms.find(function(r) { return r.id === lastActive; }) || state.rooms[0];
                await switchRoom(target.id);
            }
        }

        // Set initial poll timestamp to now (only poll future messages)
        state.lastPollTS = Date.now();
        startPolling();
        startHealthCheck();
        inputEl.focus();
    })();
    </script>
    </body>
    </html>
    """
}
