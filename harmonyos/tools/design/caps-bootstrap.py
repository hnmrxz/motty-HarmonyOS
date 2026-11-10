#!/usr/bin/env python3
"""Bootstrap spec/capabilities.json from CAPABILITY-MATRIX.md.

This is a *bootstrap* tool, not the architectural `caps-gen` (which goes the other
way: capabilities.json -> ArkTS constants + CI assertions).

Why it exists: the capability matrix and the registry must never drift, and the
matrix is currently the human-authored source of truth. Parsing it guarantees the
registry's key set equals the matrix's row set on day one (CI assertion ①), and
flags every row whose level cell is ambiguous so a human resolves it once, in
place, instead of the two documents diverging.

Usage:
    python tools/design/caps-bootstrap.py \
        --matrix harmonyos/CAPABILITY-MATRIX.md \
        --out harmonyos/spec/capabilities.json

Rule for levels (deliberately conservative):
  - any mention of T3 with no T1 -> T3
  - T2 with no T1               -> T2
  - T1 present                  -> T1 (mixed cells keep `levelRaw`)
  - anything else               -> null + needsReview
A row is never silently upgraded: ambiguous cells always carry needsReview=true.
"""
import argparse
import json
import re
import sys

GROUP_RE = re.compile(r'^##\s+([A-H])\.\s+(.+)$')
# | name | where | plan | level | dep | acceptance |
ROW_RE = re.compile(r'^\|\s*(.+?)\s*\|\s*(.*?)\s*\|\s*(.*?)\s*\|\s*(.+?)\s*\|\s*(.*?)\s*\|\s*(.*?)\s*\|\s*$')
SEP_RE = re.compile(r'^\|[\s\-:|]+\|$')


def classify(level_cell):
    """Return (level, needs_review)."""
    cell = level_cell.replace('*', '').strip()
    has_t1 = 'T1' in cell
    has_t2 = 'T2' in cell
    has_t3 = 'T3' in cell
    if has_t3 and not has_t1:
        return 'T3', has_t2  # e.g. "平板 T3" is fine, "T2/T3" needs review
    if has_t2 and not has_t1:
        return 'T2', False
    if has_t1:
        return 'T1', has_t2 or has_t3  # mixed cells need a human
    return None, True


def parse(matrix_path):
    entries = []
    group = None
    group_title = None
    row_no = 0
    with open(matrix_path, 'r', encoding='utf-8') as fh:
        for raw in fh:
            line = raw.rstrip('\n')
            m = GROUP_RE.match(line)
            if m:
                group, group_title = m.group(1), m.group(2).strip()
                row_no = 0
                continue
            if not line.startswith('|') or SEP_RE.match(line):
                continue
            if group is None:
                continue
            m = ROW_RE.match(line)
            if not m:
                continue
            name, where, plan, level_cell, dep, accept = (x.strip() for x in m.groups())
            if name in ('能力',) or set(name) <= set('-: '):
                continue
            row_no += 1
            level, needs_review = classify(level_cell)
            entries.append({
                'id': f'{group}{row_no:02d}',
                'title': name,
                'group': f'{group}. {group_title}',
                'level': level,
                'levelRaw': level_cell,
                'needsReview': needs_review,
                # A' 落点：矩阵里 B 组写的是"原样保留 Go 内核"，A′ 下不成立，
                # 必须由矩阵补两列后回填；这里先留空，绝不抄进错误答案。
                'aPrime': {'where': None, 'evidence': None},
                'evidence': 'E3',
                'proof': [],
                'fallback': None,
                'userText': None,
                'source': {
                    'where': where,
                    'planInMatrix': plan,
                    'deps': dep,
                    'acceptance': accept,
                },
            })
    return entries


# R51: packages the matrix never enumerated (found by walking the package tree).
# They enter the registry now so CI assertion ① cannot pass while they are missing;
# level is null until the matrix is re-dressed.
R51_PACKAGES = [
    ('pkg.telnet', 'Telnet 协议', 387),
    ('pkg.notes', 'Notes', 6878),
    ('pkg.cmdhistory', '命令历史', 853),
    ('pkg.aiproviderimport', 'AI 供应商导入', 1682),
    ('pkg.remotestats', '远端统计', 1619),
]


def r51_entries(first_id):
    out = []
    n = first_id
    for pid, title, loc in R51_PACKAGES:
        out.append({
            'id': pid,
            'title': title,
            'group': 'R51. 矩阵漏项',
            'level': None,
            'levelRaw': 'not-in-matrix',
            'needsReview': True,
            'aPrime': {'where': None, 'evidence': None},
            'evidence': 'E3',
            'proof': [],
            'fallback': None,
            'userText': None,
            'source': {'where': f'internal/（约 {loc} 行）', 'planInMatrix': '', 'deps': '', 'acceptance': ''},
        })
        n += 1
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--matrix', default='harmonyos/CAPABILITY-MATRIX.md')
    ap.add_argument('--out', default='harmonyos/spec/capabilities.json')
    args = ap.parse_args()

    entries = parse(args.matrix)
    if not entries:
        print('no rows parsed; check the matrix path/format', file=sys.stderr)
        return 1
    entries.extend(r51_entries(len(entries) + 1))

    doc = {
        'schema': 1,
        '_comment': (
            'A′ 能力注册表 v0.1（引导生成，勿手改 id）。'
            'level 为 null 或 needsReview=true 的条目必须由人裁决后填实；'
            'aPrime.where 留空表示尚未落到 A′ 实现，禁止用矩阵 B 组的"原样保留 Go 内核"填充。'
        ),
        '_generatedBy': 'harmonyos/tools/design/caps-bootstrap.py',
        '_sourceMatrix': args.matrix,
        'entries': entries,
    }
    with open(args.out, 'w', encoding='utf-8', newline='\n') as fh:
        json.dump(doc, fh, ensure_ascii=False, indent=2)
        fh.write('\n')

    by_level = {}
    for e in entries:
        by_level[e['level']] = by_level.get(e['level'], 0) + 1
    print(f'wrote {args.out}: {len(entries)} entries')
    print('levels:', by_level)
    print('needsReview:', sum(1 for e in entries if e['needsReview']))
    return 0


if __name__ == '__main__':
    sys.exit(main())
