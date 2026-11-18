# How we made a local AI feel faster than the cloud

*homie engineering notes · Nov 17, 2026*

homie is a voice buddy that lives in your Mac's notch and runs entirely on your computer. No cloud, no account needed to think, works on flight mode. The catch is that a small local model on a laptop is slow. Here's how we made it feel instant anyway.

## The problem: the brain types slowly

We measured before changing anything. On a MacBook with an 8-core GPU, our 4-billion-parameter model writes about **11–15 tokens a second**. That's fine for chatting. It's painful for doing things, because asking the AI to use a tool means it has to *write out* the request, like `{"song": "Billie Jean", "artist": "Michael Jackson"}`. That alone took 3–5 seconds.

Asking homie to play Billie Jean took about **15 seconds** from the end of the sentence to music playing.

## Fix 1: reflexes before thinking

Most things people say to a voice assistant need no thinking at all. "Set a timer for 5 minutes." "Dark mode." "Open Spotify." "Play Billie Jean by Michael Jackson."

So homie got a reflex lane. A tiny pattern matcher reads what you said, recognizes the common phrasings, and runs the action directly. It takes about a millisecond, with no AI involved. The AI only wakes up for requests that actually need judgment, like "what's on my calendar tomorrow" or "open Spotify and play Drake."

Reflexes are dangerous if they fire on the wrong thing, so every reflex has tests for phrases it must ignore: "close this window," "open my last email," "why is dark mode bad for your eyes." Anything with "and" or "then" always goes to the AI, because it needs a plan.

If a reflex action fails, homie doesn't pretend. It hands the result to the AI, which explains what happened.

## Fix 2: the slow part wasn't the AI

Our logs showed homie found the song in **7 milliseconds**. Then it spent **10 seconds** looking for the song row on screen so it could press play. It was searching Apple Music's entire interface, menus included, while the page was still loading, and each lookup could stall.

Now it searches only the Music window, never waits long on any single element, gives up a pass after 1.5 seconds and retries quickly. Pressing play went from 10 s to about 2.5 s, and most of that is Apple Music loading its own page.

## Fix 3: a shorter, plainer instruction sheet

The AI reads a description of every tool it can use. Ours were written for a big cloud model: long, careful, full of edge cases. That's about 4,500 tokens of reading for a small model, and more chances to get confused.

We rewrote them in plain, short sentences for the local model and removed tools it can't use yet. On our 30-request test, accuracy went from 28/30 to **29/30**, turns got about 0.6 s faster, and the first reply after launch dropped from 17 s to **10 s**.

We also auto-correct the classic small-model mistakes before anything runs. One example is "tomorrow" turning into the wrong day. Another is the AI inventing a browser or reminders list you never mentioned.

## Fix 4: don't re-read the instructions every launch

Every time homie started, the AI re-read its whole instruction sheet: about 3,300 tokens, 5–10 seconds. If you asked something right after opening your Mac, you waited.

Now homie saves its "already read" state to disk the first time (about 300 MB, kept on your Mac). On the next launch it loads that back in **0.12 seconds**, and the first question only costs reading your new words, about 0.2 s. The save is tied to the exact instructions, so if they change, homie re-reads once and saves again.

## What we deliberately didn't do

The textbook trick is to show the AI only the 5–8 tools that matter for each request. We measured it, and on a laptop it backfires. The AI keeps its instructions in a warm cache, and changing the tool list forces it to reread everything, which costs **4–17 seconds**. One stable list wins.

## Result

| Request | Before | After |
|---|---|---|
| "Set a timer for 5 minutes" | ~4 s | **~0.5 s** |
| "Play Billie Jean by Michael Jackson" | ~15 s | **~5 s** |
| "Dark mode", "open Spotify", "volume 30" | 3–5 s | **under 1 s** |
| Getting ready after launch | 5–10 s | **0.12 s** |

Reflexes handle the everyday 80%. The brain handles the 20% that needs thinking. Everything stays on your Mac.
