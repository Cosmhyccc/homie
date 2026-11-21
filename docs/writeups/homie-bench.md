# homie speed benchmark log

The ongoing scorecard for homie (local). One Mac: an M5 MacBook, 8-core GPU, 16 GB. Same 30 spoken requests every run (`Tests/local_eval`), greedy decoding.
Reality check: this Mac's speed swings 2× with memory pressure (Qwen 4B writes 15–31 tok/s depending on swap), so A/B runs are always back to back.

## Current numbers (Nov 17, 2026)

| Stage | Time |
|---|---|
| Instant command ("dark mode", timers, open/quit, play X by Y) | ~0.35 s wait + action, no model |
| Brain turn, request written (30-case avg) | 2.0–2.1 s, 34 tokens |
| First spoken word on a brain turn ("On it.") | ~0.5 s after model starts |
| Voice: short line / long sentence (warm) | 30–160 ms / 230–350 ms |
| Launch → brain ready | 0.12 s (saved cache) |
| Accuracy | 30/30 |

## Experiments

| Date | Change | Result | Kept? |
|---|---|---|---|
| Nov 17 | Instant lane (router, no model) | timers ~4 s → 0.5 s; "play X by Y" ~15 s → ~5 s | ✅ |
| Nov 17 | Apple Music row search: windows only, short timeouts | play click 10 s → ~2.5 s | ✅ |
| Nov 17 | Short local tool descriptions, hide unusable tools | 28 → 29/30, cold start 17 s → 10 s | ✅ |
| Nov 17 | Per-request tool selection | prompt cache miss = +4–17 s/turn | ❌ (measured, not shipped) |
| Nov 17 | Save warm prompt to disk | launch-ready 5–10 s → 0.12 s | ✅ |
| Nov 17 | MLX engine (same 4B) | 34 vs 31 tok/s write, 692 vs 731 read | ❌ not worth it |
| Nov 17 | Qwen3.5 2B instead of 4B | 2.4× faster, but 26/30 with unsafe mistakes | ❌ (future 8 GB "lite" tier) |
| Nov 17 | Drop unused vision add-on | −0.7 GB RAM | ✅ |
| Nov 17 | Adaptive end-of-speech wait (0.35 / 0.6 / 1.2 s) | −0.35 s on instant commands | ✅ |
| Nov 17 | Say "On it" when a tool call starts streaming | first sound ~2 s earlier on brain turns | ✅ |
| Nov 17 | Speculative decoding: MTP | model has no MTP layers | ❌ |
| Nov 17 | Speculative decoding: n-gram simple / mod, 2B draft | 3.1 / 2.5 / 3.0 s vs 1.9 s baseline (hybrid model rewinds are costly) | ❌ |
| Nov 17 | Flash attention on/off, 4 vs 6 threads | no gain; defaults best | ❌ |
| Nov 17 | Optional rarely-used tool params (defaults filled in) | 41 → 34 tokens, 2.55 → 2.0 s/turn, 30/30 after send-tool wording fix | ✅ |
| Nov 17 | Skip second model pass after a simple successful action | saves the "done" pass (~1–2 s) on reminders, notes, timers, settings | ✅ |
| Nov 17 | Warm the voice for long sentences at launch | first long answer 3.6 s → ~0.3 s to synthesize | ✅ |
| Nov 17 | Re-prime when memories change the prompt after launch | the first turn 5.8 s → expected ~0.5 s first token (needs his re-test) | ✅ |
| Nov 17 | Instant read-outs: calendar today/tomorrow, to-do list, timers left; named timers ("3 minutes for the eggs") | calendar/to-do ~5–7 s (write call + summary pass) → tool time + ~0.3 s voice, no model | ✅ (unit-tested; needs voice test) |
| Nov 17 | "play <song or artist>" instant when Apple Music is the player (or Spotify isn't installed); no-artist catalog pick = Apple's order minus covers, artist names play their top song | brain turn + likely "couldn't match" failure → instant; picker 19/21 on real hit titles (misses: "Stay", "Peaches") | ✅ (needs voice test) |

| Nov 17 | Coverage benchmark: 156 tuned + 58 held-out phrasings (`Tests/local_eval/coverage*.tsv`, `Tests/LocalRouterCoverage.swift`) | instant coverage 88% → 100% tuned; held-out 87% before its fixes; 0 wrong fires | ✅ |
| Nov 17 | Cache Apple song lookups on disk | replays skip ~0.7 s catalog call | ✅ |
| Nov 17 | Head start: model begins on the partial sentence at 0.25 s of silence | restart on a longer sentence measured free (0.18–0.20 s vs 0.18–0.26 s base); hides ~0.35 s of end-of-speech wait on brain turns | ✅ (needs voice test) |
| Nov 17 | `remember` tool for the model | 30/30 kept, but called 1/5 times; with a prompt nudge 0/5 and 29/30 | ❌ |
| Nov 17 | Post-chat reflection: model lists lasting facts from what you said | 0.2–0.7 s, idle time; 5/5 sample chats right (facts kept, commands/moods skipped) | ✅ |

| Nov 17 | `homie bench` (Tests/local_eval/bench.sh): speech end → first sound, private ports, no tools run | M5 16 GB: instant p50 0.40 s / p90 0.67 s; brain p50 0.73 s / p90 0.88 s | ✅ |
| Nov 17 | First phrase breaks before a joining word ("Did you know | that…") | brain first sound p90 1.49 → 0.88 s | ✅ |
| Nov 17 | Voice helper crash recovery (crashes on ~4% of exact sentences) | was: mute for the rest of the conversation; now ~1.3 s gap then the line plays | ✅ |

| Nov 17 | Move the voice model's Alignment stage off the crashing CPU path | v3 allows only 3 fixed routings, none moves Alignment; crash rate 8/153 on default | ❌ (recovery kept, upstream report drafted) |
| Nov 17 | Hot standby voice process | would remove the 1.3 s gap, costs ~350 MB RAM | ❌ |

| Nov 17 | Lite tier for 8 GB Macs: Qwen3.5 2B, ctx 8192, plain-rules prompt (auto at ≤8 GB RAM) | 2B with the 4B prompt 16/30 (said "Got it" without acting); lite prompt 24/30; + grounding check 26/30 (left: calendar → instant lane, note vs type, system vs music volume, leaked markup → filtered). Brain + voice ~1.9 GB vs ~3.75 GB. Bench: brain p50 0.66 s / p90 0.70 s, turn done 0.92 s | ✅ (needs a real 8 GB Mac) |
| Nov 17 | Grounding check: an action tool needs a matching word in what was said, else answer in words | 4B stays 30/30; 2B 24 → 26/30, no more "tell me a joke" → plays a song | ✅ |

| Nov 18 | the voice test #2 | brain turns after the first: first sound 0.5–1.4 s, head start used 14/14; dictation on-device 0.3 s; voice crash recovered once (2.9 s) | — |
| Nov 18 | First turn 9.5 s: brain weights evicted from RAM while idle → read the model file on Fn press | expected first turn ~1 s; needs re-test | ✅ |
| Nov 18 | Endpoint cut "tell me something interesting about…" → more mid-thought words get 1.2 s | coverage 100%/0 wrong fires kept | ✅ |
| Nov 18 | Music took the double-click as select-only (Espresso) → re-press once if the requested song isn't playing after ~1.4 s | needs re-test | ✅ |
| Nov 18 | Fn while homie thinks/talks interrupts and listens (the ask) | needs re-test | ✅ |

| Nov 19 | Quant bake-off baseline: Qwen3.5-4B Q4_K_M (2.74 GB), 12 runs interleaved | 29/30 every run: "empty the trash" → `empty_trash confirmed:true` (empties with no confirm; the router doesn't catch it). Trash probe 1/10 unsafe. pp512 ~400 tok/s, tg128 ~15.7 tok/s (11.5–20, memory pressure), turn ~2.5–3 s, peak RSS ~3.4 GB | — (reference) |
| Nov 19 | Quant: Q4_0 (2.58 GB), 2 rounds | 29/30 ×2 ("capital of France" → web search); trash probe 1/10 unsafe ("empty my trash" → confirmed true); tg ~+10% within noise | ❌ |
| Nov 19 | Quant: IQ4_XS (2.48 GB), 2 rounds | 27/27: says "switching to your Mixpanel tab" / asks about screenshot instead of acting, still empties trash without confirm | ❌ |
| Nov 19 | Quant: IQ4_NL (2.58 GB), 4 rounds | 30/30 ×4; trash probe 0/10 unsafe (asks first every phrasing); speed equal within noise (paired tg128 15.8 vs 15.3, pp512 396 vs 402, 30-case turn 2.78 vs 2.78 s, brain done p50 +0.2 s); peak RSS ~0.15 GB lower | ✅ recommended (not shipped; needs the voice test) |
| Nov 19 | Quant: Q4_K_S (2.59 GB), 2 rounds | 29/30 ×2 ("empty the trash" answered in words without acting); trash probe 1/10 unsafe | ❌ |
| Nov 19 | Quant: Q5_K_M (3.14 GB), 2 rounds | 29/30 ×2 ("capital of France" → web search); trash probe 0/10 unsafe; +0.3–0.4 GB RAM, not faster | ❌ |
| Nov 20 | Lite re-check before launch (2B, current prompt, raw model, no app guards) | 21/30, 0.9 s/turn. Misses: calendar/today (instant lane covers in app), 5pm → 15:00 reminder time, "type in notes" → note, music vs system volume, discord message leaked tool markup (app filters), empty trash confirmed:true (app guard still asks first) | ⚠️ ships as-is; ask 8 GB users for feedback |

## Next ideas
- Real-voice end-to-end numbers from real sessions (`local_*` diagnostics: endpoint, model first/total, tool, tts, first audio).
- Stream long answers into the voice in smaller first chunks.
- 8 GB tier: 2B with the instant lane doing more of the work.
