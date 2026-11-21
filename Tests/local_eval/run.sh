#!/bin/bash
# Scores homie's local model on spoken requests the instant lane does not catch.
# Usage: bash Tests/local_eval/run.sh   (starts its own model server on :19890, never touches the running app)
set -euo pipefail
export TIER=${TIER:-full}
if [[ $TIER == lite ]]; then MODEL=Qwen3.5-2B-Q4_K_M.gguf; CTX=8192; else MODEL=Qwen3.5-4B-Q4_K_M.gguf; CTX=12288; fi
cd "$(dirname "$0")/../.."
E=/private/tmp/pixie-eval; mkdir -p $E
A=build/local-prototype
# The private app links an echo canceller (C); the public one has none.
extra=(); if [[ -f Sources/EchoBridge.h ]]; then
  for s in Vendor/SpeexDSP/src/*.c; do o=$E/$(basename $s .c).o; [[ -f $o ]] || xcrun clang -O2 -DHAVE_CONFIG_H -IVendor/SpeexDSP -IVendor/SpeexDSP/include -c $s -o $o; extra+=($o); done
  extra+=(-import-objc-header Sources/EchoBridge.h -framework Security -framework WebKit)
fi
xcrun swiftc -parse-as-library $(ls Sources/*.swift | grep -v main.swift) Tests/local_eval/Dump.swift "${extra[@]}" -o $E/dump \
  -framework AppKit -framework AVFoundation -module-cache-path /private/tmp/pixie-module-cache
$E/dump $E/tools_local.json local < /dev/null
python3 - <<'PY'
import re
import os
s=open('Sources/LocalBrain.swift').read().split('private func systemPrompt()',1)[1]
blocks=[b.split('"""',1)[0] for b in s.split('return """')[1:3]]
body=blocks[0] if os.environ.get('TIER')=='lite' else blocks[1]   # lite prompt comes first in systemPrompt()
open('/private/tmp/pixie-eval/sys.txt','w').write("\n".join(l.strip() for l in re.sub(r'\\\(\w+\)','',body).strip().splitlines()))
PY
# Engines and models: public checkout (engines/ + downloaded models) or private dev folder.
SERVER=$( [[ -x engines/runtime/llama-server ]] && echo engines/runtime/llama-server || echo build/local-prototype/runtime/llama-b11912/llama-server )
VOICEBIN=$( [[ -x engines/voice/PixieVoice ]] && echo engines/voice/PixieVoice || echo build/local-prototype/voice/native/PixieVoice )
MODELS="$HOME/Library/Application Support/Pixie/Local/models"; [[ -f "$MODELS/$MODEL" ]] || MODELS=build/local-prototype/models
"$SERVER" -m "$MODELS/$MODEL" --host 127.0.0.1 --port 19890 -c $CTX -np 1 --reasoning off --jinja > $E/server.log 2>&1 &
server=$!; trap 'kill $server' EXIT
until curl -s http://127.0.0.1:19890/health | grep -q ok; do sleep 1; done
R=$PWD; cp Tests/local_eval/cases.py $E/ && cd $E && python3 "$R/Tests/local_eval/eval.py" tools_local.json
