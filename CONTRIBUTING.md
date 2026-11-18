# Contributing to homie

Thanks for helping. homie's bar is **fast, private, honest**: it answers in under a second where it can, nothing leaves the Mac unless the README says so, and it never claims it did something it didn't.

## The most useful contributions

1. **Phrasings.** Add real things people say to `Tests/local_eval/coverage.tsv` (`phrase<TAB>tool`, or `model` when the model should decide). Include phrases that must **not** trigger anything. Then make `bash scripts/test.sh` pass.
2. **Speed numbers from your Mac.** Run `bash Tests/local_eval/bench.sh` (and `TIER=lite …` on 8 GB Macs) and open a PR with the JSON it writes to `Tests/local_eval/results/`. Run `python3 scripts/latency-chart.py` to update the chart.
3. **Bugs with the exact words.** Turn on the private dev log with `defaults write local.homie.app pixie.local.devLog -bool true` (it stays on your Mac) and include what homie heard.

## Ground rules for code

- **Measure before and after.** A speed change needs bench numbers on your Mac in the PR. A behavior change needs tests.
- **The instant lane must never guess.** A new pattern needs must-not-fire tests next to it. When in doubt, let the model decide.
- **No new network calls** without a line in the README's privacy table and a good reason.
- **Keep the prompt stable.** Don't change the system prompt or tool list per request; it invalidates the cache (4–17 s).
- **Plain, small code.** Comments explain *why*, with the number that justified the choice.

## Building

```bash
bash build.sh          # first run fetches llama.cpp (SHA-256 checked) and builds the voice helper
bash scripts/test.sh   # what CI runs
```

`HOMIE_SIGNING_IDENTITY="Apple Development: You (TEAMID)" bash build.sh` signs with your own certificate, so macOS permissions survive rebuilds. The default ad-hoc signature works, but macOS asks for permissions again after each build.
