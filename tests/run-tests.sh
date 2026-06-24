#!/bin/bash
# Run PopDraft unit tests.
#
# Multi-binary harness: each entry is "<test-file>[:<extra-source>...]".
# Test files that exercise Core.swift logic co-compile it (no type drift);
# standalone tests compile on their own. Exits non-zero if any test fails.
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR/.."

# Each item: "test_file[ extra_source ...]" (space-separated extra sources).
TESTS=(
  "tests/test-actions.swift"
  "tests/test-config.swift scripts/Core.swift"
  "tests/test-model-validation.swift scripts/Core.swift"
  "tests/test-session.swift scripts/Core.swift"
  "tests/test-webengine-core.swift scripts/Core.swift"
  "tests/test-imagesearch.swift scripts/Core.swift"
  "tests/test-toolrunner.swift scripts/Core.swift"
  "tests/test-agentloop.swift scripts/Core.swift"
  "tests/test-maccontrol.swift scripts/Core.swift"
  "tests/test-ippinning.swift scripts/Core.swift"
  "tests/test-mcp.swift scripts/Core.swift"
  "tests/test-localactions.swift scripts/Core.swift scripts/MacControl.swift scripts/LocalActionTools.swift"
)

OVERALL_EXIT=0

for entry in "${TESTS[@]}"; do
  # shellcheck disable=SC2206
  parts=($entry)
  test_file="${parts[0]}"
  extra_sources=("${parts[@]:1}")
  test_name="$(basename "$test_file" .swift)"
  bin="/tmp/popdraft-$test_name"

  echo "=========================================="
  echo "Compiling $test_file..."

  if [ "${#extra_sources[@]}" -eq 0 ]; then
    # Standalone test: top-level code is fine in a single-file compile.
    compile_ok=1
    swiftc -o "$bin" "$test_file" || compile_ok=0
  else
    # Co-compiled test (e.g. with scripts/Core.swift): Swift only allows
    # top-level executable code in a file named main.swift, so stage the
    # test file as main.swift and compile it alongside the extra sources.
    stage_dir="$(mktemp -d "/tmp/popdraft-$test_name.XXXXXX")"
    cp "$test_file" "$stage_dir/main.swift"
    compile_ok=1
    swiftc -o "$bin" "$stage_dir/main.swift" "${extra_sources[@]}" || compile_ok=0
    rm -rf "$stage_dir"
  fi

  if [ "$compile_ok" -ne 1 ]; then
    echo "  [ERROR] Failed to compile $test_file"
    OVERALL_EXIT=1
    continue
  fi

  echo "Running $test_name..."
  echo ""
  if ! "$bin"; then
    OVERALL_EXIT=1
  fi
  rm -f "$bin"
  echo ""
done

