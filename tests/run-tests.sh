#!/bin/bash
# Run PopDraft action system tests
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR/.."

echo "Compiling test-actions.swift..."
swiftc -o /tmp/test-actions tests/test-actions.swift

echo "Running tests..."
echo ""
/tmp/test-actions
EXIT_CODE=$?

rm -f /tmp/test-actions
exit $EXIT_CODE
