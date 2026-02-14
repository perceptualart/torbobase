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
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <meta http-equiv="Content-Security-Policy" content="default-src 'self'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'; img-src 'self' data:; font-src 'self'; frame-src 'none'; object-src 'none'; base-uri 'self'; media-src blob: 'self';">
    <title>Torbo Base — Chat</title>
    <link rel="icon" href="data:image/svg+xml,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 100 100'><circle cx='50' cy='50' r='40' fill='%23a855f7'/></svg>">
    <style>
    * { margin: 0; padding: 0; box-sizing: border-box; }
    :root {
        --bg: #0a0a0d; --surface: #111114; --border: rgba(255,255,255,0.06);
        --text: rgba(255,255,255,0.85); --text-dim: rgba(255,255,255,0.4);
        --cyan: #00e5ff; --purple: #a855f7;
        --user-bubble-bg: rgba(0, 229, 255, 0.12); --user-bubble-border: rgba(0, 229, 255, 0.2);
        --code-bg: rgba(0,0,0,0.4); --code-border: rgba(255,255,255,0.06);
        --code-text: #e0e0e0; --inline-code-bg: rgba(0,229,255,0.08);
        --err-color: #ff4444;
    }
    [data-theme="light"] {
        --bg: #f5f5f7; --surface: #ffffff; --border: rgba(0,0,0,0.08);
        --text: rgba(0,0,0,0.85); --text-dim: rgba(0,0,0,0.45);
        --cyan: #0097a7; --purple: #7c3aed;
        --user-bubble-bg: rgba(0, 151, 167, 0.08); --user-bubble-border: rgba(0, 151, 167, 0.2);
        --code-bg: rgba(0,0,0,0.04); --code-border: rgba(0,0,0,0.08);
        --code-text: #333; --inline-code-bg: rgba(0,151,167,0.08);
        --err-color: #d32f2f;
    }
    body {
        font-family: 'Futura', 'Futura-Medium', -apple-system, BlinkMacSystemFont, sans-serif;
        background: var(--bg); color: var(--text);
        height: 100vh; display: flex; flex-direction: column;
    }
    .header {
        padding: 16px 24px; border-bottom: 1px solid var(--border);
        display: flex; align-items: center; gap: 14px;
        background: var(--surface); flex-wrap: wrap;
    }
    .torbo-icon { width: 80px; height: 80px; }
    .torbo-icon canvas { width: 100%; height: 100%; }
    .header h1 {
        font-size: 17px; font-weight: 700; letter-spacing: 2.5px;
        font-family: 'Futura', 'Futura-Medium', sans-serif;
    }
    .header .agent-name {
        font-size: 13px; color: var(--cyan); font-weight: 600;
        font-family: 'Futura', 'Futura-Medium', sans-serif;
    }
    .header .status {
        font-size: 12px; color: var(--text-dim);
        margin-left: auto; font-family: 'Futura', 'Futura-Medium', sans-serif;
    }
    .header .settings-btn {
        background: none; border: none; color: var(--text-dim);
        cursor: pointer; font-size: 22px; padding: 6px 10px;
        border-radius: 6px; transition: all 0.2s;
    }
    .header .settings-btn:hover { color: var(--text); background: rgba(255,255,255,0.06); }
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
        background: var(--user-bubble-bg);
        border: 1px solid var(--user-bubble-border);
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
        border-radius: 6px; padding: 7px 8px; color: var(--text-dim);
        font-size: 12px; font-family: 'Futura', 'Futura-Medium', sans-serif; outline: none;
        max-width: 120px; text-overflow: ellipsis;
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
    .greeting-bar {
        padding: 16px 24px; text-align: center;
        color: var(--text-dim); font-size: 13px; line-height: 1.5;
    }
    .greeting-bar.hidden { display: none; }
    .empty {
        flex: 1; display: flex; flex-direction: column;
        align-items: center; justify-content: center; gap: 16px;
        color: var(--text-dim);
    }
    [data-theme="light"] .torbo-icon { background: #0a0a0d; border-radius: 50%; }
    .empty p { font-size: 13px; }
    .empty .greeting { color: var(--text); font-size: 14px; max-width: 500px; text-align: center; line-height: 1.5; }
    /* Markdown rendering */
    .bubble pre {
        background: var(--code-bg); border-radius: 6px;
        padding: 12px; margin: 8px 0; overflow-x: auto;
        border: 1px solid var(--code-border);
    }
    .bubble pre code {
        font-family: 'SF Mono', 'Menlo', 'Consolas', monospace;
        font-size: 12px; color: var(--code-text); background: none; padding: 0;
    }
    .bubble code {
        font-family: 'SF Mono', 'Menlo', monospace; font-size: 12px;
        background: var(--inline-code-bg); padding: 2px 5px;
        border-radius: 3px; color: var(--cyan);
    }
    .bubble strong { color: var(--text); }
    .bubble em { color: rgba(255,255,255,0.7); }
    .bubble ul, .bubble ol { margin: 6px 0 6px 20px; }
    .bubble li { margin: 2px 0; }
    .bubble h1,.bubble h2,.bubble h3 { color:#fff; margin: 10px 0 4px 0; }
    .bubble h1 { font-size: 16px; }
    .bubble h2 { font-size: 14px; }
    .bubble h3 { font-size: 13px; }
    .bubble a { color: var(--cyan); text-decoration: none; }
    .bubble a:hover { text-decoration: underline; }
    .bubble .cursor { animation: blink 1s step-end infinite; color: var(--cyan); }
    @keyframes blink { 50% { opacity: 0; } }
    /* Syntax highlighting */
    .token-keyword { color: #c678dd; }
    .token-string { color: #98c379; }
    .token-comment { color: #5c6370; font-style: italic; }
    .token-number { color: #d19a66; }
    .token-function { color: #61afef; }
    /* Settings Modal */
    .modal-overlay {
        display: none; position: fixed; inset: 0;
        background: rgba(0,0,0,0.7); z-index: 100;
        align-items: center; justify-content: center;
    }
    .modal-overlay.open { display: flex; }
    .modal {
        background: var(--surface); border: 1px solid var(--border);
        border-radius: 12px; width: 480px; max-height: 80vh;
        overflow-y: auto; padding: 24px;
    }
    .modal h2 {
        font-size: 16px; font-weight: 700; margin-bottom: 16px;
        font-family: 'SF Mono', monospace; letter-spacing: 1px;
    }
    .modal .field { margin-bottom: 16px; }
    .modal label {
        display: block; font-size: 11px; color: var(--text-dim);
        font-family: 'SF Mono', monospace; margin-bottom: 6px;
        text-transform: uppercase; letter-spacing: 1px;
    }
    .modal input, .modal textarea {
        width: 100%; background: rgba(255,255,255,0.04);
        border: 1px solid var(--border); border-radius: 6px;
        padding: 8px 12px; color: var(--text); font-size: 13px;
        font-family: inherit; outline: none; transition: border-color 0.2s;
    }
    .modal input:focus, .modal textarea:focus { border-color: rgba(0,229,255,0.3); }
    .modal textarea { min-height: 60px; resize: vertical; }
    .modal .section-title {
        font-size: 12px; font-weight: 700; color: var(--cyan);
        margin: 20px 0 10px 0; text-transform: uppercase;
        letter-spacing: 1px; font-family: 'SF Mono', monospace;
    }
    .modal .btn-row { display: flex; gap: 8px; margin-top: 20px; justify-content: flex-end; }
    .modal .btn {
        padding: 8px 16px; border-radius: 6px; font-size: 12px;
        font-weight: 600; cursor: pointer; border: none; transition: opacity 0.2s;
    }
    .modal .btn-primary { background: var(--cyan); color: #000; }
    .modal .btn-secondary { background: rgba(255,255,255,0.06); color: var(--text-dim); }
    .modal .btn:hover { opacity: 0.85; }
    .skill-item {
        display: flex; align-items: center; gap: 10px;
        padding: 8px 0; border-bottom: 1px solid var(--border);
    }
    .skill-item:last-child { border-bottom: none; }
    .skill-item .skill-info { flex: 1; }
    .skill-item .skill-name { font-size: 13px; font-weight: 600; }
    .skill-item .skill-desc { font-size: 11px; color: var(--text-dim); }
    .toggle {
        width: 36px; height: 20px; border-radius: 10px;
        background: rgba(255,255,255,0.1); cursor: pointer;
        position: relative; transition: background 0.2s; border: none;
    }
    .toggle.on { background: var(--cyan); }
    .toggle::after {
        content: ''; position: absolute; width: 16px; height: 16px;
        border-radius: 50%; background: #fff; top: 2px; left: 2px;
        transition: transform 0.2s;
    }
    .toggle.on::after { transform: translateX(16px); }
    /* Room Mode */
    .room-btn {
        background: rgba(255,255,255,0.04); border: 1px solid var(--border);
        border-radius: 6px; padding: 7px 14px; color: var(--text-dim);
        font-size: 13px; font-family: 'Futura', 'Futura-Medium', sans-serif; cursor: pointer;
        transition: all 0.2s;
    }
    .room-btn:hover { color: var(--text); border-color: rgba(255,255,255,0.15); }
    .room-btn.active { background: rgba(168,85,247,0.15); border-color: var(--purple); color: var(--purple); }
    .room-agents {
        display: none; padding: 8px 24px; background: var(--surface);
        border-bottom: 1px solid var(--border); gap: 8px; flex-wrap: wrap; align-items: center;
    }
    .room-agents.open { display: flex; }
    .room-agents .label { font-size: 10px; color: var(--text-dim); font-family: 'SF Mono', monospace; text-transform: uppercase; letter-spacing: 1px; }
    .agent-chip {
        font-size: 11px; padding: 4px 10px; border-radius: 12px;
        border: 1px solid var(--border); background: rgba(255,255,255,0.04);
        color: var(--text-dim); cursor: pointer; transition: all 0.2s;
        font-family: 'SF Mono', monospace;
    }
    .agent-chip:hover { border-color: rgba(255,255,255,0.2); color: var(--text); }
    .agent-chip.selected { background: rgba(168,85,247,0.15); border-color: var(--purple); color: var(--purple); }
    .message .agent-label {
        font-size: 10px; font-weight: 700; color: var(--purple);
        font-family: 'SF Mono', monospace; letter-spacing: 0.5px;
    }
    /* Attachments */
    .attach-btn {
        background: none; border: none; color: var(--text-dim);
        cursor: pointer; font-size: 20px; padding: 6px 4px;
        transition: color 0.2s; line-height: 1;
    }
    .attach-btn:hover { color: var(--text); }
    .attachments-preview {
        display: none; padding: 8px 24px 0; gap: 8px; flex-wrap: wrap;
        background: var(--surface);
    }
    .attachments-preview.has-files { display: flex; }
    .attach-item {
        display: flex; align-items: center; gap: 6px; padding: 4px 10px;
        background: rgba(255,255,255,0.04); border: 1px solid var(--border);
        border-radius: 8px; font-size: 11px; color: var(--text-dim);
        font-family: 'SF Mono', monospace;
    }
    .attach-item img {
        width: 32px; height: 32px; object-fit: cover; border-radius: 4px;
    }
    .attach-item .remove {
        cursor: pointer; color: var(--text-dim); font-size: 14px;
        margin-left: 4px; transition: color 0.2s;
    }
    .attach-item .remove:hover { color: #ff4444; }
    .drop-overlay {
        display: none; position: fixed; inset: 0; z-index: 200;
        background: rgba(0,229,255,0.06); border: 3px dashed var(--cyan);
        align-items: center; justify-content: center;
        pointer-events: none;
    }
    .drop-overlay.active { display: flex; }
    .drop-overlay p {
        font-size: 18px; color: var(--cyan); font-weight: 700;
        font-family: 'SF Mono', monospace;
    }
    /* Header action buttons */
    .header-actions { display: flex; gap: 6px; align-items: center; }
    .header-action {
        background: none; border: none; color: var(--text-dim);
        cursor: pointer; font-size: 20px; padding: 6px 10px;
        border-radius: 6px; transition: all 0.2s;
    }
    .header-action:hover { color: var(--text); background: rgba(128,128,128,0.12); }
    .header-action.active { color: var(--cyan); }
    /* Token bar */
    .token-bar {
        display: none; padding: 8px 24px; background: var(--surface);
        border-bottom: 1px solid var(--border); gap: 10px; align-items: center;
        font-family: 'SF Mono', monospace; font-size: 11px;
    }
    .token-bar.open { display: flex; }
    .token-bar .label { color: var(--text-dim); text-transform: uppercase; letter-spacing: 1px; font-size: 10px; }
    .token-bar .token-value {
        flex: 1; color: var(--text); background: rgba(128,128,128,0.08);
        padding: 4px 10px; border-radius: 4px; border: 1px solid var(--border);
        overflow: hidden; text-overflow: ellipsis; white-space: nowrap;
        user-select: all; -webkit-user-select: all;
    }
    .token-bar .token-url {
        flex: 2; color: var(--cyan); background: rgba(128,128,128,0.08);
        padding: 4px 10px; border-radius: 4px; border: 1px solid var(--border);
        overflow: hidden; text-overflow: ellipsis; white-space: nowrap;
        user-select: all; -webkit-user-select: all;
    }
    .token-bar .copy-btn {
        background: rgba(128,128,128,0.08); border: 1px solid var(--border);
        color: var(--text-dim); padding: 4px 10px; border-radius: 4px;
        font-size: 11px; cursor: pointer; font-family: 'SF Mono', monospace;
        transition: all 0.2s;
    }
    .token-bar .copy-btn:hover { color: var(--text); border-color: var(--cyan); }
    /* Invite bar */
    .invite-bar {
        display: none; padding: 10px 24px; background: var(--surface);
        border-bottom: 1px solid var(--border); gap: 10px; align-items: center;
        font-family: 'SF Mono', monospace; font-size: 11px;
    }
    .invite-bar.open { display: flex; flex-wrap: wrap; }
    .invite-bar .label { color: var(--text-dim); text-transform: uppercase; letter-spacing: 1px; font-size: 10px; }
    .invite-bar .invite-url {
        flex: 2; color: var(--cyan); background: rgba(128,128,128,0.08);
        padding: 4px 10px; border-radius: 4px; border: 1px solid var(--border);
        overflow: hidden; text-overflow: ellipsis; white-space: nowrap;
        user-select: all; -webkit-user-select: all;
    }
    .invite-bar .copy-btn {
        background: rgba(128,128,128,0.08); border: 1px solid var(--border);
        color: var(--text-dim); padding: 4px 10px; border-radius: 4px;
        font-size: 11px; cursor: pointer; font-family: 'SF Mono', monospace;
        transition: all 0.2s;
    }
    .invite-bar .copy-btn:hover { color: var(--text); border-color: var(--cyan); }
    .invite-bar .participants {
        width: 100%; display: flex; gap: 8px; margin-top: 6px; flex-wrap: wrap;
        align-items: center;
    }
    .invite-bar .participants .participants-label {
        font-size: 10px; color: var(--text-dim); text-transform: uppercase;
        letter-spacing: 1px; margin-right: 4px;
    }
    .participant-chip {
        display: inline-flex; align-items: center; gap: 6px;
        padding: 6px 16px; border-radius: 20px; font-size: 13px; font-weight: 700;
        background: rgba(0,229,255,0.06); border: 1px solid rgba(0,229,255,0.25);
        color: var(--cyan); font-family: 'SF Mono', monospace;
        transition: all 0.4s ease; letter-spacing: 0.5px;
    }
    .participant-chip .dot {
        width: 8px; height: 8px; border-radius: 50%; background: #00e676;
        box-shadow: 0 0 4px #00e676;
    }
    .participant-chip.self { border-color: var(--purple); color: var(--purple); background: rgba(168,85,247,0.06); }
    .participant-chip.speaking {
        background: rgba(0,229,255,0.15); border-color: var(--cyan);
        box-shadow: 0 0 16px rgba(0,229,255,0.3), 0 0 40px rgba(0,229,255,0.1);
        transform: scale(1.08);
    }
    .participant-chip.speaking .dot { background: var(--cyan); box-shadow: 0 0 8px var(--cyan); }
    .participant-chip.self.speaking {
        background: rgba(168,85,247,0.15); border-color: var(--purple);
        box-shadow: 0 0 16px rgba(168,85,247,0.3), 0 0 40px rgba(168,85,247,0.1);
    }
    .participant-chip.self.speaking .dot { background: var(--purple); box-shadow: 0 0 8px var(--purple); }
    /* Room title — cinematic participant banner */
    .room-title {
        display: none; text-align: center; padding: 18px 24px 6px;
        background: transparent;
    }
    .room-title.visible { display: block; }
    .room-title .room-names {
        display: flex; justify-content: center; align-items: center;
        gap: 28px; flex-wrap: wrap;
    }
    .room-title .room-name {
        font-size: 24px; font-weight: 600; letter-spacing: 2px;
        text-transform: uppercase; font-family: 'Futura', 'Futura-Medium', sans-serif;
        color: rgba(255,255,255,0.35);
        transition: all 0.5s cubic-bezier(0.16, 1, 0.3, 1);
        text-shadow: none;
        position: relative;
    }
    .room-title .room-name.speaking-name {
        color: rgba(255,255,255,0.95);
        text-shadow: 0 0 15px rgba(255,255,255,0.5), 0 0 40px rgba(255,255,255,0.2), 0 0 80px rgba(255,255,255,0.08);
        transform: scale(1.04);
    }
    .room-title .room-divider {
        color: rgba(255,255,255,0.08); font-size: 20px; font-weight: 300;
        user-select: none;
    }
    @media (max-width: 768px) {
        .header { padding: 10px 14px; gap: 8px; }
        .torbo-icon { width: 56px; height: 56px; }
        .header h1 { font-size: 14px; letter-spacing: 1.5px; }
        .header .agent-name { font-size: 11px; }
        .header .status { font-size: 10px; }
        .model-select { max-width: 90px; font-size: 10px; padding: 5px 6px; }
        .room-btn { font-size: 11px; padding: 5px 10px; }
        .header-action { font-size: 18px; padding: 4px 6px; }
        .room-title .room-name { font-size: 20px; letter-spacing: 1.5px; }
        .room-title .room-names { gap: 18px; }
    }
    @media (max-width: 480px) {
        .header { padding: 8px 10px; gap: 6px; }
        .torbo-icon { width: 44px; height: 44px; }
        .header h1 { font-size: 12px; }
        .model-select { max-width: 72px; font-size: 9px; }
        .room-title .room-name { font-size: 16px; letter-spacing: 1px; }
        .room-title .room-names { gap: 12px; }
        .header-actions { gap: 2px; }
        .header-action { font-size: 16px; padding: 3px 5px; }
    }
    /* Nickname modal */
    .nick-overlay {
        display: none; position: fixed; inset: 0; z-index: 200;
        background: rgba(0,0,0,0.7); backdrop-filter: blur(8px);
        justify-content: center; align-items: center;
    }
    .nick-overlay.open { display: flex; }
    .nick-modal {
        background: var(--surface); border: 1px solid var(--border);
        border-radius: 16px; padding: 28px; width: 320px;
        text-align: center;
    }
    .nick-modal h3 {
        font-size: 16px; margin-bottom: 14px; font-weight: 700;
    }
    .nick-modal input {
        width: 100%; padding: 10px 14px; border-radius: 8px;
        background: rgba(128,128,128,0.08); border: 1px solid var(--border);
        color: var(--text); font-size: 14px; font-family: inherit;
        outline: none; text-align: center; margin-bottom: 14px;
    }
    .nick-modal input:focus { border-color: var(--cyan); }
    .nick-modal .btn {
        padding: 8px 24px; border-radius: 8px; border: none;
        background: var(--cyan); color: #000; font-weight: 700;
        cursor: pointer; font-size: 13px;
    }
    /* Guest messages */
    .message.guest { align-self: flex-start; }
    .message.guest .bubble {
        background: rgba(168,85,247,0.08);
        border: 1px solid rgba(168,85,247,0.2);
        border-radius: 12px 12px 12px 2px;
    }
    .message .sender-name {
        font-size: 10px; font-weight: 700; color: var(--purple);
        font-family: 'SF Mono', monospace; margin-bottom: 2px;
    }
    /* Audio controls */
    .mic-btn, .speaker-btn {
        background: none; border: none; color: var(--text-dim);
        cursor: pointer; font-size: 24px; padding: 8px 6px;
        transition: all 0.2s; line-height: 1;
    }
    .mic-btn:hover, .speaker-btn:hover { color: var(--text); }
    .mic-btn.recording { color: #ff4444; animation: pulse-red 1.5s ease infinite; }
    .speaker-btn.active { color: var(--cyan); }
    @keyframes pulse-red {
        0%, 100% { transform: scale(1); }
        50% { transform: scale(1.15); }
    }
    /* Modal select */
    .modal select {
        width: 100%; background: rgba(255,255,255,0.04);
        border: 1px solid var(--border); border-radius: 6px;
        padding: 8px 12px; color: var(--text); font-size: 13px;
        font-family: inherit; outline: none; transition: border-color 0.2s;
        -webkit-appearance: none; appearance: none;
    }
    .modal select:focus { border-color: rgba(0,229,255,0.3); }
    .modal select option { background: var(--surface); color: var(--text); }
    .modal .hint {
        font-size: 10px; color: var(--text-dim); margin-top: 4px;
        font-family: 'SF Mono', monospace;
    }
    .modal .field-row {
        display: flex; gap: 12px;
    }
    .modal .field-row .field { flex: 1; }
    .modal .section-divider {
        border: none; border-top: 1px solid var(--border); margin: 16px 0;
    }
    </style>
    </head>
    <body>
    <div class="header">
        <div class="torbo-icon"><canvas id="orbSmall" width="144" height="144"></canvas></div>
        <h1>TORBO BASE</h1>
        <select class="model-select" id="agentSelect" onchange="switchAgent()">
            <option value="sid">SiD</option>
        </select>
        <span class="agent-name" id="agentName">SiD</span>
        <select class="model-select" id="model" onchange="agentModelMap[currentAgentID] = this.value">
            <option value="qwen2.5:7b">Loading models...</option>
        </select>
        <span class="status" id="status">Connecting...</span>
        <button class="room-btn" id="roomBtn" onclick="toggleRoom()" title="Room — talk to multiple agents">&#x1f465; Room</button>
        <div class="header-actions">
            <button class="header-action" id="inviteBtn" onclick="toggleInvite()" title="Invite others to chat">&#x1f465;</button>
            <button class="header-action" onclick="clearChat()" title="Clear chat">&#x1f5d1;</button>
            <button class="header-action" id="themeBtn" onclick="toggleTheme()" title="Toggle light/dark">&#x2600;</button>
            <button class="header-action" id="tokenBtn" onclick="toggleTokenBar()" title="Show token / share link">&#x1f517;</button>
            <button class="header-action" onclick="openSettings()" title="Settings">&#9881;</button>
        </div>
    </div>
    <div class="token-bar" id="tokenBar">
        <span class="label">Link</span>
        <span class="token-url" id="shareUrl"></span>
        <button class="copy-btn" onclick="copyShareLink()">Copy Link</button>
    </div>
    <div class="invite-bar" id="inviteBar">
        <span class="label">Invite Link</span>
        <span class="invite-url" id="inviteUrl"></span>
        <button class="copy-btn" onclick="copyInviteLink()">Copy</button>
        <div class="participants" id="participants"></div>
    </div>
    <div class="room-agents" id="roomBar">
        <span class="label">Room agents:</span>
        <div id="roomChips"></div>
    </div>
    <div class="room-title" id="roomTitle">
        <div class="room-names" id="roomNames"></div>
    </div>
    <div class="greeting-bar" id="greetingBar">
        <p id="greeting">Loading...</p>
    </div>
    <div class="messages" id="messages">
    </div>
    <div class="attachments-preview" id="attachPreview"></div>
    <div class="input-area">
        <button class="attach-btn" onclick="document.getElementById('fileInput').click()" title="Attach files">&#x1f4ce;</button>
        <input type="file" id="fileInput" multiple style="display:none" onchange="handleFileSelect(event)">
        <button class="mic-btn" id="micBtn" onclick="toggleMic()" title="Voice input">&#x1f3a4;</button>
        <textarea id="input" rows="1" placeholder="Type a message..." autofocus></textarea>
        <button class="speaker-btn" id="speakerBtn" onclick="toggleSpeaker()" title="Toggle voice output">&#x1f508;</button>
        <button id="send" onclick="sendMessage()">Send</button>
    </div>
    <div class="drop-overlay" id="dropOverlay"><p>Drop files here</p></div>

    <!-- Settings Modal -->
    <div class="modal-overlay" id="settingsModal">
        <div class="modal">
            <h2>Agent Settings</h2>

            <div class="section-title">Identity</div>
            <div class="field-row">
                <div class="field">
                    <label>Name</label>
                    <input type="text" id="cfgName" placeholder="SiD">
                </div>
                <div class="field">
                    <label>Pronouns</label>
                    <select id="cfgPronouns">
                        <option value="she/her">she/her</option>
                        <option value="he/him">he/him</option>
                        <option value="they/them">they/them</option>
                        <option value="it/its">it/its</option>
                    </select>
                </div>
            </div>
            <div class="field">
                <label>Role</label>
                <input type="text" id="cfgRole" placeholder="AI assistant, code expert, creative writer...">
            </div>

            <hr class="section-divider">
            <div class="section-title">Personality</div>
            <div class="field">
                <label>Voice & Tone</label>
                <textarea id="cfgVoiceTone" rows="3" placeholder="Direct, sharp, confident..."></textarea>
            </div>
            <div class="field">
                <label>Core Values</label>
                <textarea id="cfgCoreValues" rows="2" placeholder="Intellectual honesty, privacy-first..."></textarea>
            </div>
            <div class="field">
                <label>Custom Instructions</label>
                <textarea id="cfgInstructions" rows="3" placeholder="Always respond in Spanish, keep responses short..."></textarea>
            </div>
            <div class="field">
                <label>Background Knowledge</label>
                <textarea id="cfgBackground" rows="2" placeholder="Context the agent should always know..."></textarea>
                <div class="hint">Persistent context injected into every conversation</div>
            </div>
            <div class="field">
                <label>Topics to Avoid</label>
                <input type="text" id="cfgTopicsToAvoid" placeholder="politics, religion...">
            </div>

            <hr class="section-divider">
            <div class="section-title">Voice</div>
            <div class="field-row">
                <div class="field">
                    <label>ElevenLabs Voice ID</label>
                    <input type="text" id="cfgElevenLabsVoiceID" placeholder="Leave empty for default">
                    <div class="hint">Get IDs from elevenlabs.io/voices</div>
                </div>
                <div class="field">
                    <label>Fallback Voice</label>
                    <select id="cfgFallbackVoice">
                        <option value="alloy">Alloy</option>
                        <option value="echo">Echo</option>
                        <option value="fable">Fable</option>
                        <option value="onyx">Onyx</option>
                        <option value="nova">Nova</option>
                        <option value="shimmer">Shimmer</option>
                    </select>
                    <div class="hint">OpenAI voice when ElevenLabs unavailable</div>
                </div>
            </div>

            <hr class="section-divider">
            <div class="section-title">Skills</div>
            <div id="skillsList"></div>

            <div class="btn-row">
                <button class="btn btn-secondary" onclick="closeSettings()">Cancel</button>
                <button class="btn btn-primary" onclick="saveSettings()">Save</button>
            </div>
        </div>
    </div>

    <!-- Nickname Modal -->
    <div class="nick-overlay" id="nickOverlay">
        <div class="nick-modal">
            <h3>Enter your name</h3>
            <input type="text" id="nickInput" placeholder="Your name..." maxlength="30" autocomplete="off">
            <br>
            <button class="btn" onclick="confirmNickname()">Join Chat</button>
        </div>
    </div>

    <script>
    const TOKEN = new URLSearchParams(window.location.search).get('token') || '';
    const BASE = window.location.origin;
    const messagesEl = document.getElementById('messages');
    const inputEl = document.getElementById('input');
    const modelEl = document.getElementById('model');
    const statusEl = document.getElementById('status');
    const sendBtn = document.getElementById('send');
    const agentNameEl = document.getElementById('agentName');
    const greetingEl = document.getElementById('greeting');
    const agentSelectEl = document.getElementById('agentSelect');
    let conversationHistory = [];
    let agentConfig = null;
    let skillsData = [];
    let currentAgentID = 'sid';
    let agentsList = [];
    let roomMode = false;
    let roomAgentIDs = new Set();
    let pendingAttachments = []; // { name, type, dataUrl, base64 }
    // Per-agent conversation histories for room mode
    let roomConversations = {};
    // Per-agent model selection — remembers which model each agent uses
    const agentModelMap = {};
    // localStorage keys
    const STORAGE_PREFIX = 'torbo_';
    const THEME_KEY = STORAGE_PREFIX + 'theme';
    const HISTORY_KEY = STORAGE_PREFIX + 'history_';
    const MESSAGES_KEY = STORAGE_PREFIX + 'messages_';
    const NICK_KEY = STORAGE_PREFIX + 'nickname';
    // Multi-user chat state
    let multiUserRoom = null;   // room ID if in shared chat
    let myNickname = localStorage.getItem(NICK_KEY) || '';
    let pollTimer = null;
    let lastPollTimestamp = 0;
    let seenMessageIDs = new Set();

    // ─── Theme ───
    function initTheme() {
        const saved = localStorage.getItem(THEME_KEY);
        if (saved === 'light') {
            document.documentElement.setAttribute('data-theme', 'light');
            document.getElementById('themeBtn').innerHTML = '&#x1f319;';
        }
    }
    function toggleTheme() {
        const isLight = document.documentElement.getAttribute('data-theme') === 'light';
        if (isLight) {
            document.documentElement.removeAttribute('data-theme');
            document.getElementById('themeBtn').innerHTML = '&#x2600;';
            localStorage.setItem(THEME_KEY, 'dark');
        } else {
            document.documentElement.setAttribute('data-theme', 'light');
            document.getElementById('themeBtn').innerHTML = '&#x1f319;';
            localStorage.setItem(THEME_KEY, 'light');
        }
    }
    initTheme();

    // ─── Token / Share Link ───
    function toggleTokenBar() {
        const bar = document.getElementById('tokenBar');
        const btn = document.getElementById('tokenBtn');
        bar.classList.toggle('open');
        btn.classList.toggle('active', bar.classList.contains('open'));
        if (bar.classList.contains('open')) {
            const url = window.location.origin + '/chat?token=' + TOKEN;
            document.getElementById('shareUrl').textContent = url;
        }
    }
    function copyShareLink() {
        const url = window.location.origin + '/chat?token=' + TOKEN;
        navigator.clipboard.writeText(url).then(() => {
            const btn = document.querySelector('.token-bar .copy-btn');
            btn.textContent = 'Copied!';
            setTimeout(() => { btn.textContent = 'Copy Link'; }, 1500);
        });
    }

    // ─── Multi-User Invite ───
    function toggleInvite() {
        const bar = document.getElementById('inviteBar');
        const btn = document.getElementById('inviteBtn');
        if (bar.classList.contains('open')) {
            // Close — leave room
            bar.classList.remove('open');
            btn.classList.remove('active');
            leaveRoom();
            return;
        }
        // Need nickname first
        if (!myNickname) {
            showNicknameModal(() => { startInviteRoom(); });
            return;
        }
        startInviteRoom();
    }

    function showNicknameModal(callback) {
        const overlay = document.getElementById('nickOverlay');
        const input = document.getElementById('nickInput');
        overlay.classList.add('open');
        input.value = myNickname || '';
        input.focus();
        input.onkeydown = (e) => {
            if (e.key === 'Enter') { confirmNickname(); }
        };
        window._nickCallback = callback;
    }

    function confirmNickname() {
        const input = document.getElementById('nickInput');
        const name = input.value.trim();
        if (!name) return;
        myNickname = name;
        localStorage.setItem(NICK_KEY, myNickname);
        document.getElementById('nickOverlay').classList.remove('open');
        if (window._nickCallback) { window._nickCallback(); window._nickCallback = null; }
    }

    async function startInviteRoom() {
        // Create a room on the server
        try {
            const res = await fetch(BASE + '/v1/room/create', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json', 'Authorization': 'Bearer ' + TOKEN },
                body: JSON.stringify({ sender: myNickname })
            });
            const data = await res.json();
            multiUserRoom = data.room;
            lastPollTimestamp = Date.now() / 1000;
            seenMessageIDs.clear();
        } catch(e) {
            statusEl.textContent = 'Room create failed';
            return;
        }
        // Show invite bar
        const bar = document.getElementById('inviteBar');
        bar.classList.add('open');
        document.getElementById('inviteBtn').classList.add('active');
        const inviteUrl = window.location.origin + '/chat?token=' + TOKEN + '&room=' + multiUserRoom + '&nick=';
        document.getElementById('inviteUrl').textContent = inviteUrl;
        renderParticipants([myNickname]);
        // Start polling
        startPolling();
    }

    function copyInviteLink() {
        const url = document.getElementById('inviteUrl').textContent;
        navigator.clipboard.writeText(url).then(() => {
            const btn = document.querySelector('.invite-bar .copy-btn');
            btn.textContent = 'Copied!';
            setTimeout(() => { btn.textContent = 'Copy'; }, 1500);
        });
    }

    function leaveRoom() {
        multiUserRoom = null;
        if (pollTimer) { clearInterval(pollTimer); pollTimer = null; }
        seenMessageIDs.clear();
    }

    function startPolling() {
        if (pollTimer) clearInterval(pollTimer);
        pollTimer = setInterval(pollRoomMessages, 1500);
    }

    async function pollRoomMessages() {
        if (!multiUserRoom) return;
        try {
            const res = await fetch(BASE + '/v1/room/messages?room=' + encodeURIComponent(multiUserRoom) + '&since=' + lastPollTimestamp, {
                headers: { 'Authorization': 'Bearer ' + TOKEN }
            });
            const data = await res.json();
            if (!data.messages || data.messages.length === 0) return;
            // Track unique senders for participant list
            const senders = new Set([myNickname]);
            data.messages.forEach(msg => {
                senders.add(msg.sender);
                if (seenMessageIDs.has(msg.id)) return;
                seenMessageIDs.add(msg.id);
                lastPollTimestamp = Math.max(lastPollTimestamp, msg.timestamp);
                // Don't re-render our own messages
                if (msg.sender === myNickname) return;
                // Show the message
                showGuestMessage(msg);
            });
            renderParticipants(Array.from(senders));
        } catch(e) {}
    }

    function showGuestMessage(msg) {
        setOrbCompact(true);
        const div = document.createElement('div');
        div.className = 'message ' + (msg.role === 'assistant' ? 'assistant' : 'guest');
        const time = new Date(msg.timestamp * 1000).toLocaleTimeString([], {hour:'2-digit',minute:'2-digit'});
        const senderLabel = msg.role === 'assistant'
            ? (msg.agentID || 'AI') + ' \\u2190 ' + msg.sender
            : msg.sender;
        div.innerHTML = '<div class="sender-name">' + escapeHtml(senderLabel) + '</div>' +
            '<div class="bubble">' + renderMarkdown(msg.content) + '</div>' +
            '<div class="meta">' + time + '</div>';
        messagesEl.appendChild(div);
        messagesEl.scrollTop = messagesEl.scrollHeight;
        // Light up the speaker
        highlightSpeaker(msg.sender);
    }

    function renderParticipants(names) {
        const container = document.getElementById('participants');
        container.innerHTML = '';
        const label = document.createElement('span');
        label.className = 'participants-label';
        label.textContent = 'IN ROOM';
        container.appendChild(label);
        names.forEach(name => {
            const chip = document.createElement('span');
            chip.className = 'participant-chip' + (name === myNickname ? ' self' : '');
            chip.setAttribute('data-participant', name);
            chip.innerHTML = '<span class="dot"></span>' + escapeHtml(name);
            container.appendChild(chip);
        });
        // Render cinematic room title banner
        const titleEl = document.getElementById('roomTitle');
        const namesEl = document.getElementById('roomNames');
        if (names.length >= 1) {
            titleEl.classList.add('visible');
            namesEl.innerHTML = '';
            names.forEach((name, i) => {
                if (i > 0) {
                    const divider = document.createElement('span');
                    divider.className = 'room-divider';
                    divider.textContent = '\\u00b7';
                    namesEl.appendChild(divider);
                }
                const span = document.createElement('span');
                span.className = 'room-name';
                span.setAttribute('data-participant', name);
                span.textContent = name;
                namesEl.appendChild(span);
            });
        } else {
            titleEl.classList.remove('visible');
        }
    }

    function highlightSpeaker(name) {
        // Light up participant chips (3s)
        const chips = document.querySelectorAll('.participant-chip');
        chips.forEach(chip => {
            if (chip.getAttribute('data-participant') === name) {
                chip.classList.add('speaking');
                setTimeout(() => chip.classList.remove('speaking'), 3000);
            }
        });
        // Light up room title names (3s)
        const titleNames = document.querySelectorAll('.room-name');
        titleNames.forEach(el => {
            if (el.getAttribute('data-participant') === name) {
                el.classList.add('speaking-name');
                setTimeout(() => el.classList.remove('speaking-name'), 3000);
            }
        });
    }

    async function postToRoom(content, role, agentID) {
        if (!multiUserRoom || !myNickname) return;
        try {
            await fetch(BASE + '/v1/room/message', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json', 'Authorization': 'Bearer ' + TOKEN },
                body: JSON.stringify({
                    room: multiUserRoom,
                    sender: myNickname,
                    content: content,
                    role: role,
                    agentID: agentID || null
                })
            });
        } catch(e) {}
    }

    async function joinExistingRoom(roomID) {
        // Need nickname
        if (!myNickname) {
            showNicknameModal(() => { joinExistingRoom(roomID); });
            return;
        }
        // Check room exists
        try {
            const res = await fetch(BASE + '/v1/room/exists?room=' + encodeURIComponent(roomID), {
                headers: { 'Authorization': 'Bearer ' + TOKEN }
            });
            const data = await res.json();
            if (!data.exists) {
                // Room doesn't exist yet — create it (we might be the first one with this link)
                await fetch(BASE + '/v1/room/create', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json', 'Authorization': 'Bearer ' + TOKEN },
                    body: JSON.stringify({ room: roomID, sender: myNickname })
                });
            }
        } catch(e) {}
        multiUserRoom = roomID;
        lastPollTimestamp = 0; // Get full history
        seenMessageIDs.clear();
        // Show invite bar
        const bar = document.getElementById('inviteBar');
        bar.classList.add('open');
        document.getElementById('inviteBtn').classList.add('active');
        const inviteUrl = window.location.origin + '/chat?token=' + TOKEN + '&room=' + multiUserRoom + '&nick=';
        document.getElementById('inviteUrl').textContent = inviteUrl;
        renderParticipants([myNickname]);
        startPolling();
        // Immediately poll to catch up
        await pollRoomMessages();
    }

    // ─── Clear Chat ───
    function clearChat() {
        conversationHistory = [];
        roomConversations = {};
        localStorage.removeItem(HISTORY_KEY + currentAgentID);
        localStorage.removeItem(MESSAGES_KEY + currentAgentID);
        messagesEl.innerHTML = '';
        setOrbFull();
        loadGreeting();
    }

    // ─── Persistence ───
    function saveConversation() {
        try {
            localStorage.setItem(HISTORY_KEY + currentAgentID, JSON.stringify(conversationHistory));
            // Save rendered messages HTML
            const html = messagesEl.innerHTML;
            localStorage.setItem(MESSAGES_KEY + currentAgentID, html);
        } catch(e) {} // quota exceeded — fail silently
    }
    function loadConversation() {
        try {
            const saved = localStorage.getItem(HISTORY_KEY + currentAgentID);
            const savedHtml = localStorage.getItem(MESSAGES_KEY + currentAgentID);
            if (saved && savedHtml) {
                conversationHistory = JSON.parse(saved);
                if (conversationHistory.length > 0) {
                    messagesEl.innerHTML = savedHtml;
                    setOrbCompact(true);
                    messagesEl.scrollTop = messagesEl.scrollHeight;
                    return true;
                }
            }
        } catch(e) {}
        return false;
    }

    // ─── Load Agents List ───
    async function loadAgents() {
        if (!TOKEN) return;
        try {
            const res = await fetch(BASE + '/v1/agents', {
                headers: { 'Authorization': 'Bearer ' + TOKEN }
            });
            if (res.ok) {
                const data = await res.json();
                agentsList = data.agents || [];
                agentSelectEl.innerHTML = '';
                agentsList.forEach(a => {
                    const opt = document.createElement('option');
                    opt.value = a.id;
                    opt.textContent = a.name + (a.isBuiltIn ? ' ★' : '');
                    agentSelectEl.appendChild(opt);
                });
                agentSelectEl.value = currentAgentID;
            }
        } catch(e) {}
    }

    // ─── Switch Agent ───
    async function switchAgent() {
        saveConversation(); // save current agent's chat before switching
        // Remember current agent's model
        agentModelMap[currentAgentID] = modelEl.value;
        currentAgentID = agentSelectEl.value;
        // Restore this agent's model (if previously set)
        if (agentModelMap[currentAgentID] && modelEl.querySelector('option[value="' + CSS.escape(agentModelMap[currentAgentID]) + '"]')) {
            modelEl.value = agentModelMap[currentAgentID];
        }
        conversationHistory = [];
        messagesEl.innerHTML = '';
        setOrbFull();
        await loadAgentConfig();
        // Try to restore previous conversation with this agent
        if (!loadConversation()) {
            await loadGreeting();
        }
    }

    // ─── Load Agent Config ───
    async function loadAgentConfig() {
        if (!TOKEN) return;
        try {
            const res = await fetch(BASE + '/v1/agents/' + currentAgentID, {
                headers: { 'Authorization': 'Bearer ' + TOKEN }
            });
            if (res.ok) {
                agentConfig = await res.json();
                agentNameEl.textContent = agentConfig.name || currentAgentID;
                document.title = (agentConfig.name || currentAgentID) + ' — Torbo Base';
            }
        } catch(e) {}
    }

    // ─── Load Access Level (for greeting) ───
    async function loadGreeting() {
        if (!TOKEN) return;
        try {
            const res = await fetch(BASE + '/level');
            const data = await res.json();
            const level = data.level || 0;
            const levelNames = ['OFF', 'CHAT', 'READ', 'WRITE', 'EXEC', 'FULL'];
            const name = agentConfig?.name || 'SiD';
            const isSiD = (currentAgentID === 'sid');
            if (isSiD) {
                greetingEl.textContent = "I'm SiD. I run locally on your machine \\u2014 no cloud, no surveillance, no compromises. Access level " + level + " (" + (levelNames[level] || '?') + "). What are we building?";
            } else {
                greetingEl.textContent = "I'm " + name + ", running locally on Torbo Base at access level " + level + " (" + (levelNames[level] || '?') + "). What can I help with?";
            }
        } catch(e) {
            greetingEl.textContent = 'Start a conversation';
        }
    }

    // ─── Load Skills ───
    async function loadSkills() {
        if (!TOKEN) return;
        try {
            const res = await fetch(BASE + '/v1/skills', {
                headers: { 'Authorization': 'Bearer ' + TOKEN }
            });
            if (res.ok) {
                const data = await res.json();
                skillsData = data.skills || [];
            }
        } catch(e) {}
    }

    // ─── Settings Modal ───
    function openSettings() {
        if (agentConfig) {
            document.getElementById('cfgName').value = agentConfig.name || '';
            document.getElementById('cfgPronouns').value = agentConfig.pronouns || 'they/them';
            document.getElementById('cfgRole').value = agentConfig.role || '';
            document.getElementById('cfgVoiceTone').value = agentConfig.voiceTone || agentConfig.voice_tone || '';
            document.getElementById('cfgCoreValues').value = agentConfig.coreValues || agentConfig.core_values || '';
            document.getElementById('cfgInstructions').value = agentConfig.customInstructions || agentConfig.custom_instructions || '';
            document.getElementById('cfgBackground').value = agentConfig.backgroundKnowledge || agentConfig.background_knowledge || '';
            document.getElementById('cfgTopicsToAvoid').value = agentConfig.topicsToAvoid || agentConfig.topics_to_avoid || '';
            document.getElementById('cfgElevenLabsVoiceID').value = agentConfig.elevenLabsVoiceID || '';
            document.getElementById('cfgFallbackVoice').value = agentConfig.fallbackTTSVoice || 'nova';
        }
        // Render skills
        const list = document.getElementById('skillsList');
        list.innerHTML = '';
        skillsData.forEach(skill => {
            const div = document.createElement('div');
            div.className = 'skill-item';
            div.innerHTML = `
                <div class="skill-info">
                    <div class="skill-name">${escapeHtml(skill.name)}</div>
                    <div class="skill-desc">${escapeHtml(skill.description)}</div>
                </div>
                <button class="toggle ${skill.enabled ? 'on' : ''}" data-id="${escapeHtml(skill.id)}"
                    onclick="toggleSkill(this, '${escapeHtml(skill.id)}')"></button>
            `;
            list.appendChild(div);
        });
        document.getElementById('settingsModal').classList.add('open');
    }

    function closeSettings() {
        document.getElementById('settingsModal').classList.remove('open');
    }

    async function saveSettings() {
        if (!agentConfig) agentConfig = {};
        agentConfig.name = document.getElementById('cfgName').value.trim() || 'SiD';
        agentConfig.pronouns = document.getElementById('cfgPronouns').value;
        agentConfig.role = document.getElementById('cfgRole').value.trim();
        agentConfig.voiceTone = document.getElementById('cfgVoiceTone').value.trim();
        agentConfig.coreValues = document.getElementById('cfgCoreValues').value.trim();
        agentConfig.customInstructions = document.getElementById('cfgInstructions').value.trim();
        agentConfig.backgroundKnowledge = document.getElementById('cfgBackground').value.trim();
        agentConfig.topicsToAvoid = document.getElementById('cfgTopicsToAvoid').value.trim();
        agentConfig.elevenLabsVoiceID = document.getElementById('cfgElevenLabsVoiceID').value.trim();
        agentConfig.fallbackTTSVoice = document.getElementById('cfgFallbackVoice').value;
        try {
            await fetch(BASE + '/v1/agents/' + currentAgentID, {
                method: 'PUT',
                headers: { 'Content-Type': 'application/json', 'Authorization': 'Bearer ' + TOKEN },
                body: JSON.stringify(agentConfig)
            });
            agentNameEl.textContent = agentConfig.name;
            document.title = agentConfig.name + ' — Torbo Base';
            // Refresh agents list in case name changed
            await loadAgents();
        } catch(e) {}
        closeSettings();
    }

    async function toggleSkill(btn, id) {
        const isOn = btn.classList.toggle('on');
        try {
            await fetch(BASE + '/v1/skills', {
                method: 'PUT',
                headers: { 'Content-Type': 'application/json', 'Authorization': 'Bearer ' + TOKEN },
                body: JSON.stringify({ id: id, enabled: isOn })
            });
            // Update local data
            const skill = skillsData.find(s => s.id === id);
            if (skill) skill.enabled = isOn;
        } catch(e) {}
    }

    // Close modal on overlay click
    document.getElementById('settingsModal').addEventListener('click', function(e) {
        if (e.target === this) closeSettings();
    });

    async function loadModels() {
        if (!TOKEN) {
            statusEl.textContent = 'No token';
            statusEl.style.color = '#ff4444';
            document.getElementById('greetingBar').style.display = 'none';
            messagesEl.innerHTML = '<div class="empty"><p style="color:#ff4444;font-size:15px">Missing authentication token</p><p style="font-size:11px;color:rgba(255,255,255,0.2);margin-top:6px">Open Web Chat from Torbo Base dashboard<br>or add ?token=YOUR_TOKEN to the URL</p></div>';
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
                document.getElementById('greetingBar').style.display = 'none';
                messagesEl.innerHTML = '<div class="empty"><p style="color:#ff4444;font-size:15px">Invalid token</p><p style="font-size:11px;color:rgba(255,255,255,0.2);margin-top:6px">Token may have been regenerated.<br>Open Web Chat from Torbo Base dashboard to get a fresh link.</p></div>';
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
        setOrbCompact(true);
        const div = document.createElement('div');
        div.className = 'message ' + role;
        const time = new Date().toLocaleTimeString([], {hour:'2-digit',minute:'2-digit'});
        div.innerHTML = `
            <div class="bubble">${escapeHtml(content)}</div>
            <div class="meta">${role === 'user' ? time : (model || '') + ' \\u00b7 ' + time}</div>
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
        if (!text && pendingAttachments.length === 0) return;
        // Abort any in-flight streams from previous message
        activeAbortControllers.forEach(c => c.abort());
        activeAbortControllers.clear();
        inputEl.value = '';
        inputEl.style.height = 'auto';

        // Build content (text or multimodal with attachments)
        const msgContent = buildMessageContent(text);
        const hasAttachments = pendingAttachments.length > 0;
        const attachNames = pendingAttachments.map(a => a.name);

        // Show user message with attachment indicators
        let displayText = text;
        if (hasAttachments) {
            displayText = attachNames.map(n => '\\ud83d\\udcce ' + n).join('  ') + (text ? '\\n' + text : '');
        }
        addMessage('user', displayText);

        // Clear attachments
        pendingAttachments = [];
        renderAttachments();
        sendBtn.disabled = true;

        if (roomMode && roomAgentIDs.size > 0) {
            await sendRoomMessage(text, msgContent);
        } else {
            await sendSingleMessage(text, msgContent);
        }
        sendBtn.disabled = false;
        inputEl.focus();
    }

    async function sendSingleMessage(text, msgContent) {
        conversationHistory.push({ role: 'user', content: msgContent });
        // Post user message to room if multi-user
        if (multiUserRoom) {
            postToRoom(typeof msgContent === 'string' ? msgContent : text, 'user', null);
            highlightSpeaker(myNickname);
        }

        setOrbCompact(true);
        const div = document.createElement('div');
        div.className = 'message assistant';
        const time = new Date().toLocaleTimeString([], {hour:'2-digit',minute:'2-digit'});
        div.innerHTML = `<div class="bubble streaming"><span class="cursor">\\u2588</span></div><div class="meta">${modelEl.value} \\u00b7 ${time}</div>`;
        messagesEl.appendChild(div);
        const bubble = div.querySelector('.bubble');
        messagesEl.scrollTop = messagesEl.scrollHeight;

        const fullContent = await streamToAgent(currentAgentID, conversationHistory, bubble);
        if (fullContent) {
            conversationHistory.push({ role: 'assistant', content: fullContent });
            // Post AI response to room if multi-user
            if (multiUserRoom) postToRoom(fullContent, 'assistant', currentAgentID);
            // Speak the response
            speakText(fullContent);
        }
        saveConversation();
    }

    async function sendRoomMessage(text, msgContent) {
        setOrbCompact(true);
        // Post user message to room if multi-user
        if (multiUserRoom) postToRoom(typeof msgContent === 'string' ? msgContent : text, 'user', null);

        // Add user message to each agent's conversation
        const agents = Array.from(roomAgentIDs);
        agents.forEach(aid => {
            if (!roomConversations[aid]) roomConversations[aid] = [];
            roomConversations[aid].push({ role: 'user', content: msgContent });
        });

        // Send to all agents in parallel, each gets its own bubble and model
        const promises = agents.map(async (aid) => {
            const agent = agentsList.find(a => a.id === aid);
            const agentName = agent?.name || aid;
            const agentModel = agentModelMap[aid] || modelEl.value;
            const div = document.createElement('div');
            div.className = 'message assistant';
            const time = new Date().toLocaleTimeString([], {hour:'2-digit',minute:'2-digit'});
            div.innerHTML = `<div class="agent-label">${escapeHtml(agentName)}</div><div class="bubble streaming"><span class="cursor">\\u2588</span></div><div class="meta">${agentModel} \\u00b7 ${time}</div>`;
            messagesEl.appendChild(div);
            const bubble = div.querySelector('.bubble');
            messagesEl.scrollTop = messagesEl.scrollHeight;

            const fullContent = await streamToAgent(aid, roomConversations[aid], bubble, agentModel);
            if (fullContent) {
                roomConversations[aid].push({ role: 'assistant', content: fullContent });
                // Post AI response to room if multi-user
                if (multiUserRoom) postToRoom(fullContent, 'assistant', aid);
                // Speak the response
                speakText(fullContent);
            }
        });
        await Promise.all(promises);
        saveConversation();
    }

    // Track active fetch controllers so we can abort on new send or page unload
    let activeAbortControllers = new Set();

    async function streamToAgent(agentID, messages, bubble, overrideModel) {
        const useModel = overrideModel || agentModelMap[agentID] || modelEl.value;
        let fullContent = '';
        const controller = new AbortController();
        activeAbortControllers.add(controller);
        let reader = null;
        try {
            const res = await fetch(BASE + '/v1/chat/completions', {
                method: 'POST',
                signal: controller.signal,
                headers: {
                    'Content-Type': 'application/json',
                    'Authorization': 'Bearer ' + TOKEN,
                    'x-torbo-agent-id': agentID
                },
                body: JSON.stringify({ model: useModel, messages: messages, stream: true })
            });

            if (!res.ok) {
                const err = await res.json().catch(() => ({error:'Request failed'}));
                const errMsg = typeof err.error === 'object' ? (err.error.message || JSON.stringify(err.error)) : (err.error || 'Error');
                bubble.innerHTML = '\\u26a0\\ufe0f ' + escapeHtml(String(errMsg));
                bubble.classList.remove('streaming');
                activeAbortControllers.delete(controller);
                return '';
            }

            const contentType = res.headers.get('content-type') || '';
            if (contentType.includes('text/event-stream')) {
                reader = res.body.getReader();
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
                                bubble.innerHTML = renderMarkdown(fullContent) + '<span class="cursor">\\u2588</span>';
                                messagesEl.scrollTop = messagesEl.scrollHeight;
                            }
                        } catch(e) {}
                    }
                }
            } else {
                const data = await res.json();
                if (data.choices && data.choices[0]) {
                    const c = data.choices[0].message.content;
                    fullContent = typeof c === 'string' ? c : (Array.isArray(c) ? c.filter(p => p.type === 'text').map(p => p.text).join('') : JSON.stringify(c));
                } else if (data.error) {
                    const e = data.error;
                    fullContent = '\\u26a0\\ufe0f ' + (typeof e === 'object' ? (e.message || JSON.stringify(e)) : String(e));
                }
            }

            bubble.innerHTML = renderMarkdown(fullContent);
            bubble.classList.remove('streaming');
        } catch(e) {
            if (e.name === 'AbortError') {
                bubble.innerHTML = '\\u26a0\\ufe0f Cancelled';
            } else {
                bubble.innerHTML = '\\u26a0\\ufe0f Connection error';
            }
            bubble.classList.remove('streaming');
            // Cancel the reader if it's still open
            if (reader) try { reader.cancel(); } catch(_) {}
        } finally {
            activeAbortControllers.delete(controller);
        }
        return fullContent;
    }

    // Clean up on page unload — cancel all in-flight streams
    window.addEventListener('beforeunload', () => {
        activeAbortControllers.forEach(c => c.abort());
        activeAbortControllers.clear();
    });

    function escapeHtml(s) {
        return s.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
    }

    function renderMarkdown(text) {
        let html = escapeHtml(text);
        html = html.replace(/```(\\w*)\\n([\\s\\S]*?)```/g, (_, lang, code) => {
            const highlighted = highlightSyntax(code.trim(), lang);
            const langLabel = lang ? `<div style="font-size:10px;color:rgba(255,255,255,0.2);margin-bottom:4px;font-family:monospace">${lang}</div>` : '';
            return `<pre>${langLabel}<code>${highlighted}</code></pre>`;
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
        html = html.replace(/\\[([^\\]]+)\\]\\(([^)]+)\\)/g, '<a href="$2" target="_blank">$1</a>');
        html = html.replace(/^---$/gm, '<hr style="border:none;border-top:1px solid rgba(255,255,255,0.1);margin:8px 0">');
        html = html.replace(/\\n/g, '<br>');
        html = html.replace(/<\\/(pre|h[123]|ul|ol|li|hr)><br>/g, '</$1>');
        html = html.replace(/<br><(pre|h[123]|ul|ol)/g, '<$1');
        return html;
    }

    function highlightSyntax(code, lang) {
        const keywords = /\\b(const|let|var|function|return|if|else|for|while|class|import|export|from|async|await|try|catch|def|self|print|True|False|None|fn|pub|use|mod|struct|impl|enum|match|type|interface)\\b/g;
        const strings = /(&quot;[^&]*?&quot;|&#x27;[^&]*?&#x27;)/g;
        const comments = /(\\/\\/.*?(?:<br>|$)|\\/\\*[\\s\\S]*?\\*\\/|#.*?(?:<br>|$))/g;
        const numbers = /\\b(\\d+\\.?\\d*)\\b/g;
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
        { hue:306, sat:80, bri:90,  radiusMul:1.15, phase:0.08, wave:0.25, sx:1.1,  sy:0.45, rot:0.015, blur:21,  opacity:0.05,  phaseOff:0, waveOff:0, rotOff:0 },
        { hue:0,   sat:85, bri:100, radiusMul:1.0,  phase:0.12, wave:0.35, sx:1.0,  sy:0.5,  rot:0.02,  blur:14,  opacity:0.07,  phaseOff:0, waveOff:0, rotOff:0 },
        { hue:29,  sat:90, bri:100, radiusMul:0.95, phase:0.1,  wave:0.3,  sx:0.85, sy:0.65, rot:0.018, blur:11.5,opacity:0.08,  phaseOff:1.5, waveOff:2, rotOff:Math.PI*0.3 },
        { hue:187, sat:90, bri:100, radiusMul:0.9,  phase:0.14, wave:0.4,  sx:0.75, sy:0.8,  rot:0.022, blur:9,   opacity:0.12,  phaseOff:3, waveOff:1, rotOff:Math.PI*0.7 },
        { hue:216, sat:85, bri:100, radiusMul:0.85, phase:0.09, wave:0.28, sx:0.7,  sy:0.75, rot:0.025, blur:7,   opacity:0.138, phaseOff:2, waveOff:3, rotOff:Math.PI*1.1 },
        { hue:270, sat:80, bri:100, radiusMul:0.75, phase:0.16, wave:0.45, sx:0.6,  sy:0.7,  rot:0.028, blur:5,   opacity:0.152, phaseOff:4, waveOff:2, rotOff:Math.PI*0.5 },
        { hue:331, sat:70, bri:100, radiusMul:0.6,  phase:0.11, wave:0.32, sx:0.55, sy:0.6,  rot:0.03,  blur:3.5, opacity:0.166, phaseOff:1, waveOff:4, rotOff:Math.PI*1.4 }
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
        const breatheAmp = 0.08 + intensity * 0.12;
        const breatheX = layer.sx * (1.0 + Math.sin(wp * 0.3) * breatheAmp);
        const breatheY = layer.sy * (1.0 + Math.cos(wp * 0.25) * breatheAmp);
        ctx.save();
        ctx.globalCompositeOperation = 'lighter';
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
        ctx.filter = `blur(${layer.blur}px)`;
        ctx.beginPath();
        points.forEach((p, i) => i === 0 ? ctx.moveTo(p.x, p.y) : ctx.lineTo(p.x, p.y));
        ctx.closePath();
        ctx.fillStyle = hslToRgba(layer.hue, layer.sat, layer.bri, Math.min(layer.opacity * (1.0 + intensity * 0.6), 0.85));
        ctx.fill();
        ctx.filter = `blur(${layer.blur * 0.4}px)`;
        ctx.beginPath();
        points.forEach((p, i) => i === 0 ? ctx.moveTo(p.x, p.y) : ctx.lineTo(p.x, p.y));
        ctx.closePath();
        ctx.fillStyle = hslToRgba(layer.hue, layer.sat, layer.bri, Math.min(layer.opacity * 0.49 * (1.0 + intensity * 0.6), 0.85));
        ctx.fill();
        ctx.restore();
    }

    function renderOrb(canvas) {
        if (!canvas) return;
        const ctx = canvas.getContext('2d');
        const w = canvas.width; const h = canvas.height;
        const cx = w / 2; const cy = h / 2;
        const radius = Math.min(w, h) * 0.45;
        const t = performance.now() / 1000;
        ctx.clearRect(0, 0, w, h);
        for (const layer of orbLayers) drawAuroraRibbon(ctx, cx, cy, radius, layer, t, orbIntensity);
    }

    // ─── Voice (TTS + STT) ───
    let ttsEnabled = localStorage.getItem(STORAGE_PREFIX + 'tts') === 'true';
    let mediaRecorder = null;
    let audioChunks = [];
    let isRecording = false;

    // ─── Audio Visualization ───
    let audioCtx = null;
    let ttsAnalyser = null;
    let micAnalyser = null;
    let micSource = null;
    let currentTTSAudio = null;
    let orbIntensity = 0.08;
    let orbTargetIntensity = 0.08;
    const ORB_IDLE = 0.08;
    const ORB_MAX = 0.85;
    const ORB_ATTACK = 0.18;
    const ORB_RELEASE = 0.06;

    function ensureAudioContext() {
        if (audioCtx) return;
        audioCtx = new (window.AudioContext || window.webkitAudioContext)();
        ttsAnalyser = audioCtx.createAnalyser();
        ttsAnalyser.fftSize = 256;
        ttsAnalyser.smoothingTimeConstant = 0.8;
        ttsAnalyser.connect(audioCtx.destination);

        micAnalyser = audioCtx.createAnalyser();
        micAnalyser.fftSize = 256;
        micAnalyser.smoothingTimeConstant = 0.7;
    }

    function getAudioLevel(analyser) {
        if (!analyser) return 0;
        const data = new Uint8Array(analyser.frequencyBinCount);
        analyser.getByteFrequencyData(data);
        let sum = 0, w = 0;
        const bins = Math.min(18, data.length);
        for (let i = 0; i < bins; i++) {
            const wt = i < 6 ? 1.5 : 1.0;
            sum += data[i] * wt;
            w += wt;
        }
        return Math.sqrt((sum / w) / 255);
    }

    function updateOrbIntensity() {
        let level = 0;
        if (currentTTSAudio && !currentTTSAudio.paused && !currentTTSAudio.ended) {
            level = Math.max(level, getAudioLevel(ttsAnalyser));
        }
        if (isRecording && micAnalyser) {
            level = Math.max(level, getAudioLevel(micAnalyser));
        }
        orbTargetIntensity = ORB_IDLE + level * (ORB_MAX - ORB_IDLE);
        const speed = orbTargetIntensity > orbIntensity ? ORB_ATTACK : ORB_RELEASE;
        orbIntensity += (orbTargetIntensity - orbIntensity) * speed;
        if (Math.abs(orbIntensity - ORB_IDLE) < 0.002) orbIntensity = ORB_IDLE;
    }

    // ─── Greeting State ───
    function setOrbCompact(compact) {
        const bar = document.getElementById('greetingBar');
        if (bar) bar.classList.toggle('hidden', compact);
    }
    function setOrbFull() {
        const bar = document.getElementById('greetingBar');
        if (bar) bar.classList.remove('hidden');
    }

    // ─── Orb Canvases ───
    const orbCanvases = new Map();
    function initOrb(id) { const c = document.getElementById(id); if (c) orbCanvases.set(id, c); }
    function orbLoop() {
        updateOrbIntensity();
        orbCanvases.forEach(canvas => { if (canvas.offsetParent !== null) renderOrb(canvas); });
        requestAnimationFrame(orbLoop);
    }
    initOrb('orbSmall');
    orbLoop();

    // ─── Room Mode ───
    function toggleRoom() {
        roomMode = !roomMode;
        const roomBtn = document.getElementById('roomBtn');
        roomBtn.classList.toggle('active', roomMode);
        roomBtn.innerHTML = roomMode ? '&#x1f465; Exit Room' : '&#x1f465; Room';
        document.getElementById('roomBar').classList.toggle('open', roomMode);
        if (roomMode) {
            renderRoomChips();
            agentSelectEl.style.display = 'none';
            agentNameEl.textContent = 'Room';
        } else {
            agentSelectEl.style.display = '';
            agentNameEl.textContent = agentConfig?.name || currentAgentID;
            roomAgentIDs.clear();
            roomConversations = {};
        }
    }

    function renderRoomChips() {
        const container = document.getElementById('roomChips');
        container.innerHTML = '';
        if (agentsList.length === 0) {
            container.innerHTML = '<span style="color:var(--text-dim);font-size:11px;">No agents loaded \\u2014 check connection</span>';
            return;
        }
        agentsList.forEach(a => {
            const chip = document.createElement('span');
            chip.className = 'agent-chip' + (roomAgentIDs.has(a.id) ? ' selected' : '');
            chip.textContent = a.name;
            chip.onclick = () => {
                if (roomAgentIDs.has(a.id)) { roomAgentIDs.delete(a.id); }
                else { roomAgentIDs.add(a.id); }
                chip.classList.toggle('selected', roomAgentIDs.has(a.id));
                // Init conversation for new agent
                if (roomAgentIDs.has(a.id) && !roomConversations[a.id]) {
                    roomConversations[a.id] = [];
                }
            };
            container.appendChild(chip);
        });
    }

    // ─── Attachments ───
    function handleFileSelect(event) {
        const files = Array.from(event.target.files);
        files.forEach(f => processFile(f));
        event.target.value = '';
    }

    function processFile(file) {
        const reader = new FileReader();
        reader.onload = (e) => {
            const dataUrl = e.target.result;
            const base64 = dataUrl.split(',')[1];
            pendingAttachments.push({ name: file.name, type: file.type, dataUrl, base64 });
            renderAttachments();
        };
        reader.readAsDataURL(file);
    }

    function renderAttachments() {
        const preview = document.getElementById('attachPreview');
        preview.innerHTML = '';
        preview.classList.toggle('has-files', pendingAttachments.length > 0);
        pendingAttachments.forEach((att, i) => {
            const div = document.createElement('div');
            div.className = 'attach-item';
            const isImage = att.type.startsWith('image/');
            div.innerHTML = (isImage ? `<img src="${att.dataUrl}" alt="${escapeHtml(att.name)}">` : '') +
                `<span>${escapeHtml(att.name.length > 20 ? att.name.slice(0,17) + '...' : att.name)}</span>` +
                `<span class="remove" onclick="removeAttachment(${i})">\\u2715</span>`;
            preview.appendChild(div);
        });
    }

    function removeAttachment(index) {
        pendingAttachments.splice(index, 1);
        renderAttachments();
    }

    // ─── Drag and Drop ───
    let dragCounter = 0;
    document.addEventListener('dragenter', (e) => {
        e.preventDefault();
        dragCounter++;
        document.getElementById('dropOverlay').classList.add('active');
    });
    document.addEventListener('dragleave', (e) => {
        e.preventDefault();
        dragCounter--;
        if (dragCounter <= 0) {
            dragCounter = 0;
            document.getElementById('dropOverlay').classList.remove('active');
        }
    });
    document.addEventListener('dragover', (e) => e.preventDefault());
    document.addEventListener('drop', (e) => {
        e.preventDefault();
        dragCounter = 0;
        document.getElementById('dropOverlay').classList.remove('active');
        const files = Array.from(e.dataTransfer.files);
        files.forEach(f => processFile(f));
    });

    // ─── Build message content with attachments ───
    function buildMessageContent(text) {
        if (pendingAttachments.length === 0) return text;
        // Build multimodal content array for vision models
        const parts = [];
        pendingAttachments.forEach(att => {
            if (att.type.startsWith('image/')) {
                parts.push({
                    type: 'image_url',
                    image_url: { url: att.dataUrl }
                });
            } else {
                // Non-image files: include as text reference
                parts.push({
                    type: 'text',
                    text: `[Attached file: ${att.name} (${att.type})]`
                });
            }
        });
        parts.push({ type: 'text', text: text });
        return parts;
    }

    function initVoiceUI() {
        const speakerBtn = document.getElementById('speakerBtn');
        if (ttsEnabled) {
            speakerBtn.classList.add('active');
            speakerBtn.innerHTML = '&#x1f50a;';
        }
    }

    function toggleSpeaker() {
        ttsEnabled = !ttsEnabled;
        localStorage.setItem(STORAGE_PREFIX + 'tts', ttsEnabled);
        const btn = document.getElementById('speakerBtn');
        btn.classList.toggle('active', ttsEnabled);
        btn.innerHTML = ttsEnabled ? '&#x1f50a;' : '&#x1f508;';
    }

    async function speakText(text) {
        if (!ttsEnabled || !text) return;
        // Strip markdown for cleaner speech
        const clean = text.replace(/```[\\s\\S]*?```/g, ' code block ')
            .replace(/`[^`]+`/g, '')
            .replace(/\\*\\*([^*]+)\\*\\*/g, '$1')
            .replace(/\\*([^*]+)\\*/g, '$1')
            .replace(/#{1,3}\\s*/g, '')
            .replace(/\\[([^\\]]+)\\]\\([^)]+\\)/g, '$1')
            .replace(/[\\n\\r]+/g, ' ')
            .trim();
        if (!clean) return;
        try {
            const voice = agentConfig?.elevenLabsVoiceID || agentConfig?.fallbackTTSVoice || 'nova';
            const res = await fetch(BASE + '/v1/audio/speech', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json', 'Authorization': 'Bearer ' + TOKEN },
                body: JSON.stringify({ input: clean, voice: voice })
            });
            if (!res.ok) return;
            const blob = await res.blob();
            const url = URL.createObjectURL(blob);
            const audio = new Audio(url);
            audio.onended = () => { currentTTSAudio = null; URL.revokeObjectURL(url); };
            try {
                ensureAudioContext();
                if (audioCtx.state === 'suspended') await audioCtx.resume();
                const source = audioCtx.createMediaElementSource(audio);
                source.connect(ttsAnalyser);
                currentTTSAudio = audio;
            } catch(e) { currentTTSAudio = null; }
            audio.play().catch(() => {});
        } catch(e) {}
    }

    async function toggleMic() {
        if (isRecording) {
            stopRecording();
            return;
        }
        try {
            const stream = await navigator.mediaDevices.getUserMedia({ audio: true });
            mediaRecorder = new MediaRecorder(stream);
            audioChunks = [];
            mediaRecorder.ondataavailable = (e) => { if (e.data.size > 0) audioChunks.push(e.data); };
            mediaRecorder.onstop = async () => {
                stream.getTracks().forEach(t => t.stop());
                micSource = null;
                const blob = new Blob(audioChunks, { type: 'audio/webm' });
                await transcribeAudio(blob);
            };
            mediaRecorder.start();
            isRecording = true;
            document.getElementById('micBtn').classList.add('recording');
            try {
                ensureAudioContext();
                if (audioCtx.state === 'suspended') await audioCtx.resume();
                micSource = audioCtx.createMediaStreamSource(stream);
                micSource.connect(micAnalyser);
            } catch(e) {}
        } catch(e) {
            console.error('Mic error:', e.name, e.message);
            statusEl.textContent = e.name === 'NotAllowedError'
                ? 'Mic blocked — check browser permissions'
                : e.name === 'NotFoundError'
                ? 'No microphone found'
                : e.name === 'NotReadableError'
                ? 'Mic in use by another app'
                : 'Mic error: ' + e.message;
        }
    }

    function stopRecording() {
        if (mediaRecorder && mediaRecorder.state !== 'inactive') {
            mediaRecorder.stop();
        }
        isRecording = false;
        micSource = null;
        document.getElementById('micBtn').classList.remove('recording');
    }

    async function transcribeAudio(blob) {
        statusEl.textContent = 'Transcribing...';
        try {
            const formData = new FormData();
            formData.append('file', blob, 'recording.webm');
            formData.append('model', 'whisper-1');
            const res = await fetch(BASE + '/v1/audio/transcriptions', {
                method: 'POST',
                headers: { 'Authorization': 'Bearer ' + TOKEN },
                body: formData
            });
            if (res.ok) {
                const data = await res.json();
                const text = data.text || '';
                if (text.trim()) {
                    inputEl.value = text;
                    inputEl.style.height = 'auto';
                    inputEl.style.height = inputEl.scrollHeight + 'px';
                    inputEl.focus();
                }
                statusEl.textContent = 'Ready';
            } else {
                statusEl.textContent = 'STT failed';
                setTimeout(() => { statusEl.textContent = 'Ready'; }, 2000);
            }
        } catch(e) {
            statusEl.textContent = 'STT error';
            setTimeout(() => { statusEl.textContent = 'Ready'; }, 2000);
        }
    }

    // ─── Initialize ───
    async function initApp() {
        initVoiceUI();
        await loadAgents();
        await loadAgentConfig();
        await Promise.all([loadModels(), loadSkills()]);

        // Check for room invite in URL
        const urlParams = new URLSearchParams(window.location.search);
        const roomParam = urlParams.get('room');
        const nickParam = urlParams.get('nick');
        if (nickParam) { myNickname = nickParam; localStorage.setItem(NICK_KEY, nickParam); }

        if (roomParam) {
            // Joining a shared room
            await joinExistingRoom(roomParam);
        } else {
            // Restore previous conversation or show greeting
            if (!loadConversation()) {
                await loadGreeting();
            }
        }
    }
    initApp();
    </script>
    </body>
    </html>
    """
}
