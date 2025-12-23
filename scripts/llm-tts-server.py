#!/usr/bin/env python3
"""
Kokoro-82M TTS Server for macOS
Keeps the model loaded in memory for fast speech synthesis.
"""

import sys
import os
import json
import tempfile
import subprocess
import signal
import atexit
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import parse_qs, urlparse

# Global pipeline (loaded once)
pipeline = None
SAMPLE_RATE = 24000
PID_FILE = os.path.expanduser("~/.llm-tts-server.pid")
DEFAULT_PORT = 7865

def load_model():
    """Load Kokoro model once at startup."""
    global pipeline
    if pipeline is not None:
        return

    print("Loading Kokoro-82M model...", file=sys.stderr)
    from kokoro import KPipeline
    pipeline = KPipeline(lang_code='a')
    print("Model loaded!", file=sys.stderr)

def text_to_speech(text, voice='af_heart', speed=1.0):
    """Generate speech from text."""
    import soundfile as sf
    import numpy as np

    audio_chunks = []
    for _, _, audio in pipeline(text, voice=voice, speed=speed):
        audio_chunks.append(audio)

    if not audio_chunks:
        return None

    full_audio = np.concatenate(audio_chunks)

    # Save to temp file
    fd, audio_path = tempfile.mkstemp(suffix='.wav')
    os.close(fd)
    sf.write(audio_path, full_audio, SAMPLE_RATE)

    return audio_path

class TTSHandler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass  # Suppress logging

    def do_GET(self):
        parsed = urlparse(self.path)

        if parsed.path == '/health':
            self.send_response(200)
            self.send_header('Content-Type', 'text/plain')
            self.end_headers()
            self.wfile.write(b'ok')
            return

        if parsed.path == '/speak':
            params = parse_qs(parsed.query)
            text = params.get('text', [''])[0]
            voice = params.get('voice', ['af_heart'])[0]
            speed = float(params.get('speed', ['1.0'])[0])
            play = params.get('play', ['1'])[0] == '1'

            if not text:
                self.send_response(400)
                self.send_header('Content-Type', 'text/plain')
                self.end_headers()
                self.wfile.write(b'Missing text parameter')
                return

            try:
                audio_path = text_to_speech(text, voice=voice, speed=speed)
                if audio_path:
                    if play:
                        subprocess.run(["afplay", audio_path], check=True)
                        os.unlink(audio_path)
                        self.send_response(200)
                        self.send_header('Content-Type', 'text/plain')
                        self.end_headers()
                        self.wfile.write(b'ok')
                    else:
                        self.send_response(200)
                        self.send_header('Content-Type', 'text/plain')
                        self.end_headers()
                        self.wfile.write(audio_path.encode())
                else:
                    self.send_response(500)
                    self.send_header('Content-Type', 'text/plain')
                    self.end_headers()
                    self.wfile.write(b'Failed to generate audio')
            except Exception as e:
                self.send_response(500)
                self.send_header('Content-Type', 'text/plain')
                self.end_headers()
                self.wfile.write(str(e).encode())
            return

        self.send_response(404)
        self.end_headers()

    def do_POST(self):
        if self.path == '/speak':
            content_length = int(self.headers.get('Content-Length', 0))
            body = self.rfile.read(content_length).decode('utf-8')

            try:
                data = json.loads(body)
            except json.JSONDecodeError:
                data = {'text': body}

            text = data.get('text', '')
            voice = data.get('voice', 'af_heart')
            speed = float(data.get('speed', 1.0))
            play = data.get('play', True)

            if not text:
                self.send_response(400)
                self.send_header('Content-Type', 'text/plain')
                self.end_headers()
                self.wfile.write(b'Missing text')
                return

            try:
                audio_path = text_to_speech(text, voice=voice, speed=speed)
                if audio_path:
                    if play:
                        subprocess.run(["afplay", audio_path], check=True)
                        os.unlink(audio_path)
                    self.send_response(200)
                    self.send_header('Content-Type', 'text/plain')
                    self.end_headers()
                    self.wfile.write(b'ok' if play else audio_path.encode())
                else:
                    self.send_response(500)
                    self.end_headers()
            except Exception as e:
                self.send_response(500)
                self.send_header('Content-Type', 'text/plain')
                self.end_headers()
                self.wfile.write(str(e).encode())
            return

        self.send_response(404)
        self.end_headers()

def cleanup():
    """Remove PID file on exit."""
    if os.path.exists(PID_FILE):
        os.unlink(PID_FILE)

def write_pid():
    """Write current PID to file."""
    with open(PID_FILE, 'w') as f:
        f.write(str(os.getpid()))

def main():
    import argparse
    parser = argparse.ArgumentParser(description='Kokoro TTS Server')
    parser.add_argument('-p', '--port', type=int, default=DEFAULT_PORT, help='Port to listen on')
    parser.add_argument('--daemon', action='store_true', help='Run in background')
    args = parser.parse_args()

    if args.daemon:
        # Fork to background
        pid = os.fork()
        if pid > 0:
            print(f"TTS server started on port {args.port} (PID: {pid})")
            sys.exit(0)
        os.setsid()

    # Setup cleanup
    atexit.register(cleanup)
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    signal.signal(signal.SIGINT, lambda *_: sys.exit(0))

    # Load model before starting server
    load_model()

    # Write PID file
    write_pid()

    # Start server
    server = HTTPServer(('127.0.0.1', args.port), TTSHandler)
    print(f"TTS server listening on http://127.0.0.1:{args.port}", file=sys.stderr)
    server.serve_forever()

if __name__ == '__main__':
    main()
