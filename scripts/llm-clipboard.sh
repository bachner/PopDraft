#!/bin/bash
# LLM Clipboard Processor
# Usage: llm-clipboard.sh "instruction"
# Copies selected text, processes with LLM, appends result after selection
# Preserves original clipboard content

INSTRUCTION="$1"
export PATH="/usr/local/bin:/opt/homebrew/bin:$PATH"

# Save original clipboard content
ORIGINAL_CLIPBOARD=$(pbpaste)

# Copy selected text
osascript -e 'tell application "System Events" to keystroke "c" using command down'
sleep 0.3

# Get text from clipboard
INPUT=$(pbpaste)

if [ -z "$INPUT" ]; then
    osascript -e 'display notification "No text selected" with title "LLM Process"'
    # Restore clipboard
    echo -n "$ORIGINAL_CLIPBOARD" | pbcopy
    exit 1
fi

# Show processing notification
osascript -e 'display notification "Processing..." with title "LLM Process"'

# Process with LLM
RESULT=$("$HOME/bin/llm-process.sh" "$INSTRUCTION" <<< "$INPUT")

# Put only the appended part in clipboard temporarily
echo "

---
$RESULT" | pbcopy

# Move to end of selection (right arrow) and paste
osascript -e 'tell application "System Events"
    key code 124  -- right arrow to deselect and move to end
    keystroke "v" using command down  -- paste
end tell'

sleep 0.2

# Restore original clipboard content
echo -n "$ORIGINAL_CLIPBOARD" | pbcopy

# Show done notification
osascript -e 'display notification "Done!" with title "LLM Process"'
