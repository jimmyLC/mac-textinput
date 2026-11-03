#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [[ ! -d "$ROOT/.build/McBopomofo/McBopomofo.xcodeproj" ]]; then
  echo "Run ./scripts/build.sh first." >&2
  exit 1
fi
python3 "$ROOT/scripts/check_build.py"
# The upstream update API test requires a live network service and is unrelated
# to the input engine. Run it separately when checking upstream update services.
xcodebuild -project "$ROOT/.build/McBopomofo/McBopomofo.xcodeproj" \
  -scheme McBopomofo -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath "$ROOT/.build/DerivedData" \
  -skip-testing:McBopomofoTests/VersionUpdateApiTests CODE_SIGNING_ALLOWED=NO test

# Bilingual analyzer and key router, tested standalone on real data (the router is
# also compiled into the app by prepare_upstream.py).
BIN="$(mktemp -d)"
PROTO=("$ROOT"/Sources/BilingualPrototype/*.swift)
swiftc "${PROTO[@]}" "$ROOT/tests/bilingual_resolver.swift" -o "$BIN/resolver"
swiftc "${PROTO[@]}" "$ROOT/Sources/BilingualInput/UserDictionary.swift" "$ROOT/Sources/BilingualInput/LearningStore.swift" "$ROOT/Sources/BilingualInput/DebugLog.swift" "$ROOT/tests/user_dictionary.swift" -o "$BIN/userdict"
swiftc "${PROTO[@]}" "$ROOT/Sources/BilingualInput/PhraseRepair.swift" "$ROOT/tests/phrase_repair.swift" -o "$BIN/repair"
swiftc "${PROTO[@]}" "$ROOT/tests/bilingual_analyzer.swift" -o "$BIN/analyzer"
swiftc "${PROTO[@]}" "$ROOT/Sources/BilingualInput/BilingualInput.swift" "$ROOT/Sources/BilingualInput/UserDictionary.swift" "$ROOT/Sources/BilingualInput/PhraseRepair.swift" "$ROOT/Sources/BilingualInput/LearningStore.swift" "$ROOT/Sources/BilingualInput/DebugLog.swift" "$ROOT/tests/bilingual_routing.swift" -o "$BIN/routing"
"$BIN/resolver"
"$BIN/userdict"
"$BIN/repair" "$ROOT"
"$BIN/analyzer" "$ROOT"
"$BIN/routing" "$ROOT"
rm -rf "$BIN"
