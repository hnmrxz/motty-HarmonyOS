#!/usr/bin/env python3
"""spec-lint: 校验 harmonyos/spec/scenarios/*.yaml。

依赖：pyyaml、jsonschema（仅开发期工具，不进交付物）。

除了 JSON Schema 之外，这里刻意加了几条 schema 表达不了的规则——它们是踩过坑之后
才写下来的，属于"看起来合规但实际会失效"的形态：

  1. profile 必须同时含 2in1 与 tablet（双画像是我们对 1:1 的定义的一部分）
  2. 选择器禁止纯坐标（坐标在双画像/不同 DPI 下必然失效）
  3. capabilities 必须存在于 capabilities.json（否则断言的是不存在的能力）
  4. 引用 T3 能力是错误（T3 已被移除，断言它没有意义）
  5. 至少一条 asserts 是"可判定"的（text/state/layout/screenRegex/wireLog/count/absent），
     只有截图不算验收
  6. evidence.limits 必须有实质内容（长度下限 + 不得出现"待补"这类占位词）

用法：
    python harmonyos/spec/lint.py [--strict]
退出码：0 全部通过；1 有错误。
"""
import argparse
import json
import pathlib
import re
import sys

try:
    import yaml
    import jsonschema
except ImportError:
    print('需要 pyyaml 与 jsonschema：python -m pip install pyyaml jsonschema', file=sys.stderr)
    sys.exit(2)

ROOT = pathlib.Path(__file__).resolve().parent
SCHEMA = ROOT / 'schema' / 'scenario.schema.json'
CAPS = ROOT / 'capabilities.json'
SCENARIOS = ROOT / 'scenarios'

JUDGEABLE = {'text', 'absent', 'state', 'layout', 'screenRegex', 'wireLog', 'count', 'capabilityDisabled'}
COORD_RE = re.compile(r'^-?\d+(\s*,\s*|\s+)-?\d+$')
PLACEHOLDER = ('待补', 'todo', 'tbd', 'fixme', '未写')


def load_caps():
    with open(CAPS, encoding='utf-8') as fh:
        doc = json.load(fh)
    return {e['id']: e for e in doc['entries']}


def check(path, schema, caps, errors):
    rel = path.relative_to(ROOT.parent.parent)
    try:
        with open(path, encoding='utf-8') as fh:
            doc = yaml.safe_load(fh)
    except Exception as exc:  # noqa: BLE001
        errors.append(f'{rel}: YAML 解析失败: {exc}')
        return None

    try:
        jsonschema.validate(doc, schema)
    except jsonschema.ValidationError as exc:
        loc = '/'.join(str(x) for x in exc.absolute_path) or '<root>'
        errors.append(f'{rel}: schema 不合规 @ {loc}: {exc.message}')
        return None

    # 1. 双画像
    prof = set(doc['profile'])
    if not {'2in1', 'tablet'} <= prof:
        errors.append(f'{rel}: profile 必须同时含 2in1 与 tablet，实际 {sorted(prof)}')

    # 2+5. 选择器与可判定断言
    for i, step in enumerate(doc['steps']):
        tgt = step.get('target')
        if tgt is not None:
            if not re.match(r'^(id|role|label):', tgt):
                errors.append(f'{rel}: steps[{i}].target="{tgt}" 不是 id:/role:/label: 选择器')
            if COORD_RE.match(tgt):
                errors.append(f'{rel}: steps[{i}].target="{tgt}" 是坐标，双画像下必然失效')
    # type 必须声明 target：不带 target 走的是"当前焦点"路径，实测字符会停在
    # 中文输入法的组合串里（pinyinTextInput），永远提交不到应用输入框。
    for i, step in enumerate(doc['steps']):
        if step['action'] == 'type' and not step.get('target'):
            errors.append(
                f'{rel}: steps[{i}] 是 type 但没写 target —— 会经输入法组合串丢失，'
                f'必须写成 "target: id:<输入框>" 让 runner 做聚焦+提交+回读校验')

    if not any(a['kind'] in JUDGEABLE for a in doc['asserts']):
        errors.append(f'{rel}: asserts 里没有可判定断言')

    # 3+4. 能力引用
    for cid in doc.get('capabilities', []):
        if cid not in caps:
            errors.append(f'{rel}: capabilities 引用了不存在的 id "{cid}"')
        elif caps[cid]['level'] == 'T3':
            errors.append(f'{rel}: capabilities 引用了 T3 能力 "{cid}"（T3 已移除，断言无意义）')

    # 6. limits 实质内容
    limits = doc['evidence']['limits']
    low = limits.lower()
    if len(limits) < 20:
        errors.append(f'{rel}: evidence.limits 太短（{len(limits)} 字符），必须写明模拟器/真机、ABI、未覆盖项')
    if any(w in low for w in PLACEHOLDER):
        errors.append(f'{rel}: evidence.limits 含占位词，必须写实际边界')

    return doc


def check_sbom() -> list:
    """SBOM 与产物一致性：漏登记三方库或清单过期时，lint 直接失败。"""
    import subprocess
    script = pathlib.Path(__file__).resolve().parents[1] / "tools" / "gen-sbom.py"
    if not script.exists():
        return ["缺少 tools/gen-sbom.py"]
    proc = subprocess.run([sys.executable, str(script), "--check"], capture_output=True, text=True)
    if proc.returncode != 0:
        detail = (proc.stderr or proc.stdout).strip().splitlines()
        return ["SBOM 校验失败: " + (detail[-1] if detail else "unknown")]
    return []


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--strict', action='store_true', help='把 needsReview 的能力也当作错误')
    args = ap.parse_args()

    with open(SCHEMA, encoding='utf-8') as fh:
        schema = json.load(fh)
    caps = load_caps()
    errors = []
    errors += check_sbom()
    docs = []
    for path in sorted(SCENARIOS.glob('*.yaml')):
        doc = check(path, schema, caps, errors)
        if doc:
            docs.append((path.name, doc))

    if args.strict:
        pending = [cid for cid, e in caps.items() if e['needsReview']]
        if pending:
            errors.append(f'capabilities.json 仍有 {len(pending)} 条 needsReview 未裁决: {pending[:8]}')

    print(f'scenarios: {len(docs)}  |  capabilities: {len(caps)}')
    for name, doc in docs:
        print(f'  ok  {name}  (id={doc["id"]}, steps={len(doc["steps"])}, asserts={len(doc["asserts"])})')
    if errors:
        print(f'\n{len(errors)} 个错误:', file=sys.stderr)
        for e in errors:
            print('  -', e, file=sys.stderr)
        return 1
    print('\n全部通过')
    return 0


if __name__ == '__main__':
    sys.exit(main())
