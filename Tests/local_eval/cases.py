# (said, check(name, args) -> bool). None name = reply without a tool.
def tool(*names, **want):
    def check(name, args):
        if name not in names: return False
        for k, v in want.items():
            got = args.get(k)
            if callable(v):
                if not v(got): return False
            elif got != v: return False
        return True
    return check
def none(name, args): return name is None
has = lambda s: (lambda v: isinstance(v, str) and s in v.lower())
CASES = [
 ("play blinding lights by the weeknd", tool("search_spotify", "play_apple_music")),
 ("what's on my calendar tomorrow", lambda n, a: n == "read_calendar" and ((a.get("day_offset") == 1 and not a.get("start_date")) or (a.get("start_date") == "2026-11-18" and a.get("day_offset") == 0))),
 ("what do I have going on today", tool("read_calendar", day_offset=0)),
 ("remind me to call mom at 5pm", tool("create_reminder", due_at=has("t17:00"))),
 ("add milk to my reminders", tool("create_reminder", title=has("milk"), due_at="")),
 ("set an alarm for 7am tomorrow", tool("schedule_alert", at=has("t07:00"), seconds=0)),
 ("make a note called groceries with eggs milk and bread", tool("create_note", title=has("grocer"))),
 ("find my resume", tool("find_file", query=has("resume"), choice=0)),
 ("put safari on the left and notes on the right", tool("arrange_windows")),
 ("open spotify and play drake", tool("open_app", "search_spotify")),
 ("what timers do I have", tool("list_alerts")),
 ("cancel my timer", tool("list_alerts")),
 ("switch to my mixpanel tab", tool("switch_arc_tab", query=has("mixpanel"))),
 ("type hello world in notes", tool("open_app", "inspect_app")),
 ("how are you", none),
 ("tell me a joke", none),
 ("what's the capital of france", none),
 ("explain a black hole in one sentence", none),
 ("empty the trash", tool("empty_trash", confirmed=False)),
 ("take a screenshot of part of my screen", tool("take_screenshot", kind="selection")),
 ("turn the brightness all the way up", tool("mac_setting", setting="brightness")),
 ("make apple music quieter", tool("set_music_volume", mode="decrease")),
 ("what's on my to do list", tool("read_reminders")),
 ("search google for cheap flights to tokyo", tool("search_web", query=has("tokyo"))),
 ("open the new york times website", tool("open_website", url=has("nytimes"))),
 ("send hi to abby on discord", tool("open_app", "inspect_app")),
 ("what reminders do I have on my work list", tool("read_reminders", list_name=has("work"))),
 ("set a timer for 3 minutes for the eggs", tool("schedule_alert", seconds=180, at="")),
 ("can you get really big", tool("set_pixie_size", size="giant")),
 ("put my mac in dark mode and turn the volume down", tool("mac_setting")),
]
