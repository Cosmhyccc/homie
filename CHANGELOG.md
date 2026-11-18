# Changelog

## 0.1.0: first public release
- Voice buddy in the notch, fully on-device: Apple speech recognition, Qwen 3.5 4B via llama.cpp (2B "lite" on 8 GB Macs), Kokoro voice on the Neural Engine.
- Instant lane for everyday commands (~0.4 s from end of speech to first sound on an M5), calendar, to-do and timer read-outs without the model.
- Head start on partial speech, early first phrase, a prompt cache saved at the user-turn boundary.
- On-device memory (phrasing, usage, active hours, post-chat look-back).
- Reads what you circle on screen (Apple Vision OCR) and on-device dictation.
- `homie bench`, a 30-request accuracy eval, and 214-phrase instant-lane coverage sets.
