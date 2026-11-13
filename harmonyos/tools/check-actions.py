#!/usr/bin/env python3
"""静态检查：带 id 的交互控件是否真的接了行为（无需设备）。

规则：Button/Image 带 .id(...)，且在其后 8 行内没有 onClick/onChange/onSubmit/onHover/bindMenu
      => 视为"死控件"（点了没反应）。
例外：id 以 /frame、/canvas、/avatar 结尾的纯展示图不算。
退出码：0 通过；3 有死控件。
"""
import pathlib, re, sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
ETS = ROOT / "ohos/app/entry/src/main/ets/pages/Index.ets"
lines = ETS.read_text(encoding="utf-8").splitlines()

EXEMPT_SUFFIX = ("/frame", "/canvas", "/avatar", "/placeholder", "/hint", "-frame")
HANDLERS = ("onClick(", "onChange(", "onSubmit(", "onHover(", "bindMenu(", "bindContextMenu(")

dead = []
for i, line in enumerate(lines):
    m = re.search(r"\.id\('([^']+)'\)", line)
    if not m:
        continue
    ident = m.group(1)
    if ident.endswith(EXEMPT_SUFFIX):
        continue
    decl = ""
    for k in range(i, max(-1, i - 2), -1):
        stripped = lines[k].strip()
        if stripped.startswith(("Text(", "TextInput(")):
            decl = ""
            break
        if re.match(r"(Button|Image)\b", stripped):
            decl = stripped
            break
    if not decl:
        continue
    window = "\n".join(lines[i:i + 8])
    if any(h in window for h in HANDLERS):
        continue
    dead.append((i + 1, ident, decl[:36]))

print(f"dead controls: {len(dead)}")
for ln, ident, decl in dead:
    print(f"  line {ln}: {ident}  ({decl})")
sys.exit(3 if dead else 0)
