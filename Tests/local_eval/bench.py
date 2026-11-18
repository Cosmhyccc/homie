"""homie bench: how fast homie answers on *this* Mac, from the moment you stop talking to the first sound.

Runs a private model server and voice engine on spare ports; never touches a running homie and never runs tools
(nothing gets opened, played or changed). Tool time on real apps is reported separately from your own diagnostics.
Usage: bash Tests/local_eval/bench.sh            (prints a table and writes bench-<chip>.json)
"""
import json, os, platform, statistics, subprocess, sys, time, http.client, re
E = os.environ.get("BENCH_DIR", "/private/tmp/pixie-eval")
ROOT = os.path.dirname(os.path.abspath(__file__))
VOICE_KEY = open(os.path.join(E, "bench-voice-key.txt")).read().strip()
HEAD_START = 0.25   # the model starts on the partial sentence after this much silence

INSTANT = ["Set a timer for 5 minutes.", "Dark mode.", "Volume 30.", "Open Notes.", "What time is it?", "Pause.", "Next song.",
           "Play Blinding Lights by The Weeknd.", "Take a screenshot.", "Google best tacos near me.", "Quit Slack.", "Set a timer for 3 minutes for the eggs."]
READOUT = {"What's on my calendar tomorrow?": "You've got 3 things tomorrow: Standup at 9 AM, Lunch with Abby at noon, and Gym at 6:30 PM.",
           "What's on my to-do list?": "You've got 2 things: Buy milk and Call mom."}
BRAIN = ["remind me to call mom at 5pm", "make a note called groceries with eggs milk and bread", "put safari on the left and notes on the right",
         "open spotify and play drake", "set an alarm for 7am tomorrow", "find my resume", "what's the capital of france",
         "tell me something interesting about space", "how are you", "explain a black hole in one sentence", "tell me a joke", "I'm tired"]

