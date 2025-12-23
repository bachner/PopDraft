#!/bin/bash
# LLM TTS - Text-to-Speech using Kokoro-82M
# Usage: llm-tts.sh [options] ["text"]
# If no text argument, reads from clipboard/selection

export PATH="/usr/local/bin:/opt/homebrew/bin:$HOME/bin:$PATH"

# Check if text was passed as argument
if [ -n "$1" ]; then
    # Text provided as argument
    python3 "$HOME/bin/llm-tts.py" "$@"
else
    # No argument - try to get from stdin or clipboard
    if [ ! -t 0 ]; then
        # Reading from stdin
        python3 "$HOME/bin/llm-tts.py"
    else
        # Try to get selected text via clipboard
        ORIGINAL_CLIPBOARD=$(pbpaste)

        # Copy selected text
        osascript -e 'tell application "System Events" to keystroke "c" using command down' 2>/dev/null
        sleep 0.3

        INPUT=$(pbpaste)

        if [ -z "$INPUT" ]; then
            osascript -e 'display notification "No text selected" with title "LLM TTS"'
            # Restore clipboard
            echo -n "$ORIGINAL_CLIPBOARD" | pbcopy
            exit 1
        fi

        # Show notification
        osascript -e 'display notification "Speaking..." with title "LLM TTS"'

        # Speak the text
        python3 "$HOME/bin/llm-tts.py" "$INPUT"

        # Restore clipboard
        echo -n "$ORIGINAL_CLIPBOARD" | pbcopy

        osascript -e 'display notification "Done!" with title "LLM TTS"'
    fi
fi
