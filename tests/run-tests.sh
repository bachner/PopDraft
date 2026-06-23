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

echo "=========================================="
if [ "$OVERALL_EXIT" -eq 0 ]; then
  echo "ALL TEST SUITES PASSED"
else
  echo "ONE OR MORE TEST SUITES FAILED"
fi
exit "$OVERALL_EXIT"
