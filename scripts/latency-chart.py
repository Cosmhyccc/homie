#!/usr/bin/env python3
"""Draws docs/assets/latency.svg from Tests/local_eval/results/*.json (homie bench output).
Usage: python3 scripts/latency-chart.py   — re-run after a bench so the README shows measured numbers only."""
import glob, json, os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
results = sorted(glob.glob(os.path.join(ROOT, "Tests/local_eval/results/*.json")))
runs = []
for path in results:
    d = json.load(open(path))
    m = d["machine"]
    tier = d.get("tier", "full")
    label = f'{m["chip"]} · {m["ram_gb"]} GB · {"homie lite (2B)" if tier == "lite" else "homie (4B)"}'
    runs.append((label, [("Everyday commands", d["instant_first_audio_p50"], d["instant_first_audio_p90"]),
                         ("Questions for the brain", d["brain_first_audio_p50"], d["brain_first_audio_p90"])]))

W, left, scale_s = 760, 230, 2.0          # axis runs 0–2 s
bar_w = W - left - 40
row_h, group_gap, top = 34, 26, 64
H = top + sum(len(rows) * row_h + group_gap + 22 for _, rows in runs) + 40
x = lambda s: left + min(s, scale_s) / scale_s * bar_w

svg = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" width="{W}" height="{H}" font-family="-apple-system,BlinkMacSystemFont,Segoe UI,Helvetica,Arial,sans-serif">',
       '<style>.bg{fill:#ffffff}.t{fill:#1f2328}.m{fill:#59636e}.g{stroke:#d1d9e0}@media (prefers-color-scheme:dark){.bg{fill:#0d1117}.t{fill:#f0f6fc}.m{fill:#9198a1}.g{stroke:#3d444d}}</style>',
       f'<rect class="bg" x="0" y="0" width="{W}" height="{H}" rx="12"/>',
       f'<text x="24" y="30" class="t" font-size="17" font-weight="600">From the end of your sentence to homie\'s first sound</text>',
       f'<text x="24" y="50" class="m" font-size="12.5">p50 bar, p90 tick · includes the wait to be sure you stopped talking · measured with Tests/local_eval/bench.sh</text>']
for tick in [0, 0.5, 1.0, 1.5, 2.0]:
    svg.append(f'<line x1="{x(tick):.1f}" y1="{top}" x2="{x(tick):.1f}" y2="{H-34}" class="g" stroke-width="1"/>')
    svg.append(f'<text x="{x(tick):.1f}" y="{H-16}" class="m" font-size="11.5" text-anchor="middle">{tick:g} s</text>')
y = top
for label, rows in runs:
    y += 16
    svg.append(f'<text x="24" y="{y}" class="t" font-size="13" font-weight="600">{label}</text>')
    y += 10
    for name, p50, p90 in rows:
        color = "#e5577f" if name.startswith("Everyday") else "#3b82f6"
        svg.append(f'<text x="24" y="{y+19}" class="t" font-size="13">{name}</text>')
        svg.append(f'<rect x="{left}" y="{y+6}" width="{x(p50)-left:.1f}" height="18" rx="4" fill="{color}"/>')
        svg.append(f'<line x1="{x(p90):.1f}" y1="{y+3}" x2="{x(p90):.1f}" y2="{y+27}" stroke="{color}" stroke-width="2.5"/>')
        svg.append(f'<text x="{x(p90)+8:.1f}" y="{y+19}" class="m bglabel" font-size="12" font-weight="500">{p50:.2f} s · p90 {p90:.2f} s</text>')
        y += row_h
    y += group_gap
svg.append("</svg>")
out = os.path.join(ROOT, "docs/assets/latency.svg")
os.makedirs(os.path.dirname(out), exist_ok=True)
open(out, "w").write("\n".join(svg))
print("wrote", os.path.relpath(out, ROOT), "from", len(runs), "bench runs")
