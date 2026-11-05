#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
build_dir=$(mktemp -d "${TMPDIR:-/tmp}/gotify-history-tests.XXXXXX")
trap 'rm -rf "$build_dir"' EXIT
xcrun swiftc -parse-as-library -target "$(uname -m)-apple-macosx26.2" \
    Gotify-Swift/Models/*.swift \
    Gotify-Swift/Services/*.swift \
    Gotify-Swift/Localization.swift \
    Gotify-Swift/ViewModels/MainViewModel.swift \
    Gotify-Swift/Views/MessageListView.swift \
    Gotify-Swift/Views/MessageTableCellView.swift \
    Tests/HistoryLoadingTests.swift \
    Tests/MessageListTests.swift \
    -o "$build_dir/history-tests"
"$build_dir/history-tests"
xcrun swiftc -parse-as-library -target "$(uname -m)-apple-macosx26.2" \
    Gotify-Swift/Models/MarkdownContent.swift \
    Tests/MarkdownContentTests.swift \
    -o "$build_dir/markdown-tests"
"$build_dir/markdown-tests"
