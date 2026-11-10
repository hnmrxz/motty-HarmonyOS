#!/usr/bin/env python3
"""gen-sbom.py —— 生成/校验 SBOM（软件物料清单）

为什么需要：GPLv3 组合分发要求能说明"分发物里到底有什么"，上架应用市场也越来越要求 SBOM。
本脚本从**实际产物**（native/third_party/ohos/<arch>/lib/*.a + 头文件目录）出发，
配合人工维护的组件台账（COMPONENTS），产出 CycloneDX 风格的最小 SBOM。

机器判定：`--check` 会做两件事并以非零退出码报错
  1. SBOM 里声明的每个库文件必须真实存在（防止"清单过期"）
  2. 产物目录里的每个 .a 必须在 SBOM 里有归属（防止"偷偷链接了没登记的库"）

用法：
  python harmonyos/tools/gen-sbom.py                  # 生成 harmonyos/SBOM.json
  python harmonyos/tools/gen-sbom.py --check           # 只校验，不写文件
"""
import argparse
import hashlib
import json
import pathlib
import sys

REPO = pathlib.Path(__file__).resolve().parents[2]
THIRD_PARTY = REPO / "harmonyos" / "native" / "third_party" / "ohos"
SBOM_PATH = REPO / "harmonyos" / "SBOM.json"
ARCHES = ["x86_64", "arm64"]

# 组件台账：库文件名 -> 组件信息。新增三方库时必须在这里登记，否则 --check 会失败。
COMPONENTS = {
    "libssh2.a": {"name": "libssh2", "version": "1.11.1", "license": "BSD-3-Clause",
                  "use": "SSH2 传输/SFTP/端口转发"},
    "libmbedtls.a": {"name": "mbedTLS", "version": "3.6.2", "license": "Apache-2.0",
                     "use": "libssh2 的密码学后端"},
    "libmbedx509.a": {"name": "mbedTLS", "version": "3.6.2", "license": "Apache-2.0",
                      "use": "X.509（随 mbedTLS）"},
    "libmbedcrypto.a": {"name": "mbedTLS", "version": "3.6.2", "license": "Apache-2.0",
                        "use": "密码学原语（随 mbedTLS）"},
    "libeverest.a": {"name": "mbedTLS (everest)", "version": "3.6.2", "license": "Apache-2.0",
                     "use": "Curve25519（随 mbedTLS）"},
    "libp256m.a": {"name": "mbedTLS (p256-m)", "version": "3.6.2", "license": "Apache-2.0",
                   "use": "P-256（随 mbedTLS）"},
    "libvterm.a": {"name": "libvterm", "version": "neovim fork (2024)", "license": "MIT",
                   "use": "终端 VT 解析与回滚缓冲"},
    "libvncclient.a": {"name": "LibVNC (client)", "version": "0.9.14", "license": "GPL-2.0-or-later",
                       "use": "**已构建但未链接**（VNC 走自研 RFB 实现）"},
    "libvncserver.a": {"name": "LibVNC (server)", "version": "0.9.14", "license": "GPL-2.0-or-later",
                       "use": "**已构建但未链接**"},
    "libcrypto.a": {"name": "OpenSSL (libcrypto)", "version": "3.0.15", "license": "Apache-2.0",
                    "use": "FreeRDP 的 TLS/证书/哈希后端"},
    "libssl.a": {"name": "OpenSSL (libssl)", "version": "3.0.15", "license": "Apache-2.0",
                 "use": "TLS（随 OpenSSL）"},
    "libfreerdp3.a": {"name": "FreeRDP", "version": "3.9.0", "license": "Apache-2.0",
                      "use": "RDP 协议栈（当前仅连接路径）"},
    "libfreerdp-client3.a": {"name": "FreeRDP (client)", "version": "3.9.0", "license": "Apache-2.0",
                             "use": "RDP 客户端上下文（随 FreeRDP）"},
    "libwinpr3.a": {"name": "WinPR", "version": "3.9.0", "license": "Apache-2.0",
                    "use": "FreeRDP 的 Win32 兼容层（随 FreeRDP）"},
    "libwinpr-tools3.a": {"name": "WinPR tools", "version": "3.9.0", "license": "Apache-2.0",
                          "use": "WinPR 辅助（随 FreeRDP）"},
}