def machine():
    sh = lambda c: subprocess.run(c, shell=True, capture_output=True, text=True).stdout.strip()
    gpu = re.search(r"Total Number of Cores: (\d+)", sh("system_profiler SPDisplaysDataType"))
    return {"chip": sh("sysctl -n machdep.cpu.brand_string"), "gpu_cores": int(gpu.group(1)) if gpu else None,
            "ram_gb": int(sh("sysctl -n hw.memsize")) // 2**30, "macos": platform.mac_ver()[0], "model": sh("sysctl -n hw.model")}

def tts(text):
    c = http.client.HTTPConnection("127.0.0.1", 19891, timeout=60); t = time.time()
    c.request("POST", "/tts", json.dumps({"text": text, "voice": "af_heart"}), {"Content-Type": "application/json", "Authorization": "Bearer " + VOICE_KEY})
    r = c.getresponse(); body = r.read(); c.close()
    if r.status != 200 or len(body) < 2: raise RuntimeError(f"voice {r.status}")
    return time.time() - t

SYS = open(os.path.join(E, "sys.txt")).read()
TOOLS = [{"type": "function", "function": {"name": t["name"], "description": t["description"], "parameters": t["parameters"]}} for t in json.load(open(os.path.join(E, "tools_local.json")))]
def first_speakable(text):
    """Streams one brain turn. Returns (seconds to first speakable thing, what it was, seconds to finish)."""
    body = json.dumps({"messages": [{"role": "system", "content": SYS}, {"role": "user", "content": "[Nov 17, 2026 at 3:12 PM America/Chicago · frontmost app: Safari]\n" + text}],
                       "tools": TOOLS, "temperature": 0.0, "max_tokens": 200, "stream": True, "cache_prompt": True, "chat_template_kwargs": {"enable_thinking": False}})
    c = http.client.HTTPConnection("127.0.0.1", 19890, timeout=120); t = time.time()
    c.request("POST", "/v1/chat/completions", body, {"Content-Type": "application/json"}); r = c.getresponse()
    first = None; kind = None; said = ""
    while True:
        line = r.readline()
        if not line: break
        if not line.startswith(b"data: ") or line.strip() == b"data: [DONE]": continue
        delta = json.loads(line[6:])["choices"][0].get("delta", {})
        if first is None and delta.get("tool_calls"): first, kind = time.time() - t, "On it."          # homie says "On it" here
        said += delta.get("content") or ""
        if first is None:   # mirrors PhraseChunker's first phrase
            joiner = re.search(r"^(.{12,}?) (that|where|which|because|and|but|so|when|while|who|since|if|though|although|until) ", said, re.I)
            if re.search(r"[.!?]\s", said) or (re.search(r"[,;:]\s", said) and len(said) >= 18): first, kind = time.time() - t, said.strip()
            elif joiner: first, kind = time.time() - t, joiner.group(1).strip()
    done = time.time() - t; c.close()
    if first is None: first, kind = done, said.strip() or "Done."
    return first, kind, done

def pct(xs, p): xs = sorted(xs); return xs[min(len(xs) - 1, int(round(p / 100 * (len(xs) - 1))))]

def main():
    router = subprocess.Popen([os.path.join(E, "router-cli")], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
    def route(text): router.stdin.write(text + "\n"); router.stdin.flush(); return json.loads(router.stdout.readline())
    for line in ["On it.", "Added to your reminders, you're all set.", "You've got a dentist appointment at three and lunch with Ahmed at noon, pretty chill day."]: tts(line)   # same warm-up homie does at launch
    first_speakable("hi")
    rows = []
    for rnd in range(int(os.environ.get("ROUNDS", "2"))):
        for text in INSTANT + list(READOUT):
            r = route(text); assert r["tool"] is not None, text
            t0 = time.time(); route(text); router_s = time.time() - t0
            line = READOUT.get(text) or r["say"] or "It's 3:12 PM."
            voice = tts(line)
            rows.append({"lane": "instant", "text": text, "endpoint": r["endpoint"], "router": router_s, "voice": voice, "first_audio": r["endpoint"] + router_s + voice})
        for text in BRAIN:
            r = route(text); assert r["tool"] is None, text
            first, said, done = first_speakable(text)
            voice = tts(said[:200])
            # Without head start: wait out the silence, then think. With it: thinking began HEAD_START into the silence.
            plain = r["endpoint"] + first + voice
            head = max(r["endpoint"], HEAD_START + first) + voice
            rows.append({"lane": "brain", "text": text, "endpoint": r["endpoint"], "model_first": first, "model_done": done, "voice": voice,
                         "first_audio": head, "first_audio_no_head_start": plain})
    router.kill()
    inst = [r for r in rows if r["lane"] == "instant"]; brain = [r for r in rows if r["lane"] == "brain"]
    m = machine()
    summary = {"machine": m, "model": ("Qwen3.5-2B-Q4_K_M" if os.environ.get("TIER") == "lite" else "Qwen3.5-4B-Q4_K_M") + " (llama.cpp b11912)", "voice": "Kokoro af_heart (FluidAudio)",
               "instant_first_audio_p50": pct([r["first_audio"] for r in inst], 50), "instant_first_audio_p90": pct([r["first_audio"] for r in inst], 90),
               "brain_first_audio_p50": pct([r["first_audio"] for r in brain], 50), "brain_first_audio_p90": pct([r["first_audio"] for r in brain], 90),
               "brain_first_audio_p50_no_head_start": pct([r["first_audio_no_head_start"] for r in brain], 50),
               "brain_turn_done_p50": pct([r["model_done"] for r in brain], 50), "rows": rows}
    tier = os.environ.get("TIER", "full")
    summary["tier"] = tier
    name = re.sub(r"\W+", "-", f"{m['chip']}-{m['ram_gb']}gb-{tier}").strip("-").lower()
    json.dump(summary, open(os.path.join(ROOT, "results", f"bench-{name}.json"), "w"), indent=1)
    print(f"\nhomie bench · {m['chip']} {m['gpu_cores']}-core GPU · {m['ram_gb']} GB · macOS {m['macos']}")
    print("Time from the end of your sentence to homie's first sound (includes the end-of-speech wait):")
    print(f"  instant commands   p50 {summary['instant_first_audio_p50']:.2f}s   p90 {summary['instant_first_audio_p90']:.2f}s   ({len(INSTANT)+len(READOUT)} commands)")
    print(f"  brain turns        p50 {summary['brain_first_audio_p50']:.2f}s   p90 {summary['brain_first_audio_p90']:.2f}s   (no head start: p50 {summary['brain_first_audio_p50_no_head_start']:.2f}s)")
    print(f"  brain turn complete p50 {summary['brain_turn_done_p50']:.2f}s")
    print("\nslowest:")
    for r in sorted(rows, key=lambda r: -r["first_audio"])[:5]: print(f"  {r['first_audio']:.2f}s  {r['lane']:7}  {r['text']}")

if __name__ == "__main__": main()
