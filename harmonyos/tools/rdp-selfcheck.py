#!/usr/bin/env python3
"""RDP 现状自检：把 RDP 相关的三条机器判定用例串起来跑，并给出汇总。

用法：
  python harmonyos/tools/rdp-selfcheck.py --serial 127.0.0.1:10100 --profile 2in1
  python harmonyos/tools/rdp-selfcheck.py --serial <真机序列号> --profile device --fresh

退出码：
  0  三条全部通过
  1  有用例失败
  2  参数/环境问题（找不到 run.py、缺 serial）

诚实说明：
  - 这三条用例覆盖的是**现状**：能连接、能解码、且界面诚实标注"实验性"。
  - 它们**不**证明"画面内容正确"或"输入可用"——那两项仍是 E3。
"""
from __future__ import annotations

import argparse
import json
import pathlib
import subprocess
import sys

SPECS = [
    ("rdp.client-connect", "客户端与服务端完成协商并 connected"),
    ("rdp.client-render", "客户端收到并解码桌面更新（尺寸/像素数）"),
    ("ui.rdp-experimental", "界面诚实标注 RDP 为实验性"),
]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--serial", required=True, help="设备序列号，例如 127.0.0.1:10100")
    ap.add_argument("--profile", default="2in1", choices=["2in1", "tablet", "device"])
    ap.add_argument("--fresh", action="store_true", help="先卸载+安装再跑（清数据）")
    ap.add_argument("--out-dir", default="", help="证据输出目录")
    args = ap.parse_args()

    repo = pathlib.Path(__file__).resolve().parents[2]
    run_py = repo / "harmonyos" / "spec" / "run.py"
    scen = repo / "harmonyos" / "spec" / "scenarios"
    if not run_py.exists():
        print(f"找不到 runner: {run_py}")
        return 2

    out_root = pathlib.Path(args.out_dir) if args.out_dir else (repo / "harmonyos" / "spec" / "runs" / "rdp-selfcheck")
    rows = []
    for spec_id, desc in SPECS:
        spec_path = scen / f"{spec_id}.yaml"
        if not spec_path.exists():
            rows.append((spec_id, desc, "MISSING", "spec 文件不存在"))
            continue
        cmd = [sys.executable, str(run_py), str(spec_path),
               "--serial", args.serial, "--profile", args.profile,
               "--out", str(out_root / spec_id)]
        if args.fresh:
            cmd.append("--fresh")
        proc = subprocess.run(cmd, capture_output=True, text=True)
        passed = '"passed": true' in (proc.stdout + proc.stderr)
        err = ""
        for line in (proc.stdout + proc.stderr).splitlines():
            if line.strip().startswith('"error"'):
                err = line.strip().strip(",")
                break
        rows.append((spec_id, desc, "PASS" if passed else "FAIL", err))

    width = max(len(r[0]) for r in rows)
    print("\n=== RDP 现状自检 ===")
    print(f"设备 {args.serial} / 画像 {args.profile}")
    for spec_id, desc, status, err in rows:
        line = f"  {spec_id:<{width}}  {status:<6}  {desc}"
        if err:
            line += f"\n  {' ' * width}          {err[:160]}"
        print(line)

    failed = [r for r in rows if r[2] != "PASS"]
    print()
    if failed:
        print(f"结果：{len(rows) - len(failed)}/{len(rows)} 通过 —— 有失败项，见上")
        print("提醒：本自检只验证‘能连接/能解码/界面诚实’，不验证画面内容与输入。")
        return 1
    print(f"结果：{len(rows)}/{len(rows)} 全部通过")
    print("边界：画面内容正确与输入回传仍属 E3（未验证）。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
