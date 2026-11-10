#!/usr/bin/env python3
"""spec runner：把 spec/scenarios/*.yaml 跑在真实鸿蒙设备/模拟器上。

执行原语全部来自设备自带的 uitest（实测 7.0.0.1）：
    uitest start-daemon
    uitest dumpLayout -p <path>       -> 布局 JSON（含 accessibilityId/bounds/text/type）
    uitest screenCap   -p <path>      -> 屏幕 PNG
    uitest uiInput click <x> <y>
    uitest uiInput text <text>        -> 输入到当前焦点
    uitest uiInput keyEvent <key>

设计原则（都是踩过坑才写下的）：
  * spec 里只有选择器，没有坐标；坐标由本 runner 在运行时从布局解算。这样双画像与
    不同 DPI 都不会让 spec 失效。
  * 未实现的断言种类一律**报错而不是跳过**——静默跳过会让"通过"变成谎话。
  * 每次运行都把 dumpLayout JSON 与 PNG 落到 out 目录，作为可复查的证据物。
  * 结果写成 result.json，`passed` 只由断言决定，不由"跑完了"决定。

用法：
    python spec/run.py spec/scenarios/xx.yaml --serial 127.0.0.1:10100 --profile 2in1
    python spec/run.py spec/scenarios/xx.yaml --serial 127.0.0.1:10101 --profile tablet
退出码：0 通过；1 失败；2 环境错误（设备不可达等）。
"""
import argparse
import json
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile
import time

try:
    import yaml
except ImportError:
    print('需要 pyyaml：python -m pip install pyyaml', file=sys.stderr)
    sys.exit(2)

HDC = r'C:\Program Files\Huawei\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe'
DEV_TMP = '/data/local/tmp'


class EnvError(RuntimeError):
    pass


