#!/bin/bash
# PopDraft Uninstaller

echo "PopDraft Uninstaller"
echo "======================"
echo ""

read -p "This will remove all PopDraft scripts and workflows. Continue? (y/n) " -n 1 -r
echo

if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo ""
    echo "Stopping services..."

    # TTS server
    launchctl unload ~/Library/LaunchAgents/com.popdraft.tts-server.plist 2>/dev/null || true
    rm -f ~/Library/LaunchAgents/com.popdraft.tts-server.plist
    launchctl unload ~/Library/LaunchAgents/com.llm-mac.tts-server.plist 2>/dev/null || true
    rm -f ~/Library/LaunchAgents/com.llm-mac.tts-server.plist
    pkill -f llm-tts-server.py 2>/dev/null || true

    # llama.cpp server
    launchctl unload ~/Library/LaunchAgents/com.popdraft.llama-server.plist 2>/dev/null || true
    rm -f ~/Library/LaunchAgents/com.popdraft.llama-server.plist
    pkill -f "llama-server.*8080" 2>/dev/null || true

    # Popup app (PopDraft)
    launchctl unload ~/Library/LaunchAgents/com.popdraft.app.plist 2>/dev/null || true
    rm -f ~/Library/LaunchAgents/com.popdraft.app.plist
    launchctl unload ~/Library/LaunchAgents/com.popdraft.app.plist 2>/dev/null || true
    rm -f ~/Library/LaunchAgents/com.popdraft.app.plist
    pkill -f PopDraft 2>/dev/null || true
    pkill -f PopDraftApp 2>/dev/null || true
    echo "[OK] Services stopped"

    echo ""
    echo "Removing scripts and apps from ~/bin/..."
    rm -f ~/bin/llm-config.sh
    rm -f ~/bin/llm-process.sh
    rm -f ~/bin/llm-clipboard.sh
    rm -f ~/bin/llm-grammar.sh
    rm -f ~/bin/llm-articulate.sh
    rm -f ~/bin/llm-answer.sh
    rm -f ~/bin/llm-custom.sh
    rm -f ~/bin/llm-chat.sh
    rm -f ~/bin/llm-chat-session.sh
    rm -f ~/bin/llm-tts.py
    rm -f ~/bin/llm-tts.sh
    rm -f ~/bin/llm-tts-server.py
    rm -f ~/bin/LLMChat
    rm -f ~/bin/LLMChat.swift
    rm -f ~/bin/PopDraft
    rm -f ~/bin/PopDraftApp
    rm -f ~/bin/setup-workflows.sh
    rm -f ~/.llm-tts-server.pid
    echo "[OK] Scripts and apps removed"

    echo ""
    echo "Removing Quick Action workflows..."
    rm -rf ~/Library/Services/LLM\ Grammar\ Check.workflow
    rm -rf ~/Library/Services/LLM\ Articulate.workflow
    rm -rf ~/Library/Services/LLM\ Craft\ Answer.workflow
    rm -rf ~/Library/Services/LLM\ Custom\ Prompt.workflow
    rm -rf ~/Library/Services/LLM\ Chat.workflow
    rm -rf ~/Library/Services/LLM\ Speak.workflow
    echo "[OK] Workflows removed"

    echo ""
    read -p "Remove configuration and models (~/.popdraft)? (y/n) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        rm -rf ~/.popdraft
        echo "[OK] Configuration and models removed"
    else
        echo "[SKIP] Configuration preserved at ~/.popdraft"
    fi

    echo ""
    echo "Refreshing services..."
    /System/Library/CoreServices/pbs -flush 2>/dev/null || true

    echo ""
    echo "[OK] Uninstall complete!"
    echo ""
fi
