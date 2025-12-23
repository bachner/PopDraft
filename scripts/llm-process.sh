#!/bin/bash
# LLM Text Processing Script
# Usage: echo "selected text" | llm-process.sh "instruction"
# Supports both Ollama and llama.cpp backends via config

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source the config helper
if [ -f "$SCRIPT_DIR/llm-config.sh" ]; then
    source "$SCRIPT_DIR/llm-config.sh"
elif [ -f "$HOME/bin/llm-config.sh" ]; then
    source "$HOME/bin/llm-config.sh"
else
    echo "Error: llm-config.sh not found"
    exit 1
fi

INSTRUCTION="$1"
INPUT_TEXT=$(cat)

# Build the prompt
PROMPT="$INSTRUCTION

Text to process:
$INPUT_TEXT

Provide only the result without any explanation or markdown formatting."

# Use the unified API
llm_generate "$PROMPT"
