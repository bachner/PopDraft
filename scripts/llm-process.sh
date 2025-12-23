#!/bin/bash
# LLM Text Processing Script using Ollama
# Usage: echo "selected text" | llm-process.sh "instruction"

INSTRUCTION="$1"
INPUT_TEXT=$(cat)

# Escape special characters for JSON
escape_json() {
    printf '%s' "$1" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))'
}

ESCAPED_TEXT=$(escape_json "$INPUT_TEXT")
ESCAPED_INSTRUCTION=$(escape_json "$INSTRUCTION")

# Build the prompt
PROMPT="$ESCAPED_INSTRUCTION

Text to process:
$ESCAPED_TEXT

Provide only the result without any explanation or markdown formatting."

# Remove outer quotes from escaped strings for embedding
PROMPT_CLEAN=$(echo "$INSTRUCTION

Text to process:
$INPUT_TEXT

Provide only the result without any explanation or markdown formatting." | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')

# Call Ollama API
RESPONSE=$(curl -s http://localhost:11434/api/generate \
    -H "Content-Type: application/json" \
    -d "{
        \"model\": \"qwen3-coder:480b-cloud\",
        \"prompt\": $PROMPT_CLEAN,
        \"stream\": false
    }" 2>/dev/null)

# Extract response text
echo "$RESPONSE" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    print(data.get('response', 'Error: No response from LLM'))
except:
    print('Error: Failed to parse LLM response')
"
