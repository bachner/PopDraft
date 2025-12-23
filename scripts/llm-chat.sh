#!/bin/bash
# LLM Interactive Chat Launcher (Native Mac App)
# Usage: llm-chat.sh (called via keyboard shortcut)
# Captures selected text and opens native chat window

export PATH="/usr/local/bin:/opt/homebrew/bin:$PATH"

# Save original clipboard content
ORIGINAL_CLIPBOARD=$(pbpaste)

# Copy selected text
osascript -e 'tell application "System Events" to keystroke "c" using command down'
sleep 0.3

# Get text from clipboard
CONTEXT=$(pbpaste)

# Restore original clipboard
echo -n "$ORIGINAL_CLIPBOARD" | pbcopy

# Create a temp file to pass context to the chat app
CONTEXT_FILE=$(mktemp /tmp/llm-chat-context.XXXXXX)
echo "$CONTEXT" > "$CONTEXT_FILE"

# Launch native chat app
"$HOME/bin/LLMChat" "$CONTEXT_FILE" &
