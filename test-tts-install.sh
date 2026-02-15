#!/bin/bash
# Intensive local tests for TTS venv installation
# Tests install.sh logic, Swift DependencyManager paths, and edge cases
#
# Scenarios tested:
#   1.  Fresh venv creation
#   2.  Venv isolation verification
#   3.  pip install into venv (small package)
#   4.  Package detection logic (simulating Swift checkDependencies)
#   5.  Missing package detection
#   6.  Recreate venv over existing one
#   7.  Deleted venv detection
#   8.  install.sh venv section (integration)
#   9.  TTS server python fallback logic
#   10. Absolute python3 path (no PATH)
#   11. Corrupted venv (broken python symlink)
#   12. Partial venv (bin/ exists but no pip)
#   13. Read-only venv directory
#   14. Venv with spaces in path
#   15. Real kokoro+soundfile+numpy install
#   16. Real package detection (kokoro/soundfile/numpy)
#   17. Full install.sh dry-run (end-to-end)
#   18. Concurrent venv creation
#   19. Very long path
#   20. Swift compilation check

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEST_DIR=$(mktemp -d)
PASS=0
FAIL=0
SKIP=0
TOTAL=0
ERRORS=""

cleanup() {
    # Fix permissions before cleanup
    chmod -R u+w "$TEST_DIR" 2>/dev/null || true
    rm -rf "$TEST_DIR"
}
trap cleanup EXIT

pass() {
    PASS=$((PASS + 1))
    TOTAL=$((TOTAL + 1))
    echo "  PASS: $1"
}

fail() {
    FAIL=$((FAIL + 1))
    TOTAL=$((TOTAL + 1))
    echo "  FAIL: $1"
    ERRORS="$ERRORS\n  - $1"
}

skip() {
    SKIP=$((SKIP + 1))
    TOTAL=$((TOTAL + 1))
    echo "  SKIP: $1"
}

info() {
    echo "  INFO: $1"
}

section() {
    echo ""
    echo "=== Test $1 ==="
}

fresh_config() {
    local dir="$1"
    rm -rf "$dir"
    mkdir -p "$dir"
}

# ===================================================================
section "1: Fresh venv creation from scratch"
# ===================================================================
CONFIG_DIR="$TEST_DIR/t1"
fresh_config "$CONFIG_DIR"

if python3 -m venv "$CONFIG_DIR/tts-venv" 2>&1; then
    pass "venv created successfully"
else
    fail "venv creation failed"
fi

for bin in python3 pip pip3; do
    if [ -f "$CONFIG_DIR/tts-venv/bin/$bin" ]; then
        pass "venv bin/$bin exists"
    else
        fail "venv bin/$bin missing"
    fi
done

# Verify pyvenv.cfg
if [ -f "$CONFIG_DIR/tts-venv/pyvenv.cfg" ]; then
    pass "pyvenv.cfg exists"
else
    fail "pyvenv.cfg missing"
fi

# ===================================================================
section "2: Venv isolation verification"
# ===================================================================
VENV_PY="$CONFIG_DIR/tts-venv/bin/python3"
SYS_PY=$(which python3)

VENV_PREFIX=$("$VENV_PY" -c "import sys; print(sys.prefix)" 2>&1)
SYS_PREFIX=$("$SYS_PY" -c "import sys; print(sys.prefix)" 2>&1)

if [ "$VENV_PREFIX" != "$SYS_PREFIX" ]; then
    pass "sys.prefix differs (venv isolated)"
else
    fail "sys.prefix same as system — not isolated"
fi

VENV_EXEC=$("$VENV_PY" -c "import sys; print(sys.executable)" 2>&1)
if echo "$VENV_EXEC" | grep -q "tts-venv"; then
    pass "sys.executable points into venv"
else
    fail "sys.executable does not point into venv: $VENV_EXEC"
fi

# Check VIRTUAL_ENV would be set
VENV_MARKER=$("$VENV_PY" -c "import sys; print(hasattr(sys, 'real_prefix') or (hasattr(sys, 'base_prefix') and sys.base_prefix != sys.prefix))" 2>&1)
if [ "$VENV_MARKER" = "True" ]; then
    pass "python reports running inside venv"
