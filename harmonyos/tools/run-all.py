import json, pathlib, subprocess, sys, time

root = pathlib.Path(r"E:\motty-HarmonyOS\harmonyos")
runner = root / "spec" / "run.py"
outdir = root / "spec" / "evidence" / "runs" / "full21"
outdir.mkdir(parents=True, exist_ok=True)
py = r"C:\Python315\python.exe"
serial = "127.0.0.1:10100"

specs = sorted((root / "spec" / "scenarios").glob("*.yaml"))
results = []
for i, sp in enumerate(specs):
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
    results.append({"spec": sp.stem, "passed": passed, "seconds": dt, "error": str(err)[:200]})
    print(f"[{i+1}/{len(specs)}] {'PASS' if passed else 'FAIL'} {sp.stem} ({dt}s)", flush=True)

passed_n = sum(1 for r in results if r["passed"])
summary = {"total": len(results), "passed": passed_n, "failed": len(results) - passed_n,
           "results": results, "at": time.strftime("%Y-%m-%dT%H:%M:%S")}
(outdir / "summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2), encoding="utf-8")
print(f"SUMMARY passed={passed_n}/{len(results)}", flush=True)
