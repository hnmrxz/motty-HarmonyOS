/**
 * Motty HarmonyOS —— 产品形态收敛（第 17 轮）
 *
 * 本轮的形状目标：让界面像一个产品，而不是一排诊断按钮。
 *   - 顶栏只留：Motty / Diagnostics（折叠所有诊断入口）/ New Host
 *   - 主机行：「Open」直接开会话（pty shell，真 shell），「Test」做一次探测连接
 *   - 有会话时页面切到终端视图（内联，不再用浮层），带「Hosts」返回
 *   - 诊断入口收进 Diagnostics 面板，spec 先点 `diag/open` 再点具体按钮
 *
 * 仍未做（写清楚，别当成已完成）：
 *   - **多标签**：目前同一时刻只有一个活动会话。要支持多会话并行，必须把 vt_core
 *     从全局单例改成实例化（每标签一个网格），这属于下一轮工作。
 *   - 分屏、会话恢复、标签重排。
 *   - 凭据只在内存，保险库未做。
 */
import { common } from '@kit.AbilityKit';
import { relationalStore } from '@kit.ArkData';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { http, socket } from '@kit.NetworkKit';
import { Strings } from '../common/strings';
import { BusinessError, pasteboard } from '@kit.BasicServicesKit';
import { asset } from '@kit.AssetStoreKit';
import { util } from '@kit.ArkTS';
import mottynapi from 'libmottynapi.so';

const DOMAIN: number = 0x0000;
const TAG: string = 'MOTTY';

const STORE_CONFIG: relationalStore.StoreConfig = {
  name: 'motty.db',
  securityLevel: relationalStore.SecurityLevel.S1
};

const SQL_CREATE_HOSTS =
  'CREATE TABLE IF NOT EXISTS hosts (' +
  'id TEXT PRIMARY KEY, label TEXT NOT NULL, address TEXT NOT NULL, usr TEXT, port TEXT, proto TEXT)';

const SQL_CREATE_KNOWN_HOSTS =
  'CREATE TABLE IF NOT EXISTS known_hosts (host TEXT PRIMARY KEY, fingerprint TEXT NOT NULL, updated_at INTEGER)';

const HOST_COLUMNS: string[] = ['id', 'label', 'address', 'usr', 'port', 'proto'];

const SQL_CREATE_FORWARDS =
  'CREATE TABLE IF NOT EXISTS forwards (' +
  'id TEXT PRIMARY KEY, host_key TEXT, mode TEXT, listen_port TEXT, target_host TEXT, target_port TEXT)';
const VAULT_PREFIX: string = 'motty.host.';

/**
 * 凭据保险库：用系统 Asset Store Kit 存口令。
 * 为什么不用自己搓 AES：口令属于系统该管的机密，Asset 由系统保管、可随锁屏状态限制访问，
 * 比自己拿 HUKS 拼一套更不容易写错。别名按 host:port 区分。
 *
 * 明确边界：这里只存口令；地址/端口/用户名仍在 relationalStore（非机密）。
 */
class Vault {
  private static aliasOf(key: string): Uint8Array {
    return new util.TextEncoder().encodeInto(VAULT_PREFIX + key);
  }

  static async save(key: string, secret: string): Promise<boolean> {
    try {
      await Vault.remove(key);
      const attr: asset.AssetMap = new Map();
      attr.set(asset.Tag.ALIAS, Vault.aliasOf(key));
      attr.set(asset.Tag.SECRET, new util.TextEncoder().encodeInto(secret));
      attr.set(asset.Tag.ACCESSIBILITY, asset.Accessibility.DEVICE_UNLOCKED);
      await asset.add(attr);
      return true;
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'vault save failed: %{public}s', JSON.stringify(e));
      return false;
    }
  }

  static async load(key: string): Promise<string> {
    try {
      const query: asset.AssetMap = new Map();
      query.set(asset.Tag.ALIAS, Vault.aliasOf(key));
      query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL);
      const res: asset.AssetMap[] = await asset.query(query);
      if (res.length === 0) {
        return '';
      }
      const raw = res[0].get(asset.Tag.SECRET) as Uint8Array;
      return raw === undefined ? '' : util.TextDecoder.create('utf-8').decodeToString(raw);
    } catch (e) {
      // 没存过会抛 NOT_FOUND，这里按"没有"处理
      return '';
    }
  }

  static async remove(key: string): Promise<void> {
    try {
      const query: asset.AssetMap = new Map();
      query.set(asset.Tag.ALIAS, Vault.aliasOf(key));
      await asset.remove(query);
    } catch (e) {
      // 不存在就算了
    }
  }
}

interface HostItem {
  id: string;
  label: string;
  address: string;
  user: string;
  port: string;
  proto: string;
}

interface TabInfo {
  id: string;
  label: string;
  shellId: number;
  vtId: number;
}

interface HostRow {
  h: HostItem;
  index: number;
}

interface Cred {
  address: string;
  port: number;
  user: string;
  password: string;
}

@Entry
@Component
struct Index {
  @State hosts: HostItem[] = [];
  @State statuses: string[] = [];
  @State showDialog: boolean = false;
  @State formLabel: string = '';
  @State formAddress: string = '';
  @State formUser: string = '';
  @State formPort: string = '';
  @State formPassword: string = '';
  @State probeText: string = '(not probed)';
  @State keyDialog: boolean = false;
  @State changedDialog: boolean = false;
  @State changedOld: string = '';
  @State changedNew: string = '';
  @State pendingFp: string = '';
  @State pendingKey: string = '';
  @State diagOpen: boolean = false;
  @State termVisible: boolean = false;
  @State tabs: TabInfo[] = [];
  @State activeId: string = '';
  @State showHosts: boolean = true;
  @State termText: string = '';
  @State termInput: string = '';
  @State vtStatus: string = '';
  @State vtHistory: string = '';
  @State ptyStatus: string = '';
  @State vtScroll: number = 0;
  @State lang: string = 'en';
  @State aiAnswer: string = '';
  @State aiEndpoint: string = 'http://127.0.0.1:2297/v1/ai';
  @State rdpSrvStatus: string = '';
  @State rdpSrvPort: number = 13389;  // 3389 是特权端口，应用绑不上
  @State selText: string = '';
  @State clipText: string = '';
  private touchLastY: number = -1;
  private touchAccum: number = 0;
  @State filesOpen: boolean = false;
  @State sftpPath: string = '.';
  @State sftpFile: string = 'hello.txt';
  @State sftpList: string = '';
  @State sftpEntries: string[] = [];
  @State sftpPreview: string = '';
  @State sftpStatus: string = '';
  @State sftpUploadName: string = 'uploaded.txt';
  @State sftpUploadText: string = 'uploaded-marker-ok\n';
  @State sftpResult: string = '';
  @State sftpRenameTo: string = 'renamed.txt';
  @State sftpNewDir: string = 'newdir';
  @State fwdOpen: boolean = false;
  @State fwdListen: string = '2201';
  @State fwdTargetHost: string = '127.0.0.1';
  @State fwdTargetPort: string = '2223';
  @State fwdEvents: string = '';
  @State fwdResult: string = '';
  @State fwdMode: string = 'local';
  @State vncResult: string = '';
  @State vncOpen: boolean = false;
  @State vncStatus: string = '';
  @State vncFrameInfo: string = '';
  @State vncDrawn: number = 0;
  @State vncCanvasW: number = 320;
  @State vncCanvasH: number = 240;
  @State vncClip: string = '';
  @State vncClipOut: string = 'app-clip';
  @State vncPassword: string = 'secret';
  @State rdpResult: string = '';
  @State knownOpen: boolean = false;
  @State knownKeys: string[] = [];
  @State knownFps: string[] = [];
  @State fwdRules: string[] = [];   // 展示用："id|mode|listen->target"
  @State fwdRuleCount: number = 0;
  @State editingId: string = '';      // 非空 = 编辑模式
  @State deleteDialog: boolean = false;
  @State deleteIndex: number = -1;
  @State hostQuery: string = '';

  private creds: Map<string, Cred> = new Map<string, Cred>();
  private store: relationalStore.RdbStore | null = null;
  private readonly fixtureKey: string = '127.0.0.1:2222';
  private shellId: number = 0;
  private tabSeq: number = 0;
  private fwdId: number = 0;
  private vncId: number = 0;
  private vncCtx: CanvasRenderingContext2D = new CanvasRenderingContext2D(new RenderingContextSettings(true));
  private vncW: number = 0;
  private vncH: number = 0;
  private vncReady: boolean = false;
  private pendingAction: string = 'connect';
  private pendingLabel: string = '';

  aboutToAppear(): void {
    this.initStore();
  }

  private hostKey(address: string, port: string): string {
    return address + ':' + port;
  }