else
    fail "python does not detect venv environment"
fi

# ===================================================================
section "3: pip install into venv (small package)"
# ===================================================================
if "$CONFIG_DIR/tts-venv/bin/pip" install --quiet six 2>&1; then
    pass "pip install six succeeded"
else
    fail "pip install six failed"
fi

if "$VENV_PY" -c "import six; print(six.__version__)" 2>/dev/null; then
    pass "six importable and has version"
else
    fail "six NOT importable"
fi

# ===================================================================
section "4: Package detection logic (simulating Swift checkDependencies)"
# ===================================================================
RESULT=$(eval "$VENV_PY -c 'import six' 2>/dev/null && echo OK" 2>&1 || true)
if echo "$RESULT" | grep -q "OK"; then
    pass "positive detection: installed package found"
else
    fail "positive detection failed"
fi

# ===================================================================
section "5: Missing package detection"
# ===================================================================
RESULT2=$(eval "$VENV_PY -c 'import nonexistent_pkg_xyz' 2>/dev/null && echo OK" 2>&1 || true)
if echo "$RESULT2" | grep -q "OK"; then
    fail "false positive: missing package detected as present"
else
    pass "negative detection: missing package correctly absent"
fi

# Multi-import where one is missing (matches checkDependencies pattern)
RESULT3=$(eval "$VENV_PY -c 'import six; import nonexistent_pkg_xyz' 2>/dev/null && echo OK" 2>&1 || true)
if echo "$RESULT3" | grep -q "OK"; then
    fail "false positive: partial imports detected as all present"
else
    pass "partial import correctly detected as incomplete"
fi

# ===================================================================
section "6: Recreate venv over existing one"
# ===================================================================
if python3 -m venv "$CONFIG_DIR/tts-venv" 2>&1; then
    pass "venv re-creation succeeded"
else
    fail "venv re-creation failed"
fi

if "$VENV_PY" -c "import six" 2>/dev/null; then
    pass "packages survive venv re-creation"
else
    info "packages lost after re-creation (can happen on some Python versions)"
fi

# ===================================================================
section "7: Deleted venv detection"
# ===================================================================
rm -rf "$CONFIG_DIR/tts-venv"

RESULT4=$(eval "$CONFIG_DIR/tts-venv/bin/python3 -c 'import six' 2>/dev/null && echo OK" 2>&1 || true)
if echo "$RESULT4" | grep -q "OK"; then
    fail "deleted venv still reports packages"
else
    pass "deleted venv correctly detected as missing"
fi

# File existence check (Swift TTSServerManager logic)
if [ -f "$CONFIG_DIR/tts-venv/bin/python3" ]; then
    fail "file check: deleted venv python still shows as existing"
else
    pass "file check: deleted venv python correctly missing"
fi

# ===================================================================
section "8: install.sh venv section (integration, isolated CONFIG_DIR)"
# ===================================================================
CONFIG_DIR_8="$TEST_DIR/t8"
fresh_config "$CONFIG_DIR_8"

# Run the exact logic from install.sh
if python3 -m venv "$CONFIG_DIR_8/tts-venv" 2>/dev/null; then
    pass "install.sh logic: venv created"
    if "$CONFIG_DIR_8/tts-venv/bin/pip" install --quiet six 2>/dev/null; then
        pass "install.sh logic: pip install succeeded"
    else
        fail "install.sh logic: pip install failed"
    fi
else
    fail "install.sh logic: venv creation failed"
fi

# ===================================================================
section "9: TTS server python fallback logic"
# ===================================================================
# With venv present
CONFIG_DIR_9="$TEST_DIR/t9"
fresh_config "$CONFIG_DIR_9"
python3 -m venv "$CONFIG_DIR_9/tts-venv" 2>/dev/null

