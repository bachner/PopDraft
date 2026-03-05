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
import threading
from http.server import HTTPServer, BaseHTTPRequestHandler
from socketserver import ThreadingMixIn
from urllib.parse import parse_qs, urlparse


class ThreadingHTTPServer(ThreadingMixIn, HTTPServer):
    """Handle requests in separate threads."""
    daemon_threads = True

# Pipeline cache keyed by lang_code (loaded on demand)
pipelines = {}
pipelines_lock = threading.Lock()
SAMPLE_RATE = 24000

# Language code mapping for Kokoro v1.0 multilingual voices
# Voice names follow the pattern: {lang_code}{gender}_{name}
LANG_CODES = {
    'a': 'American English',
    'b': 'British English',
    'j': 'Japanese',
    'z': 'Mandarin Chinese',
    'e': 'Spanish',
    'f': 'French',
    'h': 'Hindi',
    'i': 'Italian',
    'p': 'Brazilian Portuguese',
}
PID_FILE = os.path.expanduser("~/.llm-tts-server.pid")
DEFAULT_PORT = 7865

# Track current playback process (thread-safe)
playback_lock = threading.Lock()
current_playback = None
current_audio_file = None

def get_pipeline(voice='af_heart'):
    """Get or create a KPipeline for the given voice's language.

    Extracts the first character of the voice name as the lang_code,
    looks it up in the cache, and creates a new KPipeline if needed.
    """
    lang_code = voice[0] if voice else 'a'
    if lang_code not in LANG_CODES:
        lang_code = 'a'  # Fall back to American English

    with pipelines_lock:
        if lang_code in pipelines:
            return pipelines[lang_code]

    # Create outside the lock to avoid blocking other languages
    print(f"Loading Kokoro pipeline for '{lang_code}' ({LANG_CODES[lang_code]})...", file=sys.stderr)
    from kokoro import KPipeline
    new_pipeline = KPipeline(lang_code=lang_code)
    print(f"Pipeline '{lang_code}' loaded!", file=sys.stderr)

    with pipelines_lock:
        # Another thread may have created it while we were loading
        if lang_code not in pipelines:
            pipelines[lang_code] = new_pipeline
        return pipelines[lang_code]


def load_model():
    """Pre-load the default American English pipeline at startup."""
    print("Loading default Kokoro pipeline...", file=sys.stderr)
    get_pipeline('af_heart')
    print("Default pipeline ready!", file=sys.stderr)

def text_to_speech(text, voice='af_heart', speed=1.0):
    """Generate speech from text."""
    import soundfile as sf
    import numpy as np

    pipe = get_pipeline(voice)
    audio_chunks = []
    for _, _, audio in pipe(text, voice=voice, speed=speed):
        audio_chunks.append(audio)

    if not audio_chunks:
        return None

    full_audio = np.concatenate(audio_chunks)

    # Save to temp file
    fd, audio_path = tempfile.mkstemp(suffix='.wav')
    os.close(fd)
    sf.write(audio_path, full_audio, SAMPLE_RATE)

    return audio_path

def stop_playback():
    """Stop current playback if any."""
    global current_playback, current_audio_file
    with playback_lock:
        if current_playback and current_playback.poll() is None:
            current_playback.terminate()
            try:
                current_playback.wait(timeout=1)
            except:
                current_playback.kill()
        current_playback = None
        if current_audio_file and os.path.exists(current_audio_file):
            try:
                os.unlink(current_audio_file)
            except:
                pass
        current_audio_file = None

def pause_playback():
    """Pause current playback using SIGSTOP."""
    global current_playback
    with playback_lock:
        if current_playback and current_playback.poll() is None:
            current_playback.send_signal(signal.SIGSTOP)
            return True
    return False

def resume_playback():
    """Resume paused playback using SIGCONT."""
    global current_playback
    with playback_lock:
        if current_playback and current_playback.poll() is None:
            current_playback.send_signal(signal.SIGCONT)
            return True
    return False

def playback_monitor(audio_path):
    """Monitor playback and cleanup when done."""
    global current_playback, current_audio_file
    while True:
        with playback_lock:
            if current_playback is None:
                break
            if current_playback.poll() is not None:
                # Playback finished
                if current_audio_file and os.path.exists(current_audio_file):
                    try:
                        os.unlink(current_audio_file)
                    except:
                        pass
                current_audio_file = None
                current_playback = None
                break
        threading.Event().wait(0.1)  # Check every 100ms

