#!/bin/bash
# LLM Interactive Chat Session
# Usage: llm-chat-session.sh <context_file>
# Runs an interactive chat with the LLM, keeping the initial context

export PATH="/usr/local/bin:/opt/homebrew/bin:$PATH"

CONTEXT_FILE="$1"
CONTEXT=""

if [ -n "$CONTEXT_FILE" ] && [ -f "$CONTEXT_FILE" ]; then
    CONTEXT=$(cat "$CONTEXT_FILE")
    rm -f "$CONTEXT_FILE"
fi

MODEL="qwen3-coder:480b-cloud"
MESSAGES_FILE=$(mktemp /tmp/llm-chat-messages.XXXXXX)

# Initialize messages array
echo '[]' > "$MESSAGES_FILE"

# Colors
BLUE='\033[0;34m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color
BOLD='\033[1m'

clear
echo -e "${BOLD}${BLUE}=== LLM Chat Session ===${NC}"
echo -e "${CYAN}Model: $MODEL${NC}"
echo -e "${CYAN}Type 'exit' or 'quit' to end the session${NC}"
echo -e "${CYAN}Type 'clear' to start a new conversation${NC}"
echo ""

# Add context as system message if provided
if [ -n "$CONTEXT" ]; then
    echo -e "${YELLOW}--- Context from selection ---${NC}"
    echo "$CONTEXT"
    echo -e "${YELLOW}------------------------------${NC}"
    echo ""

    # Add context as the first user message to establish context
    python3 << PYEOF
import json

messages = []
context_msg = {
    "role": "user",
    "content": "I'm sharing the following context with you. Please keep it in mind for our conversation:\n\n$CONTEXT"
}
messages.append(context_msg)

# Add assistant acknowledgment
ack_msg = {
    "role": "assistant",
    "content": "I've noted the context you shared. How can I help you with this?"
}
messages.append(ack_msg)

with open("$MESSAGES_FILE", "w") as f:
    json.dump(messages, f)
PYEOF

    echo -e "${GREEN}Assistant:${NC} I've noted the context you shared. How can I help you with this?"
    echo ""
fi

# Chat loop
while true; do
    echo -ne "${BOLD}${BLUE}You:${NC} "
    read -r USER_INPUT

    # Handle special commands
    if [ -z "$USER_INPUT" ]; then
        continue
    fi

    if [ "$USER_INPUT" = "exit" ] || [ "$USER_INPUT" = "quit" ]; then
        echo -e "${CYAN}Goodbye!${NC}"
        rm -f "$MESSAGES_FILE"
        exit 0
    fi

    if [ "$USER_INPUT" = "clear" ]; then
        echo '[]' > "$MESSAGES_FILE"
        clear
        echo -e "${BOLD}${BLUE}=== LLM Chat Session ===${NC}"
        echo -e "${CYAN}Conversation cleared. Starting fresh.${NC}"
        echo ""
        continue
    fi

    # Add user message to history
    python3 << PYEOF
import json

with open("$MESSAGES_FILE", "r") as f:
    messages = json.load(f)

messages.append({"role": "user", "content": $(printf '%s' "$USER_INPUT" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')})

with open("$MESSAGES_FILE", "w") as f:
    json.dump(messages, f)
PYEOF

    # Call Ollama chat API
    MESSAGES_JSON=$(cat "$MESSAGES_FILE")

    echo -ne "${GREEN}Assistant:${NC} "

    RESPONSE=$(curl -s http://localhost:11434/api/chat \
        -H "Content-Type: application/json" \
        -d "{
            \"model\": \"$MODEL\",
            \"messages\": $MESSAGES_JSON,
            \"stream\": false
        }" 2>/dev/null)

    # Extract and display response
    ASSISTANT_MSG=$(echo "$RESPONSE" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    msg = data.get('message', {})
    print(msg.get('content', 'Error: No response from LLM'))
except Exception as e:
    print(f'Error: Failed to parse LLM response - {e}')
")

    echo "$ASSISTANT_MSG"
    echo ""

    # Add assistant response to history
    python3 << PYEOF
import json

with open("$MESSAGES_FILE", "r") as f:
    messages = json.load(f)

messages.append({"role": "assistant", "content": $(printf '%s' "$ASSISTANT_MSG" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')})

with open("$MESSAGES_FILE", "w") as f:
    json.dump(messages, f)
PYEOF

done
