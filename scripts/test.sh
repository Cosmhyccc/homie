#!/bin/bash
# Runs every test that needs no model, microphone or permissions. Same script locally and in CI.
# Usage: bash scripts/test.sh
set -euo pipefail
cd "$(dirname "$0")/.."
out=$(mktemp -d); trap 'rm -rf "$out"' EXIT
cache="$out/module-cache"
build() { xcrun swiftc -parse-as-library -module-cache-path "$cache" "$@" 2>&1 | grep -E "error:" && exit 1 || true; }

echo "▸ instant-lane router";      build Sources/LocalRouter.swift Tests/LocalRouterTests.swift -o "$out/router" && "$out/router" < /dev/null | tail -1
echo "▸ on-device memory";         build Sources/LocalRouter.swift Sources/LocalMemory.swift Tests/LocalMemoryTests.swift -o "$out/memory" && "$out/memory" | tail -1
echo "▸ first-phrase chunker";     build Sources/PhraseChunker.swift Tests/PhraseChunkerTests.swift -o "$out/chunker" && "$out/chunker" | tail -1
echo "▸ song matching";            build Sources/SongMatch.swift Tests/SongMatchTests.swift -o "$out/songs" && "$out/songs" | tail -1
echo "▸ instant-lane coverage";    build Sources/LocalRouter.swift Tests/LocalRouterCoverage.swift -o "$out/coverage"
for set in coverage coverage_holdout; do printf "  %-18s" "$set:"; "$out/coverage" "Tests/local_eval/$set.tsv" | tail -1; done
echo "▸ model downloader (local server, no internet)"
build Sources/HomieModels.swift Tests/HomieDownloaderTests.swift -o "$out/downloader"
head -c 8000000 /dev/urandom > "$out/fake.gguf"
port=$((20000 + RANDOM % 20000))
(cd "$out" && exec python3 -m http.server "$port" --bind 127.0.0.1 >/dev/null 2>&1) & server=$!
sleep 1; "$out/downloader" "$out" "$port" | tail -1; kill $server; wait $server 2>/dev/null || true
echo "✓ all tests passed"
