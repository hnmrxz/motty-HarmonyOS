#!/usr/bin/env python3
"""静态对比度自检（无需设备）：检查主题两套调色板里"文字色 vs 表面色"的 WCAG 对比度。

只覆盖 th() 里显式映射的表面/文字组合；彩色强调色（绿/蓝/红/紫）不在主题范围内，不检查。
阈值：正文 >= 4.5，次要文字 >= 3.0，边线 >= 1.4（仅为可辨识下限，不做严格 WCAG）。
"""
import sys

DARK_SURFACES = {"bgApp": "#17181C", "bgTop": "#0C0D10", "bgSide": "#101114",
                 "surface": "#1C1F24", "surface2": "#1E2127", "btn": "#23262B"}
DARK_TEXT = {"text": "#E8EAED", "text2": "#C7CBD1", "text3": "#8A8F98", "text4": "#6B7078"}

LIGHT_SURFACES = {"bgApp": "#F5F6F8", "bgTop": "#FFFFFF", "bgSide": "#FAFAFB",
                  "surface": "#FFFFFF", "surface2": "#F0F1F3", "btn": "#EDEFF2"}
LIGHT_TEXT = {"text": "#12141A", "text2": "#2A2D33", "text3": "#5A6068", "text4": "#7A8189"}


def lum(hexcolor: str) -> float:
    h = hexcolor.lstrip("#")
    r, g, b = (int(h[i:i + 2], 16) / 255 for i in (0, 2, 4))

    def f(c):
        return c / 12.92 if c <= 0.03928 else ((c + 0.055) / 1.055) ** 2.4

    return 0.2126 * f(r) + 0.7152 * f(g) + 0.0722 * f(b)


def ratio(a: str, b: str) -> float:
    la, lb = lum(a), lum(b)
    hi, lo = max(la, lb), min(la, lb)
    return (hi + 0.05) / (lo + 0.05)


def check(name, surfaces, texts):
    print(f"== {name} ==")
    bad = 0
    for tk, tv in texts.items():
        worst = min(((ratio(tv, sv), sk) for sk, sv in surfaces.items()))
        flag = "OK"
        if worst[0] < 3.0:
            flag = "LOW"
            bad += 1
        print(f"  {tk:6s} {tv}  worst {worst[0]:.2f} vs {worst[1]:8s} [{flag}]")
    return bad


bad = check("dark", DARK_SURFACES, DARK_TEXT) + check("light", LIGHT_SURFACES, LIGHT_TEXT)
print(f"text/surface combos below 3.0: {bad}")
sys.exit(0 if bad == 0 else 4)
