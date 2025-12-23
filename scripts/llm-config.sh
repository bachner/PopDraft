#!/bin/bash
# PopDraft Configuration Helper
# Provides functions for reading config and API abstraction

CONFIG_DIR="$HOME/.popdraft"
CONFIG_FILE="$CONFIG_DIR/config"

# Default values
DEFAULT_BACKEND="ollama"
DEFAULT_OLLAMA_URL="http://localhost:11434"
DEFAULT_LLAMACPP_URL="http://localhost:8080"
DEFAULT_MODEL="qwen2.5:7b"
DEFAULT_LLAMACPP_MODEL="$HOME/.popdraft/models/qwen2.5-7b-instruct-q4_k_m.gguf"

# Initialize config if it doesn't exist
init_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        mkdir -p "$CONFIG_DIR"
        cat > "$CONFIG_FILE" << EOF
# PopDraft Configuration
# Backend: ollama or llamacpp
BACKEND=ollama

# Ollama settings
OLLAMA_URL=http://localhost:11434
OLLAMA_MODEL=qwen2.5:7b

# llama.cpp settings
LLAMACPP_URL=http://localhost:8080
LLAMACPP_MODEL_PATH=$HOME/.popdraft/models/qwen2.5-7b-instruct-q4_k_m.gguf
EOF
    fi
}

# Load config
load_config() {
    init_config
    source "$CONFIG_FILE"

    # Set defaults if not defined
    BACKEND="${BACKEND:-$DEFAULT_BACKEND}"
    OLLAMA_URL="${OLLAMA_URL:-$DEFAULT_OLLAMA_URL}"
    LLAMACPP_URL="${LLAMACPP_URL:-$DEFAULT_LLAMACPP_URL}"
    OLLAMA_MODEL="${OLLAMA_MODEL:-$DEFAULT_MODEL}"
    LLAMACPP_MODEL_PATH="${LLAMACPP_MODEL_PATH:-$DEFAULT_LLAMACPP_MODEL}"
}

# Get API URL based on backend
get_api_url() {
    load_config
    if [ "$BACKEND" = "llamacpp" ]; then
        echo "$LLAMACPP_URL"
    else
        echo "$OLLAMA_URL"
    fi
}

# Get model name
get_model() {
    load_config
    echo "$OLLAMA_MODEL"
}