class Runner:
    def __init__(self, serial, outdir, profile, verbose=False, fresh=False):
        self.serial = serial
        self.outdir = pathlib.Path(outdir)
        self.outdir.mkdir(parents=True, exist_ok=True)
        self.profile = profile
        self.verbose = verbose
        self.fresh = fresh
        self.log = []

    # ---------- 设备原语 ----------
    def sh(self, cmd, check=True):
        full = [HDC, '-t', self.serial, 'shell', cmd]
        p = subprocess.run(full, capture_output=True, text=True, encoding='utf-8', errors='replace', timeout=120)
        out = (p.stdout or '') + (p.stderr or '')
        if self.verbose:
            print(f'    $ {cmd}\n      {out.strip()[:300]}')
        if check and p.returncode not in (0, None) and 'error' in out.lower():
            raise EnvError(f'设备命令失败: {cmd} -> {out.strip()[:300]}')
        return out

    def which_device(self):
        out = subprocess.run([HDC, 'list', 'targets'], capture_output=True, text=True, timeout=60)
        if self.serial not in (out.stdout or ''):
            raise EnvError(f'设备 {self.serial} 不在 hdc 列表里: {(out.stdout or "").strip()!r}')

    def start_uitest(self):
        self.sh('uitest start-daemon', check=False)

    def dump_layout(self, name):
        dev_path = f'{DEV_TMP}/{name}.json'
        self.sh(f'uitest dumpLayout -p {dev_path}', check=False)
        local = self.outdir / f'{name}.json'
        subprocess.run([HDC, '-t', self.serial, 'file', 'recv', dev_path, str(local)],
                       capture_output=True, text=True, timeout=120)
        if not local.exists():
            raise EnvError(f'拉取布局失败: {dev_path}')
        return json.loads(local.read_text(encoding='utf-8'))

    def screenshot(self, name):
        dev_path = f'{DEV_TMP}/{name}.png'
        self.sh(f'uitest screenCap -p {dev_path}', check=False)
        local = self.outdir / f'{name}.png'
        subprocess.run([HDC, '-t', self.serial, 'file', 'recv', dev_path, str(local)],
                       capture_output=True, text=True, timeout=120)
        return local if local.exists() else None

    def launch(self, app):
        bundle = app['bundleName']
        ability = app.get('ability', 'EntryAbility')
        self.sh(f'aa force-stop {bundle}', check=False)
        out = self.sh(f'aa start -a {ability} -b {bundle}', check=False)
        if 'successfully' not in out and 'error' in out.lower():
            raise EnvError(f'启动失败: {out.strip()[:300]}')
        time.sleep(app.get('settleMs', 800) / 1000.0)
        self.assert_no_blocking_dialog()

    # 首次安装后启动可能被系统对话框挡住（实测："是否将应用自动添加至桌面？"）。
    # 这时所有选择器都会"找不到"，看起来像 spec 写错了。必须报成环境问题。
    SYSTEM_DIALOG_MARKERS = ('是否将应用自动添加至桌面', '想要访问', '仅使用期间允许',
                              '小艺输入法', '请仔细阅读上述声明', '本应用需要联网',
                              '请选择中文键盘布局', '拉起键盘后默认展示该布局')

    def assert_no_blocking_dialog(self, layout=None):
        if layout is None:
            layout = self.dump_layout('launch')
        hits = []
        for node in self.walk(layout):
            text = self.attrs(node).get('text') or ''
            for marker in self.SYSTEM_DIALOG_MARKERS:
                if marker in text:
                    hits.append(text)
                    break
        if hits:
            raise EnvError(
                '启动后被系统对话框遮挡，后续选择器必然找不到: '
                + ' | '.join(hits[:2])
                + '  → 先手动点掉（uitest uiInput click <x> <y>）再重跑；这是环境问题，不是 spec 失败。')

    # ---------- 选择器 -> 节点 ----------
    @staticmethod
    def walk(node):
        yield node
        for ch in node.get('children') or []:
            yield from Runner.walk(ch)

    @staticmethod
    def attrs(node):
        return node.get('attributes') or {}

    @staticmethod
    def parse_bounds(s):
        m = re.match(r'^\[(-?\d+),(-?\d+)\]\[(-?\d+),(-?\d+)\]$', (s or '').strip())
        if not m:
            return None
        return tuple(int(x) for x in m.groups())

    def resolve(self, layout, selector):
        kind, _, value = selector.partition(':')
        if not _:
            raise ValueError(f'选择器缺少类型前缀: {selector}')
        hits = []
        for node in self.walk(layout):
            a = self.attrs(node)
            if kind == 'id':
                if a.get('accessibilityId') == value or a.get('id') == value:
                    hits.append(node)
            elif kind == 'label':
                if (a.get('text') or '') == value:
                    hits.append(node)
            elif kind == 'role':
                if (a.get('type') or '').lower() == value.lower():
                    hits.append(node)
            else:
                raise ValueError(f'未知选择器类型: {kind}')
        if not hits:
            return None
        # 取面积最小的命中（最具体的那个），避免容器抢先
        def area(n):
            b = self.parse_bounds(self.attrs(n).get('bounds'))
            return (b[2] - b[0]) * (b[3] - b[1]) if b else 1 << 30
        hits.sort(key=area)
        return hits[0]

    def center(self, node):
        b = self.parse_bounds(self.attrs(node).get('bounds'))
        if not b:
            raise ValueError('节点没有可用 bounds')
        return (b[0] + b[2]) // 2, (b[1] + b[3]) // 2

    # ---------- 输入（先聚焦，再取新鲜坐标注入，最后回读校验）----------
    def type_into(self, selector, text, step_i, attempts=3, secret=False):
        """把 text 注入到 selector 命中的输入框，并回读校验。

        每一步都是踩出来的（dump 逐帧可查）：
          * `uiInput text` 会把字符送进中文输入法候选框（pinyinTextInput/candidateView），
            不点候选词永远提交不到应用输入框；
          * 改用 `inputText <x> <y> <text>` 后出现新问题：**软键盘/输入法一弹出，
            对话框会上移**（实测 Y 位移约 110px），拿旧坐标注入就落到相邻字段上
            （曾把 label 与 address 的值串成 '10.0.0.110.0.0.2'）。
        所以顺序固定为：dump→点击聚焦→等 IME 稳定→**重新 dump 取新坐标**→注入→回读校验。
        """
        last = '未执行'
        for attempt in range(1, attempts + 1):
            # 1) 聚焦（这一步会拉起输入法，布局随之后移）
            layout = self.dump_layout(f'step-{step_i:02d}-focus{attempt}')
            self.assert_no_blocking_dialog(layout)
            node = self.resolve(layout, selector)
            if node is None:
                return False, f'选择器未命中: {selector}'
            fx, fy = self.center(node)
            self.sh(f'uitest uiInput click {fx} {fy}', check=False)
            time.sleep(0.45)

            # 2) IME 稳定后重新取坐标，避免用旧布局的坐标
            layout = self.dump_layout(f'step-{step_i:02d}-fresh{attempt}')
            node = self.resolve(layout, selector)
            if node is None:
                return False, f'聚焦后选择器消失: {selector}'
            x, y = self.center(node)
            self.sh(f'uitest uiInput inputText {x} {y} {text}', check=False)
            time.sleep(0.85)   # 输入法组词需要时间，太快就看不到组合串
            # inputText 同样走输入法：字符只落到组合串里（实测 pinyinTextInput + candidateView）。
            # 必须发 ENTER(2054) 提交组合，应用输入框才会真正拿到文本。
            self.sh('uitest uiInput keyEvent 2054', check=False)
            time.sleep(0.85)   # ENTER 提交组合后再回读

            if secret:
                # 口令字段被掩码，回读拿不到原文；这里只确认"注入没有抛错"，
                # 真正的验证交给后续连接结果（连得上 = 口令对）。
                return True, 'secret: 已注入，未回读'
            # 3) 回读校验
            after = self.dump_layout(f'step-{step_i:02d}-after{attempt}')
            node2 = self.resolve(after, selector)
            got = (self.attrs(node2).get('text') or '') if node2 else ''
            if got == text or text in got:
                return True, None if attempt == 1 else f'第 {attempt} 次注入才落位'
            last = f'注入未落位（回读值 {got!r}）'
        return False, last

    # ---------- 断言 ----------

    def assert_once(self, layout, a):
        kind = a['kind']
        if kind == 'text':
            want = a['value']
            for node in self.walk(layout):
                if (self.attrs(node).get('text') or '') == want:
                    return True, None
            return False, f'未找到文本 {want!r}'
        if kind == 'absent':
            want = a['value']
            for node in self.walk(layout):
                if (self.attrs(node).get('text') or '') == want:
                    return False, f'不应出现但出现了: {want!r}'
            return True, None
        if kind == 'screenRegex':
            pat = a.get('regex') or a.get('value') or ''
            blob = '\n'.join((self.attrs(n).get('text') or '') for n in self.walk(layout))
            if re.search(pat, blob):
                return True, None
            return False, f'正则 {pat!r} 未命中（屏幕文本: {blob[:120]!r}）'
        if kind == 'layout':
            # 保守版：所有带文本的节点必须有正的宽高，且落在屏幕内。
            # 这不能代替人工目检，但能抓住"文字被裁成 0 宽"这类硬故障。
            screen = self.parse_bounds(self.attrs(layout).get('bounds')) or (0, 0, 0, 0)
            bad = []
            for node in self.walk(layout):
                a2 = self.attrs(node)
                if not a2.get('text'):
                    continue
                b = self.parse_bounds(a2.get('bounds'))
                if not b:
                    continue
                if b[2] - b[0] <= 0 or b[3] - b[1] <= 0:
                    bad.append(('zero-size', a2.get('text')))
                elif b[0] < screen[0] or b[1] < screen[1] or b[2] > screen[2] or b[3] > screen[3]:
                    bad.append(('out-of-screen', a2.get('text')))
            if bad:
                return False, f'布局问题: {bad[:3]}'
            return True, None
        raise NotImplementedError(f'断言类型 {kind} 尚未实现（故意报错而不是跳过）')

    def run_assert(self, a, idx):
        deadline = time.time() + a.get('withinMs', 3000) / 1000.0
        last = None
        while True:
            layout = self.dump_layout(f'assert-{idx}')
            ok, why = self.assert_once(layout, a)
            if ok:
                return True, None
            last = why
            if time.time() >= deadline:
                return False, last
            time.sleep(0.3)

    # ---------- 主流程 ----------
    def run_spec(self, spec):
        self.which_device()
        self.start_uitest()
        if self.fresh and 'app' in spec:
            # 清应用数据：让断言不依赖上一次运行遗留的库内容（可重复性）
            self.sh("bm clean -n " + spec["app"]["bundleName"] + " -d", check=False)
            time.sleep(0.5)
        result = {
            'spec': spec['id'],
            'profile': self.profile,
            'serial': self.serial,
            'steps': [],
            'asserts': [],
            'evidence': {},
            'passed': False,
        }

        for i, step in enumerate(spec['steps']):
            act = step['action']
            entry = {'i': i, 'action': act, 'ok': True, 'detail': None}
            try:
                if act == 'launch':
                    if 'app' not in spec:
                        raise EnvError('spec 没有 app 块，无法 launch')
                    self.launch(spec['app'])
                elif act == 'wait':
                    time.sleep(step['ms'] / 1000.0)
                elif act == 'click':
                    layout = self.dump_layout(f'step-{i:02d}')
                    self.assert_no_blocking_dialog(layout)
                    node = self.resolve(layout, step['target'])
                    if node is None:
                        raise AssertionError(f'选择器未命中: {step["target"]}')
                    x, y = self.center(node)
                    self.sh(f'uitest uiInput click {x} {y}', check=False)
                    time.sleep(0.25)
                elif act == 'type':
                    if step.get('target'):
                        ok, detail = self.type_into(step['target'], step['text'], i,
                                                    secret=bool(step.get('secret', False)))
                        entry['detail'] = detail
                        if not ok:
                            raise AssertionError(detail)
                    else:
                        self.sh(f'uitest uiInput text {step["text"]}', check=False)
                        time.sleep(0.2)
                elif act == 'key':
                    self.sh(f'uitest uiInput keyEvent {step["text"]}', check=False)
                elif act in ('swipe', 'longPress', 'rightClick', 'setVariable', 'invoke'):
                    raise NotImplementedError(f'动作 {act} 尚未实现（故意报错而不是跳过）')
                else:
                    raise NotImplementedError(f'未知动作 {act}')
                # 步骤级 expect：允许"中途断言"（例如先断言对话框出现，再点确认）
                if step.get('expect') is not None:
                    ok, why = self.run_assert(step['expect'], f's{i}')
                    entry['expect'] = {'ok': ok, 'detail': why}
                    if not ok:
                        raise AssertionError(f'步骤内 expect 失败: {why}')
            except Exception as exc:  # noqa: BLE001
                entry['ok'] = False
                entry['detail'] = str(exc)
                result['steps'].append(entry)
                result['error'] = f'step {i} ({act}) 失败: {exc}'
                break
            result['steps'].append(entry)

        if 'error' not in result:
            for j, a in enumerate(spec['asserts']):
                ok, why = self.run_assert(a, j)
                result['asserts'].append({'i': j, 'kind': a['kind'], 'ok': ok, 'detail': why})
                if not ok:
                    result['error'] = f'assert {j} ({a["kind"]}) 失败: {why}'
                    break

        shot = self.screenshot('final')
        tree = self.outdir / 'final-layout.json'
        if shot:
            result['evidence']['png'] = shot.name
        if tree.exists():
            result['evidence']['tree'] = tree.name
        result['evidence']['limits'] = spec['evidence']['limits']
        result['passed'] = ('error' not in result
                            and all(s['ok'] for s in result['steps'])
                            and all(a['ok'] for a in result['asserts'])
                            and len(result['asserts']) > 0)
        return result


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('spec')
    ap.add_argument('--serial', required=True)
    ap.add_argument('--profile', choices=['2in1', 'tablet'], required=True)
    ap.add_argument('--out', default=None)
    ap.add_argument('--verbose', action='store_true')
    ap.add_argument('--fresh', action='store_true', help='运行前清空应用数据，保证可重复')
    args = ap.parse_args()

    spec_path = pathlib.Path(args.spec)
    spec = yaml.safe_load(spec_path.read_text(encoding='utf-8'))
    if args.profile not in spec['profile']:
        print(f'错误: spec 未声明 profile {args.profile}', file=sys.stderr)
        return 2

    out = pathlib.Path(args.out) if args.out else (spec_path.parent.parent / 'runs' /
                                                   f'{spec["id"]}-{args.profile}-{int(time.time())}')
    r = Runner(args.serial, out, args.profile, args.verbose, args.fresh)
    try:
        result = r.run_spec(spec)
    except EnvError as exc:
        print(f'环境错误: {exc}', file=sys.stderr)
        return 2

    (out / 'result.json').write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding='utf-8')
    print(json.dumps({k: result[k] for k in ('spec', 'profile', 'passed', 'error') if k in result},
                     ensure_ascii=False, indent=2))
    print('evidence ->', out)
    return 0 if result['passed'] else 1


if __name__ == '__main__':
    sys.exit(main())
