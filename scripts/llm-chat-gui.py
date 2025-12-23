#!/usr/bin/env python3
"""
LLM Chat GUI - Web-based chat interface for Ollama
Opens a local web server and launches browser
Usage: llm-chat-gui.py [context_file]
"""

import http.server
import socketserver
import json
import urllib.request
import urllib.error
import threading
import webbrowser
import sys
import os
import html
from urllib.parse import parse_qs, urlparse

# Global state
context = ""
messages = []
model = "qwen3-coder:480b-cloud"
api_url = "http://localhost:11434/api/chat"

HTML_TEMPLATE = '''<!DOCTYPE html>
<html>
<head>
    <title>LLM Chat</title>
    <meta charset="UTF-8">
    <style>
        * { box-sizing: border-box; margin: 0; padding: 0; }
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
            background: #1a1a2e;
            color: #eee;
            height: 100vh;
            display: flex;
            flex-direction: column;
        }
        .header {
            background: #16213e;
            padding: 15px 20px;
            border-bottom: 1px solid #0f3460;
        }
        .header h1 { font-size: 18px; font-weight: 500; }
        .context-box {
            background: #0f3460;
            margin: 15px 20px;
            padding: 12px 15px;
            border-radius: 8px;
            font-size: 13px;
            color: #aaa;
            max-height: 100px;
            overflow-y: auto;
        }
        .context-label { color: #e94560; font-weight: 600; margin-bottom: 5px; }
        .chat-container {
            flex: 1;
            overflow-y: auto;
            padding: 20px;
        }
        .message {
            margin-bottom: 15px;
            animation: fadeIn 0.3s ease;
        }
        @keyframes fadeIn { from { opacity: 0; transform: translateY(10px); } to { opacity: 1; transform: translateY(0); } }
        .message-header {
            font-size: 12px;
            font-weight: 600;
            margin-bottom: 5px;
        }
        .user .message-header { color: #4fc3f7; }
        .assistant .message-header { color: #81c784; }
        .message-content {
            background: #16213e;
            padding: 12px 15px;
            border-radius: 12px;
            line-height: 1.5;
            white-space: pre-wrap;
            word-wrap: break-word;
        }
        .user .message-content { background: #1e3a5f; border-bottom-right-radius: 4px; }
        .assistant .message-content { background: #1e3d1e; border-bottom-left-radius: 4px; }
        .thinking {
            color: #888;
            font-style: italic;
            padding: 10px 15px;
        }
        .input-container {
            background: #16213e;
            padding: 15px 20px;
            border-top: 1px solid #0f3460;
            display: flex;
            gap: 10px;
        }
        #userInput {
            flex: 1;
            background: #0f3460;
            border: 1px solid #1e3a5f;
            border-radius: 8px;
            padding: 12px 15px;
            color: #eee;
            font-size: 14px;
            resize: none;
            outline: none;
        }
        #userInput:focus { border-color: #4fc3f7; }
        #sendBtn {
            background: #e94560;
            color: white;
            border: none;
            border-radius: 8px;
            padding: 12px 25px;
            font-size: 14px;
            font-weight: 600;
            cursor: pointer;
            transition: background 0.2s;
        }
        #sendBtn:hover { background: #ff6b6b; }
        #sendBtn:disabled { background: #555; cursor: not-allowed; }
        .status { font-size: 11px; color: #666; padding: 5px 20px; text-align: center; }
    </style>
</head>
<body>
    <div class="header">
        <h1>LLM Chat</h1>
    </div>
    CONTEXT_HTML
    <div class="chat-container" id="chatContainer">
        INITIAL_MESSAGES
    </div>
    <div class="input-container">
        <textarea id="userInput" rows="2" placeholder="Type your message... (Enter to send, Shift+Enter for newline)"></textarea>
        <button id="sendBtn" onclick="sendMessage()">Send</button>
    </div>
    <div class="status">Press Escape to close | Connected to Ollama</div>

    <script>
        const chatContainer = document.getElementById('chatContainer');
        const userInput = document.getElementById('userInput');
        const sendBtn = document.getElementById('sendBtn');

        userInput.focus();

        userInput.addEventListener('keydown', (e) => {
            if (e.key === 'Enter' && !e.shiftKey) {
                e.preventDefault();
                sendMessage();
            }
        });

        document.addEventListener('keydown', (e) => {
            if (e.key === 'Escape') {
                fetch('/shutdown');
                window.close();
            }
        });

        function addMessage(role, content) {
            const div = document.createElement('div');
            div.className = 'message ' + role;
            div.innerHTML = `
                <div class="message-header">${role === 'user' ? 'You' : 'Assistant'}</div>
                <div class="message-content">${escapeHtml(content)}</div>
            `;
            chatContainer.appendChild(div);
            chatContainer.scrollTop = chatContainer.scrollHeight;
        }

        function escapeHtml(text) {
            const div = document.createElement('div');
            div.textContent = text;
            return div.innerHTML;
        }

        function showThinking() {
            const div = document.createElement('div');
            div.id = 'thinking';
            div.className = 'thinking';
            div.textContent = 'Assistant is thinking...';
            chatContainer.appendChild(div);
            chatContainer.scrollTop = chatContainer.scrollHeight;
        }

        function hideThinking() {
            const el = document.getElementById('thinking');
            if (el) el.remove();
        }

        async function sendMessage() {
            const text = userInput.value.trim();
            if (!text) return;

            userInput.value = '';
            addMessage('user', text);
            sendBtn.disabled = true;
            userInput.disabled = true;
            showThinking();

            try {
                const response = await fetch('/chat', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({ message: text })
                });
                const data = await response.json();
                hideThinking();
                addMessage('assistant', data.response);
            } catch (error) {
                hideThinking();
                addMessage('assistant', 'Error: ' + error.message);
            }

            sendBtn.disabled = false;
            userInput.disabled = false;
            userInput.focus();
        }
    </script>
</body>
</html>'''


class ChatHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass  # Suppress logging

    def do_GET(self):
        if self.path == '/':
            self.send_response(200)
            self.send_header('Content-type', 'text/html')
            self.end_headers()

            # Build context HTML
            context_html = ""
            if context.strip():
                escaped_context = html.escape(context[:500] + ('...' if len(context) > 500 else ''))
                context_html = f'''<div class="context-box">
                    <div class="context-label">Context:</div>
                    <div>{escaped_context}</div>
                </div>'''

            # Build initial messages HTML
            initial_html = ""
            for msg in messages:
                role = msg['role']
                if role == 'user' and msg['content'].startswith("I'm sharing the following context"):
                    continue  # Skip context message
                escaped_content = html.escape(msg['content'])
                initial_html += f'''<div class="message {role}">
                    <div class="message-header">{'You' if role == 'user' else 'Assistant'}</div>
                    <div class="message-content">{escaped_content}</div>
                </div>'''

            page = HTML_TEMPLATE.replace('CONTEXT_HTML', context_html).replace('INITIAL_MESSAGES', initial_html)
            self.wfile.write(page.encode())

        elif self.path == '/shutdown':
            self.send_response(200)
            self.end_headers()
            threading.Thread(target=self.server.shutdown).start()

        else:
            self.send_response(404)
            self.end_headers()

    def do_POST(self):
        if self.path == '/chat':
            content_length = int(self.headers['Content-Length'])
            post_data = self.rfile.read(content_length)
            data = json.loads(post_data.decode('utf-8'))
            user_message = data.get('message', '')

            # Add user message
            messages.append({"role": "user", "content": user_message})

            # Call LLM
            try:
                payload = json.dumps({
                    "model": model,
                    "messages": messages,
                    "stream": False
                }).encode('utf-8')

                req = urllib.request.Request(
                    api_url,
                    data=payload,
                    headers={'Content-Type': 'application/json'}
                )

                with urllib.request.urlopen(req, timeout=120) as response:
                    result = json.loads(response.read().decode('utf-8'))
                    assistant_message = result.get('message', {}).get('content', 'Error: No response')

                messages.append({"role": "assistant", "content": assistant_message})

                self.send_response(200)
                self.send_header('Content-type', 'application/json')
                self.end_headers()
                self.wfile.write(json.dumps({"response": assistant_message}).encode())

            except Exception as e:
                self.send_response(200)
                self.send_header('Content-type', 'application/json')
                self.end_headers()
                self.wfile.write(json.dumps({"response": f"Error: {e}"}).encode())
        else:
            self.send_response(404)
            self.end_headers()


def main():
    global context, messages

    # Read context from file if provided
    if len(sys.argv) > 1:
        context_file = sys.argv[1]
        if os.path.exists(context_file):
            with open(context_file, 'r') as f:
                context = f.read()
            try:
                os.remove(context_file)
            except:
                pass

    # Initialize messages with context
    if context.strip():
        messages.append({
            "role": "user",
            "content": f"I'm sharing the following context with you. Please keep it in mind for our conversation:\n\n{context}"
        })
        messages.append({
            "role": "assistant",
            "content": "I've noted the context you shared. How can I help you with this?"
        })

    # Find available port
    port = 8765
    for p in range(8765, 8800):
        try:
            with socketserver.TCPServer(("", p), ChatHandler) as httpd:
                port = p
                break
        except OSError:
            continue

    # Start server
    with socketserver.TCPServer(("", port), ChatHandler) as httpd:
        url = f"http://localhost:{port}"
        print(f"Starting chat server at {url}")

        # Open browser
        webbrowser.open(url)

        # Serve until shutdown
        httpd.serve_forever()


if __name__ == "__main__":
    main()