# Make a generate request (handles both backends with auto-fallback)
# Usage: llm_generate "prompt" [system_prompt]
llm_generate() {
    local prompt="$1"
    local system_prompt="$2"

    load_config

    # Auto-select available backend with fallback
    local active_backend=$(select_backend)
    if [ "$active_backend" = "none" ]; then
        echo "Error: No LLM backend available. Start llama-server or Ollama."
        return 1
    fi

    if [ "$active_backend" = "llamacpp" ]; then
        # llama.cpp server uses OpenAI-compatible API
        local messages="[]"
        if [ -n "$system_prompt" ]; then
            messages=$(python3 -c "
import json
msgs = [{'role': 'system', 'content': $(printf '%s' "$system_prompt" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')}]
msgs.append({'role': 'user', 'content': $(printf '%s' "$prompt" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')})
print(json.dumps(msgs))
")
        else
            messages=$(python3 -c "
import json
msgs = [{'role': 'user', 'content': $(printf '%s' "$prompt" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')}]
print(json.dumps(msgs))
")
        fi

        RESPONSE=$(curl -s "$LLAMACPP_URL/v1/chat/completions" \
            -H "Content-Type: application/json" \
            -d "{
                \"messages\": $messages,
                \"stream\": false,
                \"max_tokens\": 4096
            }" 2>/dev/null)

        echo "$RESPONSE" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    if 'choices' in data and len(data['choices']) > 0:
        content = data['choices'][0].get('message', {}).get('content', '')
        print(content)
    elif 'error' in data:
        print('Error: ' + data['error'].get('message', 'Unknown error'))
    else:
        print('Error: No response from LLM')
except Exception as e:
    print(f'Error: Failed to parse LLM response - {e}')
"
    else
        # Ollama API
        PROMPT_JSON=$(printf '%s' "$prompt" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')

        local body="{\"model\": \"$OLLAMA_MODEL\", \"prompt\": $PROMPT_JSON, \"stream\": false}"
        if [ -n "$system_prompt" ]; then
            SYSTEM_JSON=$(printf '%s' "$system_prompt" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')
            body="{\"model\": \"$OLLAMA_MODEL\", \"prompt\": $PROMPT_JSON, \"system\": $SYSTEM_JSON, \"stream\": false}"
        fi

        RESPONSE=$(curl -s "$OLLAMA_URL/api/generate" \
            -H "Content-Type: application/json" \
            -d "$body" 2>/dev/null)

        echo "$RESPONSE" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    response = data.get('response', '')
    # Clean up think tags if present
    if '</think>' in response:
        response = response.split('</think>')[-1].strip()
    print(response)
except:
    print('Error: Failed to parse LLM response')
"
    fi
}

# Make a chat request (handles both backends with auto-fallback)
# Usage: llm_chat "messages_json_file"
llm_chat() {
    local messages_file="$1"
    local messages_json=$(cat "$messages_file")

    load_config

    # Auto-select available backend with fallback
    local active_backend=$(select_backend)
    if [ "$active_backend" = "none" ]; then
        echo "Error: No LLM backend available. Start llama-server or Ollama."
        return 1
    fi

    if [ "$active_backend" = "llamacpp" ]; then
        # llama.cpp uses OpenAI-compatible API
        RESPONSE=$(curl -s "$LLAMACPP_URL/v1/chat/completions" \
            -H "Content-Type: application/json" \
            -d "{
                \"messages\": $messages_json,
                \"stream\": false,
                \"max_tokens\": 4096
            }" 2>/dev/null)

        echo "$RESPONSE" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    if 'choices' in data and len(data['choices']) > 0:
        content = data['choices'][0].get('message', {}).get('content', '')
        print(content)
    elif 'error' in data:
        print('Error: ' + data['error'].get('message', 'Unknown error'))
    else:
        print('Error: No response from LLM')
except Exception as e:
    print(f'Error: Failed to parse LLM response - {e}')
"
    else
        # Ollama chat API
        RESPONSE=$(curl -s "$OLLAMA_URL/api/chat" \
            -H "Content-Type: application/json" \
            -d "{
                \"model\": \"$OLLAMA_MODEL\",
                \"messages\": $messages_json,
                \"stream\": false
            }" 2>/dev/null)

        echo "$RESPONSE" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    msg = data.get('message', {})
    print(msg.get('content', 'Error: No response from LLM'))
except Exception as e:
    print(f'Error: Failed to parse LLM response - {e}')
"
    fi
}

# Check if a specific backend is available
check_backend_available() {
    local backend="$1"
    if [ "$backend" = "llamacpp" ]; then
        curl -s --max-time 2 "$LLAMACPP_URL/health" > /dev/null 2>&1
    else
        curl -s --max-time 2 "$OLLAMA_URL/api/tags" > /dev/null 2>&1
    fi
}

# Check if backend is available (returns "ok" or "error")
check_backend() {
    load_config
    if check_backend_available "$BACKEND"; then
        echo "ok"
    else
        echo "error"
    fi
}

# Select the best available backend (with fallback)
select_backend() {
    load_config

    # Try configured backend first
    if check_backend_available "$BACKEND"; then
        echo "$BACKEND"
        return 0
    fi

    # Fallback to the other backend
    if [ "$BACKEND" = "llamacpp" ]; then
        if check_backend_available "ollama"; then
            echo "ollama"
            return 0
        fi
    else
        if check_backend_available "llamacpp"; then
            echo "llamacpp"
            return 0
        fi
    fi

    # No backend available
    echo "none"
    return 1
}

# If script is run directly, show config
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    load_config
    echo "PopDraft Configuration:"
    echo "  Configured backend: $BACKEND"
    echo ""
    echo "Backend Status:"
    if check_backend_available "llamacpp"; then
        echo "  llama.cpp: OK ($LLAMACPP_URL)"
    else
        echo "  llama.cpp: not running"
    fi
    if check_backend_available "ollama"; then
        echo "  Ollama: OK ($OLLAMA_URL)"
    else
        echo "  Ollama: not running"
    fi
    echo ""
    active=$(select_backend)
    if [ "$active" = "none" ]; then
        echo "Active backend: NONE (no backend available!)"
    else
        echo "Active backend: $active"
        if [ "$active" != "$BACKEND" ]; then
            echo "  (fallback from $BACKEND)"
        fi
    fi
fi
