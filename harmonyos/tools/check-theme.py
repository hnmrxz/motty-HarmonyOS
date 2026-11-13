#!/usr/bin/env python3
"""静态检查：灰色系颜色字面量是否都走了主题函数 th()（无需设备）。"""
import pathlib, re, sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
ETS = ROOT / "ohos/app/entry/src/main/ets/pages/Index.ets"
text = ETS.read_text(encoding="utf-8")

# 有意保留的固定对比色（等设备目视后再决定是否主题化）：
#   #E6E6E6/#1A1A1A  终端工具条的历史"浅底深字"按钮
#   #12141A          深色文字（用在浅色 chip 上，深浅主题都需要深字）
#   #999999/#666666/#DDDDDD  历史边线/次要文字
#   #000000/#1E1E1E/#D4D4D4/#333333  终端永远是深色底（不随主题）
#   #888888/#FAFAFA  固定对比（指纹灰字 / 浅色信息盒）
ALLOW = {"#E6E6E6", "#1A1A1A", "#12141A", "#999999", "#666666", "#DDDDDD", "#3A3E45",
         "#000000", "#1E1E1E", "#D4D4D4", "#333333", "#888888", "#FAFAFA",
         # th() 内部返回的浅色值（它们本来就是"浅色模式的值"，不是漏主题化）
         "#F5F6F8", "#FFFFFF", "#FAFAFB", "#F0F1F3", "#EDEFF2", "#E3E6EA",
         "#5A6068", "#7A8189", "#D7DBE0", "#E7EAEE", "#EAEDF1", "#DDE1E6", "#CFD4DA"}

offenders = []
for m in re.finditer(r"'(#[0-9A-Fa-f]{6})'", text):
    if text[max(0, m.start() - 9):m.start()].endswith("this.th("):
        continue
    hexv = m.group(1)
    r, g, b = (int(hexv[i:i + 2], 16) for i in (1, 3, 5))
    if max(r, g, b) - min(r, g, b) > 12:
        continue
    if hexv.upper() in ALLOW:
        continue
    line = text.count("\n", 0, m.start()) + 1
    offenders.append((line, hexv))

print(f"non-themed gray colors: {len(offenders)}")
for ln, c in offenders[:60]:
    print(f"  line {ln}: {c}")
sys.exit(5 if offenders else 0)
