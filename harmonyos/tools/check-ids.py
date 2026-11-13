#!/usr/bin/env python3
"""静态交叉检查（无需设备）：
1) spec 的 target:id 是否都存在于 Index.ets；
2) Index.ets 内静态 id 是否重复（重复会让用例解析到错误控件）。
退出码：0 全通过；1 有缺失 target；2 有重复 id。
"""
import pathlib, re, sys
from collections import Counter

ROOT = pathlib.Path(__file__).resolve().parents[1]
ETS = ROOT / "ohos/app/entry/src/main/ets/pages/Index.ets"

text = ETS.read_text(encoding="utf-8")
defined = set()
for m in re.finditer(r"\.id\('([^']*)'(?:\s*\+\s*[^)]*)?\)", text):
    defined.add(m.group(1))
for m in re.finditer(r"pcNavItem\('[^']*',\s*'([^']+)'", text):
    defined.add(m.group(1))
# 通过 @Builder 参数传入的 id（如 settingsOpt(label, 'id', ...)）
for m in re.finditer(r"\b(?:btnPrimary|btnSecondary|btnDanger|settingsOpt)\([^,]+,\s*'([^']+)'", text):
    defined.add(m.group(1))
dynamic = {d for d in defined if d.endswith(("/", "-"))}

static_ids = [m.group(1) for m in re.finditer(r"\.id\('([^']*)'\)", text)]
dups = {k: v for k, v in Counter(static_ids).items() if v > 1}

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

print(f"defined ids: {len(defined)}  dynamic: {len(dynamic)}  dup: {len(dups)}")
rc = 0
if dups:
    print("DUPLICATE static ids:")
    for k, v in dups.items():
        print(f"  {k} x{v}")
    rc = 2
if missing:
    print(f"MISSING targets: {len(missing)}")
    for f, t in missing:
        print(f"  {f}: {t}")
    rc = 1 if rc == 0 else rc
if rc == 0:
    print("OK: targets exist, ids unique")
sys.exit(rc)
