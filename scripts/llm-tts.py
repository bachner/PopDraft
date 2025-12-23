#!/usr/bin/env python3
"""
Kokoro-82M Text-to-Speech for macOS
Converts text to speech using the Kokoro-82M model.

Uses TTS server if running (instant), otherwise loads model directly (slow first time).
Start server with: llm-tts-server.py --daemon
"""

import sys
import os
import argparse
import tempfile
import subprocess
import urllib.request
import urllib.parse
import urllib.error

TTS_SERVER_URL = "http://127.0.0.1:7865"

def try_server(text, voice='af_heart', speed=1.0, output_file=None):
    """Try to use the TTS server if running. Returns True if successful."""
    try:
        params = urllib.parse.urlencode({
            'text': text,
            'voice': voice,
            'speed': str(speed),
            'play': '0' if output_file else '1'
        })
        url = f"{TTS_SERVER_URL}/speak?{params}"

        req = urllib.request.Request(url, method='GET')
        with urllib.request.urlopen(req, timeout=60) as response:
            result = response.read().decode('utf-8')
            if output_file and result != 'ok':
                # Server returned a temp file path, copy it to output
                import shutil
                shutil.move(result, output_file)
                print(f"Audio saved to: {output_file}")
            return True
    except (urllib.error.URLError, ConnectionRefusedError, OSError):
        return False

def check_dependencies():
    """Check if required dependencies are installed."""
    missing = []

    try:
        import kokoro
    except ImportError:
        missing.append("kokoro")

    try:
        import soundfile
    except ImportError:
        missing.append("soundfile")

    # Check for espeak-ng
    result = subprocess.run(["which", "espeak-ng"], capture_output=True)
    if result.returncode != 0:
        # Also check for espeak (espeak-ng may be installed as espeak via brew)
        result = subprocess.run(["which", "espeak"], capture_output=True)
        if result.returncode != 0:
            missing.append("espeak-ng (install with: brew install espeak-ng)")

    if missing:
        print("Missing dependencies:", file=sys.stderr)
        for dep in missing:
            print(f"  - {dep}", file=sys.stderr)
        print("\nInstall Python packages with: pip install kokoro soundfile", file=sys.stderr)
        sys.exit(1)

def text_to_speech(text, voice='af_heart', speed=1.0, lang_code='a', output_file=None):
    """
    Convert text to speech using Kokoro-82M.

    Args:
        text: Text to convert to speech
        voice: Voice preset (default: af_heart - American female)
        speed: Speech speed multiplier (default: 1.0)
        lang_code: Language code ('a'=American English, 'b'=British English)
        output_file: Optional output file path (if None, plays directly)

    Returns:
        Path to the generated audio file
    """
    from kokoro import KPipeline
    import soundfile as sf

    # Initialize pipeline
    pipeline = KPipeline(lang_code=lang_code)

    # Generate audio
    audio_chunks = []
    for _, _, audio in pipeline(text, voice=voice, speed=speed):
        audio_chunks.append(audio)

    if not audio_chunks:
        print("Error: No audio generated", file=sys.stderr)
        sys.exit(1)

    # Concatenate all chunks
    import numpy as np
    full_audio = np.concatenate(audio_chunks)

    # Determine output path
    if output_file:
        audio_path = output_file
    else:
        # Create temp file for playback
        fd, audio_path = tempfile.mkstemp(suffix='.wav')
        os.close(fd)

    # Write audio file
    sf.write(audio_path, full_audio, 24000)

    return audio_path

def play_audio(audio_path):
    """Play audio file using macOS afplay."""
    try:
        subprocess.run(["afplay", audio_path], check=True)
    except subprocess.CalledProcessError as e:
        print(f"Error playing audio: {e}", file=sys.stderr)
    except FileNotFoundError:
        print("Error: afplay not found (required for audio playback)", file=sys.stderr)

def main():
    parser = argparse.ArgumentParser(
        description='Kokoro-82M Text-to-Speech for macOS',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog='''
Examples:
  echo "Hello world" | llm-tts.py
  llm-tts.py "Hello world"
  llm-tts.py -v bf_emma -s 1.2 "Hello world"
  llm-tts.py -o output.wav "Hello world"

Voices:
  American English (lang_code='a'):
    af_heart, af_bella, af_nicole, af_sarah, af_sky
    am_adam, am_michael

  British English (lang_code='b'):
    bf_emma, bf_isabella
    bm_george, bm_lewis

Language codes:
  a = American English (default)
  b = British English
'''
    )

    parser.add_argument('text', nargs='?', help='Text to speak (or read from stdin)')
    parser.add_argument('-v', '--voice', default='af_heart',
                        help='Voice preset (default: af_heart)')
    parser.add_argument('-s', '--speed', type=float, default=1.0,
                        help='Speech speed multiplier (default: 1.0)')
    parser.add_argument('-l', '--lang', default='a',
                        help='Language code: a=American, b=British (default: a)')
    parser.add_argument('-o', '--output', metavar='FILE',
                        help='Output WAV file (if not specified, plays audio)')
    parser.add_argument('--no-play', action='store_true',
                        help='Generate audio file but do not play')
    parser.add_argument('--check', action='store_true',
                        help='Check dependencies and exit')

    args = parser.parse_args()

    # Check dependencies
    check_dependencies()

    if args.check:
        print("All dependencies are installed.")
        sys.exit(0)

    # Get text from argument or stdin
    if args.text:
        text = args.text
    elif not sys.stdin.isatty():
        text = sys.stdin.read().strip()
    else:
        parser.error("No text provided. Use 'llm-tts.py \"text\"' or pipe text via stdin.")

    if not text:
        print("Error: Empty text provided", file=sys.stderr)
        sys.exit(1)

    # Try server first (instant if running)
    if not args.no_play or args.output:
        if try_server(text, voice=args.voice, speed=args.speed, output_file=args.output):
            sys.exit(0)

    # Fall back to loading model directly (slow)
    print("TTS server not running, loading model directly...", file=sys.stderr)
    print("Tip: Start server for instant TTS: llm-tts-server.py --daemon", file=sys.stderr)

    # Generate speech
    audio_path = text_to_speech(
        text=text,
        voice=args.voice,
        speed=args.speed,
        lang_code=args.lang,
        output_file=args.output
    )

    # Handle output
    if args.output:
        print(f"Audio saved to: {audio_path}")
    elif not args.no_play:
        play_audio(audio_path)
        # Clean up temp file
        if not args.output:
            os.unlink(audio_path)
    else:
        print(audio_path)

if __name__ == '__main__':
    main()
