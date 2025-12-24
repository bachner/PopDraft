#!/bin/bash
# PopDraft Uninstaller

echo "PopDraft Uninstaller"
echo "======================"
echo ""

read -p "This will remove PopDraft and all its data. Continue? (y/n) " -n 1 -r
echo

if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo ""
    echo "Stopping PopDraft..."

    # Kill running processes
    pkill -f PopDraft 2>/dev/null || true
    pkill -f llm-tts-server.py 2>/dev/null || true
    pkill -f "llama-server.*8080" 2>/dev/null || true

    # Remove LaunchAgents
    launchctl unload ~/Library/LaunchAgents/com.popdraft.app.plist 2>/dev/null || true
    launchctl unload ~/Library/LaunchAgents/com.popdraft.tts-server.plist 2>/dev/null || true
    launchctl unload ~/Library/LaunchAgents/com.popdraft.llama-server.plist 2>/dev/null || true
    rm -f ~/Library/LaunchAgents/com.popdraft.*.plist

    # Legacy cleanup
    launchctl unload ~/Library/LaunchAgents/com.llm-mac.tts-server.plist 2>/dev/null || true
    rm -f ~/Library/LaunchAgents/com.llm-mac.*.plist

    echo "[OK] Processes stopped"

    # Remove app from Applications
    if [ -d "/Applications/PopDraft.app" ]; then
        rm -rf "/Applications/PopDraft.app"
        echo "[OK] Removed /Applications/PopDraft.app"
    fi

    # Remove legacy scripts from ~/bin
    echo ""
    echo "Cleaning up legacy files..."
    rm -f ~/bin/llm-*.sh ~/bin/llm-*.py 2>/dev/null || true
    rm -f ~/bin/LLMChat ~/bin/LLMChat.swift 2>/dev/null || true
    rm -f ~/bin/PopDraft ~/bin/PopDraftApp 2>/dev/null || true
    rm -f ~/bin/setup-workflows.sh 2>/dev/null || true
    rm -f ~/.llm-tts-server.pid 2>/dev/null || true

    # Remove legacy workflows
    rm -rf ~/Library/Services/LLM*.workflow 2>/dev/null || true
    echo "[OK] Legacy files removed"

    # Config directory
    echo ""
    read -p "Remove configuration and models (~/.popdraft)? (y/n) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        rm -rf ~/.popdraft
        echo "[OK] Configuration removed"
    else
        echo "[SKIP] Configuration preserved at ~/.popdraft"
    fi

    echo ""
    echo "[OK] Uninstall complete!"
    echo ""
fi
