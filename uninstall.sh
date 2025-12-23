#!/bin/bash
# QuickLLM Uninstaller

echo "QuickLLM Uninstaller"
echo "======================"
echo ""

read -p "This will remove all QuickLLM scripts and workflows. Continue? (y/n) " -n 1 -r
echo

if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo ""
    echo "Stopping TTS server..."
    launchctl unload ~/Library/LaunchAgents/com.quickllm.tts-server.plist 2>/dev/null || true
    rm -f ~/Library/LaunchAgents/com.quickllm.tts-server.plist
    # Also clean up old naming if present
    launchctl unload ~/Library/LaunchAgents/com.llm-mac.tts-server.plist 2>/dev/null || true
    rm -f ~/Library/LaunchAgents/com.llm-mac.tts-server.plist
    pkill -f llm-tts-server.py 2>/dev/null || true
    echo "[OK] TTS server stopped"

    echo ""
    echo "Removing scripts from ~/bin/..."
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
    rm -f ~/bin/setup-workflows.sh
    rm -f ~/.llm-tts-server.pid
    echo "[OK] Scripts removed"

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
    echo "Refreshing services..."
    /System/Library/CoreServices/pbs -flush 2>/dev/null || true

    echo ""
    echo "[OK] Uninstall complete!"
    echo ""
fi