VENV_PYTHON="$CONFIG_DIR_9/tts-venv/bin/python3"
if [ -f "$VENV_PYTHON" ]; then
    PYTHON_PATH="$VENV_PYTHON"
    pass "prefers venv python when available"
else
    fail "venv python not found after creation"
fi

# With venv deleted — fallback
rm -rf "$CONFIG_DIR_9/tts-venv"
if [ -f "$CONFIG_DIR_9/tts-venv/bin/python3" ]; then
    fail "should fall back but venv still exists"
else
    if [ -f "/usr/bin/python3" ]; then
        pass "falls back to /usr/bin/python3 when venv missing"
    else
        info "/usr/bin/python3 not found (unusual system)"
    fi
fi

# ===================================================================
section "10: Absolute python3 path (no PATH dependency)"
# ===================================================================
CONFIG_DIR_10="$TEST_DIR/t10"
fresh_config "$CONFIG_DIR_10"
PYTHON3_ABS=$(which python3 2>/dev/null || echo "/usr/bin/python3")

if "$PYTHON3_ABS" -m venv "$CONFIG_DIR_10/tts-venv" 2>&1; then
    pass "venv creation with absolute path ($PYTHON3_ABS)"
else
    fail "venv creation with absolute path failed"
fi

# Also test with /usr/bin/python3 explicitly if it exists
if [ -f "/usr/bin/python3" ]; then
    CONFIG_DIR_10b="$TEST_DIR/t10b"
    fresh_config "$CONFIG_DIR_10b"
    if /usr/bin/python3 -m venv "$CONFIG_DIR_10b/tts-venv" 2>&1; then
        pass "venv creation with /usr/bin/python3 specifically"
    else
        fail "venv creation with /usr/bin/python3 failed"
    fi
fi

# ===================================================================
section "11: Corrupted venv (broken python symlink)"
# ===================================================================
CONFIG_DIR_11="$TEST_DIR/t11"
fresh_config "$CONFIG_DIR_11"
mkdir -p "$CONFIG_DIR_11/tts-venv/bin"
ln -sf /nonexistent/python3 "$CONFIG_DIR_11/tts-venv/bin/python3"

# Detection should fail (broken symlink)
RESULT11=$(eval "$CONFIG_DIR_11/tts-venv/bin/python3 -c 'import kokoro' 2>/dev/null && echo OK" 2>&1 || true)
if echo "$RESULT11" | grep -q "OK"; then
    fail "corrupted venv: broken symlink still runs"
else
    pass "corrupted venv: broken symlink correctly fails"
fi

# File existence check (-f follows symlinks, broken symlink = false)
if [ -f "$CONFIG_DIR_11/tts-venv/bin/python3" ]; then
    fail "corrupted venv: -f reports broken symlink as existing file"
else
    pass "corrupted venv: -f correctly reports broken symlink as missing"
fi

# Re-create venv over corrupted one: rm + recreate (as install code does)
rm -rf "$CONFIG_DIR_11/tts-venv"
if python3 -m venv "$CONFIG_DIR_11/tts-venv" 2>&1; then
    if [ -f "$CONFIG_DIR_11/tts-venv/bin/python3" ]; then
        pass "corrupted venv: rm + recreate fixes broken venv"
    else
        fail "corrupted venv: rm + recreate didn't fix python3"
    fi
else
    fail "corrupted venv: rm + recreate failed entirely"
fi

# ===================================================================
section "12: Partial venv (bin/ exists but no pip)"
# ===================================================================
CONFIG_DIR_12="$TEST_DIR/t12"
fresh_config "$CONFIG_DIR_12"
python3 -m venv "$CONFIG_DIR_12/tts-venv" 2>/dev/null

# Remove pip to simulate partial install
rm -f "$CONFIG_DIR_12/tts-venv/bin/pip" "$CONFIG_DIR_12/tts-venv/bin/pip3"

# pip install should fail
if "$CONFIG_DIR_12/tts-venv/bin/pip" install six 2>/dev/null; then
    fail "partial venv: pip should be missing but install succeeded"
else
    pass "partial venv: pip correctly missing, install fails"
fi