def sha256(path: pathlib.Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def collect() -> dict:
    files = []
    problems = []
    for arch in ARCHES:
        lib_dir = THIRD_PARTY / arch / "lib"
        if not lib_dir.is_dir():
            problems.append(f"缺少产物目录: {lib_dir}")
            continue
        for lib in sorted(lib_dir.glob("*.a")):
            comp = COMPONENTS.get(lib.name)
            if comp is None:
                problems.append(f"未登记的三方库: {arch}/{lib.name}（请在 COMPONENTS 里加一行）")
                continue
            files.append({
                "arch": arch,
                "file": f"native/third_party/ohos/{arch}/lib/{lib.name}",
                "sizeBytes": lib.stat().st_size,
                "sha256": sha256(lib),
                **comp,
            })
    return {"files": files, "problems": problems}


def build_doc(collected: dict) -> dict:
    # 按组件聚合（同一组件在不同架构下各有一份产物）
    components = {}
    for f in collected["files"]:
        key = (f["name"], f["version"], f["license"])
        entry = components.setdefault(key, {"name": f["name"], "version": f["version"],
                                            "license": f["license"], "use": f["use"],
                                            "artifacts": []})
        entry["artifacts"].append({"arch": f["arch"], "file": f["file"],
                                   "sizeBytes": f["sizeBytes"], "sha256": f["sha256"]})
    return {
        "bomFormat": "CycloneDX-like (minimal)",
        "specVersion": "1.4",
        "metadata": {
            "component": {
                "type": "application",
                "name": "com.motty.harmony",
                "version": "0.1.0",
                "licenses": [{"license": {"id": "GPL-3.0-or-later"}}],
            },
            "note": ("整体以 GPL-3.0-or-later 组合分发（含 GPL-2.0-or-later 的 LibVNC 已构建但未链接）。"
                     "详见 harmonyos/LICENSING.md。本文件由 harmonyos/tools/gen-sbom.py 生成，不要手改。"),
        },
        "components": sorted(components.values(), key=lambda c: c["name"]),
    }


def check(doc: dict, collected: dict) -> int:
    errors = list(collected["problems"])
    # 1) 清单里的文件必须存在
    for comp in doc["components"]:
        for art in comp["artifacts"]:
            path = REPO / "harmonyos" / art["file"]
            if not path.exists():
                errors.append(f"SBOM 声明的产物不存在: {art['file']}")
            elif sha256(path) != art["sha256"]:
                errors.append(f"产物哈希与 SBOM 不一致: {art['file']}")
    # 2) 产物目录里的每个 .a 都要有归属（collected 里已记录 problems）
    # 3) 用例/能力表一致性交给 spec/lint.py，这里不重复
    if errors:
        print("[SBOM] 校验失败：", file=sys.stderr)
        for e in errors:
            print("  -", e, file=sys.stderr)
        return 1
    print(f"[SBOM] 校验通过：{len(doc['components'])} 个组件、"
          f"{sum(len(c['artifacts']) for c in doc['components'])} 份产物")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true", help="只校验不写文件")
    args = ap.parse_args()

    collected = collect()
    doc = build_doc(collected)

    if args.check:
        if not SBOM_PATH.exists():
            print("[SBOM] 缺少 harmonyos/SBOM.json，先运行不带 --check 的生成", file=sys.stderr)
            return 1
        return check(json.loads(SBOM_PATH.read_text(encoding="utf-8")), collected)

    SBOM_PATH.write_text(json.dumps(doc, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"[SBOM] 已写入 {SBOM_PATH.relative_to(REPO)}：{len(doc['components'])} 个组件")
    return check(doc, collected)


if __name__ == "__main__":
    sys.exit(main())
