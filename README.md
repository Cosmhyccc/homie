# homie

A voice buddy that lives in your Mac's notch and runs entirely on your Mac. Press **Fn**, talk, and it sets timers, plays music, reads your calendar, flips dark mode, opens apps, takes notes, and chats back out loud. The brain, the voice and your memories never leave the computer. It works in airplane mode.

**Speed on an M5 MacBook (16 GB), from the end of your sentence to homie's first sound:**

| | p50 | p90 |
|---|---|---|
| Everyday commands (timer, dark mode, open Notes, "what's on my calendar tomorrow") | **0.40 s** | 0.67 s |
| Requests that need the model ("remind me to call mom at 5", "tell me something about space") | **0.73 s** | 0.88 s |

That includes the wait to be sure you've stopped talking. Run it on your own Mac with `bash Tests/local_eval/bench.sh` and send us your numbers.

## How it gets that fast

A 4-billion-parameter model on a laptop writes about 15–30 tokens a second. Asking it to call a tool means it has to *write out* the call, which takes 2–5 seconds. So most of the speed comes from not asking it.

- **Reflexes before thinking.** A pattern matcher (`Sources/LocalRouter.swift`, about 600 lines) catches everyday phrasings and runs the action directly in about a millisecond. On a held-out set of real phrasings it covered 87% of the commands it should, with zero wrong fires, before we fixed its misses. Every reflex has tests for phrases it must *not* fire on ("close this window", "why is dark mode bad for your eyes"). Anything with "and" or "then" goes to the model.
- **Read-outs without the model.** "What's on my calendar tomorrow?" reads the calendar and speaks a summary built in code. No model pass, so it takes under a second instead of 5–7.
- **Start thinking before you finish.** After 0.25 s of silence the model starts on what you've said so far. If you keep talking, it restarts, and that costs nothing measurable: llama.cpp keeps a checkpoint right after the prompt. If you were done, it's already about 0.35 s ahead.
- **Never re-read the instructions.** The model's "already read the prompt" state is saved to disk and restored at launch in 0.12 s, instead of 5–10 s of reading.
- **Start talking early.** The first spoken phrase breaks at a natural joint ("Did you know | that there's a black hole…") instead of waiting for the full sentence.
- **Smaller requests.** Short tool descriptions written for a small model, optional parameters with defaults filled in afterwards (41 → 34 tokens per call), and no second model pass just to say "done".

## What didn't work (measured, not shipped)

- **Speculative decoding** made things *slower* on this hybrid model: n-gram 2.5–3.1 s and a 2B draft model 3.0 s, against a 1.9 s baseline. Qwen3.5 has no MTP layers either.
- **MLX** was 34 vs 31 tok/s against llama.cpp: not worth switching engines.
- **Giving the model only the 5–8 tools relevant to each request** is the textbook trick, and it backfires on a laptop: a different tool list throws away the prompt cache, which costs 4–17 s per turn. One stable list wins.
- **A `remember` tool** for the model to save facts: it called it 1 time in 5, and once said "I'll remember that" without doing it. Instead, homie learns from your phrasing, plus a short look-back pass after each conversation (0.2–0.7 s while you're not talking).
- **The 2B model with the 4B's prompt** scored 16/30 and kept saying "Got it!" without acting. Plain rules and a grounding check (an action needs a matching word in what you said) brought it to 26/30.

## Privacy, exactly

Everything runs on your Mac. homie makes these network requests, and no others:

1. **Once, on first launch:** the model file from Hugging Face (1.3 or 2.7 GB, pinned to an exact commit and checked against its SHA-256) and the voice model (about 390 MB, fetched by FluidAudio).
2. **When you ask to play a song:** Apple's public iTunes Search API to find it, and the album art from Apple's CDN.
3. **When you ask to open a website or search the web:** your browser opens it.

There are no accounts and no analytics. Speech recognition is Apple's on-device recognizer. What homie learns about you is stored in `~/Library/Application Support/Pixie/Local/memory.json`, readable only by you. Say "forget everything" to clear it.

## Install

Requires an Apple Silicon Mac running macOS 26 or later. Macs with 8 GB of memory automatically get **lite**, the 2B model (about 1.9 GB of memory for brain and voice instead of 3.75 GB).

```bash
git clone <this repo> && cd homie
bash build.sh          # fetches llama.cpp (checksum-verified) and builds the voice engine on first run
open build/homie.app   # press Fn and talk
```

macOS will ask for Microphone, Speech Recognition and, when you first use them, Accessibility, Calendar and Reminders access.

## Layout

| | |
|---|---|
| `Sources/LocalBrain.swift` | Listening, end-of-speech detection, head start, the model loop, speaking, memory |
| `Sources/LocalRouter.swift` | The instant lane, model-call repairs, the grounding check |
| `Sources/LocalMemory.swift` | What homie learns about you |
| `Sources/HomieModels.swift` | Bundled engines, the checksum-verified model download |
| `Sources/*Controller.swift`, `MacControls.swift` | The tools: music, apps, windows, files, reminders, timers, settings |
| `LocalVoice/` | The voice helper: Kokoro-82M on the Neural Engine via FluidAudio |
| `Tests/` | Router, memory, chunker, song matching and downloader tests, plus `local_eval/` (accuracy eval, coverage sets, `bench.sh`) |

## Known issues

- The voice model crashes on about 5% of exact sentences, inside Core ML ([FluidAudio#1172](https://github.com/FluidInference/FluidAudio/issues/1172)). homie restarts it (about 1.3 s) and says the line with a comma moved.
- Spotify playback opens search results but doesn't press play yet. Apple Music plays directly.

## License

MIT for the code. The homie name and logo are not covered. Third-party components keep their own licenses (see `LICENSE`).
