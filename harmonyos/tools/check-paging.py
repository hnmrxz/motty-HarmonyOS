#!/usr/bin/env python3
"""分页规则静态检查（无需设备）。

诊断面板是分页的：调试页的 id 需要先点 diag/tab-debug，快照页需要 diag/tab-snap，
RDP 页需要 diag/tab-rdp（默认页）。用例若直接点某页的控件而没有先切到该页，
运行时就会"选择器未命中"。

本脚本按"首次出现顺序"检查每个 spec 的 target 是否在其所属页已激活之后。
"""
import pathlib, re, sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
TAB_BY_PREFIX = [
    ("catalog/", "debug"), ("net/", "debug"), ("ssh/probe", "debug"), ("ssh/hostkey-check", "debug"),
    ("vnc/result", "debug"), ("terminal/demo", "debug"), ("terminal/shell", "debug"),
    ("terminal/vt", "debug"), ("terminal/vt2", "debug"), ("terminal/pty-status", "debug"),
    ("terminal/sel", "debug"), ("terminal/clip", "debug"), ("terminal/history", "debug"),
    ("terminal/vt-status", "debug"), ("vnc/session", "debug"), ("vnc/session-bad", "debug"),
    ("rdp/canvas", "snap"), ("rdp/ticks", "snap"), ("rdp/experimental", "snap"),
    ("rdp/srv-", "rdp"), ("rdp/probe-", "rdp"), ("rdp/render", "rdp"), ("rdp/input", "rdp"),
    ("rdp/tcpprobe", "rdp"), ("rdp/host", "rdp"), ("rdp/port", "rdp"), ("rdp/user", "rdp"),
    ("rdp/pass", "rdp"), ("rdp/nla", "rdp"), ("rdp/result", "rdp"), ("rdp/frame", "rdp"),
    ("rdp/session", "rdp"),
]
TAB_CLICK = {"debug": "diag/tab-debug", "snap": "diag/tab-snap", "rdp": "diag/tab-rdp"}

def tab_of(tid):
    for prefix, tab in TAB_BY_PREFIX:
        if tid.startswith(prefix):
            return tab
    return None

bad = []
for sp in sorted((ROOT / "spec/scenarios").glob("*.yaml")):
    active = None
    for line in sp.read_text(encoding="utf-8").splitlines():
        m = re.search(r"target:\s*id:([A-Za-z0-9_\-/]+)", line)
        if m:
            tid = m.group(1)
            if tid == TAB_CLICK["debug"]:
                active = "debug"; continue
            if tid == TAB_CLICK["snap"]:
                active = "snap"; continue
            if tid == TAB_CLICK["rdp"]:
                active = "rdp"; continue
            want = tab_of(tid)
            if want and want != (active or "rdp"):
                bad.append((sp.name, tid, want, active or "rdp"))
print(f"scenarios: {len(list((ROOT / 'spec/scenarios').glob('*.yaml')))}  paging violations: {len(bad)}")
for f, tid, want, got in bad:
    print(f"  {f}: target {tid} 需要先切到 {want}（当时是 {got}）")
sys.exit(1 if bad else 0)
