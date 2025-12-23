#!/bin/bash
# LLM Chat GUI using native macOS dialogs
# Usage: llm-chat-gui.sh [context_file]

export PATH="/usr/local/bin:/opt/homebrew/bin:$PATH"

CONTEXT_FILE="$1"
CONTEXT=""
MODEL="qwen3-coder:480b-cloud"

# Read context from file if provided
if [ -n "$CONTEXT_FILE" ] && [ -f "$CONTEXT_FILE" ]; then
    CONTEXT=$(cat "$CONTEXT_FILE")
    rm -f "$CONTEXT_FILE"
fi

# Initialize conversation history as JSON array
MESSAGES_FILE=$(mktemp /tmp/llm-chat-messages.XXXXXX)
echo '[]' > "$MESSAGES_FILE"

# Function to escape text for JSON
escape_json() {
    python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))' <<< "$1"
}

# Function to call LLM
call_llm() {
    local messages_json=$(cat "$MESSAGES_FILE")

    local response=$(curl -s http://localhost:11434/api/chat \
        -H "Content-Type: application/json" \
        -d "{
            \"model\": \"$MODEL\",
            \"messages\": $messages_json,
            \"stream\": false
        }" 2>/dev/null)

    echo "$response" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    msg = data.get('message', {})
    print(msg.get('content', 'Error: No response from LLM'))
except Exception as e:
    print(f'Error: {e}')
"
}

# Function to add message to history
add_message() {
    local role="$1"
    local content="$2"

    python3 << PYEOF
import json

with open("$MESSAGES_FILE", "r") as f:
    messages = json.load(f)

messages.append({"role": "$role", "content": $(escape_json "$content")})

with open("$MESSAGES_FILE", "w") as f:
    json.dump(messages, f)
PYEOF
}

# Show context and initialize conversation if context provided
DISPLAY_CONTEXT=""
if [ -n "$CONTEXT" ]; then
    # Truncate context for display
    if [ ${#CONTEXT} -gt 300 ]; then
        DISPLAY_CONTEXT="${CONTEXT:0:300}..."
    else
        DISPLAY_CONTEXT="$CONTEXT"
    fi

    # Add context to conversation
    add_message "user" "I'm sharing the following context with you. Please keep it in mind for our conversation:

$CONTEXT"
    add_message "assistant" "I've noted the context you shared. How can I help you with this?"
fi

# Chat loop
HISTORY=""
if [ -n "$DISPLAY_CONTEXT" ]; then
    HISTORY="[Context: $DISPLAY_CONTEXT]