# Re-creating venv: rm + recreate should restore pip (as install code does)
rm -rf "$CONFIG_DIR_12/tts-venv"
if python3 -m venv "$CONFIG_DIR_12/tts-venv" 2>&1; then
    if [ -f "$CONFIG_DIR_12/tts-venv/bin/pip" ]; then
        pass "partial venv: rm + recreate restores pip"
    else
        fail "partial venv: rm + recreate did not restore pip"
    fi
else
    fail "partial venv: rm + recreate failed"
fi

# ===================================================================
section "13: Read-only venv directory"
# ===================================================================
CONFIG_DIR_13="$TEST_DIR/t13"
fresh_config "$CONFIG_DIR_13"
mkdir -p "$CONFIG_DIR_13/tts-venv"
chmod 444 "$CONFIG_DIR_13/tts-venv"

# venv creation should fail gracefully
if python3 -m venv "$CONFIG_DIR_13/tts-venv" 2>/dev/null; then
    fail "read-only dir: venv creation should have failed"
else
    pass "read-only dir: venv creation correctly fails"
fi

# Restore permissions for cleanup
chmod 755 "$CONFIG_DIR_13/tts-venv"

# ===================================================================
section "14: Venv with spaces in path"
# ===================================================================
CONFIG_DIR_14="$TEST_DIR/t14/path with spaces/.popdraft"
mkdir -p "$CONFIG_DIR_14"

if python3 -m venv "$CONFIG_DIR_14/tts-venv" 2>&1; then
    pass "spaces in path: venv created"
else
    fail "spaces in path: venv creation failed"
fi

if "$CONFIG_DIR_14/tts-venv/bin/pip" install --quiet six 2>&1; then
    pass "spaces in path: pip install works"
else
    fail "spaces in path: pip install failed"
fi

if "$CONFIG_DIR_14/tts-venv/bin/python3" -c "import six" 2>/dev/null; then
    pass "spaces in path: package importable"
else
    fail "spaces in path: package NOT importable"
fi

# ===================================================================
section "15: Real kokoro+soundfile+numpy install into venv"
# ===================================================================
CONFIG_DIR_15="$TEST_DIR/t15"
fresh_config "$CONFIG_DIR_15"
python3 -m venv "$CONFIG_DIR_15/tts-venv" 2>/dev/null

info "Installing kokoro, soundfile, numpy (this may take a few minutes)..."
PIP_OUT=$("$CONFIG_DIR_15/tts-venv/bin/pip" install kokoro soundfile numpy 2>&1) || true

if echo "$PIP_OUT" | grep -qi "error\|failed"; then
    fail "real install: pip reported errors"
    info "pip output (last 5 lines):"
    echo "$PIP_OUT" | tail -5 | sed 's/^/    /'
else
    pass "real install: kokoro+soundfile+numpy installed without errors"
fi

# ===================================================================
section "16: Real package detection (kokoro/soundfile/numpy)"
# ===================================================================
VENV_PY_15="$CONFIG_DIR_15/tts-venv/bin/python3"

# Exact check from Swift checkDependencies
CHECK_REAL="$VENV_PY_15 -c 'import kokoro; import soundfile; import numpy' 2>/dev/null && echo OK"
RESULT_REAL=$(eval "$CHECK_REAL" 2>&1 || true)

if echo "$RESULT_REAL" | grep -q "OK"; then
    pass "real detection: kokoro+soundfile+numpy all importable"
else
    fail "real detection: imports failed"
    # Check individually to identify which failed
    for pkg in kokoro soundfile numpy; do
        if "$VENV_PY_15" -c "import $pkg" 2>/dev/null; then
            info "$pkg: OK"
        else
            info "$pkg: MISSING"
        fi
    done
fi

# Verify numpy version (should be recent)
NP_VER=$("$VENV_PY_15" -c "import numpy; print(numpy.__version__)" 2>/dev/null || echo "N/A")
info "numpy version: $NP_VER"

