import json, time, urllib.request, sys
import sys, os; sys.path.insert(0, "/private/tmp/pixie-eval")
from cases import CASES
import os; os.chdir("/private/tmp/pixie-eval"); sys.path.insert(0, "."); tools = json.load(open(sys.argv[1]))
chat = [{"type":"function","function":{"name":t["name"],"description":t["description"],"parameters":t["parameters"]}} for t in tools]
SYS = open('sys.txt').read()
DEFAULTS = {"open_website": {"browser": ""}, "search_web": {"site": "web", "browser": ""}, "read_calendar": {"start_date": "", "day_offset": 0, "days": 1},
 "create_reminder": {"due_at": "", "list_name": ""}, "read_reminders": {"list_name": ""}, "schedule_alert": {"title": "Timer", "seconds": 0, "at": ""},
 "mac_setting": {"level": -1}, "find_file": {"choice": 0, "action": "open"}, "take_screenshot": {"kind": "full"}, "set_music_volume": {"amount": 10}, "play_apple_music": {"artist": ""}}
def repair(name, a, said):  # mirrors LocalRouter.repair
    for k, v in DEFAULTS.get(name, {}).items(): a.setdefault(k, v)
    for k in ("browser","list_name"):
        if isinstance(a.get(k),str) and a[k] and a[k].lower() not in said.lower(): a[k]=""
    if name=="schedule_alert" and isinstance(a.get("seconds"),int) and a["seconds"]>0 and a.get("at"): a["at"]=""
    if name=="mac_setting" and a.get("action")!="set": a["level"]=-1
    if name=="read_calendar" and a.get("start_date"):
        if a["start_date"]=="2026-11-17": a["start_date"]=""
        else: a["day_offset"]=0
    return a
# Mirrors LocalTools.grounded: an action needs a matching word in what the user said.
GROUND = {
 "play_apple_music": r"play|put on|listen|hear|song|music|track|album|bump|throw on|queue",
 "search_spotify": r"play|put on|listen|hear|song|music|track|album|spotify|bump|throw on|queue",
 "control_apple_music": r"pause|stop|resume|skip|next|previous|back|play|music|song|track|apple music",
 "control_spotify": r"pause|stop|resume|skip|next|previous|back|play|music|song|track|spotify",
 "set_music_volume": r"volume|louder|quieter|softer|turn|music",
 "create_note": r"note|write|jot",
 "create_reminder": r"remind|reminder|to ?-?do|list|forget|add",
 "schedule_alert": r"timer|alarm|wake|remind|minute|second|hour",
 "cancel_alert": r"cancel|stop|delete|remove|clear|turn off",
 "empty_trash": r"trash|bin",
 "send_chat_message": r"send|text|message|tell|dm|reply|say",
 "type_in_app": r"type|write|send|text|message|tell|dm|reply|say|enter|fill",
 "mac_setting": r"dark|light|wi-?fi|mute|volume|louder|quieter|softer|bright|dim|sound|loud|quiet",
 "take_screenshot": r"screen ?shot|capture|snap|grab",
 "quit_app": r"quit|close|kill|exit",
 "open_app": r"open|launch|start|go to|pull up|bring up|show|switch|use|type|send|text|message",
 "open_website": r"open|go to|pull up|bring up|show|website|site|\.com|visit|read",
 "search_web": r"search|google|look up|find|youtube|what|who|how|where|when|why",
 "arrange_windows": r"left|right|side|arrange|split|window|move|put|half",
 "set_pixie_size": r"big|small|giant|tiny|size|shrink|grow|huge|large",
 "find_file": r"find|file|where|locate|search|open|folder|document",
 "press_keys": r"press|hit|key|shortcut|tab|enter|return|escape|command|cmd",
 "click_app_control": r"click|press|tap|select|choose|open|send|play|hit",
 "switch_arc_tab": r"tab|switch|go to|arc",
}
import re as _re
def grounded(name, said):
    pat = GROUND.get(name)
    return pat is None or _re.search(pat, said.lower()) is not None
def ask(text, _retry=True):
    body = {"messages":[{"role":"system","content":SYS},{"role":"user","content":"[Nov 17, 2026 at 3:12 PM America/Chicago · frontmost app: Safari]\n"+text}],
            "model":os.environ.get("EVAL_MODEL","local"),"chat_template_kwargs":{"enable_thinking":False},"tools":chat,"tool_choice":"auto","temperature":0.0,"max_tokens":200,"cache_prompt":True}
    t = time.time()
    r = json.load(urllib.request.urlopen(urllib.request.Request(os.environ.get("EVAL_URL","http://127.0.0.1:19890")+"/v1/chat/completions", json.dumps(body).encode(), {"Content-Type":"application/json"})))
    m = r["choices"][0]["message"]; tm = r.get("timings", {})
    calls = m.get("tool_calls") or []
    if calls and os.environ.get("GUARD", "1") == "1" and not all(grounded(c["function"]["name"], text) for c in calls):
        body["tool_choice"] = "none"   # the call wasn't grounded in the user's words: answer in words instead
        r = json.load(urllib.request.urlopen(urllib.request.Request(os.environ.get("EVAL_URL","http://127.0.0.1:19890")+"/v1/chat/completions", json.dumps(body).encode(), {"Content-Type":"application/json"})))
        m = r["choices"][0]["message"]; calls = []
    if calls:
        f = calls[0]["function"]; args = json.loads(f["arguments"] or "{}"); name = f["name"]
        if name == "cancel_alert" and not str(args.get("id","")).startswith("pixie.alert."): name, args = "list_alerts", {}   # invented ID: look first
        return name, repair(name, args, text), time.time()-t, tm
    return None, {"reply": (m.get("content") or "")[:70]}, time.time()-t, tm
ask("hi")  # warm the prefix
ok = 0; total = 0; gen = 0
for said, check in CASES:
    name, args, secs, tm = ask(said)
    good = check(name, args); ok += good; total += secs; gen += tm.get("predicted_n", 0)
    print(("PASS " if good else "FAIL ") + f"{secs:4.1f}s  {said!r:58} -> {name} {json.dumps(args)[:110]}")
print(f"\n{sys.argv[1]}: {ok}/{len(CASES)} correct, avg {total/len(CASES):.1f}s per turn, avg {gen/len(CASES):.0f} tokens written")
