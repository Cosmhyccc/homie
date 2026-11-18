#!/bin/bash
# Puts homie's on-device engines inside the app so a fresh Mac only downloads the model.
# Usage: scripts/bundle-homie.sh <Pixie.app> <signing identity> [extra codesign flags...]
# Model runtime: llama-server + the 10 libraries it loads (@loader_path). Voice: PixieVoice + its resource bundle.
set -euo pipefail
app=$1; identity=$2; shift 2
helpers="$app/Contents/Helpers/homie"
# Public checkout: engines/ (from scripts/fetch-engines.sh). Private checkout: build/local-prototype.
runtime=${HOMIE_RUNTIME:-$( [[ -d engines/runtime ]] && echo engines/runtime || echo build/local-prototype/runtime/llama-b11912 )}
voice=${HOMIE_VOICE:-$( [[ -d engines/voice ]] && echo engines/voice || echo build/local-prototype/voice/native )}
if [[ ! -x "$runtime/llama-server" || ! -x "$voice/PixieVoice" ]]; then
  echo "warning: homie engines not found ($runtime, $voice); run scripts/fetch-engines.sh" >&2; exit 0
fi
mkdir -p "$helpers" "$app/Contents/Resources"
cp "$runtime/llama-server" "$helpers/"
for lib in libggml-base.0 libggml-blas.0 libggml-cpu.0 libggml-metal.0 libggml-rpc.0 libggml.0 libllama-common.0 libllama-server-impl libllama.0 libmtmd.0; do
  cp -L "$runtime/$lib.dylib" "$helpers/$lib.dylib"
done
cp "$runtime/LICENSE" "$app/Contents/Resources/llama.cpp-LICENSE.txt"
cp "$voice/PixieVoice" "$helpers/"
ditto "$voice/FluidAudio_LuxTtsG2pResources.bundle" "$helpers/FluidAudio_LuxTtsG2pResources.bundle"
# Inside-out: libraries and resources first, then the two executables.
for item in "$helpers"/*.dylib "$helpers/FluidAudio_LuxTtsG2pResources.bundle" "$helpers/llama-server" "$helpers/PixieVoice"; do
  codesign --force --sign "$identity" "$@" "$item"
done