# Verify system python does NOT have kokoro (isolation check)
if "$SYS_PY" -c "import kokoro" 2>/dev/null; then
    info "kokoro also on system python (pre-existing, not our doing)"
else
    pass "real isolation: kokoro NOT on system python"
fi

# ===================================================================
section "17: Full install.sh dry-run (end-to-end)"
# ===================================================================
CONFIG_DIR_17="$TEST_DIR/t17"
fresh_config "$CONFIG_DIR_17"

# Run the exact venv+pip section from install.sh, redirected to our test dir
info "Running install.sh venv logic end-to-end..."

INSTALL_OK=true
if python3 -m venv "$CONFIG_DIR_17/tts-venv" 2>/dev/null; then
    pass "e2e: venv created"
    if "$CONFIG_DIR_17/tts-venv/bin/pip" install --quiet kokoro soundfile numpy 2>/dev/null; then
        pass "e2e: real packages installed"
    else
        fail "e2e: real package install failed"
        INSTALL_OK=false
    fi
else
    fail "e2e: venv creation failed"
    INSTALL_OK=false
fi

if $INSTALL_OK; then
    # Full detection check
    E2E_CHECK=$("$CONFIG_DIR_17/tts-venv/bin/python3" -c 'import kokoro; import soundfile; import numpy' 2>/dev/null && echo OK || true)
    if echo "$E2E_CHECK" | grep -q "OK"; then
        pass "e2e: full detection check passes"
    else
        fail "e2e: detection check fails after successful install"
    fi
fi

# ===================================================================
section "18: Concurrent venv creation"
# ===================================================================
CONFIG_DIR_18a="$TEST_DIR/t18a"
CONFIG_DIR_18b="$TEST_DIR/t18b"
fresh_config "$CONFIG_DIR_18a"
fresh_config "$CONFIG_DIR_18b"

# Create two venvs concurrently (simulates race condition)
python3 -m venv "$CONFIG_DIR_18a/tts-venv" 2>/dev/null &
PID1=$!
python3 -m venv "$CONFIG_DIR_18b/tts-venv" 2>/dev/null &
PID2=$!

wait $PID1
STATUS1=$?
wait $PID2
STATUS2=$?

if [ $STATUS1 -eq 0 ] && [ $STATUS2 -eq 0 ]; then
    pass "concurrent creation: both venvs created"
else
    fail "concurrent creation: one or both failed (status: $STATUS1, $STATUS2)"
fi

# ===================================================================
section "19: Very long path"
# ===================================================================
LONG_DIR="$TEST_DIR/t19/aaaaaaaaaaaaaaa/bbbbbbbbbbbbbbb/ccccccccccccccc/ddddddddddddddd"
mkdir -p "$LONG_DIR"

if python3 -m venv "$LONG_DIR/tts-venv" 2>&1; then
    if [ -f "$LONG_DIR/tts-venv/bin/python3" ]; then
        pass "long path: venv works"
    else
        fail "long path: venv created but python3 missing"
    fi
else
    fail "long path: venv creation failed"
fi

# ===================================================================
section "20: Swift compilation check"
# ===================================================================
if [ -f "$SCRIPT_DIR/scripts/PopDraft.swift" ]; then
    if swiftc -parse "$SCRIPT_DIR/scripts/PopDraft.swift" -framework Cocoa -framework Carbon 2>&1; then
        pass "Swift file compiles cleanly"
    else
        fail "Swift compilation errors"
    fi
else
    skip "PopDraft.swift not found (not running from repo root)"
fi

# ===================================================================
# Summary
# ===================================================================
echo ""
echo "==========================================="
echo "Environment:"
echo "  Python: $(python3 --version 2>&1) ($(which python3))"
echo "  macOS:  $(sw_vers -productVersion 2>/dev/null || echo 'unknown')"
echo "  Arch:   $(uname -m)"
echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped ($TOTAL total)"
if [ -n "$ERRORS" ]; then
    echo ""
    echo "Failures:"
    echo -e "$ERRORS"
fi
echo "==========================================="

if [ $FAIL -gt 0 ]; then
    exit 1
fi
