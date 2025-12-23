#!/bin/bash
export PATH="/usr/local/bin:/opt/homebrew/bin:$PATH"

INSTRUCTION=$(osascript -e 'display dialog "Enter your instruction:" default answer "" buttons {"Cancel", "OK"} default button "OK"' -e 'text returned of result' 2>/dev/null)

[ -z "$INSTRUCTION" ] && exit 0

~/bin/llm-clipboard.sh "$INSTRUCTION IMPORTANT: Always respond in the SAME LANGUAGE as the input text."
