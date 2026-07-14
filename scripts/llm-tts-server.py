#!/usr/bin/env python3
"""
Higgs Audio v3 (4B) TTS Server for macOS — runs on Apple Silicon via MLX-Audio.

Keeps the model loaded in memory for fast, near-real-time speech synthesis.
Model: bosonai/higgs-audio-v3-tts-4b (100+ languages incl. Hebrew, voice cloning).
Runtime: MLX-Audio (native M-series acceleration). Same HTTP API as the previous
Kokoro server so the app's Swift client is unchanged.

Note: Higgs TTS 3 is under a Research & Non-Commercial license; weights are
downloaded from Hugging Face to the user's machine (not bundled with the app).
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


# The Higgs model repo (MLX-Audio resolves + loads it; ~8 GB, cached under
# ~/.cache/huggingface). Overridable via env for testing.
MODEL_ID = os.environ.get("POPDRAFT_TTS_MODEL", "bosonai/higgs-audio-v3-tts-4b")
SAMPLE_RATE = 24000

# The model is large + generation is single-slot; serialize synthesis so
# concurrent /speak calls don't fight over MLX/Metal.
model = None
model_lock = threading.Lock()
synth_lock = threading.Lock()

# Curated subset of Higgs' languages we expose by NAME (the value passed to
# model.generate(language=...)). "auto" (the default) detects the script instead.
LANGUAGES = [
    "English", "Hebrew", "Spanish", "French", "German", "Italian",
    "Portuguese", "Russian", "Arabic", "Chinese", "Japanese", "Korean",
    "Hindi", "Dutch", "Turkish", "Polish",
]
_LANG_SET = {l.lower() for l in LANGUAGES}

PID_FILE = os.path.expanduser("~/.llm-tts-server.pid")
DEFAULT_PORT = 7865

# Track current playback process (thread-safe)
playback_lock = threading.Lock()
current_playback = None
current_audio_file = None


def detect_language(text):
    """Pick a Higgs language name from the text's dominant script. Falls back to
    English. Covers the scripts most relevant here (Hebrew first — the user works
    in Hebrew)."""
    for ch in text:
        o = ord(ch)
        if 0x0590 <= o <= 0x05FF:
            return "Hebrew"
        if 0x0600 <= o <= 0x06FF or 0x0750 <= o <= 0x077F:
            return "Arabic"
        if 0x0400 <= o <= 0x04FF:
            return "Russian"
        if 0x3040 <= o <= 0x30FF:
            return "Japanese"
        if 0xAC00 <= o <= 0xD7A3:
            return "Korean"
        if 0x4E00 <= o <= 0x9FFF:
            return "Chinese"
        if 0x0900 <= o <= 0x097F:
            return "Hindi"
    return "English"


def resolve_language(voice, text):
    """The app sends the chosen language in the `voice` field (legacy name). If it
    names a known language, honor it; otherwise ("auto", empty, or a stale Kokoro
    voice id like 'af_heart') auto-detect from the text."""
    v = (voice or "").strip()
    if v.lower() in _LANG_SET:
        # Normalize to the canonical capitalization Higgs expects.
        for l in LANGUAGES:
            if l.lower() == v.lower():
                return l
    return detect_language(text)


def load_model():
    """Load the Higgs model once, into memory (kept resident for fast repeats)."""
    global model
    with model_lock:
        if model is not None:
            return model
        print(f"Loading Higgs TTS model ({MODEL_ID})...", file=sys.stderr)
        from mlx_audio.tts.utils import load_model as _load
        model = _load(MODEL_ID)
        print("Higgs TTS model loaded!", file=sys.stderr)
        return model


def _apply_speed(audio, speed):
    """Pitch-preserving time-stretch for the speed slider. No-op if speed≈1 or
    librosa isn't available (Higgs' natural pace is used)."""
    if abs(speed - 1.0) < 0.02:
        return audio
    try:
        import librosa
        return librosa.effects.time_stretch(audio, rate=speed)
    except Exception as e:
        print(f"speed control unavailable ({e}); using natural pace", file=sys.stderr)
        return audio


def text_to_speech(text, voice='auto', speed=1.0):
    """Generate speech WAV from text and return its path (or None)."""
    import numpy as np
    from scipy.io import wavfile

    m = load_model()
    lang = resolve_language(voice, text)

    with synth_lock:  # one generation at a time
        chunks = []
        try:
            gen = m.generate(text=text, voice="default_voice", language=lang)
        except TypeError:
            gen = m.generate(text=text, voice="default_voice")
        for r in gen:
            chunks.append(np.array(r.audio, copy=False).reshape(-1))

    if not chunks:
        return None
    audio = np.concatenate(chunks).astype(np.float32)
    audio = _apply_speed(audio, speed)

    fd, audio_path = tempfile.mkstemp(suffix='.wav')
    os.close(fd)
    # 16-bit PCM keeps afplay happy and the file small.
    pcm = np.clip(audio, -1.0, 1.0)
    wavfile.write(audio_path, SAMPLE_RATE, (pcm * 32767).astype(np.int16))
    return audio_path


def stop_playback():
    """Stop current playback if any."""
    global current_playback, current_audio_file
    with playback_lock:
        if current_playback and current_playback.poll() is None:
            current_playback.terminate()
            try:
                current_playback.wait(timeout=1)
            except Exception:
                current_playback.kill()
        current_playback = None
        if current_audio_file and os.path.exists(current_audio_file):
            try:
                os.unlink(current_audio_file)
            except Exception:
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
                if current_audio_file and os.path.exists(current_audio_file):
                    try:
                        os.unlink(current_audio_file)
                    except Exception:
                        pass
                current_audio_file = None
                current_playback = None
                break
        threading.Event().wait(0.1)


class TTSHandler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass  # Suppress logging

    def _text(self, code, body):
        self.send_response(code)
        self.send_header('Content-Type', 'text/plain')
        self.end_headers()
        self.wfile.write(body if isinstance(body, bytes) else body.encode())

    def do_GET(self):
        global current_playback, current_audio_file
        parsed = urlparse(self.path)

        if parsed.path == '/health':
            self._text(200, b'ok')
            return

        if parsed.path == '/voices':
            # Chatterbox/Kokoro-style shape kept for compatibility: one "voice"
            # per language (Higgs has a single base voice; the language is the knob).
            voices = {"auto": {"language": "Auto-detect", "voices": ["auto"]}}
            for lang in LANGUAGES:
                voices[lang] = {"language": lang, "voices": [lang]}
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps(voices, indent=2).encode())
            return

        if parsed.path == '/status':
            with playback_lock:
                if current_playback is None or current_playback.poll() is not None:
                    status = 'idle'
                else:
                    status = 'playing'
            self._text(200, status)
            return

        if parsed.path == '/stop':
            stop_playback()
            self._text(200, b'stopped')
            return

        if parsed.path == '/pause':
            self._text(200, b'paused') if pause_playback() else self._text(404, b'nothing playing')
            return

        if parsed.path == '/resume':
            self._text(200, b'resumed') if resume_playback() else self._text(404, b'nothing to resume')
            return

        if parsed.path == '/speak':
            params = parse_qs(parsed.query)
            text = params.get('text', [''])[0]
            voice = params.get('voice', ['auto'])[0]
            speed = float(params.get('speed', ['1.0'])[0])
            play = params.get('play', ['1'])[0] == '1'

            if not text:
                self._text(400, b'Missing text parameter')
                return

            try:
                stop_playback()
                audio_path = text_to_speech(text, voice=voice, speed=speed)
                if audio_path:
                    if play:
                        with playback_lock:
                            current_audio_file = audio_path
                            current_playback = subprocess.Popen(["afplay", audio_path])
                        threading.Thread(target=playback_monitor, args=(audio_path,), daemon=True).start()
                        self._text(200, b'playing')
                    else:
                        self._text(200, audio_path.encode())
                else:
                    self._text(500, b'Failed to generate audio')
            except Exception as e:
                self._text(500, str(e))
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
            voice = data.get('voice', 'auto')
            speed = float(data.get('speed', 1.0))
            play = data.get('play', True)

            if not text:
                self._text(400, b'Missing text')
                return

            try:
                audio_path = text_to_speech(text, voice=voice, speed=speed)
                if audio_path:
                    if play:
                        subprocess.run(["afplay", audio_path], check=True)
                        os.unlink(audio_path)
                    self._text(200, b'ok' if play else audio_path.encode())
                else:
                    self.send_response(500)
                    self.end_headers()
            except Exception as e:
                self._text(500, str(e))
            return

        self.send_response(404)
        self.end_headers()


def cleanup():
    if os.path.exists(PID_FILE):
        os.unlink(PID_FILE)


def write_pid():
    with open(PID_FILE, 'w') as f:
        f.write(str(os.getpid()))


def main():
    import argparse
    parser = argparse.ArgumentParser(description='Higgs TTS Server')
    parser.add_argument('-p', '--port', type=int, default=DEFAULT_PORT, help='Port to listen on')
    parser.add_argument('--daemon', action='store_true', help='Run in background')
    args = parser.parse_args()

    if args.daemon:
        pid = os.fork()
        if pid > 0:
            print(f"TTS server started on port {args.port} (PID: {pid})")
            sys.exit(0)
        os.setsid()

    atexit.register(cleanup)
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    signal.signal(signal.SIGINT, lambda *_: sys.exit(0))

    # Load the model in the BACKGROUND so /health is up immediately and the ~8 GB
    # first-run download/load doesn't block the server from starting (the app's
    # health check would otherwise time out). The first /speak waits on model_lock
    # until the load finishes; later ones are instant.
    threading.Thread(target=load_model, daemon=True).start()
    write_pid()

    server = ThreadingHTTPServer(('127.0.0.1', args.port), TTSHandler)
    print(f"TTS server listening on http://127.0.0.1:{args.port}", file=sys.stderr)
    server.serve_forever()


if __name__ == '__main__':
    main()
