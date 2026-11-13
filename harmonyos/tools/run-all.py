import json, pathlib, subprocess, sys, time, re

try:
    import yaml
except Exception:
    yaml = None

FIXTURE = r"E:\motty-HarmonyOS\harmonyos\.bin\sshfixture.exe"
HOSTKEY = r"E:\motty-HarmonyOS\harmonyos\.bin\.sshfixture\hostkey"
HDC = r"C:\Program Files\Huawei\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe"
_current = {"vncAuth": None, "vncResize": None}

def restart_fixture(spec_path):
    """按 spec 的 fixture 声明重启夹具（vncAuth / vncResize 两种参数互斥地影响 VNC 行为）。"""
    global _current
    want = {"vncAuth": False, "vncResize": False}
    if yaml is not None:
        try:
            doc = yaml.safe_load(spec_path.read_text(encoding="utf-8"))
            fx = (doc or {}).get("fixture") or {}
            want["vncAuth"] = bool(fx.get("vncAuth", False))
            want["vncResize"] = bool(fx.get("vncResize", False))
        except Exception:
            pass
    if _current["vncAuth"] == want["vncAuth"] and _current["vncResize"] == want["vncResize"]:
        return
    subprocess.run(["powershell", "-NoProfile", "-Command",
                    "Get-Process sshfixture -ErrorAction SilentlyContinue | Stop-Process -Force"],
                   capture_output=True, text=True)
    time.sleep(0.6)
    subprocess.run([HDC, "-t", os.environ.get("MOTTY_SERIAL", "127.0.0.1:10100"), "rport", "tcp:2222", "tcp:2223"], capture_output=True, text=True)
    subprocess.run([HDC, "-t", os.environ.get("MOTTY_SERIAL", "127.0.0.1:10100"), "rport", "tcp:5901", "tcp:5901"], capture_output=True, text=True)
    args = [FIXTURE, "-addr", "127.0.0.1:2223", "-hostkey", HOSTKEY, "-hostkeytype", "rsa"]
    if want["vncAuth"]:
        args += ["-vnc-auth", "secret"]
    if want["vncResize"]:
        args += ["-vnc-resize"]
    subprocess.Popen(args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(1.6)
    _current = want
    print(f"     [fixture] vncAuth={want['vncAuth']} vncResize={want['vncResize']}", flush=True)

root = pathlib.Path(r"E:\motty-HarmonyOS\harmonyos")
runner = root / "spec" / "run.py"
import os
run_id = os.environ.get("MOTTY_RUN_ID", "full21")
outdir = root / "spec" / "evidence" / "runs" / run_id
outdir.mkdir(parents=True, exist_ok=True)
py = r"C:\Python315\python.exe"
serial = os.environ.get("MOTTY_SERIAL", "127.0.0.1:10100")

resume = "--resume" in sys.argv
# --quick：冒烟子集（12 条，覆盖最容易被改坏的路径，约 12 分钟）
QUICK = ["host.manage", "host.icon", "host.lastused", "host.detail", "host.group-order",
         "ssh.connect-from-list", "terminal.vt", "sftp.browse",
         "forward.typed", "logs.search", "vnc.host-session", "rdp.session-view"]
only = ""
for i, a in enumerate(sys.argv):
    if a == "--only" and i + 1 < len(sys.argv):
        only = sys.argv[i + 1]
specs = sorted((root / "spec" / "scenarios").glob("*.yaml"))
if "--quick" in sys.argv:
    specs = [sp for sp in specs if sp.stem in QUICK]
if only:
    prefixes = [x.strip() for x in only.split(",") if x.strip()]
    specs = [sp for sp in specs if any(sp.stem.startswith(pf) for pf in prefixes)]
results = []
for i, sp in enumerate(specs):
    restart_fixture(sp)
    if resume and (outdir / sp.stem / "result.json").exists():
        print(f"[{i+1}/{len(specs)}] SKIP {sp.stem} (已有结果)", flush=True)
        continue
    t0 = time.time()
    out = outdir / sp.stem
    proc = subprocess.run([py, str(runner), str(sp), "--serial", serial, "--profile", "2in1",
                           "--fresh", "--out", str(out)], capture_output=True, text=True)
    dt = round(time.time() - t0, 1)
    res = None
    rp = out / "result.json"
    if rp.exists():
        try:
            res = json.loads(rp.read_text(encoding="utf-8"))
        except Exception:
            res = None
    passed = bool(res and res.get("passed"))
    err = (res or {}).get("error", "")
    # 仅对"第 1 步就失败"的基础设施抖动重跑一次：批量里偶发首启空屏（应用还没画出来），
    # 这不是产品失败；其它步骤的失败一律不重试，避免掩盖真实回归。
    if not passed and re.search(r"step 1 \(", str(err)):
        print(f"     [retry] {sp.stem} 首步失败，重跑一次：{str(err)[:80]}", flush=True)
        subprocess.run([HDC, "-t", serial, "shell", "aa force-stop com.motty.harmony"], capture_output=True, text=True)
        time.sleep(2.0)
        t1 = time.time()
        out2 = outdir / (sp.stem + "-retry")
        subprocess.run([py, str(runner), str(sp), "--serial", serial, "--profile", "2in1",
                        "--fresh", "--out", str(out2)], capture_output=True, text=True)
        rp2 = out2 / "result.json"
        if rp2.exists():
            try:
                res2 = json.loads(rp2.read_text(encoding="utf-8"))
            except Exception:
                res2 = None
            if res2 and res2.get("passed"):
                passed = True
                dt = round(dt + (time.time() - t1), 1)
                err = ""
                print(f"     [retry] {sp.stem} 重跑通过（retry 结果在 {out2.name}）", flush=True)
    results.append({"spec": sp.stem, "passed": passed, "seconds": dt, "error": str(err)[:200]})
    print(f"[{i+1}/{len(specs)}] {'PASS' if passed else 'FAIL'} {sp.stem} ({dt}s)", flush=True)

passed_n = sum(1 for r in results if r["passed"])
summary = {"total": len(results), "passed": passed_n, "failed": len(results) - passed_n,
           "results": results, "at": time.strftime("%Y-%m-%dT%H:%M:%S")}
(outdir / "summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2), encoding="utf-8")
print(f"SUMMARY passed={passed_n}/{len(results)}", flush=True)
