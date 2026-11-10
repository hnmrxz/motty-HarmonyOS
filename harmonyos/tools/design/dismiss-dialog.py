#!/usr/bin/env python3
"""按文本点掉设备上的遮挡物（典型：首次安装后的"是否将应用自动添加至桌面？"）。

存在理由：这类系统对话框会盖住应用 UI，让 spec runner 的所有选择器都"找不到"，
看起来像 spec 写错了。它是一个可复用的运维动作，不该每次临时敲坐标。

用法：
    python tools/design/dismiss-dialog.py --serial 127.0.0.1:10100 --text 不添加
    python tools/design/dismiss-dialog.py --serial 127.0.0.1:10100 --list     # 只列出可点文本
退出码：0 点掉了 / 1 没找到 / 2 环境错误
"""
import argparse
import json
import re
import subprocess
import sys
import tempfile
from pathlib import Path

HDC = r'C:\Program Files\Huawei\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe'
BOUNDS = re.compile(r'^\[(-?\d+),(-?\d+)\]\[(-?\d+),(-?\d+)\]$')


def hdc(serial, *args, shell=False, timeout=120):
    cmd = [HDC, '-t', serial]
    cmd += ['shell', ' '.join(args)] if shell else list(args)
    p = subprocess.run(cmd, capture_output=True, text=True, encoding='utf-8', errors='replace', timeout=timeout)
    return (p.stdout or '') + (p.stderr or '')


def walk(node):
    yield node
    for ch in node.get('children') or []:
        yield from walk(ch)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--serial', required=True)
    ap.add_argument('--text', help='要点击的节点文本（精确匹配）')
    ap.add_argument('--contains', help='要点击的节点文本（包含匹配）')
    ap.add_argument('--list', action='store_true', help='列出当前所有非空文本节点')
    args = ap.parse_args()

    if args.serial not in hdc(args.serial, 'list', 'targets'):
        print(f'设备 {args.serial} 不在 hdc 列表', file=sys.stderr)
        return 2

    hdc(args.serial, 'uitest start-daemon', shell=True)
    tmp = Path(tempfile.gettempdir()) / 'dismiss-layout.json'
    out = hdc(args.serial, 'uitest dumpLayout -p /data/local/tmp/dismiss.json', shell=True)
    if 'saved' not in out.lower() and 'success' not in out.lower():
        print(f'dumpLayout 失败: {out.strip()[:200]}', file=sys.stderr)
        return 2
    hdc(args.serial, 'file', 'recv', '/data/local/tmp/dismiss.json', str(tmp))
    if not tmp.exists():
        print('布局拉取失败', file=sys.stderr)
        return 2

    layout = json.loads(tmp.read_text(encoding='utf-8'))
    nodes = []
    for n in walk(layout):
        a = n.get('attributes') or {}
        t = (a.get('text') or '').strip()
        b = BOUNDS.match((a.get('bounds') or '').strip())
        if t and b:
            nodes.append((t, tuple(int(x) for x in b.groups())))

    if args.list:
        for t, (x1, y1, x2, y2) in nodes:
            print(f'{t!r}  bounds=[{x1},{y1}][{x2},{y2}]  center=({(x1+x2)//2},{(y1+y2)//2})')
        return 0

    if not args.text and not args.contains:
        print('需要 --text 或 --contains 或 --list', file=sys.stderr)
        return 2

    target = None
    for t, b in nodes:
        if (args.text and t == args.text) or (args.contains and args.contains in t):
            target = (t, b)
            break
    if not target:
        print(f'没找到文本 {args.text or args.contains!r}；可用 --list 查看当前文本', file=sys.stderr)
        return 1

    t, (x1, y1, x2, y2) = target
    cx, cy = (x1 + x2) // 2, (y1 + y2) // 2
    out = hdc(args.serial, f'uitest uiInput click {cx} {cy}', shell=True)
    print(f'clicked {t!r} at ({cx},{cy}) -> {out.strip()[:80]}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