class TTSHandler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass  # Suppress logging

    def do_GET(self):
        global current_playback, current_audio_file
        parsed = urlparse(self.path)

        if parsed.path == '/health':
            self.send_response(200)
            self.send_header('Content-Type', 'text/plain')
            self.end_headers()
            self.wfile.write(b'ok')
            return

        if parsed.path == '/voices':
            voices = {
                'a': {
                    'language': 'American English',
                    'voices': [
                        'af_heart', 'af_alloy', 'af_aoede', 'af_bella',
                        'af_jessica', 'af_kore', 'af_nicole', 'af_nova',
                        'af_river', 'af_sarah', 'af_sky',
                        'am_adam', 'am_echo', 'am_eric', 'am_fenrir',
                        'am_liam', 'am_michael', 'am_onyx', 'am_puck',
                        'am_santa',
                    ],
                },
                'b': {
                    'language': 'British English',
                    'voices': [
                        'bf_alice', 'bf_emma', 'bf_isabella', 'bf_lily',
                        'bm_daniel', 'bm_fable', 'bm_george', 'bm_lewis',
                    ],
                },
                'j': {
                    'language': 'Japanese',
                    'voices': [
                        'jf_alpha', 'jf_gongitsune', 'jf_nezumi',
                        'jf_tebukuro',
                        'jm_kumo',
                    ],
                },
                'z': {
                    'language': 'Mandarin Chinese',
                    'voices': [
                        'zf_xiaobei', 'zf_xiaoni', 'zf_xiaoxiao',
                        'zf_xiaoyi',
                        'zm_yunjian', 'zm_yunxi', 'zm_yunxia', 'zm_yunyang',
                    ],
                },
                'e': {
                    'language': 'Spanish',
                    'voices': [
                        'ef_dora',
                        'em_alex', 'em_santa',
                    ],
                },
                'f': {
                    'language': 'French',
                    'voices': [
                        'ff_siwis',
                        'fm_gilles',
                    ],
                },
                'h': {
                    'language': 'Hindi',
                    'voices': [
                        'hf_alpha', 'hf_beta',
                        'hm_omega', 'hm_psi',
                    ],
                },
                'i': {
                    'language': 'Italian',
                    'voices': [
                        'if_sara',
                        'im_nicola',
                    ],
                },
                'p': {
                    'language': 'Brazilian Portuguese',
                    'voices': [
                        'pf_dora',
                        'pm_alex', 'pm_santa',
                    ],
                },
            }
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps(voices, indent=2).encode())
            return

        if parsed.path == '/status':
            with playback_lock:
                if current_playback is None:
                    status = 'idle'
                elif current_playback.poll() is not None:
                    status = 'idle'
                else:
                    # Check if paused (we need to track this)
                    status = 'playing'
            self.send_response(200)
            self.send_header('Content-Type', 'text/plain')
            self.end_headers()
            self.wfile.write(status.encode())
            return

        if parsed.path == '/stop':
            stop_playback()
            self.send_response(200)
            self.send_header('Content-Type', 'text/plain')
            self.end_headers()
            self.wfile.write(b'stopped')
            return

        if parsed.path == '/pause':
            if pause_playback():
                self.send_response(200)
                self.send_header('Content-Type', 'text/plain')
                self.end_headers()
                self.wfile.write(b'paused')
            else:
                self.send_response(404)
                self.send_header('Content-Type', 'text/plain')
                self.end_headers()
                self.wfile.write(b'nothing playing')
            return

        if parsed.path == '/resume':
            if resume_playback():
                self.send_response(200)
                self.send_header('Content-Type', 'text/plain')
                self.end_headers()
                self.wfile.write(b'resumed')
            else:
                self.send_response(404)
                self.send_header('Content-Type', 'text/plain')
                self.end_headers()
                self.wfile.write(b'nothing to resume')
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
                # Stop any existing playback
                stop_playback()

                audio_path = text_to_speech(text, voice=voice, speed=speed)
                if audio_path:
                    if play:
                        with playback_lock:
                            current_audio_file = audio_path
                            current_playback = subprocess.Popen(["afplay", audio_path])
                        # Start monitor thread to cleanup when done
                        threading.Thread(target=playback_monitor, args=(audio_path,), daemon=True).start()
                        # Return immediately - don't wait for playback
                        self.send_response(200)
                        self.send_header('Content-Type', 'text/plain')
                        self.end_headers()
                        self.wfile.write(b'playing')
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

    # Start server (threaded to handle concurrent requests)
    server = ThreadingHTTPServer(('127.0.0.1', args.port), TTSHandler)
    print(f"TTS server listening on http://127.0.0.1:{args.port}", file=sys.stderr)
    server.serve_forever()

if __name__ == '__main__':
    main()