# ----------------------------------------------------------------------------
# History browser test — pure HistorySearch predicate (History.swift). Its host
# view references app-wide types (ChatPalette, LiquidGlassBackground, AppDelegate,
# …), so it co-compiles with all app sources EXCEPT scripts/Main.swift (the @main
# entry) — the test file is staged as main.swift to be the sole entry point.
# Swift autolinks the system frameworks it imports, so no -framework flags here.
# ----------------------------------------------------------------------------
echo "=========================================="
echo "Compiling tests/test-history.swift..."
HSTAGE="$(mktemp -d /tmp/popdraft-history.XXXXXX)"
cp "tests/test-history.swift" "$HSTAGE/main.swift"
HBIN="/tmp/popdraft-test-history"
HIST_SOURCES=()
for f in scripts/*.swift; do
  [ "$f" = "scripts/Main.swift" ] && continue
  HIST_SOURCES+=("$f")
done
if swiftc -o "$HBIN" "$HSTAGE/main.swift" "${HIST_SOURCES[@]}"; then
  echo "Running test-history..."
  echo ""
  if ! "$HBIN"; then OVERALL_EXIT=1; fi
else
  echo "  [ERROR] Failed to compile tests/test-history.swift"
  OVERALL_EXIT=1
fi
rm -rf "$HSTAGE"
rm -f "$HBIN"
echo ""

# ----------------------------------------------------------------------------
# GUI / WebKit tests (LOCAL ONLY) — gated behind RUN_GUI_TESTS=1.
#
# Hosted CI can't reliably drive an offscreen WKWebView, so these only run when
# explicitly requested. They co-compile with the real engine (all of the app's
# scripts/*.swift sources except scripts/Main.swift, which carries the app's
# @main) so the test's top-level code is the sole entry point, and drive it
# against a local Python fixture server.
# ----------------------------------------------------------------------------
if [ "${RUN_GUI_TESTS:-0}" = "1" ]; then
  echo "=========================================="
  echo "Running GUI/WebKit tests (RUN_GUI_TESTS=1)..."

  GUI_TEST="tests/test-webengine-gui.swift"
  FIXTURE="tests/fixtures/server.py"

  # Start the fixture server; capture its announced ephemeral port.
  SRV_LOG="$(mktemp /tmp/popdraft-fixture.XXXXXX.log)"
  python3 "$FIXTURE" > "$SRV_LOG" 2>&1 &
  SRV_PID=$!
  trap 'kill "$SRV_PID" 2>/dev/null; rm -f "$SRV_LOG"' EXIT

  # Wait (up to ~5s) for the "PORT <n>" line.
  PORT=""
  for _ in $(seq 1 50); do
    PORT="$(grep -m1 '^PORT ' "$SRV_LOG" 2>/dev/null | awk '{print $2}')"
    [ -n "$PORT" ] && break
    sleep 0.1
  done

  if [ -z "$PORT" ]; then
    echo "  [ERROR] fixture server did not announce a port"
    cat "$SRV_LOG"
    OVERALL_EXIT=1
  else
    echo "  Fixture server on 127.0.0.1:$PORT"
    export PD_FIXTURE_BASE="http://127.0.0.1:$PORT"
    # TEST-ONLY: allow the SSRF guard to reach the loopback fixture on THIS port.
    # The shipping app never sets this, so its SSRF protection is unchanged.
    export PD_WEB_ALLOW_LOOPBACK_PORT="$PORT"

    # Stage the GUI test as the module's main.swift so its top-level code is the
    # entry point, then co-compile it with ALL of the real app's sources EXCEPT
    # scripts/Main.swift (which carries the app's own @main) — so there's exactly
    # one top-level entry point. After the source split, the engine lives across
    # scripts/WebEngine.swift + its dependencies, so we link every app file.
    GSTAGE="$(mktemp -d /tmp/popdraft-webgui.XXXXXX)"
    cp "$GUI_TEST" "$GSTAGE/main.swift"
    GBIN="/tmp/popdraft-test-webengine-gui"

    # Every app source except Main.swift (the @main entry).
    APP_SOURCES=()
    for f in scripts/*.swift; do
      [ "$f" = "scripts/Main.swift" ] && continue
      APP_SOURCES+=("$f")
    done

    if swiftc -o "$GBIN" "$GSTAGE/main.swift" "${APP_SOURCES[@]}" \
         -framework Cocoa -framework Carbon -framework WebKit -framework AVFoundation -framework Network; then
      echo "  Compiled. Running..."
      if ! "$GBIN"; then OVERALL_EXIT=1; fi
    else
      echo "  [ERROR] Failed to compile $GUI_TEST"
      OVERALL_EXIT=1
    fi
    rm -rf "$GSTAGE"
    rm -f "$GBIN"
  fi

  kill "$SRV_PID" 2>/dev/null
  trap - EXIT
  rm -f "$SRV_LOG"
fi

echo "=========================================="
if [ "$OVERALL_EXIT" -eq 0 ]; then
  echo "ALL TEST SUITES PASSED"
else
  echo "ONE OR MORE TEST SUITES FAILED"
fi
exit "$OVERALL_EXIT"
