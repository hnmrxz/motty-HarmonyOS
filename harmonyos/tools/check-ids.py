#!/usr/bin/env python3
"""静态交叉检查：spec 的 target: id:xxx 是否都存在于 Index.ets（无需设备）。"""
import pathlib, re, sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
ETS = ROOT / "ohos/app/entry/src/main/ets/pages/Index.ets"

text = ETS.read_text(encoding="utf-8")
defined = set()
for m in re.finditer(r"\.id\('([^']*)'(?:\s*\+\s*[^)]*)?\)", text):
    defined.add(m.group(1))
for m in re.finditer(r"pcNavItem\('[^']*',\s*'([^']+)'", text):
    defined.add(m.group(1))
dynamic = {d for d in defined if d.endswith(("/", "-"))}

missing = []
for sp in sorted((ROOT / "spec/scenarios").glob("*.yaml")):
    body = sp.read_text(encoding="utf-8")
    for m in re.finditer(r"target:\s*id:([A-Za-z0-9_\-/]+)", body):
        tid = m.group(1)
        if tid in defined:
            continue
        if any(tid.startswith(p) for p in dynamic):
            continue
        missing.append((sp.name, tid))

print(f"defined ids: {len(defined)}  dynamic: {len(dynamic)}")
if not missing:
    print("OK: all spec targets exist")
    sys.exit(0)
print(f"MISSING: {len(missing)}")
for f, t in missing:
    print(f"  {f}: {t}")
sys.exit(1)
