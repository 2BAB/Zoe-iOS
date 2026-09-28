#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
xcrun swiftc -DDEBUG -parse-as-library -swift-version 6 -target arm64-apple-macos27.0 \
  Zoe/Workflow/*.swift Zoe/Browser/*.swift Zoe/LanguageModels/*.swift \
  Zoe/Builder/*.swift Tools/*.swift -o /private/tmp/zoe-smoke
exec /private/tmp/zoe-smoke "$@"