  // ---------------- 存储 ----------------
  private async initStore(): Promise<void> {
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      this.store = await relationalStore.getRdbStore(ctx, STORE_CONFIG);
      await this.store.executeSql(SQL_CREATE_HOSTS);
      await this.store.executeSql(SQL_CREATE_KNOWN_HOSTS);
      await this.store.executeSql(SQL_CREATE_FORWARDS);
      await this.reload();
      await this.reloadRules();
      hilog.info(DOMAIN, TAG, 'store ready, hosts=%{public}d', this.hosts.length);
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'store init failed: %{public}s', JSON.stringify(e));
    }
  }

  private async reload(): Promise<void> {
    if (this.store === null) {
      return;
    }
    const predicates = new relationalStore.RdbPredicates('hosts');
    const rs = await this.store.query(predicates, HOST_COLUMNS);
    const out: HostItem[] = [];
    while (rs.goToNextRow()) {
      out.push({
        id: rs.getString(0),
        label: rs.getString(1),
        address: rs.getString(2),
        user: rs.getString(3),
        port: rs.getString(4),
        proto: rs.getString(5)
      });
    }
    rs.close();
    this.hosts = out;
    // 从保险库预热：进程重启后凭据仍然可用，这是"落盘"与"只在内存"的分界
    for (let i = 0; i < out.length; i++) {
      const key = this.hostKey(out[i].address, out[i].port);
      if (this.creds.get(key) !== undefined) {
        continue;
      }
      const pw = await Vault.load(key);
      if (pw.length > 0) {
        this.creds.set(key, {
          address: out[i].address,
          port: Number.parseInt(out[i].port, 10),
          user: out[i].user,
          password: pw
        });
      }
    }
    const st: string[] = [];
    for (let i = 0; i < out.length; i++) {
      st.push(this.statuses.length > i ? this.statuses[i] : '');
    }
    this.statuses = st;
  }

  private async lookupFp(key: string): Promise<string> {
    if (this.store === null) {
      return '';
    }
    const pred = new relationalStore.RdbPredicates('known_hosts');
    pred.equalTo('host', key);
    const rs = await this.store.query(pred, ['fingerprint']);
    let fp = '';
    if (rs.goToNextRow()) {
      fp = rs.getString(0);
    }
    rs.close();
    return fp;
  }

  private async saveFp(key: string, fp: string): Promise<void> {
    if (this.store === null) {
      return;
    }
    const bucket: relationalStore.ValuesBucket = {
      'host': key,
      'fingerprint': fp,
      'updated_at': Date.now()
    };
    await this.store.insert('known_hosts', bucket, relationalStore.ConflictResolution.ON_CONFLICT_REPLACE);
    hilog.info(DOMAIN, TAG, 'known_hosts saved for %{public}s', key);
  }

  private setStatus(index: number, text: string): void {
    const next: string[] = [];
    for (let i = 0; i < this.statuses.length; i++) {
      next.push(i === index ? text : this.statuses[i]);
    }
    if (index >= next.length) {
      next.push(text);
    }
    this.statuses = next;
    this.probeText = text;
  }

  private resetForm(): void {
    this.formLabel = '';
    this.formAddress = '';
    this.formUser = '';
    this.formPort = '';
    this.formPassword = '';
  }

  private openEditHost(index: number): void {
    const h = this.hosts[index];
    if (h === undefined) {
      return;
    }
    this.editingId = h.id;
    this.formLabel = h.label;
    this.formAddress = h.address;
    this.formUser = h.user;
    this.formPort = h.port;
    this.formPassword = '';
    this.showDialog = true;
  }

  private askDeleteHost(index: number): void {
    if (index >= this.hosts.length) {
      return;
    }
    this.deleteIndex = index;
    this.deleteDialog = true;
  }

  // 删除主机：同时清掉它的 known_hosts 与保险库口令（否则会留下孤儿信任）
  private async confirmDeleteHost(): Promise<void> {
    const idx = this.deleteIndex;
    this.deleteDialog = false;
    if (idx < 0 || idx >= this.hosts.length || this.store === null) {
      return;
    }
    const h = this.hosts[idx];
    const key = this.hostKey(h.address, h.port);
    const hp = new relationalStore.RdbPredicates('hosts');
    hp.equalTo('id', h.id);
    await this.store.delete(hp);
    const kp = new relationalStore.RdbPredicates('known_hosts');
    kp.equalTo('host', key);
    await this.store.delete(kp);
    await Vault.remove(key);
    this.creds.delete(key);
    hilog.info(DOMAIN, TAG, 'host deleted: %{public}s (known_hosts + vault cleared)', key);
    await this.reload();
    await this.reloadRules();
  }

  private async submit(): Promise<void> {
    const label = this.formLabel.trim();
    const address = this.formAddress.trim();
    if (label.length === 0 || address.length === 0 || this.store === null) {
      return;
    }
    const port = this.formPort.trim().length > 0 ? this.formPort.trim() : '22';
    if (this.editingId.length > 0) {
      // 编辑：更新既有行（id 不变，避免规则/引用失联）
      const pred = new relationalStore.RdbPredicates('hosts');
      pred.equalTo('id', this.editingId);
      const patch: relationalStore.ValuesBucket = {
        'label': label, 'address': address, 'usr': this.formUser.trim(), 'port': port
      };
      await this.store.update(patch, pred);
      const key = this.hostKey(address, port);
      if (this.formPassword.length > 0) {
        await Vault.save(key, this.formPassword);
        this.creds.set(key, {
          address: address, port: Number.parseInt(port, 10),
          user: this.formUser.trim(), password: this.formPassword
        });
      }
      this.editingId = '';
      await this.reload();
      this.showDialog = false;
      this.resetForm();
      hilog.info(DOMAIN, TAG, 'host updated');
      return;
    }
    const bucket: relationalStore.ValuesBucket = {
      'id': String(Date.now()),
      'label': label,
      'address': address,
      'usr': this.formUser.trim(),
      'port': port,
      'proto': 'ssh'
    };
    try {
      await this.store.insert('hosts', bucket);
      const key = this.hostKey(address, port);
      // 口令为空时不写保险库、也不塞内存：否则"空口令"会被当成一个有效凭据，
      // 掩盖"保险库到底有没有旧口令"这一区别（负向用例正依赖它）
      if (this.formPassword.length > 0) {
        const saved = await Vault.save(key, this.formPassword);
        hilog.info(DOMAIN, TAG, 'vault save for %{public}s -> %{public}s', key, String(saved));
        this.creds.set(key, {
          address: address,
          port: Number.parseInt(port, 10),
          user: this.formUser.trim(),
          password: this.formPassword
        });
      }
      await this.reload();
      this.showDialog = false;
      this.resetForm();
      hilog.info(DOMAIN, TAG, 'host inserted, total=%{public}d', this.hosts.length);
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'insert failed: %{public}s', JSON.stringify(e));
    }
  }

  // ---------------- 会话 ----------------
  private openSession(label: string, index: number): void {
    this.pendingAction = 'open';
    const h = this.hosts[index];
    if (h === undefined) {
      return;
    }
    const key = this.hostKey(h.address, h.port);
    const cred = this.creds.get(key);
    if (cred === undefined) {
      this.setStatus(index, 'no credentials in memory (vault not implemented yet)');
      return;
    }
    this.pendingLabel = label;
    this.lookupFp(key).then((fp: string) => {
      if (fp.length > 0) {
        this.startSession(cred, fp, h.label);
        return;
      }
      this.setStatus(index, 'unknown host, fetching key...');
      mottynapi.probe(cred.address, cred.port, cred.user, cred.password, 'echo no-auth-yet', '',
        (first: string) => {
          const m = new RegExp('SHA256:[A-Za-z0-9+/]+').exec(first);
          if (m === null || first.indexOf('unknown_host') !== 0) {
            this.setStatus(index, first);
            return;
          }
          this.pendingFp = m[0];
          this.pendingKey = key;
          this.keyDialog = true;
          this.setStatus(index, 'waiting for user to trust ' + this.pendingFp);
        });
    });
  }

  private refreshTab(vtId: number): void {
    this.termText = mottynapi.vtScreen(vtId);
    this.vtStatus = mottynapi.vtStatus(vtId);
    this.vtHistory = mottynapi.vtScrollBack(vtId, 3);
  }

  private startSession(cred: Cred, fp: string, label: string): void {
    this.diagOpen = false;
    this.tabSeq = this.tabSeq + 1;
    const tabId: string = 't' + this.tabSeq;
    const tabLabel: string = label + ' #' + this.tabSeq;
    const vtId: number = mottynapi.vtNew(80, 24);
    const id: number = mottynapi.openChannel(cred.address, cred.port, cred.user, cred.password,
      fp, 80, 24, true,
      (chunk: string) => {
        mottynapi.vtFeed(vtId, chunk);
        if (this.activeId === tabId) {
          if (this.vtScroll > 0) {
            this.termText = mottynapi.vtView(vtId, this.vtScroll);
          } else {
            this.refreshTab(vtId);
          }
        }
      },
      (status: string) => {
        if (this.activeId === tabId) {
          this.refreshTab(vtId);
        }
        this.probeText = tabLabel + ': ' + status;
      });
    if (id === 0) {
      mottynapi.vtFree(vtId);
      this.probeText = 'failed to open session';
      return;
    }
    const next: TabInfo[] = this.tabs.slice();
    next.push({ id: tabId, label: tabLabel, shellId: id, vtId: vtId });
    this.tabs = next;
    this.activeId = tabId;
    this.shellId = id;
    this.vtScroll = 0;
    this.showHosts = false;
    this.termVisible = true;
    this.ptyStatus = '';
    this.refreshTab(vtId);
  }

  private selectTab(tabId: string): void {
    for (let i = 0; i < this.tabs.length; i++) {
      if (this.tabs[i].id === tabId) {
        this.activeId = tabId;
        this.shellId = this.tabs[i].shellId;
        this.showHosts = false;
        this.refreshTab(this.tabs[i].vtId);
        return;
      }
    }
  }

  private closeTab(tabId: string): void {
    const remain: TabInfo[] = [];
    for (let i = 0; i < this.tabs.length; i++) {
      const t = this.tabs[i];
      if (t.id === tabId) {
        mottynapi.closeShell(t.shellId);
        mottynapi.vtFree(t.vtId);
      } else {
        remain.push(t);
      }
    }
    this.tabs = remain;
    if (this.activeId === tabId) {
      if (remain.length > 0) {
        this.selectTab(remain[remain.length - 1].id);
      } else {
        this.activeId = '';
        this.shellId = 0;
        this.termVisible = false;
        this.showHosts = true;
        this.termText = '';
      }
    }
  }

  private activeTab(): TabInfo | null {
    for (let i = 0; i < this.tabs.length; i++) {
      if (this.tabs[i].id === this.activeId) {
        return this.tabs[i];
      }
    }
    return null;
  }

  // ---------------- 回滚区交互 ----------------
  private scrollView(delta: number): void {
    const tab = this.activeTab();
    if (tab === null) {
      this.ptyStatus = 'scroll: no session';
      return;
    }
    const next = this.vtScroll + delta;
    this.vtScroll = next < 0 ? 0 : next;
    this.termText = mottynapi.vtView(tab.vtId, this.vtScroll);
    this.ptyStatus = 'scroll=' + this.vtScroll;
  }

  // ---------------- 触控拖动滚动回滚区 ----------------
  private onTermTouch(event: TouchEvent): void {
    if (event.touches.length === 0) {
      return;
    }
    const y = event.touches[0].y;
    if (event.type === TouchType.Down) {
      this.touchLastY = y;
      this.touchAccum = 0;
      return;
    }
    if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
      this.touchLastY = -1;
      return;
    }
    if (event.type === TouchType.Move && this.touchLastY >= 0) {
      // 手指上滑(y 变小) => 回看历史(offset 增大)
      this.touchAccum += (this.touchLastY - y);
      this.touchLastY = y;
      const STEP = 18;   // 每 18vp 走一行，避免过于灵敏
      while (this.touchAccum >= STEP) {
        this.touchAccum -= STEP;
        this.scrollView(1);
      }
      while (this.touchAccum <= -STEP) {
        this.touchAccum += STEP;
        this.scrollView(-1);
      }
    }
  }

  // ---------------- 选区与复制 ----------------
  // 选中"当前视图"（含回滚区偏移），点 Copy 写入系统剪贴板并回读自证。
  private selectAllVisible(): void {
    this.selText = this.termText;
    this.ptyStatus = 'selected ' + this.selText.length + ' chars';
  }

  private async copySelection(): Promise<void> {
    const text = this.selText;
    if (text.length === 0) {
      this.ptyStatus = 'copy: nothing selected';
      return;
    }
    try {
      const board = pasteboard.getSystemPasteboard();
      await board.setData(pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text));
      // 回读只是加分项：模拟器上 setData 成功后 getData 可能短暂返回空，
      // 所以重试几次；仍读不到就如实显示"读不到"，但明确区分于"写失败"。
      let back = '';
      for (let i = 0; i < 5; i++) {
        const data = await board.getData();
        const t: string = (data === undefined || data === null) ? '' : data.getPrimaryText();
        back = (t === undefined || t === null) ? '' : t;
        if (back.length > 0) {
          break;
        }
        await new Promise<void>((resolve) => setTimeout(resolve, 150));
      }
      this.clipText = back.length > 0 ? back : '(readback empty)';
      this.ptyStatus = 'copied ' + text.length + ' chars' +
        (back.length > 0 ? ' (readback ok)' : ' (readback unavailable)');
    } catch (e) {
      this.clipText = '';
      this.ptyStatus = 'copy failed: ' + JSON.stringify(e);
    }
  }

  // 控制字符直发：Ctrl-C 走 sendRaw，不追加换行（追加换行会变成"^C + 回车"两件事）
  // 方向键：sendKey 把名字映射成 VT 序列（普通光标模式）
  private sendSpecial(name: string): void {
    const tab = this.activeTab();
    if (tab === null) {
      this.ptyStatus = 'key: no session';
      return;
    }
    mottynapi.sendKey(tab.shellId, name);
    this.ptyStatus = 'sent ' + name;
  }

  // ---------------- AI 通路（最小切片） ----------------
  // 真实产品接外部模型；这里把"请求构造 / 超时 / 错误处理 / 结果呈现"验证到可断言，
  // 模型质量本身不在验证范围内（见 spec 的 evidence.limits）。
  // ---------------- RDP 服务端（诊断用：给客户端一个真实协议的对端）----------------
  private startRdpServer(): void {
    // OHOS 没有 XDG 配置目录：shadow_server_init 需要一个可写目录来放自签证书
    const ctx = getContext(this) as common.UIAbilityContext;
    const dir: string = ctx !== undefined && ctx.cacheDir !== undefined ? ctx.cacheDir : '/data/storage/el2/base/cache';
    const rc: number = mottynapi.rdpServerStart(this.rdpSrvPort, 'tester', 'secret', dir);
    this.rdpSrvStatus = 'rdp-server: start rc=' + rc + ' ' + mottynapi.rdpServerStatus();
  }

  private stopRdpServer(): void {
    mottynapi.rdpServerStop();
    this.rdpSrvStatus = 'rdp-server: ' + mottynapi.rdpServerStatus();
  }

  private refreshRdpServer(): void {
    this.rdpSrvStatus = 'rdp-server: ' + mottynapi.rdpServerStatus();
  }

  private async askAI(): Promise<void> {
    const tab = this.activeTab();
    const tail = tab === null ? this.termText.slice(-200)
                              : this.termText.slice(Math.max(0, this.termText.length - 200));
    if (tail.trim().length === 0) {
      this.aiAnswer = 'ai: (empty context)';
      return;
    }
    this.aiAnswer = 'ai: asking...';
    try {
      const client = http.createHttp();
      const resp = await client.request(this.aiEndpoint, {
        method: http.RequestMethod.POST,
        header: { 'Content-Type': 'application/json' } as Record<string, string>,
        extraData: JSON.stringify({ prompt: tail }),
        connectTimeout: 5000,
        readTimeout: 5000
      });
      const code: number = resp.responseCode as number;
      const body: string = typeof resp.result === 'string' ? resp.result : JSON.stringify(resp.result);
      if (code === 200) {
        const obj: Record<string, string> = JSON.parse(body) as Record<string, string>;
        this.aiAnswer = 'ai: ' + (obj.answer === undefined ? '(no answer field)' : obj.answer);
      } else {
        this.aiAnswer = 'ai: http ' + code;
      }
      client.destroy();
    } catch (e) {
      this.aiAnswer = 'ai: request failed';
      hilog.error(DOMAIN, TAG, 'ai request failed: %{public}s', JSON.stringify(e));
    }
  }

  private sendCtrlC(): void {
    const tab = this.activeTab();
    if (tab === null) {
      this.ptyStatus = 'ctrl-c: no session';
      return;
    }
    mottynapi.sendRaw(tab.shellId, '\u0003');
    this.ptyStatus = 'sent ^C';
  }

  private sendTermInput(): void {
    const tab = this.activeTab();
    if (tab === null) {
      this.ptyStatus = 'no session';
      return;
    }
    const text = this.termInput;
    if (text.length === 0) {
      return;
    }
    mottynapi.sendInput(tab.shellId, text);
    this.termInput = '';
  }

  private resizeSession(): void {
    const tab = this.activeTab();
    if (tab === null) {
      this.ptyStatus = 'resize: no session';
      return;
    }
    mottynapi.resizeShell(tab.shellId, 100, 30);
    this.ptyStatus = 'resize->100x30';
  }

  // ---------------- 诊断（收进面板，但保留全部能力与 id） ----------------
  private connectFixtureDemo(kind: string): void {
    this.pendingAction = kind;
    const cred = this.creds.get(this.fixtureKey);
    if (cred === undefined) {
      this.probeText = 'no fixture credentials';
      return;
    }
    this.lookupFp(this.fixtureKey).then((fp: string) => {
      if (fp.length === 0) {
        mottynapi.probe(cred.address, cred.port, cred.user, cred.password, 'echo no-auth-yet', '',
          (first: string) => {
            const m = new RegExp('SHA256:[A-Za-z0-9+/]+').exec(first);
            if (m === null || first.indexOf('unknown_host') !== 0) {
              this.probeText = first;
              return;
            }
            this.pendingFp = m[0];
            this.pendingKey = this.fixtureKey;
            this.keyDialog = true;
          });
        return;
      }
      this.runDemoWith(cred, fp, kind);
    });
  }

  private runDemoWith(cred: Cred, fp: string, kind: string): void {
    if (kind === 'shell') {
      this.startSession(cred, fp, 'fixture shell');
      return;
    }
    this.diagOpen = false;
    this.tabSeq = this.tabSeq + 1;
    const tabId: string = 't' + this.tabSeq;
    const tabLabel: string = kind + ' #' + this.tabSeq;
    const vtId: number = mottynapi.vtNew(80, 24);
    const next: TabInfo[] = this.tabs.slice();
    next.push({ id: tabId, label: tabLabel, shellId: 0, vtId: vtId });
    this.tabs = next;
    this.activeId = tabId;
    this.showHosts = false;
    this.termVisible = true;
    this.ptyStatus = '';
    this.refreshTab(vtId);

    if (kind === 'term-echo') {
      const id: number = mottynapi.openShell(cred.address, cred.port, cred.user, cred.password, fp,
        (chunk: string) => {
          mottynapi.vtFeed(vtId, chunk);
          if (this.activeId === tabId) {
            this.refreshTab(vtId);
          }
        },
        (status: string) => { this.probeText = tabLabel + ': ' + status; });
      const withId: TabInfo[] = [];
      for (let i = 0; i < this.tabs.length; i++) {
        const t = this.tabs[i];
        withId.push(t.id === tabId ? { id: t.id, label: t.label, shellId: id, vtId: t.vtId } : t);
      }
      this.tabs = withId;
      this.shellId = id;
      return;
    }

    const cmd = kind === 'vt' ? 'vt-demo' : (kind === 'vt2' ? 'vt-demo2' : 'term-demo');
    mottynapi.exec(cred.address, cred.port, cred.user, cred.password, cmd, fp,
      (chunk: string) => {
        mottynapi.vtFeed(vtId, chunk);
        if (this.activeId === tabId) {
          if (this.vtScroll > 0) {
            this.termText = mottynapi.vtView(vtId, this.vtScroll);
          } else {
            this.refreshTab(vtId);
          }
        }
      },
      (status: string) => {
        if (this.activeId === tabId) {
          this.refreshTab(vtId);
        }
        this.probeText = cmd + ': ' + status;
      });
  }

  // ---------------- SFTP（M2 起点：列目录 / 读文件）----------------
  private openFiles(index: number): void {
    this.pendingAction = 'files';
    const h = this.hosts[index];
    if (h === undefined) {
      return;
    }
    this.pendingLabel = h.label;
    const key = this.hostKey(h.address, h.port);
    const cred = this.creds.get(key);
    if (cred === undefined) {
      this.setStatus(index, 'no credentials in memory (vault not implemented yet)');
      return;
    }
    this.lookupFp(key).then((fp: string) => {
      if (fp.length > 0) {
        this.startFiles(cred, fp);
        return;
      }
      mottynapi.probe(cred.address, cred.port, cred.user, cred.password, 'echo no-auth-yet', '',
        (first: string) => {
          const m = new RegExp('SHA256:[A-Za-z0-9+/]+').exec(first);
          if (m === null || first.indexOf('unknown_host') !== 0) {
            this.setStatus(index, first);
            return;
          }
          this.pendingFp = m[0];
          this.pendingKey = key;
          this.keyDialog = true;
        });
    });
  }

  private startFiles(cred: Cred, fp: string): void {
    this.filesOpen = true;
    this.sftpList = '';
    this.sftpPreview = '';
    this.sftpStatus = '';
    this.sftpPath = '.';
    this.sftpFile = 'hello.txt';
    this.refreshListing(cred, fp);
  }

  private refreshListing(cred: Cred, fp: string): void {
    this.sftpStatus = 'listing ' + this.sftpPath;
    mottynapi.sftp(cred.address, cred.port, cred.user, cred.password, fp, 'list', this.sftpPath,
      (result: string) => {
        this.sftpList = result;
        this.sftpEntries = result.length > 0 ? result.split('\n') : [];
        this.sftpStatus = 'listed ' + this.sftpPath + ' (' + this.sftpEntries.length + ' entries)';
      });
  }

  // ---------------- 目录层级导航 ----------------
  // 列表条目形如 "name|size"，目录带尾斜杠（C 层已标注）。
  private enterEntry(cred: Cred, fp: string, entry: string): void {
    const name = entry.substring(0, entry.indexOf('|'));
    if (!name.endsWith('/')) {
      this.sftpFile = name;
      this.sftpStatus = 'selected ' + name;
      return;
    }
    const dir = name.substring(0, name.length - 1);
    this.sftpPath = this.joinPath(this.sftpPath, dir);
    this.sftpFile = '';
    this.refreshListing(cred, fp);
  }

  private goUp(cred: Cred, fp: string): void {
    const p = this.sftpPath;
    if (p === '.' || p === '/' || p.length === 0) {
      this.sftpStatus = 'already at root';
      return;
    }
    const trimmed = p.endsWith('/') ? p.substring(0, p.length - 1) : p;
    const idx = trimmed.lastIndexOf('/');
    this.sftpPath = idx <= 0 ? '.' : trimmed.substring(0, idx);
    this.refreshListing(cred, fp);
  }

  private joinPath(base: string, name: string): string {
    if (base === '.' || base.length === 0) {
      return name;
    }
    return base.endsWith('/') ? base + name : base + '/' + name;
  }

  private downloadFile(cred: Cred, fp: string): void {
    this.sftpStatus = 'reading ' + this.sftpFile;
    mottynapi.sftp(cred.address, cred.port, cred.user, cred.password, fp, 'read', this.sftpFile,
      (result: string) => {
        this.sftpPreview = result;
        this.sftpStatus = 'read ' + this.sftpFile + ' (' + result.length + ' chars)';
      });
  }

  private uploadFile(cred: Cred, fp: string): void {
    this.sftpStatus = 'uploading ' + this.sftpUploadName;
    mottynapi.sftpWrite(cred.address, cred.port, cred.user, cred.password, fp,
      this.sftpUploadName, this.sftpUploadText,
      (result: string) => {
        this.sftpResult = 'upload: ' + result;
        this.sftpStatus = 'upload done';
        this.refreshListing(cred, fp);
      });
  }

  private renameFile(cred: Cred, fp: string): void {
    const from = this.sftpFile;
    const to = this.sftpRenameTo;
    this.sftpStatus = 'renaming ' + from + ' -> ' + to;
    mottynapi.sftpRename(cred.address, cred.port, cred.user, cred.password, fp, from, to,
      (result: string) => {
        this.sftpResult = 'rename: ' + result;
        this.sftpFile = to;
        this.refreshListing(cred, fp);
      });
  }

  private mkdirRemote(cred: Cred, fp: string): void {
    this.sftpStatus = 'creating dir ' + this.sftpNewDir;
    mottynapi.sftpMkdir(cred.address, cred.port, cred.user, cred.password, fp, this.sftpNewDir,
      (result: string) => {
        this.sftpResult = 'mkdir: ' + result;
        this.refreshListing(cred, fp);
      });
  }

  private deleteFile(cred: Cred, fp: string): void {
    this.sftpStatus = 'deleting ' + this.sftpFile;
    mottynapi.sftpDelete(cred.address, cred.port, cred.user, cred.password, fp, this.sftpFile,
      (result: string) => {
        this.sftpResult = 'delete: ' + result;
        this.sftpStatus = 'delete done';
        this.sftpPreview = '';
        this.refreshListing(cred, fp);
      });
  }

  // ---------------- 端口转发（本地 forward）----------------
  private startForward(): void {
    const cred = this.creds.get(this.fixtureKey);
    if (cred === undefined) {
      this.fwdEvents = 'no credentials (create a host for 127.0.0.1:2222 first)';
      return;
    }
    this.lookupFp(this.fixtureKey).then((fp: string) => {
      if (fp.length === 0) {
        this.fwdEvents = 'host key not trusted yet (use Test on the host row first)';
        return;
      }
      this.fwdEvents = 'starting...';
      this.fwdResult = '';
      this.fwdId = mottynapi.forwardStart(cred.address, cred.port, cred.user, cred.password, fp,
        Number.parseInt(this.fwdListen, 10), this.fwdTargetHost, Number.parseInt(this.fwdTargetPort, 10),
        this.fwdMode,
        (event: string) => {
          this.fwdEvents = this.fwdEvents + '\n' + event;
        });
    });
  }

  private stopForward(): void {
    if (this.fwdId !== 0) {
      mottynapi.forwardStop(this.fwdId);
      this.fwdId = 0;
    }
  }

  // 用本机 socket 连自己的转发端口，读回远端 banner —— 这才算"隧道真的通了"
  private testForward(): void {
    const port = Number.parseInt(this.fwdListen, 10);
    this.fwdResult = 'connecting 127.0.0.1:' + port + ' (' + this.fwdMode + ') ...';
    const tcp = socket.constructTCPSocketInstance();
    let acc = '';
    let greeted = false;
    let connected = false;
    const mode = this.fwdMode;
    const append = (text: string) => { this.fwdResult = acc; };

    tcp.on('message', (info: socket.SocketMessageInfo) => {
      const u8 = new Uint8Array(info.message as ArrayBuffer);
      for (let i = 0; i < u8.length; i++) {
        acc += String.fromCharCode(u8[i]);
      }
      if (mode === 'socks5') {
        if (!greeted && u8.length >= 2 && u8[0] === 5 && u8[1] === 0) {
          greeted = true;
          // CONNECT 127.0.0.1:2223（IPv4）
          const req = new Uint8Array([5, 1, 0, 1, 127, 0, 0, 1, 2223 >> 8, 2223 & 0xFF]);
          tcp.send({ data: req.buffer as ArrayBuffer }).catch((e: BusinessError) => {
            this.fwdResult = 'send failed: ' + e.message;
          });
          return;
        }
        if (greeted && !connected && u8.length >= 4 && u8[0] === 5 && u8[1] === 0) {
          connected = true;
          acc = 'tunnel established; ';
          return;
        }
      } else if (mode === 'http') {
        if (!connected && acc.indexOf('200') >= 0) {
          connected = true;
        }
      }
      append(acc);
    });
    tcp.on('error', (e: BusinessError) => {
      this.fwdResult = 'socket error: ' + e.message;
    });
    tcp.connect({ address: { address: '127.0.0.1', port: port, family: 1 }, timeout: 5000 })
      .then(() => {
        if (mode === 'socks5') {
          const hello = new Uint8Array([5, 1, 0]);
          tcp.send({ data: hello.buffer as ArrayBuffer }).catch(() => {});
        } else if (mode === 'http') {
          const req = 'CONNECT 127.0.0.1:2223 HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n';
          const enc = new util.TextEncoder().encodeInto(req);
          tcp.send({ data: enc.buffer as ArrayBuffer }).catch(() => {});
        }
        setTimeout(() => { tcp.close(); }, 2500);
      })
      .catch((e: BusinessError) => {
        this.fwdResult = 'connect failed: ' + e.code + ' ' + e.message;
      });
  }

  // ---------------- VNC 会话（自研 RFB 后端）----------------
  private startVnc(pwd: string): void {
    this.vncOpen = true;
    this.vncReady = false;
    this.vncStatus = 'connecting...';
    this.vncFrameInfo = '';
    this.vncDrawn = 0;
    try {
      this.vncId = mottynapi.vncStart('127.0.0.1', 5901, pwd,
        (frameStr: string) => {
          const sep = frameStr.indexOf(':');
          if (sep <= 0 || !this.vncReady) {
            return;
          }
          const dims = frameStr.substring(0, sep).split('x');
          const w = Number.parseInt(dims[0], 10);
          const h = Number.parseInt(dims[1], 10);
          this.vncW = w;
          this.vncH = h;
          try {
            const hex = frameStr.substring(sep + 1);
            const cw = 320 / w;
            const ch = 240 / h;
            let drawn = 0;
            for (let y = 0; y < h; y++) {
              for (let x = 0; x < w; x++) {
                const i = (y * w + x) * 6;
                if (i + 5 >= hex.length) {
                  continue;
                }
                const r = Number.parseInt(hex.substring(i, i + 2), 16);
                const g = Number.parseInt(hex.substring(i + 2, i + 4), 16);
                const b = Number.parseInt(hex.substring(i + 4, i + 6), 16);
                this.vncCtx.fillStyle = 'rgb(' + r + ',' + g + ',' + b + ')';
                this.vncCtx.fillRect(x * cw, y * ch, cw + 0.5, ch + 0.5);
                drawn++;
              }
            }
            this.vncDrawn = drawn;
          } catch (e) {
            hilog.error(DOMAIN, TAG, 'vnc draw failed: %{public}s', JSON.stringify(e));
          }
        },
        (status: string) => {
          this.vncStatus = status;
          if (status.indexOf('frame=') === 0) {
            this.vncFrameInfo = status;
            const m = new RegExp('([0-9]+)x([0-9]+)').exec(status);
            if (m !== null) {
              this.vncW = Number.parseInt(m[1], 10);
              this.vncH = Number.parseInt(m[2], 10);
              this.updateCanvasSize(this.vncW, this.vncH);
            }
          }
        });
    } catch (e) {
      this.vncStatus = 'start failed: ' + String(e);
    }
  }

  // VNC 剪贴板：读出服务端内容 / 把本地内容推给服务端
  // 画布尺寸跟随远端：长边不超过 640vp，保持宽高比。
  // 之前写死 320x240，远端换分辨率（如 80x60）后会变形/留白。
  private updateCanvasSize(w: number, h: number): void {
    if (w <= 0 || h <= 0) {
      return;
    }
    const maxSide = 640;
    const scale = Math.min(1.0, maxSide / Math.max(w, h));
    this.vncCanvasW = Math.max(1, Math.round(w * scale));
    this.vncCanvasH = Math.max(1, Math.round(h * scale));
  }

  private refreshVncClip(): void {
    if (this.vncId === 0) {
      this.vncClip = '';
      return;
    }
    this.vncClip = mottynapi.vncClipboard(this.vncId);
  }

  private sendClipToVnc(): void {
    if (this.vncId === 0) {
      this.vncClip = '(no session)';
      return;
    }
    const ok: number = mottynapi.vncCutText(this.vncId, this.vncClipOut);
    this.vncClip = ok === 1 ? 'sent: ' + this.vncClipOut : 'send failed';
  }

  private stopVnc(): void {
    if (this.vncId !== 0) {
      mottynapi.vncStop(this.vncId);
      this.vncId = 0;
    }
  }

  private sendVncPointer(localX: number, localY: number, mask: number): void {
    if (this.vncId === 0 || this.vncW === 0) {
      return;
    }
    mottynapi.vncPointer(this.vncId, Math.round(localX), Math.round(localY), mask);
  }

  // ---------------- RDP（FreeRDP 接入，仅连接路径）----------------
  // 说明：本轮只验证"能起、能失败、能报错"，没有画面与输入。
  private rdpProbe(port: number): void {
    this.rdpResult = 'rdp: probing 127.0.0.1:' + port + ' ...';
    mottynapi.rdpProbe('127.0.0.1', port, 'administrator', 'wrong-password',
      (result: string) => {
        this.rdpResult = 'rdp: ' + result;
        this.probeText = 'rdp: ' + result;
      });
  }

  // ---------------- known_hosts 管理 ----------------
  private async openKnownHosts(): Promise<void> {
    this.knownOpen = true;
    await this.refreshKnownHosts();
  }

  private async refreshKnownHosts(): Promise<void> {
    if (this.store === null) {
      return;
    }
    const rs = await this.store.query(new relationalStore.RdbPredicates('known_hosts'), ['host', 'fingerprint']);
    const keys: string[] = [];
    const fps: string[] = [];
    while (rs.goToNextRow()) {
      keys.push(rs.getString(0));
      fps.push(rs.getString(1));
    }
    rs.close();
    this.knownKeys = keys;
    this.knownFps = fps;
  }

  private async deleteKnownHost(key: string): Promise<void> {
    if (this.store === null) {
      return;
    }
    const pred = new relationalStore.RdbPredicates('known_hosts');
    pred.equalTo('host', key);
    await this.store.delete(pred);
    hilog.info(DOMAIN, TAG, 'known_hosts deleted for %{public}s', key);
    await this.refreshKnownHosts();
  }

  // ---------------- 转发规则持久化 ----------------
  private async reloadRules(): Promise<void> {
    if (this.store === null) {
      return;
    }
    const rs = await this.store.query(new relationalStore.RdbPredicates('forwards'),
      ['id', 'mode', 'listen_port', 'target_host', 'target_port']);
    const out: string[] = [];
    while (rs.goToNextRow()) {
      out.push(rs.getString(0) + '|' + rs.getString(1) + '|' + rs.getString(2) + '->' +
        rs.getString(3) + ':' + rs.getString(4));
    }
    rs.close();
    this.fwdRules = out;
    this.fwdRuleCount = out.length;
  }

  private async saveRule(): Promise<void> {
    if (this.store === null) {
      return;
    }
    const bucket: relationalStore.ValuesBucket = {
      'id': String(Date.now()),
      'host_key': this.fixtureKey,
      'mode': this.fwdMode,
      'listen_port': this.fwdListen,
      'target_host': this.fwdTargetHost,
      'target_port': this.fwdTargetPort
    };
    await this.store.insert('forwards', bucket);
    await this.reloadRules();
    hilog.info(DOMAIN, TAG, 'forward rule saved, total=%{public}d', this.fwdRuleCount);
  }

  private async deleteRule(id: string): Promise<void> {
    if (this.store === null) {
      return;
    }
    const pred = new relationalStore.RdbPredicates('forwards');
    pred.equalTo('id', id);
    await this.store.delete(pred);
    await this.reloadRules();
  }

  // 用已保存的规则启动转发
  private startSavedRule(id: string, mode: string, listenPort: string,
                         targetHost: string, targetPort: string): void {
    this.fwdMode = mode;
    this.fwdListen = listenPort;
    this.fwdTargetHost = targetHost;
    this.fwdTargetPort = targetPort;
    this.startForward();
  }

  // 过滤主机：返回 (host, 原下标) 对。下标必须来自**未过滤**数组，
  // 否则 host-row/<i> 会随搜索变化而指向别的机器（spec 与用户都会踩到）。
  private matchesQuery(h: HostItem): boolean {
    const q = this.hostQuery.trim().toLowerCase();
    if (q.length === 0) {
      return true;
    }
    return h.label.toLowerCase().indexOf(q) >= 0 || h.address.toLowerCase().indexOf(q) >= 0;
  }

  private matchCount(): number {
    let n = 0;
    for (let i = 0; i < this.hosts.length; i++) {
      if (this.matchesQuery(this.hosts[i])) {
        n++;
      }
    }
    return n;
  }

  private t(key: string): string {
    return Strings.get(this.lang, key);
  }

  private toggleLang(): void {
    this.lang = this.lang === 'zh' ? 'en' : 'zh';
  }

  private probeNet(): void {
    this.probeText = 'connecting...';
    const tcp = socket.constructTCPSocketInstance();
    let acc = '';
    tcp.on('message', (info: socket.SocketMessageInfo) => {
      const u8 = new Uint8Array(info.message as ArrayBuffer);
      for (let i = 0; i < u8.length; i++) {
        acc += String.fromCharCode(u8[i]);
      }
      this.probeText = acc;
    });
    tcp.on('error', (e: BusinessError) => {
      this.probeText = 'socket error: ' + e.message;
    });
    tcp.connect({ address: { address: '127.0.0.1', port: 2222, family: 1 }, timeout: 5000 })
      .then(() => { setTimeout(() => { tcp.close(); }, 1500); })
      .catch((e: BusinessError) => { this.probeText = 'connect failed: ' + e.code + ' ' + e.message; });
  }

  private probeSsh(): void {
    this.probeText = 'ssh: fetching host key...';
    mottynapi.probe('127.0.0.1', 2222, 'tester', 'secret', 'echo hello-from-ssh', '',
      (first: string) => {
        const m = new RegExp('SHA256:[A-Za-z0-9+/]+').exec(first);
        if (m === null) {
          this.probeText = 'ssh: no fingerprint, got ' + first;
          return;
        }
        const fp: string = m[0];
        this.probeText = 'ssh: host key ' + fp + ', connecting...';
        mottynapi.probe('127.0.0.1', 2222, 'tester', 'secret', 'echo hello-from-ssh', fp,
          (result: string) => { this.probeText = 'ssh: ' + result; });
      });
  }

  private hostkeyCheck(): void {
    const lines: string[] = [];
    const show = () => { this.probeText = lines.join('\n'); };
    lines.push('hostkey check: start');
    show();
    mottynapi.probe('127.0.0.1', 2222, 'tester', 'secret', 'echo should-not-run-1', '',
      (r1: string) => {
        lines.push('[1 unknown] ' + r1);
        show();
        const m = new RegExp('SHA256:[A-Za-z0-9+/]+').exec(r1);
        const fp: string = m !== null ? m[0] : '';
        mottynapi.probe('127.0.0.1', 2222, 'tester', 'secret', 'echo should-run-2', fp,
          (r2: string) => {
            lines.push('[2 match] ' + r2);
            show();
            mottynapi.probe('127.0.0.1', 2222, 'tester', 'secret', 'echo must-not-run-3',
              'SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
              (r3: string) => {
                lines.push('[3 mismatch] ' + r3);
                show();
              });
          });
      });
  }

  private trustAndConnect(): void {
    const fp = this.pendingFp;
    const key = this.pendingKey;
    this.keyDialog = false;
    this.pendingFp = '';
    this.pendingKey = '';
    this.saveFp(key, fp).then(() => {
      const cred = this.creds.get(key);
      if (cred === undefined) {
        this.probeText = 'no credentials in memory';
        return;
      }
      if (this.pendingAction === 'connect') {
        for (let i = 0; i < this.hosts.length; i++) {
          if (this.hostKey(this.hosts[i].address, this.hosts[i].port) === key) {
            this.runProbe(i, cred, fp);
            return;
          }
        }
        return;
      }
      if (this.pendingAction === 'open') {
        this.startSession(cred, fp, this.pendingLabel);
        return;
      }
      if (this.pendingAction === 'files') {
        this.startFiles(cred, fp);
        return;
      }
      this.runDemoWith(cred, fp, this.pendingAction);
    });
  }

  private runProbe(index: number, cred: Cred, fp: string): void {
    mottynapi.probe(cred.address, cred.port, cred.user, cred.password, 'echo hello-from-list', fp,
      (result: string) => {
        this.setStatus(index, result);
        // 主机密钥变更：必须显式告警，且**不自动连接**
        if (result.indexOf('hostkey-mismatch') === 0) {
          const m = new RegExp('actual=(SHA256:[A-Za-z0-9+/]+)').exec(result);
          this.changedOld = fp;
          this.changedNew = m !== null ? m[1] : 'unknown';
          this.changedDialog = true;
        }
      });
  }

  // 用户明确接受新密钥：更新 known_hosts 后重试
  private acceptChangedKey(index: number): void {
    const key = this.hostKey(this.hosts[index].address, this.hosts[index].port);
    const newFp = this.changedNew;
    this.changedDialog = false;
    this.saveFp(key, newFp).then(() => {
      const cred = this.creds.get(key);
      if (cred !== undefined) {
        this.runProbe(index, cred, newFp);
      }
    });
  }

  private async connectRow(index: number): Promise<void> {
    this.pendingAction = 'connect';
    if (index >= this.hosts.length) {
      return;
    }
    const h = this.hosts[index];
    const key = this.hostKey(h.address, h.port);
    const cred = this.creds.get(key);
    if (cred === undefined) {
      this.setStatus(index, 'no credentials in memory (vault not implemented yet)');
      return;
    }
    const stored = await this.lookupFp(key);
    if (stored.length > 0) {
      this.setStatus(index, 'using stored key ' + stored);
      this.runProbe(index, cred, stored);
      return;
    }
    this.setStatus(index, 'unknown host, fetching key...');
    mottynapi.probe(cred.address, cred.port, cred.user, cred.password, 'echo no-auth-yet', '',
      (first: string) => {
        const m = new RegExp('SHA256:[A-Za-z0-9+/]+').exec(first);
        if (m === null || first.indexOf('unknown_host') !== 0) {
          this.setStatus(index, first);
          return;
        }
        this.pendingFp = m[0];
        this.pendingKey = key;
        this.keyDialog = true;
        this.setStatus(index, 'waiting for user to trust ' + this.pendingFp);
      });
  }

  // ---------------- UI ----------------
  @Builder
  hostForm() {
    Column({ space: 10 }) {
      Text(this.editingId.length > 0 ? 'Edit Host' : 'New Host').fontSize(20).fontWeight(FontWeight.Bold).width('100%')
      Text('Label').fontSize(12).fontColor('#666666').width('100%')
      TextInput({ placeholder: 'my server' }).id('shell/dialog-label').width('100%')
        .onChange((v: string) => { this.formLabel = v; })
      Text('Address').fontSize(12).fontColor('#666666').width('100%')
      TextInput({ placeholder: '10.0.0.1' }).id('shell/dialog-address').width('100%')
        .onChange((v: string) => { this.formAddress = v; })
      Row({ space: 10 }) {
        Column({ space: 6 }) {
          Text('User').fontSize(12).fontColor('#666666').width('100%')
          TextInput({ placeholder: 'root' }).id('shell/dialog-user').width('100%')
            .onChange((v: string) => { this.formUser = v; })
        }.layoutWeight(1)
        Column({ space: 6 }) {
          Text('Port').fontSize(12).fontColor('#666666').width('100%')
          TextInput({ placeholder: '22' }).id('shell/dialog-port').width('100%').type(InputType.Number)
            .onChange((v: string) => { this.formPort = v; })
        }.layoutWeight(1)
      }.width('100%')
      Text('Password (memory only, not stored)').fontSize(12).fontColor('#666666').width('100%')
      TextInput({ placeholder: 'password' }).id('shell/dialog-password').width('100%')
        .type(InputType.Password).onChange((v: string) => { this.formPassword = v; })
      Row({ space: 12 }) {
        Button('Cancel').id('shell/dialog-cancel').backgroundColor('#E6E6E6').fontColor('#1A1A1A')
          .onClick(() => { this.showDialog = false; this.editingId = ''; this.resetForm(); })
        Button(this.editingId.length > 0 ? this.t('common.save') : this.t('common.add')).id('shell/dialog-submit').onClick(() => { this.submit(); })
      }.width('100%').justifyContent(FlexAlign.End)
    }
    .id('host-form/dialog').width(560).padding(20).backgroundColor(Color.White).borderRadius(12)
    .shadow({ radius: 24, color: '#33000000', offsetY: 8 })
  }

  @Builder
  keyConfirm() {
    Column({ space: 12 }) {
      Text('Unknown host key').fontSize(18).fontWeight(FontWeight.Bold).width('100%')
      Text('Verify the fingerprint out-of-band before trusting it.').fontSize(12).fontColor('#666666').width('100%')
      Text(this.pendingFp).id('hostkey/fingerprint').fontSize(13).fontFamily('monospace').width('100%')
      Row({ space: 12 }) {
        Button('Cancel').id('hostkey/cancel').backgroundColor('#E6E6E6').fontColor('#1A1A1A')
          .onClick(() => {
            this.keyDialog = false; this.pendingFp = ''; this.pendingKey = '';
            this.probeText = 'cancelled, nothing trusted';
          })
        Button('Trust').id('hostkey/trust').onClick(() => this.trustAndConnect())
      }.width('100%').justifyContent(FlexAlign.End)
    }
    .id('hostkey/dialog').width(520).padding(20).backgroundColor(Color.White).borderRadius(12)
    .shadow({ radius: 24, color: '#33000000', offsetY: 8 })
  }

  @Builder
  filesPanel() {
    Column({ space: 8 }) {
      Row() {
        Text('Files (SFTP)').fontSize(16).fontWeight(FontWeight.Bold)
        Blank()
        Button('Close').id('sftp/close').backgroundColor('#E6E6E6').fontColor('#1A1A1A')
          .onClick(() => { this.filesOpen = false; })
      }.width('100%')
      Text(this.sftpStatus.length > 0 ? this.sftpStatus : 'sftp: (idle)')
        .id('sftp/status').fontSize(11).fontColor('#0A6C00').width('100%')
      Text(this.sftpResult.length > 0 ? this.sftpResult : 'sftp: no operation yet')
        .id('sftp/result').fontSize(11).fontColor('#6A1B9A').width('100%')
      Row({ space: 8 }) {
        TextInput({ text: this.sftpPath, placeholder: '.' }).id('sftp/path')
          .layoutWeight(1).onChange((v: string) => { this.sftpPath = v; })
        Button(this.t('sftp.up')).id('sftp/up').backgroundColor('#E6E6E6').fontColor('#1A1A1A')
          .onClick(() => {
            const cred = this.creds.get(this.fixtureKey);
            if (cred !== undefined) {
              this.lookupFp(this.fixtureKey).then((fp: string) => { this.goUp(cred, fp); });
            }
          })
        Button(this.t('sftp.list')).id('sftp/list-btn').onClick(() => {
          const cred = this.creds.get(this.fixtureKey);
          if (cred !== undefined) {
            this.lookupFp(this.fixtureKey).then((fp: string) => { this.refreshListing(cred, fp); });
          }
        })
      }.width('100%')
      Scroll() {
        Column({ space: 2 }) {
          ForEach(this.sftpEntries, (entry: string) => {
            Row() {
              Button(entry.indexOf('|') > 0 ? entry.substring(0, entry.indexOf('|')) : entry)
                .id('sftp/entry/' + (entry.indexOf('|') > 0 ? entry.substring(0, entry.indexOf('|')) : entry))
                .backgroundColor(Color.Transparent)
                .fontColor(entry.endsWith('/') ? '#1A6DD0' : '#1A1A1A')
                .fontSize(12)
                .onClick(() => {
                  const name = entry.indexOf('|') > 0 ? entry.substring(0, entry.indexOf('|')) : entry;
                  const cred = this.creds.get(this.fixtureKey);
                  if (cred === undefined) {
                    return;
                  }
                  if (name.endsWith('/')) {
                    const base = this.sftpPath === '.' ? '' : this.sftpPath;
                    const clean = name.substring(0, name.length - 1);
                    this.sftpPath = base.length > 0 ? base + '/' + clean : clean;
                    this.lookupFp(this.fixtureKey).then((fp: string) => {
                      this.refreshListing(cred, fp);
                    });
                  } else {
                    this.sftpFile = name;
                    this.sftpStatus = 'selected ' + name;
                  }
                })
            }.width('100%')
          }, (entry: string) => entry)
          Text(this.sftpList.length > 0 ? this.sftpList : '(empty)')
            .id('sftp/list').fontSize(10).fontFamily('monospace').fontColor('#999999').width('100%')
        }.width('100%').alignItems(HorizontalAlign.Start)
      }.height(220).width('100%').border({ width: 1, color: '#DDDDDD' }).padding(8)
        .align(Alignment.TopStart)
      Row({ space: 8 }) {
        TextInput({ text: this.sftpFile, placeholder: 'hello.txt' }).id('sftp/file')
          .layoutWeight(1).onChange((v: string) => { this.sftpFile = v; })
        Button(this.t('sftp.download')).id('sftp/download').onClick(() => {
          const cred = this.creds.get(this.fixtureKey);
          if (cred !== undefined) {
            this.lookupFp(this.fixtureKey).then((fp: string) => { this.downloadFile(cred, fp); });
          }
        })
        Button(this.t('sftp.delete')).id('sftp/delete').backgroundColor('#C62828').fontColor(Color.White)
          .onClick(() => {
            const cred = this.creds.get(this.fixtureKey);
            if (cred !== undefined) {
              this.lookupFp(this.fixtureKey).then((fp: string) => { this.deleteFile(cred, fp); });
            }
          })
        Button(this.t('sftp.rename')).id('sftp/rename').backgroundColor('#E6E6E6').fontColor('#1A1A1A')
          .onClick(() => {
            const cred = this.creds.get(this.fixtureKey);
            if (cred !== undefined) {
              this.lookupFp(this.fixtureKey).then((fp: string) => { this.renameFile(cred, fp); });
            }
          })
        Button(this.t('sftp.mkdir')).id('sftp/mkdir').backgroundColor('#E6E6E6').fontColor('#1A1A1A')
          .onClick(() => {
            const cred = this.creds.get(this.fixtureKey);
            if (cred !== undefined) {
              this.lookupFp(this.fixtureKey).then((fp: string) => { this.mkdirRemote(cred, fp); });
            }
          })
      }.width('100%')

      Row({ space: 8 }) {
        TextInput({ text: this.sftpUploadName, placeholder: 'uploaded.txt' }).id('sftp/upload-name')
          .layoutWeight(1).onChange((v: string) => { this.sftpUploadName = v; })
        Button(this.t('sftp.upload')).id('sftp/upload').onClick(() => {
          const cred = this.creds.get(this.fixtureKey);
          if (cred !== undefined) {
            this.lookupFp(this.fixtureKey).then((fp: string) => { this.uploadFile(cred, fp); });
          }
        })
      }.width('100%')
      TextArea({ text: this.sftpUploadText, placeholder: 'content to upload' })
        .id('sftp/upload-text').height(70).width('100%')
        .onChange((v: string) => { this.sftpUploadText = v; })
      Scroll() {
        Text(this.sftpPreview.length > 0 ? this.sftpPreview : '(not downloaded)')
          .id('sftp/preview').fontSize(12).fontFamily('monospace').width('100%')
      }.height(120).width('100%').border({ width: 1, color: '#DDDDDD' }).padding(8)
        .align(Alignment.TopStart)
      Text('Limits: text only, 256 KiB cap, no upload/rename/delete yet.')
        .fontSize(10).fontColor('#999999').width('100%')
    }
    .id('sftp/panel').width(680).padding(16).backgroundColor(Color.White).borderRadius(12)
    .shadow({ radius: 24, color: '#33000000', offsetY: 8 })
  }

  @Builder
  forwardPanel() {
    Column({ space: 8 }) {
      Row() {
        Text('Port forwarding (local)').fontSize(16).fontWeight(FontWeight.Bold)
        Blank()
        Button('Close').id('fwd/close').backgroundColor('#E6E6E6').fontColor('#1A1A1A')
          .onClick(() => { this.fwdOpen = false; })
      }.width('100%')
      Row({ space: 8 }) {
        Text('listen').fontSize(11).fontColor('#666666')
        TextInput({ text: this.fwdListen }).id('fwd/listen').width(80)
          .onChange((v: string) => { this.fwdListen = v; })
        Text('->').fontSize(11).fontColor('#666666')
        TextInput({ text: this.fwdTargetHost }).id('fwd/target-host').width(120)
          .onChange((v: string) => { this.fwdTargetHost = v; })
        Text(':').fontSize(11).fontColor('#666666')
        TextInput({ text: this.fwdTargetPort }).id('fwd/target-port').width(80)
          .onChange((v: string) => { this.fwdTargetPort = v; })
      }.width('100%')
      Row({ space: 8 }) {
        Text('mode').fontSize(11).fontColor('#666666')
        Button('local').id('fwd/mode-local')
          .backgroundColor(this.fwdMode === 'local' ? '#1A6DD0' : '#E6E6E6')
          .fontColor(this.fwdMode === 'local' ? Color.White : '#1A1A1A')
          .onClick(() => { this.fwdMode = 'local'; })
        Button('SOCKS5').id('fwd/mode-socks5')
          .backgroundColor(this.fwdMode === 'socks5' ? '#1A6DD0' : '#E6E6E6')
          .fontColor(this.fwdMode === 'socks5' ? Color.White : '#1A1A1A')
          .onClick(() => { this.fwdMode = 'socks5'; })
        Button('HTTP').id('fwd/mode-http')
          .backgroundColor(this.fwdMode === 'http' ? '#1A6DD0' : '#E6E6E6')
          .fontColor(this.fwdMode === 'http' ? Color.White : '#1A1A1A')
          .onClick(() => { this.fwdMode = 'http'; })
        Text('mode=' + this.fwdMode).id('fwd/mode').fontSize(11).fontColor('#0A6C00')
      }.width('100%')
      Row({ space: 8 }) {
        Button('Start').id('fwd/start').onClick(() => { this.startForward(); })
        Button('Stop').id('fwd/stop').backgroundColor('#E6E6E6').fontColor('#1A1A1A')
          .onClick(() => { this.stopForward(); })
        Button('Test tunnel').id('fwd/test').backgroundColor('#1A6DD0').fontColor(Color.White)
          .onClick(() => { this.testForward(); })
        Button(this.t('fwd.save')).id('fwd/save').backgroundColor('#0A6C00').fontColor(Color.White)
          .onClick(() => { this.saveRule(); })
      }.width('100%')
      Text('saved rules: ' + this.fwdRuleCount)
        .id('fwd/rule-count').fontSize(11).fontColor('#0A6C00').width('100%')
      Column({ space: 4 }) {
        ForEach(this.fwdRules, (rule: string) => {
          Row({ space: 8 }) {
            Text(rule.substring(rule.indexOf('|') + 1)).fontSize(11).fontFamily('monospace')
              .layoutWeight(1)
            Button('Start').id('fwd/rule/' + rule.substring(0, rule.indexOf('|')))
              .fontSize(11)
              .onClick(() => {
                // 展示串格式: id|mode|listen->targetHost:targetPort
                const parts = rule.split('|');
                const rest = parts.length > 2 ? parts[2] : '';
                const arrow = rest.indexOf('->');
                const listen = arrow > 0 ? rest.substring(0, arrow) : this.fwdListen;
                const target = arrow > 0 ? rest.substring(arrow + 2) : '127.0.0.1:2223';
                const colon = target.lastIndexOf(':');
                this.startSavedRule(parts[0], parts[1], listen, target.substring(0, colon),
                  target.substring(colon + 1));
              })
            Button('Del').id('fwd/rule-del/' + rule.substring(0, rule.indexOf('|')))
              .backgroundColor('#C62828').fontColor(Color.White).fontSize(11)
              .onClick(() => { this.deleteRule(rule.substring(0, rule.indexOf('|'))); })
          }.width('100%')
        }, (rule: string) => rule)
        if (this.fwdRules.length === 0) {
          Text('(no saved rules)').id('fwd/rule-empty').fontSize(11).fontColor('#999999').width('100%')
        }
      }.width('100%')
      Scroll() {
        Text(this.fwdEvents.length > 0 ? this.fwdEvents : '(no events)')
          .id('fwd/events').fontSize(11).fontFamily('monospace').width('100%')
      }.height(110).width('100%').border({ width: 1, color: '#DDDDDD' }).padding(8)
        .align(Alignment.TopStart)
      Scroll() {
        Text(this.fwdResult.length > 0 ? this.fwdResult : '(tunnel not tested)')
          .id('fwd/result').fontSize(11).fontFamily('monospace').width('100%')
      }.height(80).width('100%').border({ width: 1, color: '#DDDDDD' }).padding(8)
        .align(Alignment.TopStart)
      Text('Limits: one active connection at a time, no ACL, local forward only.')
        .fontSize(10).fontColor('#999999').width('100%')
    }
    .id('fwd/panel').width(680).padding(16).backgroundColor(Color.White).borderRadius(12)
    .shadow({ radius: 24, color: '#33000000', offsetY: 8 })
  }

  @Builder
  vncPanel() {
    Column({ space: 8 }) {
      Row() {
        Text('VNC (RFB 3.8)').fontSize(16).fontWeight(FontWeight.Bold)
        Blank()
        Button('Stop').id('vnc/stop').backgroundColor('#E6E6E6').fontColor('#1A1A1A')
          .onClick(() => { this.stopVnc(); })
        Button(this.t('common.close')).id('vnc/close').backgroundColor('#E6E6E6').fontColor('#1A1A1A')
          .onClick(() => { this.stopVnc(); this.vncOpen = false; })
      }.width('100%')
      Row({ space: 8 }) {
        Text(this.vncClip.length > 0 ? 'clip: ' + this.vncClip : 'clip: (empty)')
          .id('vnc/clip').fontSize(11).fontFamily('monospace').fontColor('#0A6C00').layoutWeight(1)
        Button(this.t('vnc.readClip')).id('vnc/clip-read').backgroundColor('#E6E6E6').fontColor('#1A1A1A')
          .fontSize(11).onClick(() => { this.refreshVncClip(); })
        Button(this.t('vnc.sendClip')).id('vnc/clip-send').backgroundColor('#1A6DD0').fontColor(Color.White)
          .fontSize(11).onClick(() => { this.sendClipToVnc(); })
      }.width('100%')
      Text(this.vncStatus.length > 0 ? this.vncStatus : 'vnc: (idle)')
        .id('vnc/status').fontSize(11).fontFamily('monospace').fontColor('#6A1B9A').width('100%')
      Canvas(this.vncCtx)
        .id('vnc/canvas')
        .width(this.vncCanvasW).height(this.vncCanvasH)
        .backgroundColor('#000000')
        .onReady(() => { this.vncReady = true; })
        .onTouch((event: TouchEvent) => {
          if (event.touches.length > 0) {
            const t = event.touches[0];
            const mask = event.type === TouchType.Down || event.type === TouchType.Move ? 1 : 0;
            this.sendVncPointer(t.x / 5, t.y / 5, mask);
          }
        })
      Row({ space: 8 }) {
        Text('canvas=' + this.vncCanvasW + 'x' + this.vncCanvasH)
        .id('vnc/canvas-size').fontSize(11).fontColor('#1A6DD0').width('100%')
      Text('drawn=' + this.vncDrawn + ' (fillRect grid)')
          .id('vnc/drawn').fontSize(11).fontColor('#0A6C00')
        Button('Send pointer (10,10)')
          .id('vnc/tap')
          .onClick(() => { this.sendVncPointer(10, 10, 1); this.sendVncPointer(10, 10, 0); })
        Button('Send key a')
          .id('vnc/key')
          .onClick(() => {
            if (this.vncId !== 0) {
              mottynapi.vncKey(this.vncId, 0x61, 1);
              mottynapi.vncKey(this.vncId, 0x61, 0);
            }
          })
      }.width('100%')

      Text(this.vncFrameInfo.length > 0 ? this.vncFrameInfo : 'frame: (none)')
        .id('vnc/frame').fontSize(11).fontFamily('monospace').width('100%')
    }
    .id('vnc/panel').width(700).padding(16).backgroundColor(Color.White).borderRadius(12)
    .shadow({ radius: 24, color: '#33000000', offsetY: 8 })
  }

  @Builder
  deleteHostConfirm() {
    Column({ space: 10 }) {
      Text('Delete host?').fontSize(16).fontWeight(FontWeight.Bold).width('100%')
      Text('This also removes its trusted host key and stored password.')
        .fontSize(12).fontColor('#666666').width('100%')
      Row({ space: 12 }) {
        Button('Cancel').id('hostdel/cancel').backgroundColor('#E6E6E6').fontColor('#1A1A1A')
          .onClick(() => { this.deleteDialog = false; this.deleteIndex = -1; })
        Button('Delete').id('hostdel/confirm').backgroundColor('#C62828').fontColor(Color.White)
          .onClick(() => { this.confirmDeleteHost(); })
      }.width('100%').justifyContent(FlexAlign.End)
    }
    .id('hostdel/dialog').width(480).padding(20).backgroundColor(Color.White).borderRadius(12)
    .shadow({ radius: 24, color: '#33000000', offsetY: 8 })
  }

  @Builder
  changedKeyWarning() {
    Column({ space: 10 }) {
      Text('HOST KEY HAS CHANGED').fontSize(16).fontWeight(FontWeight.Bold).fontColor('#C62828').width('100%')
      Text('This can mean the server was reinstalled — or that someone is intercepting the connection.')
        .fontSize(12).fontColor('#666666').width('100%')
      Text('old: ' + this.changedOld).id('hostkey/old').fontSize(11).fontFamily('monospace').width('100%')
      Text('new: ' + this.changedNew).id('hostkey/new').fontSize(11).fontFamily('monospace')
        .fontColor('#C62828').width('100%')
      Row({ space: 12 }) {
        Button('Cancel').id('hostkey/cancel-changed').backgroundColor('#E6E6E6').fontColor('#1A1A1A')
          .onClick(() => {
            this.changedDialog = false;
            // 同时写主机行状态：诊断面板没打开时 probeText 是看不见的
            this.setStatus(0, 'host key changed: refused (user did not accept)');
          })
        Button('Accept new key').id('hostkey/update').backgroundColor('#C62828').fontColor(Color.White)
          .onClick(() => { this.acceptChangedKey(0); })
      }.width('100%').justifyContent(FlexAlign.End)
    }
    .id('hostkey/changed').width(560).padding(20).backgroundColor(Color.White).borderRadius(12)
    .shadow({ radius: 24, color: '#33000000', offsetY: 8 })
  }

  @Builder
  knownPanel() {
    Column({ space: 8 }) {
      Row() {
        Text('Known hosts').fontSize(16).fontWeight(FontWeight.Bold)
        Blank()
        Button(this.t('common.close')).id('known/close').backgroundColor('#E6E6E6').fontColor('#1A1A1A')
          .onClick(() => { this.knownOpen = false; })
      }.width('100%')
      Text('trusted entries: ' + this.knownKeys.length)
        .id('known/count').fontSize(11).fontColor('#0A6C00').width('100%')
      Scroll() {
        Column({ space: 4 }) {
          ForEach(this.knownKeys, (key: string, idx: number) => {
            Row({ space: 8 }) {
              Column({ space: 2 }) {
                Text(key).fontSize(12).fontFamily('monospace').width('100%')
                Text(this.knownFps[idx]).fontSize(10).fontFamily('monospace').fontColor('#888888').width('100%')
              }.layoutWeight(1).alignItems(HorizontalAlign.Start)
              Button('Delete').id('known/del/' + key).backgroundColor('#C62828').fontColor(Color.White)
                .fontSize(12)
                .onClick(() => { this.deleteKnownHost(key); })
            }.width('100%').padding(6).backgroundColor('#FAFAFA').borderRadius(6)
          }, (key: string) => key)
          if (this.knownKeys.length === 0) {
            Text('(no trusted hosts)').id('known/empty').fontSize(12).fontColor('#999999').width('100%')
          }
        }.width('100%').alignItems(HorizontalAlign.Start)
      }.height(200).width('100%').border({ width: 1, color: '#DDDDDD' }).padding(8)
        .align(Alignment.TopStart)
      Text('Deleting an entry forces the trust prompt again on next connect.')
        .fontSize(10).fontColor('#999999').width('100%')
    }
    .id('known/panel').width(620).padding(16).backgroundColor(Color.White).borderRadius(12)
    .shadow({ radius: 24, color: '#33000000', offsetY: 8 })
  }

  @Builder
  diagPanel() {
    Column({ space: 10 }) {
      Row() {
        Text('Diagnostics').fontSize(16).fontWeight(FontWeight.Bold)
        Blank()
        Button(this.t('common.close')).id('diag/close').backgroundColor('#E6E6E6').fontColor('#1A1A1A')
          .onClick(() => { this.diagOpen = false; })
      }.width('100%')
      Text('These entries exist to exercise protocol paths that the product UI does not expose yet.')
        .fontSize(11).fontColor('#666666').width('100%')
      Row({ space: 8 }) {
        Button('TCP probe').id('net/probe').backgroundColor('#E6E6E6').fontColor('#1A1A1A')
          .onClick(() => { this.probeNet(); })
        Button('SSH probe').id('ssh/probe').backgroundColor('#E6E6E6').fontColor('#1A1A1A')
          .onClick(() => { this.probeSsh(); })
        Button('Hostkey check').id('ssh/hostkey-check').backgroundColor('#E6E6E6').fontColor('#1A1A1A')
          .onClick(() => { this.hostkeyCheck(); })
      }.width('100%')
      Row({ space: 8 }) {
        Button('term-echo').id('diag/term-echo').backgroundColor('#E6E6E6').fontColor('#1A1A1A')
          .onClick(() => { this.connectFixtureDemo('term-echo'); })
        Button('vt-demo').id('terminal/demo').backgroundColor('#E6E6E6').fontColor('#1A1A1A')
          .onClick(() => { this.connectFixtureDemo('demo'); })
        Button('vt-demo2').id('terminal/vt2').backgroundColor('#E6E6E6').fontColor('#1A1A1A')
          .onClick(() => { this.connectFixtureDemo('vt2'); })
        Button('vt').id('terminal/vt').backgroundColor('#E6E6E6').fontColor('#1A1A1A')
          .onClick(() => { this.connectFixtureDemo('vt'); })
        Button('pty shell').id('terminal/shell').backgroundColor('#0A6C00').fontColor(Color.White)
          .onClick(() => { this.connectFixtureDemo('shell'); })
        Button('VNC session').id('vnc/session').backgroundColor('#6A1B9A').fontColor(Color.White)
          .onClick(() => { this.diagOpen = false; this.startVnc('secret'); })
        Button('VNC bad pw').id('vnc/session-bad').backgroundColor('#C62828').fontColor(Color.White)
          .onClick(() => { this.diagOpen = false; this.startVnc('wrong-password'); })
        Button('RDP srv start').id('rdp/srv-start').backgroundColor('#0A6C00').fontColor(Color.White)
          .onClick(() => { this.startRdpServer(); })
        Button('RDP srv stop').id('rdp/srv-stop').backgroundColor('#C62828').fontColor(Color.White)
          .onClick(() => { this.stopRdpServer(); })
        Button('RDP srv status').id('rdp/srv-status').backgroundColor('#37474F').fontColor(Color.White)
          .onClick(() => { this.refreshRdpServer(); })
        Button('RDP local :13389').id('rdp/probe-local').backgroundColor('#1A6DD0').fontColor(Color.White)
          .onClick(() => { this.rdpProbe(13389); })
        Button('RDP :3390').id('rdp/probe-closed').backgroundColor('#37474F').fontColor(Color.White)
          .onClick(() => { this.rdpProbe(3390); })
        Button('RDP :2222').id('rdp/probe-ssh').backgroundColor('#37474F').fontColor(Color.White)
          .onClick(() => { this.rdpProbe(2222); })
      }.width('100%')
      Text(this.vncResult.length > 0 ? this.vncResult : 'vnc: (not probed)')
        .id('vnc/result').fontSize(11).fontFamily('monospace').fontColor('#6A1B9A').width('100%')
      Text(this.rdpSrvStatus.length > 0 ? this.rdpSrvStatus : 'rdp-server: (idle)')
        .id('rdp/srv-state').fontSize(11).fontFamily('monospace').fontColor('#0A6C00').width('100%')
      Text(this.rdpResult.length > 0 ? this.rdpResult : 'rdp: (not probed)')
        .id('rdp/result').fontSize(11).fontFamily('monospace').fontColor('#37474F').width('100%')
      Scroll() {
        Text(this.probeText).id('net/probe-result').fontSize(11).fontFamily('monospace').width('100%')
      }.height(120).width('100%').border({ width: 1, color: '#DDDDDD' }).padding(8)
    }
    .id('diag/panel').width(680).padding(16).backgroundColor(Color.White).borderRadius(12)
    .shadow({ radius: 24, color: '#33000000', offsetY: 8 })
  }

  @Builder
  tabBar() {
    Row({ space: 6 }) {
      Scroll() {
        Row({ space: 6 }) {
          ForEach(this.tabs, (t: TabInfo) => {
            Row({ space: 4 }) {
              Button(t.label)
                .id('session-tab/' + t.id)
                .backgroundColor(this.activeId === t.id ? '#1A6DD0' : '#E6E6E6')
                .fontColor(this.activeId === t.id ? Color.White : '#1A1A1A')
                .fontSize(12)
                .onClick(() => { this.selectTab(t.id); })
              Button('\u00d7')
                .id('session-close/' + t.id)
                .backgroundColor('#F0F0F0')
                .fontColor('#666666')
                .fontSize(12)
                .onClick(() => { this.closeTab(t.id); })
            }
          }, (t: TabInfo) => t.id)
        }
      }
      .scrollable(ScrollDirection.Horizontal)
      .layoutWeight(1)
      Text(this.tabs.length > 1 ? this.tabs.length + ' sessions' : '1 session')
        .id('session/count').fontSize(11).fontColor('#666666')
    }
    .id('session/tabbar').width('100%').padding({ left: 16, right: 16, top: 8, bottom: 8 })
    .backgroundColor('#EFEFEF')
  }

  @Builder
  terminalView() {
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        TextInput({ text: this.termInput, placeholder: 'type a line and press Send' })
          .id('terminal/input').layoutWeight(1).onChange((v: string) => { this.termInput = v; })
        Button('Send').id('terminal/send').onClick(() => { this.sendTermInput(); })
        Button('Resize').id('terminal/resize').backgroundColor('#E6E6E6').fontColor('#1A1A1A')
          .onClick(() => { this.resizeSession(); })
        Button('\u25b2').id('terminal/scroll-up').backgroundColor('#E6E6E6').fontColor('#1A1A1A')
          .onClick(() => { this.scrollView(5); })
        Button('\u25bc').id('terminal/scroll-down').backgroundColor('#E6E6E6').fontColor('#1A1A1A')
          .onClick(() => { this.scrollView(-5); })
        Button('Sel all').id('terminal/selall').backgroundColor('#E6E6E6').fontColor('#1A1A1A')
          .onClick(() => { this.selectAllVisible(); })
        Button('Copy').id('terminal/copy').backgroundColor('#1A6DD0').fontColor(Color.White)
          .onClick(() => { this.copySelection().catch((e: BusinessError) => { this.ptyStatus = 'copy error'; }); })
        Button('AI').id('ai/ask').backgroundColor('#6A1B9A').fontColor(Color.White)
          .onClick(() => { this.askAI().catch((e: BusinessError) => { this.aiAnswer = 'ai: error'; }); })
        Button('^C').id('terminal/ctrl-c').backgroundColor('#E6E6E6').fontColor('#1A1A1A')
          .onClick(() => { this.sendCtrlC(); })
        Button('\u2191').id('terminal/up').backgroundColor('#E6E6E6').fontColor('#1A1A1A')
          .onClick(() => { this.sendSpecial('up'); })
        Button('\u2193').id('terminal/down').backgroundColor('#E6E6E6').fontColor('#1A1A1A')
          .onClick(() => { this.sendSpecial('down'); })
        Button('\u2190').id('terminal/left').backgroundColor('#E6E6E6').fontColor('#1A1A1A')
          .onClick(() => { this.sendSpecial('left'); })
        Button('\u2192').id('terminal/right').backgroundColor('#E6E6E6').fontColor('#1A1A1A')
          .onClick(() => { this.sendSpecial('right'); })
      }.width('100%')
      Text(this.ptyStatus.length > 0 ? this.ptyStatus : 'pty: (idle)')
        .id('terminal/pty-status').fontSize(11).fontColor('#0A6C00').width('100%')
      Text(this.aiAnswer.length > 0 ? this.aiAnswer : 'ai: (idle)')
        .id('ai/answer').fontSize(11).fontFamily('monospace').fontColor('#6A1B9A').width('100%')
      Text('selected: ' + (this.selText.length > 0 ? this.selText.length + ' chars' : '(none)'))
        .id('terminal/sel').fontSize(11).fontColor('#999999').width('100%')
      Text('clipboard: ' + (this.clipText.length > 0 ? this.clipText.length + ' chars' : '(empty)'))
        .id('terminal/clip').fontSize(11).fontColor('#0A6C00').width('100%')
      Text('history tail: ' + (this.vtHistory.length > 0 ? this.vtHistory.replace(/\n/g, ' | ') : '(empty)'))
        .id('terminal/history').fontSize(11).fontColor('#999999').width('100%')
      Text(this.vtStatus.length > 0 ? this.vtStatus : 'vt: (idle)')
        .id('terminal/vt-status').fontSize(11).fontColor('#999999').width('100%')
      Scroll() {
        Text(this.termText.length > 0 ? this.termText : '(no output yet)')
          .id('terminal/output').fontSize(13).fontFamily('monospace').fontColor('#D4D4D4')
          .width('100%')
          .onTouch((event: TouchEvent) => { this.onTermTouch(event); })
      }
      .layoutWeight(1).width('100%').align(Alignment.TopStart)
      .border({ width: 1, color: '#333333' }).padding(8).backgroundColor('#1E1E1E')
    }
    .id('terminal/panel').layoutWeight(1).width('100%').padding(16)
  }

  @Builder
  hostListView() {
    Column() {
      Text(this.t('host.title')).id('host/title-text').fontSize(13).fontColor('#666666').width('100%')
        .padding({ left: 16, top: 10, bottom: 4 })
      TextInput({ text: this.hostQuery, placeholder: 'search label or address' })
        .id('hosts/search')
        .width('100%')
        .padding({ left: 16, right: 16 })
        .onChange((v: string) => { this.hostQuery = v; })
      List({ space: 8 }) {
        ForEach(this.hosts, (h: HostItem, index: number) => {
          ListItem() {
            if (this.matchesQuery(h)) {
            Column({ space: 4 }) {
              Row({ space: 12 }) {
                Column({ space: 4 }) {
                  Text(h.label).fontSize(16).fontWeight(FontWeight.Medium).width('100%')
                  Row({ space: 2 }) {
                    Text(h.address).fontSize(12).fontColor('#666666')
                    Text(':' + h.port).fontSize(12).fontColor('#999999')
                  }.width('100%')
                }.layoutWeight(1).alignItems(HorizontalAlign.Start)
                Button(this.t('host.test')).id('host-row/' + index).backgroundColor('#E6E6E6').fontColor('#1A1A1A')
                  .onClick(() => { this.connectRow(index); })
                Button(this.t('host.edit')).id('host-edit/' + index).backgroundColor('#E6E6E6').fontColor('#1A1A1A')
                  .onClick(() => { this.openEditHost(index); })
                Button(this.t('host.del')).id('host-del/' + index).backgroundColor('#C62828').fontColor(Color.White)
                  .onClick(() => { this.askDeleteHost(index); })
                Button(this.t('host.files')).id('host-files/' + index).backgroundColor('#E6E6E6').fontColor('#1A1A1A')
                  .onClick(() => { this.openFiles(index); })
                Button(this.t('host.open')).id('host-open/' + index).backgroundColor('#1A6DD0').fontColor(Color.White)
                  .onClick(() => { this.openSession(h.label, index); })
              }.width('100%')
              if (this.statuses.length > index && this.statuses[index].length > 0) {
                Text(this.statuses[index]).id('host-status/' + index).fontSize(11).fontColor('#0A6C00').width('100%')
              }
            }.width('100%').padding(12).backgroundColor(Color.White).borderRadius(8)
            }
          }
        }, (h: HostItem) => h.id + '|' + h.label + '|' + h.address + '|' + h.port)
      }
      .id('host-grid/list').layoutWeight(1).width('100%').padding({ left: 16, right: 16, bottom: 16 })

      if (this.hosts.length === 0) {
        Text(this.t('host.empty')).id('host-grid/empty').fontSize(13).fontColor('#999999')
          .width('100%').textAlign(TextAlign.Center).padding({ bottom: 24 })
      } else if (this.matchCount() === 0) {
        Text(this.t('host.noMatch')).id('hosts/no-match').fontSize(13).fontColor('#999999')
          .width('100%').textAlign(TextAlign.Center).padding({ bottom: 24 })
      }
    }
    .layoutWeight(1).width('100%')
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      Column() {
        Row({ space: 8 }) {
          Text('Motty').fontSize(20).fontWeight(FontWeight.Bold)
          Blank()
          if (this.tabs.length > 0) {
            Button('Hosts').id('nav/hosts').backgroundColor('#E6E6E6').fontColor('#1A1A1A')
              .onClick(() => { this.showHosts = true; })
          }
          Button(this.t('top.known')).id('known/open').backgroundColor('#E6E6E6').fontColor('#1A1A1A')
            .onClick(() => { this.openKnownHosts(); })
          Button(this.t('top.forward')).id('fwd/open').backgroundColor('#E6E6E6').fontColor('#1A1A1A')
            .onClick(() => { this.fwdOpen = true; this.reloadRules(); })
          Button(this.t('top.diag')).id('diag/open').backgroundColor('#E6E6E6').fontColor('#1A1A1A')
            .onClick(() => { this.diagOpen = true; })
          Button(this.t('top.lang')).id('ui/lang').backgroundColor('#455A64').fontColor(Color.White)
            .onClick(() => { this.toggleLang(); })
          Button(this.t('top.newHost')).id('shell/add-host')
            .onClick(() => { this.resetForm(); this.showDialog = true; })
        }
        .width('100%').padding({ left: 16, right: 16, top: 12, bottom: 12 }).backgroundColor('#F5F5F5')

        if (this.tabs.length > 0) {
          this.tabBar()
        }
        if (this.showHosts || this.tabs.length === 0) {
          this.hostListView()
        } else {
          this.terminalView()
        }
      }
      .width('100%').height('100%').backgroundColor('#FAFAFA')

      if (this.vncOpen) {
        Column().width('100%').height('100%').backgroundColor('#66000000').onClick(() => {})
        this.vncPanel()
      }
      if (this.deleteDialog) {
        Column().width('100%').height('100%').backgroundColor('#66000000').onClick(() => {})
        this.deleteHostConfirm()
      }
      if (this.changedDialog) {
        Column().width('100%').height('100%').backgroundColor('#66000000').onClick(() => {})
        this.changedKeyWarning()
      }
      if (this.knownOpen) {
        Column().width('100%').height('100%').backgroundColor('#66000000').onClick(() => {})
        this.knownPanel()
      }
      if (this.fwdOpen) {
        Column().width('100%').height('100%').backgroundColor('#66000000').onClick(() => {})
        this.forwardPanel()
      }
      if (this.filesOpen) {
        Column().width('100%').height('100%').backgroundColor('#66000000').onClick(() => {})
        this.filesPanel()
      }
      if (this.diagOpen) {
        Column().width('100%').height('100%').backgroundColor('#66000000').onClick(() => {})
        this.diagPanel()
      }
      if (this.keyDialog) {
        Column().width('100%').height('100%').backgroundColor('#66000000').onClick(() => {})
        this.keyConfirm()
      }
      if (this.showDialog) {
        Column().width('100%').height('100%').backgroundColor('#66000000').onClick(() => {})
        this.hostForm()
      }
    }
    .width('100%').height('100%')
  }
}
