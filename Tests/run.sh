#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/annotate-tests.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT
cat Annotate.swift Tests/EditingTests.swift > "$test_dir/main.swift"
swiftc -D ANNOTATE_TESTING "$test_dir/main.swift" -o "$test_dir/editing-tests"
"$test_dir/editing-tests" "$PWD/test-terminal.png"
