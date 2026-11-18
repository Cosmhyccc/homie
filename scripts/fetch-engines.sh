#!/bin/bash
# Fetches homie's two on-device engines into engines/ and verifies them.
#   runtime: llama.cpp b11912 (macOS arm64 release), checked against its published SHA-256
#   voice:   PixieVoice, built from LocalVoice/ (Kokoro on the Neural Engine via FluidAudio)
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p engines
if [[ ! -x engines/runtime/llama-server ]]; then
  url=https://github.com/ggml-org/llama.cpp/releases/download/b11912/llama-b11912-bin-macos-arm64.tar.gz
  sha=3c826048ae8dc5b1ab60632f6a8a649e5885fa4e80a996f71455c36b83a6598b
  tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
  echo "Downloading llama.cpp b11912 (16 MB)…"
  curl -fL --progress-bar "$url" -o "$tmp/runtime.tar.gz"
  echo "$sha  $tmp/runtime.tar.gz" | shasum -a 256 -c - >/dev/null || { echo "llama.cpp checksum mismatch" >&2; exit 1; }
  mkdir -p "$tmp/x" && tar -xzf "$tmp/runtime.tar.gz" -C "$tmp/x"
  server=$(find "$tmp/x" -name llama-server -type f | head -1)
  rm -rf engines/runtime && mkdir -p engines/runtime && cp -R "$(dirname "$server")"/. engines/runtime/
fi
if [[ ! -x engines/voice/PixieVoice ]]; then
  echo "Building the voice engine (first time pulls FluidAudio)…"
  (cd LocalVoice && swift build -c release --product PixieVoice)
  mkdir -p engines/voice
  cp LocalVoice/.build/release/PixieVoice engines/voice/
  ditto LocalVoice/.build/release/FluidAudio_LuxTtsG2pResources.bundle engines/voice/FluidAudio_LuxTtsG2pResources.bundle
fi
echo "Engines ready in engines/"
