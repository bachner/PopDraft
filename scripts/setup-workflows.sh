#!/bin/bash
# Setup Automator Quick Action workflows for LLM Mac
# Creates .workflow bundles in ~/Library/Services/

set -e

SERVICES_DIR="$HOME/Library/Services"
mkdir -p "$SERVICES_DIR"

# Function to create a workflow that runs a shell script and outputs text
create_text_workflow() {
    local NAME="$1"
    local SCRIPT="$2"
    local WORKFLOW_DIR="$SERVICES_DIR/$NAME.workflow"

    # Escape XML special characters in script
    SCRIPT=$(echo "$SCRIPT" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')

    # Remove existing workflow
    rm -rf "$WORKFLOW_DIR"

    # Create workflow structure
    mkdir -p "$WORKFLOW_DIR/Contents/QuickLook"

    # Create Info.plist
    cat > "$WORKFLOW_DIR/Contents/Info.plist" << 'INFOPLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>NSServices</key>
    <array>
        <dict>
            <key>NSBackgroundColorName</key>
            <string>background</string>
            <key>NSIconName</key>
            <string>NSActionTemplate</string>
            <key>NSMenuItem</key>
            <dict>
                <key>default</key>
                <string>WORKFLOW_NAME</string>
            </dict>
            <key>NSMessage</key>
            <string>runWorkflowAsService</string>
            <key>NSReturnTypes</key>
            <array>
                <string>public.utf8-plain-text</string>
            </array>
            <key>NSSendTypes</key>
            <array>
                <string>public.utf8-plain-text</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
INFOPLIST

    # Replace placeholder with actual name
    sed -i '' "s/WORKFLOW_NAME/$NAME/g" "$WORKFLOW_DIR/Contents/Info.plist"

    # Create document.wflow
    cat > "$WORKFLOW_DIR/Contents/document.wflow" << WFLOWEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>AMApplicationBuild</key>
    <string>533</string>
    <key>AMApplicationVersion</key>
    <string>2.10</string>
    <key>AMDocumentVersion</key>
    <string>2</string>
    <key>actions</key>
    <array>
        <dict>
            <key>action</key>
            <dict>
                <key>AMAccepts</key>
                <dict>
                    <key>Container</key>
                    <string>List</string>
                    <key>Optional</key>
                    <true/>
                    <key>Types</key>
                    <array>
                        <string>com.apple.cocoa.string</string>
                    </array>
                </dict>
                <key>AMActionVersion</key>
                <string>2.0.3</string>
                <key>AMApplication</key>
                <array>
                    <string>Automator</string>
                </array>
                <key>AMParameterProperties</key>
                <dict>
                    <key>COMMAND_STRING</key>
                    <dict/>
                    <key>CheckedForUserDefaultShell</key>
                    <dict/>
                    <key>inputMethod</key>
                    <dict/>
                    <key>shell</key>
                    <dict/>
                    <key>source</key>
                    <dict/>
                </dict>
                <key>AMProvides</key>
                <dict>
                    <key>Container</key>
                    <string>List</string>
                    <key>Types</key>
                    <array>
                        <string>com.apple.cocoa.string</string>
                    </array>
                </dict>
                <key>ActionBundlePath</key>
                <string>/System/Library/Automator/Run Shell Script.action</string>
                <key>ActionName</key>
                <string>Run Shell Script</string>
                <key>ActionParameters</key>
                <dict>
                    <key>COMMAND_STRING</key>
                    <string>$SCRIPT</string>
                    <key>CheckedForUserDefaultShell</key>
                    <true/>
                    <key>inputMethod</key>
                    <integer>0</integer>
                    <key>shell</key>
                    <string>/bin/bash</string>
                    <key>source</key>
                    <string></string>
                </dict>
                <key>BundleIdentifier</key>
                <string>com.apple.RunShellScript</string>
                <key>CFBundleVersion</key>
                <string>2.0.3</string>
                <key>CanShowSelectedItemsWhenRun</key>
                <false/>
                <key>CanShowWhenRun</key>
                <true/>
                <key>Category</key>
                <array>
                    <string>AMCategoryUtilities</string>
                </array>
                <key>Class Name</key>
                <string>RunShellScriptAction</string>
                <key>InputUUID</key>
                <string>$(uuidgen)</string>
                <key>Keywords</key>
                <array>
                    <string>Shell</string>
                    <string>Script</string>
                    <string>Command</string>
                    <string>Run</string>
                    <string>Unix</string>
                </array>
                <key>OutputUUID</key>
                <string>$(uuidgen)</string>
                <key>UUID</key>
                <string>$(uuidgen)</string>
                <key>UnlocalizedApplications</key>
                <array>
                    <string>Automator</string>
                </array>
                <key>arguments</key>
                <dict>
                    <key>0</key>
                    <dict>
                        <key>default value</key>
                        <integer>0</integer>
                        <key>name</key>
                        <string>inputMethod</string>
                        <key>required</key>
                        <string>0</string>
                        <key>type</key>
                        <string>0</string>
                        <key>uuid</key>
                        <string>0</string>
                    </dict>
                    <key>1</key>
                    <dict>
                        <key>default value</key>
                        <false/>
                        <key>name</key>
                        <string>CheckedForUserDefaultShell</string>
                        <key>required</key>
                        <string>0</string>
                        <key>type</key>
                        <string>0</string>
                        <key>uuid</key>
                        <string>1</string>
                    </dict>
                    <key>2</key>
                    <dict>
                        <key>default value</key>
                        <string></string>
                        <key>name</key>
                        <string>source</string>
                        <key>required</key>
                        <string>0</string>
                        <key>type</key>
                        <string>0</string>
                        <key>uuid</key>
                        <string>2</string>
                    </dict>
                    <key>3</key>
                    <dict>
                        <key>default value</key>
                        <string></string>
                        <key>name</key>
                        <string>COMMAND_STRING</string>
                        <key>required</key>
                        <string>0</string>
                        <key>type</key>
                        <string>0</string>
                        <key>uuid</key>
                        <string>3</string>
                    </dict>
                    <key>4</key>
                    <dict>
                        <key>default value</key>
                        <string>/bin/sh</string>
                        <key>name</key>
                        <string>shell</string>
                        <key>required</key>
                        <string>0</string>
                        <key>type</key>
                        <string>0</string>
                        <key>uuid</key>
                        <string>4</string>
                    </dict>
                </dict>
                <key>conversionLabel</key>
                <integer>0</integer>
                <key>isViewVisible</key>
                <integer>1</integer>
                <key>location</key>
                <string>309.000000:305.000000</string>
                <key>nibPath</key>
                <string>/System/Library/Automator/Run Shell Script.action/Contents/Resources/Base.lproj/main.nib</string>
            </dict>
            <key>isViewVisible</key>
            <integer>1</integer>
        </dict>
    </array>
    <key>connectors</key>
    <dict/>
    <key>workflowMetaData</key>
    <dict>
        <key>applicationBundleIDsByPath</key>
        <dict/>
        <key>applicationPaths</key>
        <array/>
        <key>inputTypeIdentifier</key>
        <string>com.apple.Automator.text</string>
        <key>outputTypeIdentifier</key>
        <string>com.apple.Automator.text</string>
        <key>presentationMode</key>
        <integer>11</integer>
        <key>processesInput</key>
        <integer>0</integer>
        <key>serviceInputTypeIdentifier</key>
        <string>com.apple.Automator.text</string>
        <key>serviceOutputTypeIdentifier</key>
        <string>com.apple.Automator.text</string>
        <key>serviceProcessesInput</key>
        <integer>0</integer>
        <key>systemImageName</key>
        <string>NSActionTemplate</string>
        <key>useAutomaticInputType</key>
        <true/>
        <key>workflowTypeIdentifier</key>
        <string>com.apple.Automator.servicesMenu</string>
    </dict>
</dict>
</plist>
WFLOWEOF

    echo "  Created: $NAME"
}

# Function to create a workflow that runs a script without text output (for chat)
create_launcher_workflow() {
    local NAME="$1"
    local SCRIPT="$2"
    local WORKFLOW_DIR="$SERVICES_DIR/$NAME.workflow"

    # Escape XML special characters in script
    SCRIPT=$(echo "$SCRIPT" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')

    # Remove existing workflow
    rm -rf "$WORKFLOW_DIR"

    # Create workflow structure
    mkdir -p "$WORKFLOW_DIR/Contents/QuickLook"

    # Create Info.plist - no return types for launcher
    cat > "$WORKFLOW_DIR/Contents/Info.plist" << 'INFOPLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>NSServices</key>
    <array>
        <dict>
            <key>NSBackgroundColorName</key>
            <string>background</string>
            <key>NSIconName</key>
            <string>NSActionTemplate</string>
            <key>NSMenuItem</key>
            <dict>
                <key>default</key>
                <string>WORKFLOW_NAME</string>
            </dict>
            <key>NSMessage</key>
            <string>runWorkflowAsService</string>
            <key>NSSendTypes</key>
            <array>
                <string>public.utf8-plain-text</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
INFOPLIST

    # Replace placeholder with actual name
    sed -i '' "s/WORKFLOW_NAME/$NAME/g" "$WORKFLOW_DIR/Contents/Info.plist"

    # Create document.wflow - no output for launcher
    cat > "$WORKFLOW_DIR/Contents/document.wflow" << WFLOWEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>AMApplicationBuild</key>
    <string>533</string>
    <key>AMApplicationVersion</key>
    <string>2.10</string>
    <key>AMDocumentVersion</key>
    <string>2</string>
    <key>actions</key>
    <array>
        <dict>
            <key>action</key>
            <dict>
                <key>AMAccepts</key>
                <dict>
                    <key>Container</key>
                    <string>List</string>
                    <key>Optional</key>
                    <true/>
                    <key>Types</key>
                    <array>
                        <string>com.apple.cocoa.string</string>
                    </array>
                </dict>
                <key>AMActionVersion</key>
                <string>2.0.3</string>
                <key>AMApplication</key>
                <array>
                    <string>Automator</string>
                </array>
                <key>AMParameterProperties</key>
                <dict>
                    <key>COMMAND_STRING</key>
                    <dict/>
                    <key>CheckedForUserDefaultShell</key>
                    <dict/>
                    <key>inputMethod</key>
                    <dict/>
                    <key>shell</key>
                    <dict/>
                    <key>source</key>
                    <dict/>
                </dict>
                <key>AMProvides</key>
                <dict>
                    <key>Container</key>
                    <string>List</string>
                    <key>Types</key>
                    <array>
                        <string>com.apple.cocoa.string</string>
                    </array>
                </dict>
                <key>ActionBundlePath</key>
                <string>/System/Library/Automator/Run Shell Script.action</string>
                <key>ActionName</key>
                <string>Run Shell Script</string>
                <key>ActionParameters</key>
                <dict>
                    <key>COMMAND_STRING</key>
                    <string>$SCRIPT</string>
                    <key>CheckedForUserDefaultShell</key>
                    <true/>
                    <key>inputMethod</key>
                    <integer>0</integer>
                    <key>shell</key>
                    <string>/bin/bash</string>
                    <key>source</key>
                    <string></string>
                </dict>
                <key>BundleIdentifier</key>
                <string>com.apple.RunShellScript</string>
                <key>CFBundleVersion</key>
                <string>2.0.3</string>
                <key>CanShowSelectedItemsWhenRun</key>
                <false/>
                <key>CanShowWhenRun</key>
                <true/>
                <key>Category</key>
                <array>
                    <string>AMCategoryUtilities</string>
                </array>
                <key>Class Name</key>
                <string>RunShellScriptAction</string>
                <key>InputUUID</key>
                <string>$(uuidgen)</string>
                <key>Keywords</key>
                <array>
                    <string>Shell</string>
                    <string>Script</string>
                    <string>Command</string>
                    <string>Run</string>
                    <string>Unix</string>
                </array>
                <key>OutputUUID</key>
                <string>$(uuidgen)</string>
                <key>UUID</key>
                <string>$(uuidgen)</string>
                <key>UnlocalizedApplications</key>
                <array>
                    <string>Automator</string>
                </array>
                <key>arguments</key>
                <dict>
                    <key>0</key>
                    <dict>
                        <key>default value</key>
                        <integer>0</integer>
                        <key>name</key>
                        <string>inputMethod</string>
                        <key>required</key>
                        <string>0</string>
                        <key>type</key>
                        <string>0</string>
                        <key>uuid</key>
                        <string>0</string>
                    </dict>
                    <key>1</key>
                    <dict>
                        <key>default value</key>
                        <false/>
                        <key>name</key>
                        <string>CheckedForUserDefaultShell</string>
                        <key>required</key>
                        <string>0</string>
                        <key>type</key>
                        <string>0</string>
                        <key>uuid</key>
                        <string>1</string>
                    </dict>
                    <key>2</key>
                    <dict>
                        <key>default value</key>
                        <string></string>
                        <key>name</key>
                        <string>source</string>
                        <key>required</key>
                        <string>0</string>
                        <key>type</key>
                        <string>0</string>
                        <key>uuid</key>
                        <string>2</string>
                    </dict>
                    <key>3</key>
                    <dict>
                        <key>default value</key>
                        <string></string>
                        <key>name</key>
                        <string>COMMAND_STRING</string>
                        <key>required</key>
                        <string>0</string>
                        <key>type</key>
                        <string>0</string>
                        <key>uuid</key>
                        <string>3</string>
                    </dict>
                    <key>4</key>
                    <dict>
                        <key>default value</key>
                        <string>/bin/sh</string>
                        <key>name</key>
                        <string>shell</string>
                        <key>required</key>
                        <string>0</string>
                        <key>type</key>
                        <string>0</string>
                        <key>uuid</key>
                        <string>4</string>
                    </dict>
                </dict>
                <key>conversionLabel</key>
                <integer>0</integer>
                <key>isViewVisible</key>
                <integer>1</integer>
                <key>location</key>
                <string>309.000000:305.000000</string>
                <key>nibPath</key>
                <string>/System/Library/Automator/Run Shell Script.action/Contents/Resources/Base.lproj/main.nib</string>
            </dict>
            <key>isViewVisible</key>
            <integer>1</integer>
        </dict>
    </array>
    <key>connectors</key>
    <dict/>
    <key>workflowMetaData</key>
    <dict>
        <key>applicationBundleIDsByPath</key>
        <dict/>
        <key>applicationPaths</key>
        <array/>
        <key>inputTypeIdentifier</key>
        <string>com.apple.Automator.text</string>
        <key>outputTypeIdentifier</key>
        <string>com.apple.Automator.nothing</string>
        <key>presentationMode</key>
        <integer>11</integer>
        <key>processesInput</key>
        <integer>0</integer>
        <key>serviceInputTypeIdentifier</key>
        <string>com.apple.Automator.text</string>
        <key>serviceOutputTypeIdentifier</key>
        <string>com.apple.Automator.nothing</string>
        <key>serviceProcessesInput</key>
        <integer>0</integer>
        <key>systemImageName</key>
        <string>NSActionTemplate</string>
        <key>useAutomaticInputType</key>
        <true/>
        <key>workflowTypeIdentifier</key>
        <string>com.apple.Automator.servicesMenu</string>
    </dict>
</dict>
</plist>
WFLOWEOF

    echo "  Created: $NAME"
}

echo "Creating LLM Mac Quick Action workflows..."
echo ""

# Grammar Check
GRAMMAR_SCRIPT='INPUT=$(cat)
export PATH="/usr/local/bin:/opt/homebrew/bin:$PATH"
RESULT=$("$HOME/bin/llm-process.sh" "Help me write this message better. Keep the same language and tone - only fix grammar mistakes, spelling errors, and typos. Return only the corrected text without any explanations." <<< "$INPUT")
echo "$INPUT"
echo ""
echo "---"
echo "[Grammar Check]"
echo "$RESULT"'
create_text_workflow "LLM Grammar Check" "$GRAMMAR_SCRIPT"

# Articulate
ARTICULATE_SCRIPT='INPUT=$(cat)
export PATH="/usr/local/bin:/opt/homebrew/bin:$PATH"
RESULT=$("$HOME/bin/llm-process.sh" "Help articulate this text more clearly and professionally. Improve the flow, clarity, and expression while preserving the original meaning and intent. IMPORTANT: Always respond in the SAME LANGUAGE as the input text. Return only the improved text without any explanations." <<< "$INPUT")
echo "$INPUT"
echo ""
echo "---"
echo "[Articulated]"
echo "$RESULT"'
create_text_workflow "LLM Articulate" "$ARTICULATE_SCRIPT"

# Craft Answer
ANSWER_SCRIPT='INPUT=$(cat)
export PATH="/usr/local/bin:/opt/homebrew/bin:$PATH"
RESULT=$("$HOME/bin/llm-process.sh" "Read the following text and craft a thoughtful, appropriate response to it. Match the tone and formality of the original message. IMPORTANT: Always respond in the SAME LANGUAGE as the input text. Return only the response without any explanations." <<< "$INPUT")
echo "$INPUT"
echo ""
echo "---"
echo "[Response]"
echo "$RESULT"'
create_text_workflow "LLM Craft Answer" "$ANSWER_SCRIPT"

# Custom Prompt
CUSTOM_SCRIPT='INPUT=$(cat)
export PATH="/usr/local/bin:/opt/homebrew/bin:$PATH"

# Get custom instruction from user
INSTRUCTION=$(osascript -e '\''display dialog "Enter your instruction for the LLM:" default answer "" buttons {"Cancel", "OK"} default button "OK" with title "LLM Custom Prompt"'\'' -e '\''text returned of result'\'' 2>/dev/null)

if [ -z "$INSTRUCTION" ]; then
    echo "$INPUT"
    exit 0
fi

RESULT=$("$HOME/bin/llm-process.sh" "$INSTRUCTION IMPORTANT: Always respond in the SAME LANGUAGE as the input text." <<< "$INPUT")
echo "$INPUT"
echo ""
echo "---"
echo "[Custom: $INSTRUCTION]"
echo "$RESULT"'
create_text_workflow "LLM Custom Prompt" "$CUSTOM_SCRIPT"

# Chat with Context - launches native Mac app
# Launcher workflow - reads from clipboard since stdin unreliable across apps
CHAT_SCRIPT='export PATH="/usr/local/bin:/opt/homebrew/bin:$PATH"

# Kill any existing LLMChat FIRST (before cat blocks waiting for stdin)
pkill -9 -x LLMChat 2>/dev/null

# Try stdin first, fallback to clipboard
INPUT=$(cat)
if [ -z "$(echo "$INPUT" | tr -d "[:space:]")" ]; then
    INPUT=$(pbpaste)
fi

# Save context to temp file
CONTEXT_FILE=$(mktemp /tmp/llm-chat-context.XXXXXX)
printf "%s" "$INPUT" > "$CONTEXT_FILE"

# Small delay to ensure old process is gone
sleep 0.2

# Launch native chat app
"$HOME/bin/LLMChat" "$CONTEXT_FILE" &'
create_launcher_workflow "LLM Chat" "$CHAT_SCRIPT"

# Text-to-Speech - speaks selected text using Kokoro-82M
TTS_SCRIPT='INPUT=$(cat)

if [ -z "$INPUT" ]; then
    osascript -e '\''display notification "No text selected" with title "LLM TTS"'\''
    exit 0
fi

osascript -e '\''display notification "Speaking..." with title "LLM TTS"'\''

# Call TTS server directly via POST (no special characters needed)
curl -s -X POST --data-binary "$INPUT" "http://127.0.0.1:7865/speak"

osascript -e '\''display notification "Done!" with title "LLM TTS"'\'''
create_launcher_workflow "LLM Speak" "$TTS_SCRIPT"

echo ""
echo "Workflows created successfully!"
echo ""

# Refresh services
echo "Refreshing services..."
/System/Library/CoreServices/pbs -flush 2>/dev/null || true
killall -HUP Finder 2>/dev/null || true

echo ""
echo "Setting up keyboard shortcuts..."

# Configure keyboard shortcuts for services
# Key equivalents: ~ = Option, ^ = Ctrl, $ = Shift, @ = Cmd
# Example: ~^g = Ctrl+Option+G

# First, disable any old conflicting shortcuts
defaults write pbs NSServicesStatus -dict-add \
    '"(null) - Custom LLM Prompt - runWorkflowAsService"' \
    '{ "enabled" = 0; "key_equivalent" = ""; }' 2>/dev/null || true

defaults write pbs NSServicesStatus -dict-add \
    '"(null) - Grammar Check - runWorkflowAsService"' \
    '{ "enabled" = 0; "key_equivalent" = ""; }' 2>/dev/null || true

defaults write pbs NSServicesStatus -dict-add \
    '"(null) - Articulate - runWorkflowAsService"' \
    '{ "enabled" = 0; "key_equivalent" = ""; }' 2>/dev/null || true

defaults write pbs NSServicesStatus -dict-add \
    '"(null) - Craft an Answer - runWorkflowAsService"' \
    '{ "enabled" = 0; "key_equivalent" = ""; }' 2>/dev/null || true

# Also disable any Shortcuts app shortcuts that might conflict
# (They use UUIDs so we search for common ones with our key bindings)
for uuid in $(defaults read pbs NSServicesStatus 2>/dev/null | grep -B5 '"~\^[galcp]"' | grep "runShortcutAsService" | sed 's/.*"\(.*\) - runShortcutAsService.*/\1/' | grep -E '^[A-F0-9-]+$'); do
    defaults write pbs NSServicesStatus -dict-add \
        "\"(null) - $uuid - runShortcutAsService\"" \
        '{ "enabled" = 0; "key_equivalent" = ""; }' 2>/dev/null || true
done

# Set keyboard shortcuts using defaults
defaults write pbs NSServicesStatus -dict-add \
    '"(null) - LLM Grammar Check - runWorkflowAsService"' \
    '{ "enabled" = 1; "key_equivalent" = "~^g"; }'

defaults write pbs NSServicesStatus -dict-add \
    '"(null) - LLM Articulate - runWorkflowAsService"' \
    '{ "enabled" = 1; "key_equivalent" = "~^a"; }'

defaults write pbs NSServicesStatus -dict-add \
    '"(null) - LLM Craft Answer - runWorkflowAsService"' \
    '{ "enabled" = 1; "key_equivalent" = "~^c"; }'

defaults write pbs NSServicesStatus -dict-add \
    '"(null) - LLM Custom Prompt - runWorkflowAsService"' \
    '{ "enabled" = 1; "key_equivalent" = "~^p"; }'

defaults write pbs NSServicesStatus -dict-add \
    '"(null) - LLM Chat - runWorkflowAsService"' \
    '{ "enabled" = 1; "key_equivalent" = "~^l"; }'

defaults write pbs NSServicesStatus -dict-add \
    '"(null) - LLM Speak - runWorkflowAsService"' \
    '{ "enabled" = 1; "key_equivalent" = "~^s"; }'

echo "[OK] Keyboard shortcuts configured"

echo ""
echo "Quick Actions are now available in the Services menu."
echo ""
echo "Keyboard shortcuts assigned:"
echo "  LLM Grammar Check  -> Ctrl+Option+G"
echo "  LLM Articulate     -> Ctrl+Option+A"
echo "  LLM Craft Answer   -> Ctrl+Option+C"
echo "  LLM Custom Prompt  -> Ctrl+Option+P"
echo "  LLM Chat           -> Ctrl+Option+L"
echo "  LLM Speak (TTS)    -> Ctrl+Option+S"
echo ""
echo "You can customize these in: System Settings > Keyboard > Keyboard Shortcuts > Services"
echo ""
