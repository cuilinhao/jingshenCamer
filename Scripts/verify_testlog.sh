#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TESTLOG_TMP="$(mktemp -d "${TMPDIR:-/tmp}/testcamer-testlog.XXXXXX")"
trap 'rm -rf "$TESTLOG_TMP"' EXIT
cd "$ROOT"
swiftc -O -swift-version 5 TestCamer/TestLog.swift Tests/TestLogTests.swift -o "$TESTLOG_TMP/testlog-tests"
"$TESTLOG_TMP/testlog-tests"
