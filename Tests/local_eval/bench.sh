#!/bin/bash
# homie bench — speech end → first sound, on this Mac. Private ports, never touches a running homie, never runs tools.
set -euo pipefail
export TIER=${TIER:-full}
if [[ $TIER == lite ]]; then MODEL=Qwen3.5-2B-Q4_K_M.gguf; CTX=8192; else MODEL=Qwen3.5-4B-Q4_K_M.gguf; CTX=12288; fi
cd "$(dirname "$0")/../.."
E=/private/tmp/pixie-eval; mkdir -p $E; A=build/local-prototype
# The private app links an echo canceller (C); the public one has none.
extra=(); if [[ -f Sources/EchoBridge.h ]]; then
  for s in Vendor/SpeexDSP/src/*.c; do o=$E/$(basename $s .c).o; [[ -f $o ]] || xcrun clang -O2 -DHAVE_CONFIG_H -IVendor/SpeexDSP -IVendor/SpeexDSP/include -c $s -o $o; extra+=($o); done
  extra+=(-import-objc-header Sources/EchoBridge.h -framework Security -framework WebKit)
fi
xcrun swiftc -parse-as-library $(ls Sources/*.swift | grep -v main.swift) Tests/local_eval/Dump.swift "${extra[@]}" -o $E/dump \
  -framework AppKit -framework AVFoundation -module-cache-path /private/tmp/pixie-module-cache 2>/dev/null
xcrun swiftc -parse-as-library Sources/LocalRouter.swift Tests/local_eval/RouterCLI.swift -o $E/router-cli -module-cache-path /private/tmp/pixie-module-cache 2>/dev/null
$E/dump $E/tools_local.json local < /dev/null > /dev/null
python3 - <<'PY'
import re
import os
s=open('Sources/LocalBrain.swift').read().split('private func systemPrompt()',1)[1]
blocks=[b.split('"""',1)[0] for b in s.split('return """')[1:3]]
body=blocks[0] if os.environ.get('TIER')=='lite' else blocks[1]   # lite prompt comes first in systemPrompt()
open('/private/tmp/pixie-eval/sys.txt','w').write("\n".join(l.strip() for l in re.sub(r'\\\(\w+\)','',body).strip().splitlines()))
PY
openssl rand -hex 16 > $E/bench-voice-key.txt; chmod 600 $E/bench-voice-key.txt
# Engines and models: public checkout (engines/ + downloaded models) or private dev folder.
SERVER=$( [[ -x engines/runtime/llama-server ]] && echo engines/runtime/llama-server || echo build/local-prototype/runtime/llama-b11912/llama-server )
VOICEBIN=$( [[ -x engines/voice/PixieVoice ]] && echo engines/voice/PixieVoice || echo build/local-prototype/voice/native/PixieVoice )
MODELS="$HOME/Library/Application Support/Pixie/Local/models"; [[ -f "$MODELS/$MODEL" ]] || MODELS=build/local-prototype/models
"$SERVER" -m "$MODELS/$MODEL" --host 127.0.0.1 --port 19890 -c $CTX -np 1 --reasoning off --jinja > $E/bench-model.log 2>&1 &
model=$!
"$VOICEBIN" 19891 $E/bench-voice-key.txt > $E/bench-voice.log 2>&1 &
voice=$!
trap 'kill $model $voice 2>/dev/null' EXIT
until curl -s http://127.0.0.1:19890/health | grep -q ok; do sleep 0.5; done
for i in $(seq 1 600); do code=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "Authorization: Bearer $(cat $E/bench-voice-key.txt)" -H 'Content-Type: application/json' -d '{"text":"hi","voice":"af_heart"}' http://127.0.0.1:19891/tts || true); [[ $code == 200 ]] && break; sleep 0.5; done
python3 Tests/local_eval/bench.py
