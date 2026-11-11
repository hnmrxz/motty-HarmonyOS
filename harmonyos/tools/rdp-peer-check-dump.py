"""rdp-peer-check-dump.py —— 被 rdp-peer-check.ps1 调用：按 id 点击并断言状态行"""
import argparse, json, pathlib, re, subprocess, sys, time

ap = argparse.ArgumentParser()
ap.add_argument("--serial", required=True)
ap.add_argument("--port", type=int, default=13389)
ap.add_argument("--hdc", required=True)
args = ap.parse_args()

TMP = pathlib.Path(r"E:\motty-HarmonyOS\harmonyos\.bin")

def sh(cmd, timeout=60):
    return subprocess.run([args.hdc, "-t", args.serial, "shell", cmd],
                          capture_output=True, text=True, timeout=timeout).stdout

def dump(tag="dd"):
    dev = f"/data/local/tmp/{tag}.json"
    local = TMP / f"{tag}.json"
    sh(f"uitest dumpLayout -p {dev}")
    subprocess.run([args.hdc, "-t", args.serial, "file", "recv", dev, str(local)],
                   capture_output=True, text=True, timeout=120)
    if not local.exists():
        return None
    try:
        return json.loads(local.read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        return None

def find(node, want, out):
    a = node.get("attributes") or {}
    if (a.get("id") or "") == want:
        out.append(a)
    for c in node.get("children") or []:
        find(c, want, out)

def click(want, retries=3):
    for _ in range(retries):
        layout = dump()
        if layout is None:
            time.sleep(1)
            continue
        hits = []
        find(layout, want, hits)
        if not hits:
            time.sleep(1)
            continue
        x1, y1, x2, y2 = [int(v) for v in re.findall(r"\d+", hits[0]["bounds"])]
        sh(f"uitest uiInput click {(x1 + x2) // 2} {(y1 + y2) // 2}")
        return True
    return False

def text_of(want, retries=3):
    for _ in range(retries):
        layout = dump()
        if layout is None:
            time.sleep(1)
            continue
        hits = []
        find(layout, want, hits)
        if hits:
            return hits[0].get("text") or ""
        time.sleep(0.5)
    return ""

sh("aa force-stop com.motty.harmony")
out = sh("aa start -a EntryAbility -b com.motty.harmony")
if "successfully" not in out:
    print(f"FAIL: 启动失败: {out[:200]}")
    sys.exit(2)
time.sleep(6)

if not click("diag/open"):
    print("FAIL: 找不到 diag/open")
    sys.exit(3)
time.sleep(1.5)
if not click("rdp/srv-start"):
    print("FAIL: 找不到 rdp/srv-start")
    sys.exit(4)
time.sleep(3.5)

state = text_of("rdp/srv-state")
print("state:", state[:300])
checks = [
    ("服务端处于 running", "running port=" in state),
    ("端口匹配", f"port={args.port}" in state),
    ("二进制含构建指纹", "built=" in state),
]
ok = True
for name, passed in checks:
    print(("PASS  " if passed else "FAIL  ") + name)
    ok = ok and passed
sys.exit(0 if ok else 1)
