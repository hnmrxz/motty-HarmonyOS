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
import { relationalStore, preferences } from '@kit.ArkData';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { http, socket } from '@kit.NetworkKit';
import { Strings } from '../common/strings';
import { BusinessError, pasteboard } from '@kit.BasicServicesKit';
import { asset } from '@kit.AssetStoreKit';
import { util } from '@kit.ArkTS';
import mottynapi from 'libmottynapi.so';
import { picker, fileIo } from '@kit.CoreFileKit';

const FRAME_W: number = 1024;
const FRAME_H: number = 768;
const DOMAIN: number = 0x0000;
const TAG: string = 'MOTTY';

const STORE_CONFIG: relationalStore.StoreConfig = {
  name: 'motty.db',
  securityLevel: relationalStore.SecurityLevel.S1
};

const SQL_CREATE_HOSTS =
  'CREATE TABLE IF NOT EXISTS hosts (' +
  'id TEXT PRIMARY KEY, label TEXT NOT NULL, address TEXT NOT NULL, usr TEXT, port TEXT, proto TEXT, ' +
  'grp TEXT, tags TEXT, color TEXT, icon TEXT)';

const SQL_CREATE_KNOWN_HOSTS =
  'CREATE TABLE IF NOT EXISTS known_hosts (host TEXT PRIMARY KEY, fingerprint TEXT NOT NULL, updated_at INTEGER)';

const SQL_CREATE_UI_STATE =
  'CREATE TABLE IF NOT EXISTS ui_state (k TEXT PRIMARY KEY, v TEXT)';
const HOST_COLUMNS: string[] = ['id', 'label', 'address', 'usr', 'port', 'proto', 'grp', 'tags', 'color', 'icon'];

// 会话日志（官方 NavSessionLogs 的最小实现）
const SQL_CREATE_NOTES =
  'CREATE TABLE IF NOT EXISTS notes (' +
  'id TEXT PRIMARY KEY, title TEXT, body TEXT, updated_at INTEGER)';
const NOTE_COLUMNS: string[] = ['id', 'title', 'body', 'updated_at'];

const SQL_CREATE_SNIPPETS =
  'CREATE TABLE IF NOT EXISTS snippets (' +
  'id TEXT PRIMARY KEY, name TEXT, cmd TEXT, grp TEXT, sort INTEGER)';
const SNIPPET_COLUMNS: string[] = ['id', 'name', 'cmd', 'grp', 'sort'];

const SQL_CREATE_LOGS =
  'CREATE TABLE IF NOT EXISTS session_logs (' +
  'id TEXT PRIMARY KEY, label TEXT, address TEXT, proto TEXT, started_at INTEGER)';
const LOG_COLUMNS: string[] = ['id', 'label', 'address', 'proto', 'started_at'];

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
  // 以下三项照抄原版 Host 结构（internal/workbench/host_catalog.go）
  group: string;   // 分组名，空 = 默认组
  tags: string;    // 逗号分隔，原版预设：开发/测试/生产
  color: string;   // #RRGGBB 连接色，空 = 无
  icon: string;    // 图标名（'', star, server, cloud, box, bolt）
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

interface CatalogHost {
  id: string;
  label: string;
  group: string;
  tags: string[];
  color: string;
  address: string;
  user: string;
  port: number;
}

interface CatalogGroup {
  name: string;
  collapsed: boolean;
}

interface CatalogDoc {
  format: string;
  version: number;
  hosts: CatalogHost[];
  groups: CatalogGroup[];
}

interface LogItem {
  id: string;
  label: string;
  address: string;
  proto: string;
  startedAt: number;
}

interface NoteItem {
  id: string;
  title: string;
  body: string;
  updatedAt: number;
}

interface SnippetItem {
  id: string;
  name: string;
  cmd: string;
  group: string;
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
  // seed* 只在对话框创建时提供初值，之后不再变化：避免 text: 绑定在重渲染时把用户输入回灌覆盖
  @State formError: string = '';
  @State seedLabel: string = '';
  @State seedAddress: string = '';
  @State seedUser: string = '';
  @State seedPort: string = '';
  @State seedPassword: string = '';
  @State seedGroup: string = '';
  @State seedTags: string = '';
  @State seedColor: string = '';
  @State formAddress: string = '';
  @State formUser: string = '';
  @State formPort: string = '';
  @State formPassword: string = '';
  @State formProto: string = 'ssh';
  @State formGroup: string = '';
  @State formTags: string = '';
  @State formColor: string = '';
  @State formIcon: string = '';
  private lastUsedMap: Map<string, number> = new Map<string, number>();
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
  @State lang: string = 'zh';
  @State pcNav: string = '主机';
  @State collapsedGroups: string[] = [];
  @State groupFilter: string = '';
  @State protoFilter: string = '';
  @State pinnedGroups: string[] = [];
  @State groupMenu: string = '';
  @State groupMenuTarget: string = '';
  @State groupOrder: string[] = [];
  @State groupRenameOpen: boolean = false;
  @State groupRenameOld: string = '';
  @State groupRenameText: string = '';
  @State groupRenameError: string = '';
  @State groupDelName: string = '';
  @State knownDelKey: string = '';
  @State vaultDelKey: string = '';
  @State vaultAddOpen: boolean = false;
  @State vaultAddr: string = '';
  @State vaultPort: string = '';
  @State vaultUser: string = '';
  @State vaultPw: string = '';
  @State vaultSeq: number = 0;
  @State vaultResult: string = '';
  @State knownResult: string = '';
  @State tabNumbers: boolean = false;
  @State tabSide: boolean = false;
  @State termScrollback: number = 3;
  @State showLastUsed: boolean = true;
  @State showTabCount: boolean = true;
  @State startupView: string = 'hosts';
  @State settingsReset: string = '';
  @State toolbarHint: string = '';
  @State toolbarHintTimer: number = -1;
  @State uiScaleKey: string = 'regular';
  @State viewMenuOpen: boolean = false;
  @State themeMode: string = 'dark';
  @State aiOpen: boolean = false;
  @State tabRenameOpen: boolean = false;
  @State tabRenameId: string = '';
  @State tabRenameText: string = '';
  @State hoverRow: number = -1;
  @State selectAll: boolean = false;
  @State selectedIds: string[] = [];
  @State catalogResult: string = '(catalog: idle)';
  @State settingsOpen: boolean = false;
  @State termFontSize: number = 13;
  @State logs: LogItem[] = [];
  @State logsQuery: string = '';
  @State logsProto: string = '';
  @State logsHost: string = '';
  @State notesQuery: string = '';
  @State snippetsQuery: string = '';
  @State knownQuery: string = '';
  @State logsExport: string = '';
  @State snippets: SnippetItem[] = [];
  @State notes: NoteItem[] = [];
  @State noteDialog: boolean = false;
  @State noteTitle: string = '';
  @State noteBody: string = '';
  @State noteEditingId: string = '';
  @State snippetDialog: boolean = false;
  @State paletteOpen: boolean = false;
  @State paletteQuery: string = '';
  @State paletteIndex: number = 0;
  @State paletteHover: number = -1;
  @State hostDetailIndex: number = -1;
  @State hostMenuIndex: number = -1;
  @State hoverHost: number = -1;
  @State snipName: string = '';
  @State snipCmd: string = '';
  @State snipEditingId: string = '';
  private prefs: preferences.Preferences | null = null;
  @State hostView: string = 'list';
  @State hostSort: string = 'manual';
  @State aiAnswer: string = '';
  @State aiEndpoint: string = 'http://127.0.0.1:2297/v1/ai';
  @State rdpSrvStatus: string = '';
  @State rdpSrvPort: number = 13389;
  @State rdpTargetHost: string = '127.0.0.1';
  @State rdpTargetPort: string = '13389';
  @State rdpTargetUser: string = 'tester';
  @State rdpTargetPass: string = 'secret';
  @State rdpUseNla: boolean = false;
  private rdpTickId: number = -1;
  @State rdpTickCount: number = 0;
  @State rdpTickDrawn: number = -1;
  @State rdpSnapDrawn: number = 0;
  @State rdpSnapColors: number = 0;
  @State rdpSnapInfo: string = 'rdp-canvas: (empty)';
  @State rdpFrameSrc: string = '';
  @State rdpFrameInfo: string = '';
  @State diagTab: string = 'rdp';
  private rdpProbeToken: number = 0;
  @State rdpFrameWrites: number = 0;
  @State rdpPreviewOn: boolean = false;
  @State rdpSessionOpen: boolean = false;
  @State rdpSessionTitle: string = '';
  @State rdpSessionStatus: string = 'idle';
  @State rdpSessionFrame: string = '';
  @State rdpSessionHostAddr: string = '';
  @State rdpSessionHostPort: number = 3389;
  @State rdpSessionUser: string = '';
  @State rdpSessionPass: string = '';
  @State rdpFrameSkips: number = 0;
  private rdpFrameLastSeq: number = -1;
  private rdpPreviewTimer: number = -1;
  private rdpCanvasCtx: CanvasRenderingContext2D = new CanvasRenderingContext2D(new RenderingContextSettings(true));  // 3389 是特权端口，应用绑不上
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
  // 默认留空：预填会导致输入的文本被**追加**在旧名字后面（实测 'uploaded.txt中文文件.txt'）
  @State sftpUploadName: string = '';
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
  @State editingRuleId: string = '';
  @State editingId: string = '';      // 非空 = 编辑模式
  @State deleteDialog: boolean = false;
  @State deleteIndex: number = -1;
  @State deleteIds: string[] = [];
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
    await this.store.executeSql(SQL_CREATE_UI_STATE);
      await this.store.executeSql(SQL_CREATE_KNOWN_HOSTS);
      await this.store.executeSql(SQL_CREATE_FORWARDS);
      await this.store.executeSql(SQL_CREATE_LOGS);
      await this.store.executeSql(SQL_CREATE_SNIPPETS);
      await this.store.executeSql(SQL_CREATE_NOTES);
      await this.migrateHosts();
      await this.reload();
      await this.reloadRules();
      await this.loadPrefs();
      await this.loadGroupOrderFromDb();
    this.applyStartupView();
    hilog.info(DOMAIN, TAG, 'store ready, hosts=%{public}d', this.hosts.length);
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'store init failed: %{public}s', JSON.stringify(e));
    }
  }

  private async migrateHosts(): Promise<void> {
    if (this.store === null) { return; }
    const stmts: string[] = [
      'ALTER TABLE hosts ADD COLUMN grp TEXT',
      'ALTER TABLE hosts ADD COLUMN tags TEXT',
      'ALTER TABLE hosts ADD COLUMN color TEXT',
      'ALTER TABLE hosts ADD COLUMN icon TEXT'
    ];
    for (let i = 0; i < stmts.length; i++) {
      try { await this.store.executeSql(stmts[i]); } catch (e) { /* 已存在 */ }
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
        proto: rs.getString(5),
        group: rs.getString(6),
        tags: rs.getString(7),
        color: rs.getString(8),
      icon: rs.getString(9)
      });
    }
    rs.close();
    this.hosts = out;
    // 最近连接：session_logs 里每个 (address|proto) 的最新时间（只用于列表展示）
    try {
      this.lastUsedMap.clear();
      const lp = new relationalStore.RdbPredicates('session_logs');
      lp.orderByDesc('started_at');
      const lrs = await this.store.query(lp, ['address', 'proto', 'started_at']);
      while (lrs.goToNextRow()) {
        const k: string = lrs.getString(0) + '|' + lrs.getString(1);
        if (!this.lastUsedMap.has(k)) {
          this.lastUsedMap.set(k, lrs.getLong(2));
        }
      }
      lrs.close();
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'lastUsed query failed: %{public}s', JSON.stringify(e));
    }
    hilog.info(DOMAIN, TAG, 'reload count=%{public}d first=%{public}s', out.length, out.length > 0 ? out[0].label : '<none>');
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
    this.formError = '';
    this.seedLabel = '';
    this.seedAddress = '';
    this.seedUser = '';
    this.seedPort = '';
    this.seedPassword = '';
    this.seedGroup = '';
    this.seedTags = '';
    this.seedColor = '';
    this.formLabel = '';
    this.formAddress = '';
    this.formUser = '';
    this.formPort = '';
    this.formPassword = '';
    this.formProto = 'ssh';
    this.formGroup = '';
    this.formTags = '';
    this.formColor = '';
    this.formIcon = '';
  }

  private openEditHost(index: number): void {
    const h = this.hosts[index];
    if (h === undefined) {
      return;
    }
    this.editingId = h.id;
    this.seedLabel = h.label;
    this.seedAddress = h.address;
    this.seedUser = h.user;
    this.seedPort = h.port;
    this.seedPassword = '';
    this.seedGroup = h.group;
    this.seedTags = h.tags;
    this.seedColor = h.color;
    this.formLabel = h.label;
    this.formAddress = h.address;
    this.formUser = h.user;
    this.formPort = h.port;
    this.formPassword = '';
    this.formProto = h.proto.length > 0 ? h.proto : 'ssh';
    this.formGroup = h.group;
    this.formTags = h.tags;
    this.formColor = h.color;
    this.formIcon = h.icon;
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
    // 批量删除分支：先清所选，再复用逐台删除的语义（hosts + known_hosts + 保险库）
    if (this.deleteIds.length > 0) {
      const ids: string[] = this.deleteIds.slice();
      this.deleteIds = [];
      this.deleteDialog = false;
      if (this.store !== null) {
        for (let i = 0; i < ids.length; i++) {
          const idx2 = this.hosts.findIndex((x: HostItem) => x.id === ids[i]);
          if (idx2 < 0) { continue; }
          const h = this.hosts[idx2];
          const key = this.hostKey(h.address, h.port);
          const hp = new relationalStore.RdbPredicates('hosts');
          hp.equalTo('id', h.id);
          await this.store.delete(hp);
          const kp = new relationalStore.RdbPredicates('known_hosts');
          kp.equalTo('host', key);
          await this.store.delete(kp);
          await Vault.remove(key);
          this.creds.delete(key);
        }
      }
      this.selectedIds = [];
      await this.settleStore();
      await this.reload();
      await this.reloadRules();
      return;
    }
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
    await this.migrateHosts();
    await this.reload();
    await this.reloadRules();
  }

  private async submit(): Promise<void> {
    const label = this.formLabel.trim();
    const address = this.formAddress.trim();
    if (label.length === 0 || address.length === 0 || this.store === null) {
      return;
    }
    const defaultPort: string = this.formProto === 'rdp' ? '3389' : (this.formProto === 'vnc' ? '5900' : '22');
    const port = this.formPort.trim().length > 0 ? this.formPort.trim() : defaultPort;
    this.formError = '';
    // 官方校验：颜色必须是 #RRGGBB 或留空（ErrHostColorInvalid）
    const color: string = this.formColor.trim();
    if (color.length > 0 && !/^#[0-9A-Fa-f]{6}$/.test(color)) {
      this.formError = '请输入 #3B82F6 这样的颜色值，或留空使用默认颜色';
      return;
    }
    // 官方校验：最多 12 个标签，每个不超过 32 个字符，且不含换行（ErrHostTagsInvalid）
    const tagsRaw: string = this.formTags.trim();
    if (tagsRaw.length > 0) {
      const parts: string[] = tagsRaw.split(',');
      if (parts.length > 12) {
        this.formError = '最多 12 个标签，每个不超过 32 个字符，且不包含逗号或换行';
        return;
      }
      for (let ti = 0; ti < parts.length; ti++) {
        const one: string = parts[ti].trim();
        if (one.length > 32 || one.indexOf('\n') >= 0) {
          this.formError = '最多 12 个标签，每个不超过 32 个字符，且不包含逗号或换行';
          return;
        }
      }
    }
    if (this.editingId.length > 0) {
      // 编辑：更新既有行（id 不变，避免规则/引用失联）
      const pred = new relationalStore.RdbPredicates('hosts');
      pred.equalTo('id', this.editingId);
      const patch: relationalStore.ValuesBucket = {
        'label': label, 'address': address, 'usr': this.formUser.trim(), 'port': port,
        'grp': this.formGroup.trim(), 'tags': this.formTags.trim(), 'color': this.formColor.trim(),
        'icon': this.formIcon
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
      await this.settleStore();
      await this.reload();
      this.showDialog = false;
      this.resetForm();
      hilog.info(DOMAIN, TAG, 'host updated submit-label=%{public}s', label);
      return;
    }
    const bucket: relationalStore.ValuesBucket = {
      'id': String(Date.now()),
      'label': label,
      'address': address,
      'usr': this.formUser.trim(),
      'port': port,
      'proto': this.formProto,
      'grp': this.formGroup.trim(),
      'tags': this.formTags.trim(),
      'color': this.formColor.trim(),
        'icon': this.formIcon
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
      await this.settleStore();
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
    // RDP 主机走会话视图（不建立 SSH 会话）
    if (h.proto === 'rdp') {
      this.openRdpSession(h);
      return;
    }
    // VNC 主机走 VNC 会话视图（地址/端口取自主机记录）
    if (h.proto === 'vnc') {
      const vkey: string = this.hostKey(h.address, h.port);
      const vcred = this.creds.get(vkey);
      const vpass: string = vcred !== undefined ? vcred.password : '';
      const vport: number = Number.parseInt(h.port, 10) || 5900;
      this.stopRdpPreview();
      this.startVnc(vpass, h.address, vport);
      return;
    }
    this.recordSession(h);
    const key = this.hostKey(h.address, h.port);
    const cred = this.creds.get(key);
    if (cred === undefined) {
      this.setStatus(index, 'no credentials in memory (add a password in host settings)');
      return;
    }
    this.pendingLabel = label;
    this.lookupFp(key).then((fp: string) => {
      if (fp.length > 0) {
        // 已有指纹也必须校验：主机密钥变更时不能静默连接（安全问题）
        mottynapi.probe(cred.address, cred.port, cred.user, cred.password, 'echo no-auth-yet', fp,
          (result: string) => {
            if (result.indexOf('hostkey-mismatch') === 0) {
              const m = new RegExp('actual=(SHA256:[A-Za-z0-9+/]+)').exec(result);
              this.changedOld = fp;
              this.changedNew = m !== null ? m[1] : 'unknown';
              this.changedDialog = true;
              return;
            }
            this.startSession(cred, fp, h.label);
          });
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
    this.vtHistory = mottynapi.vtScrollBack(vtId, this.termScrollback);
  }


  // 工具栏"新会话"：用当前会话对应的主机再开一个（无凭据则提示）
  private openNewSessionFromToolbar(): void {
    if (this.tabs.length === 0) {
      this.setToolbarHint('no session; open a host first');
      return;
    }
    const label: string = this.tabs[0].label;
    for (let i = 0; i < this.hosts.length; i++) {
      if (this.hosts[i].label === label) {
        this.openSession(this.hosts[i].label, i);
        return;
      }
    }
    this.setToolbarHint('session ' + label + ' has no saved host');
  }


  // 顶栏提示：4 秒后自动消失（避免操作反馈长期挂在标题栏），点击可立即关闭
  private hint(msg: string): void {
    this.hint(msg);
    if (this.toolbarHintTimer !== -1) { clearTimeout(this.toolbarHintTimer); }
    this.toolbarHintTimer = setTimeout(() => {
      this.hint('');
      this.toolbarHintTimer = -1;
    }, 4000);
  }

  private dismissHint(): void {
    if (this.toolbarHintTimer !== -1) { clearTimeout(this.toolbarHintTimer); this.toolbarHintTimer = -1; }
    this.hint('');
  }

  private setToolbarHint(msg: string): void {
    this.hint(msg);
  }

  // 复制主机地址到剪贴板（交互对齐：主机行的"复制地址"）
  private copyHostAddress(h: HostItem): void {
    const text: string = h.address + (h.port.length > 0 ? ':' + h.port : '');
    try {
      pasteboard.getSystemPasteboard().setData(pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text))
        .then(() => { this.hint((this.lang === 'zh' ? '已复制 ' : 'copied ') + text); })
        .catch(() => { this.hint(this.lang === 'zh' ? '复制失败' : 'copy failed'); });
    } catch (e) {
      this.hint(this.lang === 'zh' ? '复制异常' : 'copy threw');
    }
  }

  // 顶栏""粘贴""：把剪贴板文本放进终端输入框（不自动发送）
  private pasteIntoInput(): void {
    try {
      pasteboard.getSystemPasteboard().getData()
        .then((data: pasteboard.PasteData) => {
          const text: string = data.getPrimaryText();
          this.termInput = this.termInput + (text ?? '');
          this.hint((this.lang === 'zh' ? '已粘贴 ' : 'pasted ') + String((text ?? '').length) + (this.lang === 'zh' ? ' 个字符' : ' chars'));
        })
        .catch(() => { this.hint(this.lang === 'zh' ? '粘贴失败' : 'paste failed'); });
    } catch (e) {
      this.hint(this.lang === 'zh' ? '粘贴异常' : 'paste threw');
    }
  }

  private startSession(cred: Cred, fp: string, label: string): void {
    this.diagOpen = false; this.stopRdpPreview();
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


  private submitTabRename(): void {
    const next: string = this.tabRenameText.trim();
    if (next.length === 0 || this.tabRenameId.length === 0) { this.tabRenameOpen = false; return; }
    const out: TabInfo[] = [];
    for (let i = 0; i < this.tabs.length; i++) {
      const t: TabInfo = this.tabs[i];
      out.push(t.id === this.tabRenameId
        ? { id: t.id, label: next, shellId: t.shellId, vtId: t.vtId } as TabInfo
        : t);
    }
    this.tabs = out;
    this.tabRenameOpen = false;
    this.tabRenameId = '';
    this.tabRenameText = '';
  }


  // 关闭除指定标签外的其它标签
  private closeOtherTabs(keepId: string): void {
    const keep: TabInfo[] = [];
    for (let i = 0; i < this.tabs.length; i++) {
      const t: TabInfo = this.tabs[i];
      if (t.id === keepId) { keep.push(t); continue; }
      mottynapi.closeShell(t.shellId);
      mottynapi.vtFree(t.vtId);
    }
    this.tabs = keep;
    if (keep.length > 0) { this.activeId = keep[0].id; }
  }

  private closeAllTabs(): void {
    for (let i = 0; i < this.tabs.length; i++) {
      mottynapi.closeShell(this.tabs[i].shellId);
      mottynapi.vtFree(this.tabs[i].vtId);
    }
    this.tabs = [];
    if (this.activeId.length > 0) { this.activeId = ''; }
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
  // 把 C++ 侧 64x48 采样画到 Canvas（每像素一个 fillRect，共 3072 次）

  private drawRdpSnapshot(): void {
    this.rdpSnapInfo = 'rdp-canvas: start';
    let px: Uint8Array;
    try {
      px = mottynapi.rdpSnapshot() as Uint8Array;
    } catch (e) {
      this.rdpSnapInfo = 'rdp-canvas: rdpSnapshot() threw: ' + JSON.stringify(e);
      hilog.error(DOMAIN, TAG, 'rdpSnapshot threw: %{public}s', JSON.stringify(e));
      return;
    }
    if (px === undefined || px === null || px.length === 0) {
      this.rdpSnapInfo = 'rdp-canvas: rdpSnapshot() empty';
      return;
    }
    const w = 64;
    const h = 48;
    let drawn = 0;
    const seen: Set<number> = new Set<number>();
    for (let y = 0; y < h; y++) {
      for (let x = 0; x < w; x++) {
        const off = (y * w + x) * 4;
        const b = px[off + 0];
        const g = px[off + 1];
        const r = px[off + 2];
        seen.add((r << 16) | (g << 8) | b);
        drawn++;
      }
    }
    // 统计先算、先写：之前把统计放在绘制之后，Canvas 没就绪时会抛异常，
    // 结果完全看不到像素证据（rdp/canvas-info 为空）。
    this.rdpSnapDrawn = drawn;
    this.rdpSnapColors = seen.size;
    this.rdpSnapInfo = 'rdp-canvas: drawn=' + drawn + ' colors=' + this.rdpSnapColors +
      ' | cpp ' + (mottynapi.rdpSnapStats() as string);
    try {
      for (let y = 0; y < h; y++) {
        for (let x = 0; x < w; x++) {
          const off = (y * w + x) * 4;
          this.rdpCanvasCtx.fillStyle = 'rgb(' + px[off + 2] + ',' + px[off + 1] + ',' + px[off + 0] + ')';
          this.rdpCanvasCtx.fillRect(x * 8, y * 8, 8, 8);
        }
      }
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'drawRdpSnapshot canvas failed: %{public}s', JSON.stringify(e));
    }
  }

  // 输入回传探测：连接后发键鼠，看服务端收到多少
  private probeRdpInput(): void {
    this.rdpResult = 'rdp-input: connecting...';
    mottynapi.rdpInputProbe('127.0.0.1', this.rdpSrvPort, 'tester', 'secret', (result: string) => {
      this.rdpResult = 'rdp-input: ' + result;
    });
  }

  // 客户端渲染管线（最小）：连接后泵事件，把收到的位图更新统计回来
  private startRdpRender(): void {
    this.rdpResult = 'rdp-render: connecting ' + this.rdpTargetHost + ':' + this.rdpTargetPort + '...';
    let port: number = Number.parseInt(this.rdpTargetPort, 10);
    if (Number.isNaN(port) || port <= 0) {
      port = this.rdpSrvPort;
    }
    mottynapi.rdpRender(this.rdpTargetHost, port, this.rdpTargetUser, this.rdpTargetPass,
      (result: string) => {
        this.rdpResult = 'rdp-render: ' + result;
        this.drawRdpSnapshot();
        // 画布统计在面板下方、常被窗口裁掉，把关键像素证据拼进可见的 result 行
        this.rdpResult = this.rdpResult + ' | snap colors=' + this.rdpSnapColors +
          ' drawn=' + this.rdpSnapDrawn + ' | ' + (mottynapi.rdpSnapStats() as string);
      }, this.rdpUseNla);
  }

  private startRdpServer(): void {
    // OHOS 没有 XDG 配置目录：shadow_server_init 需要一个可写目录来放自签证书
    const ctx = getContext(this) as common.UIAbilityContext;
    const dir: string = ctx !== undefined && ctx.cacheDir !== undefined ? ctx.cacheDir : '/data/storage/el2/base/cache';
    const rc: number = mottynapi.rdpServerStart(this.rdpSrvPort, 'tester', 'secret', dir);
    this.rdpSrvStatus = 'rdp-server: start rc=' + rc + ' ' + mottynapi.rdpServerStatus();
    if (rc === 0 && this.rdpTickId === -1) {
      // 用 JS 定时器驱动出帧（不走 std::thread：实测在 shadow 上下文线程不被调度）
      // 先同步调用一次：若这次也没出帧，说明是 NAPI 函数本身有问题，而不是定时器。
      const d0: number = mottynapi.rdpServerTick();
      this.rdpTickDrawn = d0;
      this.rdpTickCount = 1;
      this.rdpTickId = setInterval(() => {
        this.rdpTickDrawn = mottynapi.rdpServerTick();
        this.rdpTickCount = this.rdpTickCount + 1;
        // 每 5 个 tick 刷新一次状态串（避免读到的永远是启动瞬间的快照）
        if (this.rdpTickCount % 5 === 0) {
          this.rdpSrvStatus = 'rdp-server: ' + mottynapi.rdpServerStatus();
        }
      }, 200);
    }
  }

  private stopRdpServer(): void {
    if (this.rdpTickId !== -1) {
      clearInterval(this.rdpTickId);
      this.rdpTickId = -1;
    }
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
    this.diagOpen = false; this.stopRdpPreview();
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
      this.setStatus(index, 'no credentials in memory (add a password in host settings)');
      return;
    }
    this.lookupFp(key).then((fp: string) => {
      hilog.info(DOMAIN, TAG, 'openFiles fp=%{public}d key=%{public}s', fp.length, key);
      if (fp.length > 0) {
        this.startFiles(cred, fp);
        return;
      }
      mottynapi.probe(cred.address, cred.port, cred.user, cred.password, 'echo no-auth-yet', '',
        (first: string) => {
          hilog.info(DOMAIN, TAG, 'openFiles probe=%{public}s', first.substring(0, 80));
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
    if (this.sftpUploadName.trim().length === 0) {
      this.sftpUploadName = 'uploaded.txt';
    }
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
      // 追加而不是重置：重置会把刚才的 'stopped' 抹掉，导致"停止后又启动"这段历史读不到
      this.fwdEvents = this.fwdEvents.length > 0 ? (this.fwdEvents + '\nstarting...') : 'starting...';
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
      // 明确回报"已停止"：否则界面上分不清"停了"和"根本没起来"
      this.fwdEvents = this.fwdEvents + '\nstopped';
    } else {
      this.fwdEvents = this.fwdEvents + '\nstop: no active forward';
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
  private startVnc(pwd: string, host: string = '127.0.0.1', port: number = 5901): void {
    this.vncOpen = true;
    this.vncReady = false;
    this.vncStatus = 'connecting...';
    this.vncFrameInfo = '';
    this.vncDrawn = 0;
    try {
      this.vncId = mottynapi.vncStart(host, port, pwd,
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
  private rdpProbe(port: number, user: string = 'administrator', password: string = 'wrong-password'): void {
    const probing: string = 'rdp: probing 127.0.0.1:' + port + ' ...';
    this.rdpResult = probing;
    // 对"端口开放但不是 RDP"的对端（例如 SSH 夹具），握手会一直等、回调不返回。
    // FreeRDP 的这个构建没有可用的连接超时设置，所以在 UI 层加一个守卫：8 秒没结果就明确说明。
    const token: number = Date.now();
    this.rdpProbeToken = token;
    setTimeout(() => {
      if (this.rdpProbeToken === token && this.rdpResult === probing) {
        this.rdpResult = 'rdp: probe timeout (no RDP response within 8s) on 127.0.0.1:' + port;
        this.probeText = this.rdpResult;
      }
    }, 8000);
    mottynapi.rdpProbe('127.0.0.1', port, user, password,
      (result: string) => {
        if (this.rdpProbeToken !== token) { return; }
        this.rdpProbeToken = 0;
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


  // 已知主机导出（JSON）：备份/迁移指纹
  private exportKnownHosts(): void {
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      const path: string = ctx.cacheDir + '/motty-known-hosts.json';
      const rows: string[] = [];
      for (let i = 0; i < this.knownKeys.length; i++) {
        rows.push('{"host":"' + this.knownKeys[i].replace(/"/g, '\\"') +
          '","fingerprint":"' + (this.knownFps[i] ?? '') + '"}');
      }
      const text: string = '{"format":"motty-known-hosts","version":1,"count":' + this.knownKeys.length +
        ',"hosts":[' + rows.join(',') + ']}';
      const f = fileIo.openSync(path, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(f.fd, text);
      fileIo.closeSync(f);
      const stat = fileIo.statSync(path);
      this.knownResult = 'known-export: ' + path + ' (' + stat.size + ' bytes, ' + this.knownKeys.length + ' hosts)';
    } catch (e) {
      this.knownResult = 'known-export failed: ' + JSON.stringify(e);
    }
  }

  // 已知主机导入（upsert）
  private async importKnownHosts(): Promise<void> {
    if (this.store === null) { return; }
    const store = this.store;
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      const path: string = ctx.cacheDir + '/motty-known-hosts.json';
      const f = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
      const stat = fileIo.statSync(f.fd);
      const buf = new ArrayBuffer(stat.size);
      fileIo.readSync(f.fd, buf);
      fileIo.closeSync(f);
      const text: string = util.TextDecoder.create('utf-8').decodeToString(new Uint8Array(buf));
      const doc: Record<string, Object> = JSON.parse(text) as Record<string, Object>;
      if (String(doc['format'] ?? '') !== 'motty-known-hosts') {
        this.knownResult = 'known-import: wrong format';
        return;
      }
      const hosts = doc['hosts'] as Array<Object>;
      let n: number = 0;
      for (let i = 0; i < hosts.length; i++) {
        const row: Record<string, Object> = hosts[i] as Record<string, Object>;
        const k: string = String(row['host'] ?? '');
        const fp: string = String(row['fingerprint'] ?? '');
        if (k.length === 0) { continue; }
        const pred = new relationalStore.RdbPredicates('known_hosts');
        pred.equalTo('host', k);
        await store.delete(pred);
        await store.insert('known_hosts', { 'host': k, 'fingerprint': fp, 'updated_at': Date.now() } as relationalStore.ValuesBucket);
        n = n + 1;
      }
      await this.refreshKnownHosts();
      this.knownResult = 'known-import: ' + n + ' hosts';
    } catch (e) {
      this.knownResult = 'known-import failed: ' + JSON.stringify(e);
    }
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

  private async clearKnownHosts(): Promise<void> {
    if (this.store === null) { return; }
    try {
      const pred = new relationalStore.RdbPredicates('known_hosts');
      await this.store.delete(pred);
      await this.refreshKnownHosts();
      hilog.info(DOMAIN, TAG, 'known hosts cleared');
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'clearKnownHosts failed: %{public}s', JSON.stringify(e));
    }
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
    if (this.editingRuleId.length > 0) {
      const predU = new relationalStore.RdbPredicates('forwards');
      predU.equalTo('id', this.editingRuleId);
      await this.store.update({
        'mode': this.fwdMode,
        'listen_port': this.fwdListen,
        'target_host': this.fwdTargetHost,
        'target_port': this.fwdTargetPort
      } as relationalStore.ValuesBucket, predU);
      this.editingRuleId = '';
      this.fwdResult = 'rule updated';
      await this.reloadRules();
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



  // 编辑已保存规则：把值填回状态，保存时走 update（不再新增一条）
  private editRule(id: string, mode: string, rest: string): void {
    const arrow: number = rest.indexOf('->');
    const listen: string = arrow > 0 ? rest.substring(0, arrow) : this.fwdListen;
    const target: string = arrow > 0 ? rest.substring(arrow + 2) : '';
    const colon: number = target.lastIndexOf(':');
    this.editingRuleId = id;
    this.fwdMode = mode.length > 0 ? mode : 'local';
    this.fwdListen = listen;
    this.fwdTargetHost = colon > 0 ? target.substring(0, colon) : this.fwdTargetHost;
    this.fwdTargetPort = colon > 0 ? target.substring(colon + 1) : this.fwdTargetPort;
    this.fwdResult = 'editing rule ' + id;
  }


  // 清空全部转发规则（用户需要的清理动作，也让用例可重复）
  private async clearAllRules(): Promise<void> {
    if (this.store === null) { return; }
    try {
      const pred = new relationalStore.RdbPredicates('forwards');
      await this.store.delete(pred);
      this.editingRuleId = '';
      this.fwdResult = this.lang === 'zh' ? '已清空全部规则' : 'all rules cleared';
      await this.reloadRules();
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'clearAllRules failed: %{public}s', JSON.stringify(e));
    }
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
  private matchesProto(h: HostItem): boolean {
    if (this.protoFilter.length === 0) {
      return true;
    }
    return h.proto === this.protoFilter;
  }

  private matchesQuery(h: HostItem): boolean {
    if (!this.matchesProto(h)) {
      return false;
    }
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



  private lastUsedText(h: HostItem): string {
    const at: number | undefined = this.lastUsedMap.get(h.address + '|' + h.proto);
    if (at === undefined) {
      return this.lang === 'zh' ? '未连接' : 'never connected';
    }
    const d = new Date(at);
    const hh: string = d.getHours() < 10 ? '0' + d.getHours() : String(d.getHours());
    const mm: string = d.getMinutes() < 10 ? '0' + d.getMinutes() : String(d.getMinutes());
    return (this.lang === 'zh' ? '最近连接 ' : 'last used ') + hh + ':' + mm;
  }

  private iconGlyph(name: string): string {
    if (name === 'star') { return '★'; }
    if (name === 'server') { return '▤'; }
    if (name === 'cloud') { return '☁'; }
    if (name === 'box') { return '▣'; }
    if (name === 'bolt') { return '⚡'; }
    return '';
  }

  private t(key: string): string {
    return Strings.get(this.lang, key);
  }

  private async toggleLangAndSave(): Promise<void> {
    this.toggleLang();
    await this.savePrefs();
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
      this.setStatus(index, 'no credentials in memory (add a password in host settings)');
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
      Text(this.editingId.length > 0 ? '编辑主机' : '新建主机')
        .id('hostform/title').fontSize(18).fontWeight(FontWeight.Bold).fontColor(this.th('#E8EAED')).width('100%')
      Text(this.lang === 'zh' ? '基础' : 'Basics').fontSize(11).fontColor(this.th('#6B7078')).width('100%')
      Text(this.lang === 'zh' ? '名称' : 'Name').fontSize(12).fontColor(this.th('#8A8F98')).width('100%')
      TextInput({ placeholder: this.lang === 'zh' ? '显示在主机列表中' : 'shown in the host list', text: this.formLabel }).id('shell/dialog-label').width('100%')
        .backgroundColor(this.th('#23262B')).fontColor(this.th('#E8EAED')).placeholderColor(this.th('#6B7078'))
        .onChange((v: string) => { this.formLabel = v; })
      Text(this.lang === 'zh' ? '地址' : 'Address').fontSize(12).fontColor(this.th('#8A8F98')).width('100%')
      TextInput({ placeholder: this.lang === 'zh' ? '主机名或 IP' : 'hostname or IP', text: this.formAddress }).id('shell/dialog-address').width('100%')
        .backgroundColor(this.th('#23262B')).fontColor(this.th('#E8EAED')).placeholderColor(this.th('#6B7078'))
        .onChange((v: string) => { this.formAddress = v; })
      Row({ space: 10 }) {
        Column({ space: 4 }) {
          Text(this.lang === 'zh' ? '用户' : 'User').fontSize(12).fontColor(this.th('#8A8F98')).width('100%')
          TextInput({ placeholder: this.lang === 'zh' ? '登录账户' : 'login account', text: this.formUser }).id('shell/dialog-user').width('100%')
            .backgroundColor(this.th('#23262B')).fontColor(this.th('#E8EAED')).placeholderColor(this.th('#6B7078'))
            .onChange((v: string) => { this.formUser = v; })
        }.layoutWeight(2)
        Column({ space: 4 }) {
          Text(this.lang === 'zh' ? '端口' : 'Port').fontSize(12).fontColor(this.th('#8A8F98')).width('100%')
          TextInput({ placeholder: '22', text: this.formPort }).id('shell/dialog-port').width('100%').type(InputType.Number)
            .backgroundColor(this.th('#23262B')).fontColor(this.th('#E8EAED')).placeholderColor(this.th('#6B7078'))
            .onChange((v: string) => { this.formPort = v; })
        }.layoutWeight(1)
      }.width('100%')
      Text(this.lang === 'zh' ? '密码' : 'Password').fontSize(12).fontColor(this.th('#8A8F98')).width('100%')
      TextInput({ placeholder: this.lang === 'zh' ? (this.editingId.length > 0 ? '留空则保留' : '可选 · 加密保存') : (this.editingId.length > 0 ? 'blank keeps current' : 'optional, stored encrypted'), text: this.formPassword })
        .id('shell/dialog-password').width('100%').type(InputType.Password)
        .backgroundColor(this.th('#23262B')).fontColor(this.th('#E8EAED')).placeholderColor(this.th('#6B7078'))
        .onChange((v: string) => { this.formPassword = v; })
      Row({ space: 8 }) {
        ForEach(this.tagChoices(), (tag: string) => {
          Text(tag).fontSize(11)
            .padding({ left: 10, right: 10, top: 4, bottom: 4 })
            .borderRadius(12)
            .fontColor(this.tagList({ id: '', label: '', address: '', user: '', port: '',
              proto: '', group: '', tags: this.formTags, color: '' } as HostItem).indexOf(tag) >= 0
              ? '#12141A' : this.th('#C7CBD1'))
            .backgroundColor(this.tagList({ id: '', label: '', address: '', user: '', port: '',
              proto: '', group: '', tags: this.formTags, color: '' } as HostItem).indexOf(tag) >= 0
              ? '#3DDC97' : this.th('#23262B'))
            .id('hostform/tag/' + tag)
            .onClick(() => { this.toggleFormTag(tag); })
        }, (tag: string) => 'tg-' + tag)
      }.width('100%')
      Text(this.lang === 'zh' ? '外观与归类' : 'Appearance').fontSize(11).fontColor(this.th('#6B7078')).width('100%')
      Row({ space: 10 }) {
        Column({ space: 4 }) {
          Text(this.lang === 'zh' ? '分组' : 'Group').fontSize(12).fontColor(this.th('#8A8F98')).width('100%')
          Row({ space: 8 }) {
          Text(this.lang === 'zh' ? '图标' : 'Icon').fontSize(12).fontColor(this.th('#8A8F98'))
          Text(this.lang === 'zh' ? '无' : 'None').id('hostform/icon-none').fontSize(12)
            .fontColor(this.formIcon.length === 0 ? '#12141A' : this.th('#C7CBD1'))
            .backgroundColor(this.formIcon.length === 0 ? this.th('#E8EAED') : this.th('#1E2127'))
            .padding({ left: 8, right: 8, top: 4, bottom: 4 }).borderRadius(12)
            .onClick(() => { this.formIcon = ''; })
          Text('★').id('hostform/icon-star').fontSize(12)
            .fontColor(this.formIcon === 'star' ? '#12141A' : this.th('#C7CBD1'))
            .backgroundColor(this.formIcon === 'star' ? this.th('#E8EAED') : this.th('#1E2127'))
            .padding({ left: 8, right: 8, top: 4, bottom: 4 }).borderRadius(12)
            .onClick(() => { this.formIcon = 'star'; })
          Text('▤').id('hostform/icon-server').fontSize(12)
            .fontColor(this.formIcon === 'server' ? '#12141A' : this.th('#C7CBD1'))
            .backgroundColor(this.formIcon === 'server' ? this.th('#E8EAED') : this.th('#1E2127'))
            .padding({ left: 8, right: 8, top: 4, bottom: 4 }).borderRadius(12)
            .onClick(() => { this.formIcon = 'server'; })
          Text('☁').id('hostform/icon-cloud').fontSize(12)
            .fontColor(this.formIcon === 'cloud' ? '#12141A' : this.th('#C7CBD1'))
            .backgroundColor(this.formIcon === 'cloud' ? this.th('#E8EAED') : this.th('#1E2127'))
            .padding({ left: 8, right: 8, top: 4, bottom: 4 }).borderRadius(12)
            .onClick(() => { this.formIcon = 'cloud'; })
          Text('▣').id('hostform/icon-box').fontSize(12)
            .fontColor(this.formIcon === 'box' ? '#12141A' : this.th('#C7CBD1'))
            .backgroundColor(this.formIcon === 'box' ? this.th('#E8EAED') : this.th('#1E2127'))
            .padding({ left: 8, right: 8, top: 4, bottom: 4 }).borderRadius(12)
            .onClick(() => { this.formIcon = 'box'; })
          Text('⚡').id('hostform/icon-bolt').fontSize(12)
            .fontColor(this.formIcon === 'bolt' ? '#12141A' : this.th('#C7CBD1'))
            .backgroundColor(this.formIcon === 'bolt' ? this.th('#E8EAED') : this.th('#1E2127'))
            .padding({ left: 8, right: 8, top: 4, bottom: 4 }).borderRadius(12)
            .onClick(() => { this.formIcon = 'bolt'; })
        }.width('100%').justifyContent(FlexAlign.Start)
        Row({ space: 8 }) {
          Text(this.lang === 'zh' ? '协议' : 'Protocol').fontSize(12).fontColor(this.th('#8A8F98'))
          Text('SSH').id('hostform/proto-ssh').fontSize(12)
            .fontColor(this.formProto === 'ssh' ? '#12141A' : this.th('#C7CBD1'))
            .backgroundColor(this.formProto === 'ssh' ? this.th('#E8EAED') : this.th('#1E2127'))
            .padding({ left: 10, right: 10, top: 4, bottom: 4 }).borderRadius(12)
            .onClick(() => { this.formProto = 'ssh'; })
          Text('RDP').id('hostform/proto-rdp').fontSize(12)
            .fontColor(this.formProto === 'rdp' ? '#12141A' : this.th('#C7CBD1'))
            .backgroundColor(this.formProto === 'rdp' ? this.th('#E8EAED') : this.th('#1E2127'))
            .padding({ left: 10, right: 10, top: 4, bottom: 4 }).borderRadius(12)
            .onClick(() => { this.formProto = 'rdp'; })
          Text('VNC').id('hostform/proto-vnc').fontSize(12)
            .fontColor(this.formProto === 'vnc' ? '#12141A' : this.th('#C7CBD1'))
            .backgroundColor(this.formProto === 'vnc' ? this.th('#E8EAED') : this.th('#1E2127'))
            .padding({ left: 10, right: 10, top: 4, bottom: 4 }).borderRadius(12)
            .onClick(() => { this.formProto = 'vnc'; })
        }.width('100%').justifyContent(FlexAlign.Start)
        TextInput({ placeholder: this.lang === 'zh' ? '选择或创建分组' : 'pick or create a group', text: this.formGroup }).id('shell/dialog-group').width('100%')
            .backgroundColor(this.th('#23262B')).fontColor(this.th('#E8EAED')).placeholderColor(this.th('#6B7078'))
            .onChange((v: string) => { this.formGroup = v; })
        }.layoutWeight(1)
        Column({ space: 4 }) {
          Text(this.lang === 'zh' ? '标签' : 'Tags').fontSize(12).fontColor(this.th('#8A8F98')).width('100%')
          TextInput({ placeholder: this.lang === 'zh' ? '开发,测试,生产' : 'dev,test,prod', text: this.formTags }).id('shell/dialog-tags').width('100%')
            .backgroundColor(this.th('#23262B')).fontColor(this.th('#E8EAED')).placeholderColor(this.th('#6B7078'))
            .onChange((v: string) => { this.formTags = v; })
        }.layoutWeight(1)
      }.width('100%')
      Text(this.lang === 'zh' ? '颜色' : 'Color').fontSize(12).fontColor(this.th('#8A8F98')).width('100%')
      Row({ space: 8 }) {
        ForEach(this.colorChoices(), (c: string) => {
          Row()
            .width(24).height(24).borderRadius(12)
            .backgroundColor(c.length > 0 ? c : this.th('#23262B'))
            .border({ width: this.formColor === c ? 2 : 1,
                      color: this.formColor === c ? this.th('#E8EAED') : '#3A3E45' })
            .id('hostform/color/' + (c.length > 0 ? c.substring(1) : 'none'))
            .onClick(() => { this.formColor = c; })
        }, (c: string) => 'cc-' + c)
        TextInput({ placeholder: '#3B82F6', text: this.formColor }).id('shell/dialog-color')
          .layoutWeight(1).backgroundColor(this.th('#23262B')).fontColor(this.th('#E8EAED')).placeholderColor(this.th('#6B7078'))
          .onChange((v: string) => { this.formColor = v; })
      }.width('100%')
      if (this.formError.length > 0) {
        Text(this.formError).id('shell/dialog-error').fontSize(11).fontColor('#E08A8A').width('100%')
      }
      Row({ space: 12 }) {
        Button(this.t('hostkey.cancel')).id('shell/dialog-cancel').backgroundColor(this.th('#23262B')).fontColor(this.th('#C7CBD1'))
          .onClick(() => { this.showDialog = false; this.editingId = ''; this.resetForm(); })
        Button(this.editingId.length > 0 ? this.t('common.save') : this.t('common.add'))
          .id('shell/dialog-submit').backgroundColor('#3DDC97').fontColor('#12141A')
          .onClick(() => { this.submit(); })
      }.width('100%').justifyContent(FlexAlign.End)
    }
    .id('host-form/dialog').width(620).padding(20).backgroundColor(this.th('#1C1F24')).borderRadius(12)
    .shadow({ radius: 24, color: '#66000000', offsetY: 8 })
    .shadow({ radius: 24, color: '#33000000', offsetY: 8 })
  }

  @Builder
  keyConfirm() {
    Column({ space: 12 }) {
      Text(this.t('hostkey.title')).id('hostkey/title').fontSize(18).fontWeight(FontWeight.Bold)
        .fontColor(this.th('#E8EAED')).width('100%')
      Text(this.t('hostkey.body')).fontSize(12).fontColor(this.th('#8A8F98')).width('100%')
      Text(this.pendingFp).id('hostkey/fingerprint').fontSize(13).fontFamily('monospace')
        .fontColor(this.th('#C7CBD1')).width('100%')
      Row({ space: 12 }) {
        Button(this.t('hostkey.cancel')).id('hostkey/cancel').backgroundColor(this.th('#23262B')).fontColor(this.th('#C7CBD1'))
          .onClick(() => {
            this.keyDialog = false; this.pendingFp = ''; this.pendingKey = '';
            this.probeText = 'cancelled, nothing trusted';
          })
        Button(this.t('hostkey.trust')).id('hostkey/trust').backgroundColor('#3DDC97').fontColor('#12141A')
          .onClick(() => this.trustAndConnect())
      }.width('100%').justifyContent(FlexAlign.End)
    }
    .id('hostkey/dialog').width(520).padding(20).backgroundColor(this.th('#1C1F24')).borderRadius(12)
    .shadow({ radius: 24, color: '#66000000', offsetY: 8 })
  }

  @Builder
  filesPanel() {
    Column({ space: 8 }) {
      Row() {
        Text(this.t('sftp.title')).fontSize(16).fontWeight(FontWeight.Bold)
        Blank()
        Button(this.t('sftp.close')).id('sftp/close').backgroundColor(this.th('#23262B')).fontColor(this.th('#C7CBD1'))
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
    .id('sftp/panel').width(680).padding(16).backgroundColor(this.th('#1C1F24')).borderRadius(12)
    .shadow({ radius: 24, color: '#33000000', offsetY: 8 })
  }

  @Builder
  forwardPanel() {
    Column({ space: 8 }) {
      Row() {
        Text(this.t('fwd.title')).fontSize(16).fontWeight(FontWeight.Bold)
        Blank()
        Button(this.lang === 'zh' ? '关闭' : 'Close').id('fwd/close').backgroundColor('#E6E6E6').fontColor('#1A1A1A')
          .onClick(() => { this.fwdOpen = false; })
      }.width('100%')
      Row({ space: 8 }) {
        Text('listen').fontSize(11).fontColor('#666666')
        TextInput({ placeholder: 'listen port' }).id('fwd/listen').width(80)
          .onChange((v: string) => { this.fwdListen = v; })
        Text('->').fontSize(11).fontColor('#666666')
        TextInput({ placeholder: 'target host' }).id('fwd/target-host').width(120)
          .onChange((v: string) => { this.fwdTargetHost = v; })
        Text(':').fontSize(11).fontColor('#666666')
        TextInput({ placeholder: 'target port' }).id('fwd/target-port').width(80)
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
      Row({ space: 8 }) {
        Button(this.t('fwd.start')).id('fwd/start').onClick(() => { this.startForward(); })
        Button(this.t('fwd.stop')).id('fwd/stop').backgroundColor('#E6E6E6').fontColor('#1A1A1A')
          .onClick(() => { this.stopForward(); })
        Button(this.t('fwd.test')).id('fwd/test').backgroundColor('#1A6DD0').fontColor(Color.White)
          .onClick(() => { this.testForward(); })
        Button(this.t('fwd.save')).id('fwd/save').backgroundColor('#0A6C00').fontColor(Color.White)
          .onClick(() => { this.saveRule(); })
      }.width('100%')
      Text('saved rules: ' + this.fwdRuleCount)
        .id('fwd/rule-count').fontSize(11).fontColor('#0A6C00').width('100%')
        Button(this.lang === 'zh' ? '清空全部规则' : 'Clear all rules')
          .id('fwd/clear-all').height(26).fontSize(11).backgroundColor('#C62828').fontColor(Color.White)
          .onClick(() => { this.clearAllRules(); })
      Column({ space: 4 }) {
        ForEach(this.fwdRules, (rule: string, ridx: number) => {
          Row({ space: 8 }) {
            Text(rule.substring(rule.indexOf('|') + 1)).fontSize(11).fontFamily('monospace')
              .layoutWeight(1)
            Button(this.lang === 'zh' ? '启动' : 'Start').id('fwd/rule/' + rule.substring(0, rule.indexOf('|')))
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
            Button(this.lang === 'zh' ? '编辑' : 'Edit').id('fwd/rule-edit/' + ridx)
          .fontSize(11).backgroundColor('#37474F').fontColor(Color.White)
          .onClick(() => {
            const partsE = rule.split('|');
            const restE = partsE.length > 2 ? partsE[2] : '';
            this.editRule(partsE[0], partsE[1], restE);
          })
        Button(this.lang === 'zh' ? '删除' : 'Del').id('fwd/rule-del/' + rule.substring(0, rule.indexOf('|')))
              .backgroundColor('#C62828').fontColor(Color.White).fontSize(11)
              .onClick(() => { this.deleteRule(rule.substring(0, rule.indexOf('|'))); })
          }.width('100%')
        }, (rule: string) => rule)
        if (this.fwdRules.length === 0) {
          Text('(no saved rules)').id('fwd/rule-empty').fontSize(11).fontColor('#999999').width('100%')
        }
      }.width('100%')
      Text('Limits: one active connection at a time, no ACL, local forward only.')
        .fontSize(10).fontColor('#999999').width('100%')
    }
    .id('fwd/panel').width(680).padding(16).backgroundColor(this.th('#1C1F24')).borderRadius(12)
    .shadow({ radius: 24, color: '#33000000', offsetY: 8 })
  }

  @Builder
  vncPanel() {
    Column({ space: 8 }) {
      Row() {
        Text(this.t('vnc.title')).fontSize(16).fontWeight(FontWeight.Bold)
        Blank()
        Button(this.t('vnc.stop')).id('vnc/stop').backgroundColor('#E6E6E6').fontColor('#1A1A1A')
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
      Row({ space: 8 }) {
        Text('canvas=' + this.vncCanvasW + 'x' + this.vncCanvasH)
          .id('vnc/canvas-size').fontSize(11).fontColor('#1A6DD0')
      Text('drawn=' + this.vncDrawn + ' (fillRect grid)')
          .id('vnc/drawn').fontSize(11).fontColor('#0A6C00')
        Button(this.t('vnc.pointer'))
          .id('vnc/tap')
          .onClick(() => { this.sendVncPointer(10, 10, 1); this.sendVncPointer(10, 10, 0); })
        Button(this.t('vnc.key'))
          .id('vnc/key')
          .onClick(() => {
            if (this.vncId !== 0) {
              mottynapi.vncKey(this.vncId, 0x61, 1);
              mottynapi.vncKey(this.vncId, 0x61, 0);
            }
          })
      }.width('100%')
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

      Text(this.vncFrameInfo.length > 0 ? this.vncFrameInfo : 'frame: (none)')
        .id('vnc/frame').fontSize(11).fontFamily('monospace').width('100%')
    }
    .id('vnc/panel').width(680).padding(16).backgroundColor(this.th('#1C1F24')).borderRadius(12)
    .shadow({ radius: 24, color: '#33000000', offsetY: 8 })
  }

  @Builder
  deleteHostConfirm() {
    Column({ space: 10 }) {
      Text(this.t('host.deleteTitle')).id('hostdel/title').fontSize(16).fontWeight(FontWeight.Bold)
        .fontColor(this.th('#E8EAED')).width('100%')
      Text(this.t('host.deleteDesc').replace('%d', String(this.deleteIds.length > 0 ? this.deleteIds.length : 1)))
        .fontSize(12).fontColor(this.th('#8A8F98')).width('100%')
      Row({ space: 12 }) {
        Button(this.t('hostkey.cancel')).id('hostdel/cancel').backgroundColor(this.th('#23262B')).fontColor(this.th('#C7CBD1'))
          .onClick(() => { this.deleteDialog = false; this.deleteIndex = -1; this.deleteIds = []; })
        Button(this.t('host.del')).id('hostdel/confirm').backgroundColor('#C62828').fontColor(Color.White)
          .onClick(() => { this.confirmDeleteHost(); })
      }.width('100%').justifyContent(FlexAlign.End)
    }
    .id('hostdel/dialog').width(420).padding(20).backgroundColor(this.th('#1C1F24')).borderRadius(12)
    .shadow({ radius: 24, color: '#33000000', offsetY: 8 })
  }

  @Builder
  changedKeyWarning() {
    Column({ space: 10 }) {
      Text(this.lang === 'zh' ? '主机密钥已变更' : 'Host key has changed')
        .id('hostkey/changed-title').fontSize(16).fontWeight(FontWeight.Bold)
        .fontColor('#E08A8A').width('100%')
      Text(this.lang === 'zh'
        ? '这可能意味着服务器重装过，也可能是有人在中间人攻击。未发送任何内容。'
        : 'This can mean the server was reinstalled, or that someone is intercepting the connection.')
        .fontSize(12).fontColor(this.th('#8A8F98')).width('100%')
      Text('old: ' + this.changedOld).id('hostkey/old').fontSize(11).fontFamily('monospace')
        .fontColor(this.th('#8A8F98')).width('100%')
      Text('new: ' + this.changedNew).id('hostkey/new').fontSize(11).fontFamily('monospace')
        .fontColor('#E08A8A').width('100%')
      Row({ space: 12 }) {
        Button(this.t('hostkey.cancel')).id('hostkey/cancel-changed').backgroundColor(this.th('#23262B')).fontColor(this.th('#C7CBD1'))
          .onClick(() => {
            this.changedDialog = false;
            this.setStatus(0, 'host key changed: refused (user did not accept)');
          })
        Button(this.lang === 'zh' ? '信任新密钥' : 'Accept new key').id('hostkey/update')
          .backgroundColor('#C62828').fontColor(Color.White)
          .onClick(() => { this.acceptChangedKey(0); })
      }.width('100%').justifyContent(FlexAlign.End)
    }
    .id('hostkey/changed').width(560).padding(20).backgroundColor(this.th('#1C1F24')).borderRadius(12)
    .shadow({ radius: 24, color: '#33000000', offsetY: 8 })
  }

  @Builder
  knownPanel() {
    Column({ space: 8 }) {
      Row() {
        Text(this.lang === 'zh' ? '已知主机' : 'Known hosts').fontSize(16).fontWeight(FontWeight.Bold)
        Blank()
        Button(this.t('common.close')).id('known/close').backgroundColor('#E6E6E6').fontColor('#1A1A1A')
          .onClick(() => { this.knownOpen = false; })
      }.width('100%')
      Text('trusted entries: ' + this.knownKeys.length)
        .id('known/count').fontSize(11).fontColor('#0A6C00').width('100%')
        Button(this.lang === 'zh' ? '导出' : 'Export').id('known/export-file').height(28).fontSize(12)
        .backgroundColor(this.th('#1E2127')).fontColor(this.th('#C7CBD1'))
        .onClick(() => { this.exportKnownHosts(); })
      Button(this.lang === 'zh' ? '导入' : 'Import').id('known/import-file').height(28).fontSize(12)
        .backgroundColor(this.th('#1E2127')).fontColor(this.th('#C7CBD1'))
        .onClick(() => { this.importKnownHosts(); })
      Button(this.lang === 'zh' ? '清空已知主机' : 'Clear known hosts')
          .id('known/clear').height(28).fontSize(12).backgroundColor('#C62828').fontColor(Color.White)
          .onClick(() => { this.clearKnownHosts(); })
      if (this.knownResult.length > 0) {
        Text(this.knownResult).id('known/result').fontSize(11).fontFamily('monospace').fontColor('#0A6C00').width('100%')
      }
      Row({ space: 10 }) {
        TextInput({ placeholder: this.lang === 'zh' ? '搜索主机或指纹' : 'search host or fingerprint' })
          .id('known/search').height(32).fontSize(12).layoutWeight(1)
          .onChange((v: string) => { this.knownQuery = v; })
        Text(this.knownFilteredKeys().length + ' / ' + this.knownKeys.length)
          .id('known/search-count').fontSize(11).fontColor('#999999')
      }.width('100%')
      Scroll() {
        Column({ space: 4 }) {
          ForEach(this.knownFilteredKeys(), (key: string, idx: number) => {
            Row({ space: 8 }) {
              Column({ space: 2 }) {
                Text(key).fontSize(12).fontFamily('monospace').width('100%')
                Text(this.knownFps[idx]).fontSize(10).fontFamily('monospace').fontColor('#888888').width('100%')
              }.layoutWeight(1).alignItems(HorizontalAlign.Start)
              Button(this.lang === 'zh' ? '删除' : 'Delete').id('known/del/' + key).backgroundColor('#C62828').fontColor(Color.White)
                .fontSize(12)
                .onClick(() => { this.knownDelKey = key; })
            }.width('100%').padding(6).backgroundColor('#FAFAFA').borderRadius(6)
          }, (key: string) => key)
          if (this.knownFilteredKeys().length === 0) {
            Text(this.lang === 'zh' ? '还没有已信任的主机' : '(no trusted hosts)').id('known/empty').fontSize(12).fontColor('#999999').width('100%')
          }
        }.width('100%').alignItems(HorizontalAlign.Start)
      }.height(200).width('100%').border({ width: 1, color: '#DDDDDD' }).padding(8)
        .align(Alignment.TopStart)
      Text('Deleting an entry forces the trust prompt again on next connect.')
        .fontSize(10).fontColor('#999999').width('100%')
    }
    .id('known/panel').width(620).padding(16).backgroundColor(this.th('#1C1F24')).borderRadius(12)
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
                .backgroundColor(this.th('#23262B'))
                .fontColor('#666666')
                .fontSize(12)
                .onClick(() => { this.closeTab(t.id); })
            }
          }, (t: TabInfo) => t.id)
        }
      }
      .scrollable(ScrollDirection.Horizontal)
      .layoutWeight(1)
      if (this.showTabCount) {
        Text(this.tabs.length > 1 ? this.tabs.length + ' sessions' : '1 session')
        .id('session/count').fontSize(11).fontColor('#666666')
      }
    }
    .id('session/tabbar').width('100%').padding({ left: 16, right: 16, top: 8, bottom: 8 })
    .backgroundColor(this.th('#1E2127'))
  }


  // 标签方向：侧栏（垂直）标签条
  @Builder
  tabStripVertical() {
    Column({ space: 6 }) {
      ForEach(this.tabs, (t: TabInfo, idx: number) => {
        Row({ space: 4 }) {
          Button((this.tabNumbers ? (idx + 1).toString() + ' ' : '') + t.label)
            .id('session-tabv/' + t.id)
            .backgroundColor(this.activeId === t.id ? '#1A6DD0' : this.th('#23262B'))
            .fontColor(this.activeId === t.id ? Color.White : this.th('#C7CBD1'))
            .fontSize(12).height(30).layoutWeight(1)
            .onClick(() => { this.selectTab(t.id); })
          Button('×').id('session-closev/' + t.id)
            .backgroundColor(this.th('#2A2D33')).fontColor(this.th('#C7CBD1')).fontSize(12).height(30).width(30)
            .onClick(() => { this.closeTab(t.id); })
        }.width('100%')
      }, (t: TabInfo) => 'v-' + t.id)
    }
    .id('session/tabstrip').width(210).padding({ left: 8, right: 8, top: 8, bottom: 8 })
    .backgroundColor(this.th('#17191D'))
  }

  @Builder
  terminalView() {
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        TextInput({ text: this.termInput, placeholder: 'type a line and press Send' })
          .id('terminal/input').layoutWeight(1).onChange((v: string) => { this.termInput = v; })
        Button(this.lang === 'zh' ? '发送' : 'Send').id('terminal/send').height(30).fontSize(11).onClick(() => { this.sendTermInput(); })
        Button(this.lang === 'zh' ? '改尺寸' : 'Resize').id('terminal/resize').height(30).fontSize(11).backgroundColor('#E6E6E6').fontColor('#1A1A1A')
          .onClick(() => { this.resizeSession(); })
        Button('\u25b2').id('terminal/scroll-up').height(30).fontSize(11).backgroundColor('#E6E6E6').fontColor('#1A1A1A')
          .onClick(() => { this.scrollView(5); })
        Button('\u25bc').id('terminal/scroll-down').height(30).fontSize(11).backgroundColor('#E6E6E6').fontColor('#1A1A1A')
          .onClick(() => { this.scrollView(-5); })
        Button(this.lang === 'zh' ? '全选' : 'Sel all').id('terminal/selall').height(30).fontSize(11).backgroundColor('#E6E6E6').fontColor('#1A1A1A')
          .onClick(() => { this.selectAllVisible(); })
        Button(this.lang === 'zh' ? '复制' : 'Copy').id('terminal/copy').height(30).fontSize(11).backgroundColor('#1A6DD0').fontColor(Color.White)
          .onClick(() => { this.copySelection().catch((e: BusinessError) => { this.ptyStatus = 'copy error'; }); })
        Button('AI').id('ai/ask').backgroundColor('#6A1B9A').fontColor(Color.White)
          .onClick(() => { this.askAI().catch((e: BusinessError) => { this.aiAnswer = 'ai: error'; }); })
        Button('^C').id('terminal/ctrl-c').height(30).fontSize(11).backgroundColor('#E6E6E6').fontColor('#1A1A1A')
          .onClick(() => { this.sendCtrlC(); })
        Button('\u2191').id('terminal/up').height(30).fontSize(11).backgroundColor('#E6E6E6').fontColor('#1A1A1A')
          .onClick(() => { this.sendSpecial('up'); })
        Button('\u2193').id('terminal/down').height(30).fontSize(11).backgroundColor('#E6E6E6').fontColor('#1A1A1A')
          .onClick(() => { this.sendSpecial('down'); })
        Button('\u2190').id('terminal/left').height(30).fontSize(11).backgroundColor('#E6E6E6').fontColor('#1A1A1A')
          .onClick(() => { this.sendSpecial('left'); })
        Button('\u2192').id('terminal/right').height(30).fontSize(11).backgroundColor('#E6E6E6').fontColor('#1A1A1A')
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
          .id('terminal/output').fontSize(this.termFontSize).fontFamily('monospace').fontColor('#D4D4D4')
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
    List({ space: 2 }) {
        ForEach(this.sections().filter((g: string) =>
          this.groupFilter.length === 0 || this.sectionLabel(g) === this.groupFilter), (g: string) => {
        ListItem() {
          Row({ space: 8 }) {
            Text(this.selectAll ? '☑' : '☐').fontSize(15).width(18)
              .textAlign(TextAlign.Center).fontColor(this.selectAll ? '#3DDC97' : this.th('#6B7078'))
              
              .opacity(this.selectAll ? 1 : 0.45)
            Image(this.isCollapsed(g) ? $r('app.media.ic_chevron_right') : $r('app.media.ic_chevron_down'))
              .width(14).height(14)
            Text(this.isPinned(g) ? '★' : '☆').id('group/pin/' + g).fontSize(11)
              .fontColor(this.isPinned(g) ? '#E0A458' : '#4A4F57')
              .onClick(() => { this.togglePin(g); })
            Text(this.sectionLabel(g)).fontSize(13).fontColor(this.th('#C7CBD1')).fontWeight(FontWeight.Medium)
            Text('✎').id('group/rename/' + g).fontSize(12).fontColor(this.th('#8A8F98'))
              .onClick(() => { this.openRenameGroup(g); })
            Text('🗑').id('group/del/' + g).fontSize(12).fontColor(this.th('#8A8F98'))
              .onClick(() => { this.askDeleteGroup(g); })
            Text('(' + this.countGroup(g) + ')').fontSize(12).fontColor(this.th('#6B7078'))
            Blank()
            Image($r('app.media.ic_more')).id('group/menu/' + g).width(16).height(16)
            .onClick(() => { this.groupMenu = g; this.groupMenuTarget = g; })

          }
          .width('100%').height(34).padding({ left: 8, right: 8 })
          .id('group/header/' + g)
          .onClick(() => { this.toggleGroup(g); })
        }
        if (!this.isCollapsed(g)) {
          ForEach(this.hosts, (h: HostItem, index: number) => {
            ListItem() {
              if (this.matchesQuery(h) && this.hostGroupOf(h) === g) {
                Row({ space: 14 }) {
                  Button(this.isSelected(h) ? '☑' : '☐').id('host-check/' + index)
                    .fontSize(15).width(24).height(24).padding(0).backgroundColor('#00000000')
                    .fontColor(this.isSelected(h) ? '#3DDC97' : this.th('#6B7078'))
                    .hitTestBehavior(HitTestMode.Block)
                    .onClick(() => { this.toggleSelect(h); })
                    
                    .opacity(this.isSelected(h) ? 1 : (this.selectAll ? 1 : 0.45))
                  // 颜色标记（原版 paintHostColorMark：左缘 3px 圆角竖条）
                  Column().width(3).height(40).borderRadius(2)
                    .backgroundColor(h.color.length > 0 ? h.color : Color.Transparent)
                  // 图标块：首字母
                  if (this.hasOsIcon(h)) {
                    Image(this.osImage(h)).id('host-avatar-icon/' + index).width(26).height(26)
                  } else {
                    Text(h.label.substring(0, 1).toUpperCase()).id('host-avatar-letter/' + index)
                      .fontSize(16).fontWeight(FontWeight.Bold)
                      .fontColor(Color.White).width(40).height(40).textAlign(TextAlign.Center)
                      .borderRadius(20)
                      .backgroundColor(h.color.length > 0 ? h.color : this.th('#2A2D33'))
                  }
                  // 名称 + 用户
                  Column({ space: 4 }) {
                    Text(this.iconGlyph(h.icon)).id('host-icon/' + h.id).fontSize(13).fontColor('#E0A458')
                    Text(h.label).fontSize(this.fs(15)).fontColor(this.th('#E8EAED')).fontWeight(FontWeight.Medium)
                      .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
                    Text(this.showLastUsed ? this.lastUsedText(h) : '').id('host-lastused/' + h.id).fontSize(10)
                      .fontColor(this.th('#6B7078')).maxLines(1)
                    Text('ⓘ').id('host-info/' + index).fontSize(11).fontColor(this.th('#6B7078'))
                      .onClick(() => { this.hostDetailIndex = index; })
                    Text('⎘').id('host-copy/' + index).fontSize(11).fontColor(this.th('#6B7078'))
                      .onClick(() => { this.copyHostAddress(h); })
                    Text('⋯').id('host-more/' + index).fontSize(11).fontColor(this.th('#6B7078'))
                      .onClick(() => { this.hostMenuIndex = index; })
                    Text(h.user.length > 0 ? h.user : '-').fontSize(12).fontColor(this.th('#8A8F98'))
                  }
                  .id('host-name/' + index)
                  .alignItems(HorizontalAlign.Start).layoutWeight(3)
                  .onClick(() => { this.openSession(h.label, index); })
                  // 地址（右对齐）
                  Text((h.proto === 'rdp' ? 'rdp://' : (h.proto === 'vnc' ? 'vnc://' : '')) +
                       h.address + (h.port.length > 0 ? ':' + h.port : ''))
                    .fontSize(12).fontColor(this.th('#8A8F98')).width(120).textAlign(TextAlign.End)
                  Row({ space: 4 }) {
                    Text(this.statusOf(index).length > 0 ? '●' : '○').fontSize(9)
                      .fontColor(this.statusOf(index).length > 0 ? '#3DDC97' : this.th('#6B7078'))
                    Text(this.statusOf(index).length > 0 ? this.statusOf(index) : (this.lang === 'zh' ? '未连接' : 'offline'))
                      .fontSize(11).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                      .fontColor(this.statusOf(index).length > 0 ? this.th('#C7CBD1') : this.th('#6B7078'))
                  }.id('host-status-text/' + index).width(180)
                  // 标签 chips（原版预设：开发/测试/生产）
                  ForEach(this.tagList(h), (tg: string) => {
                    Text(tg).fontSize(11).fontColor(this.th('#C7CBD1'))
                      .padding({ left: 7, right: 7, top: 3, bottom: 3 })
                      .backgroundColor(this.th('#23262B')).borderRadius(12)
                  }, (tg: string) => h.id + tg)
                  // 行内操作：默认隐藏，悬停显示（对齐原版交互），id 保持在树上供用例使用
                  Row({ space: 4 }) {
                  Button(this.t('host.test')).id('host-row/' + index).fontSize(10).height(26)
                    .backgroundColor(this.th('#23262B')).fontColor(this.th('#C7CBD1'))
                  Button(this.t('host.files')).id('host-files/' + index).fontSize(10).height(26)
                    .backgroundColor(this.th('#23262B')).fontColor(this.th('#C7CBD1'))
                    .onClick(() => { this.openFiles(index); })
                  Button(this.t('host.open')).id('host-open/' + index).fontSize(10).height(26)
                    .backgroundColor('#2F6F4F').fontColor(Color.White)
                    .onClick(() => { this.openSession(h.label, index); })
                  Button(this.t('host.edit')).id('host-edit/' + index).fontSize(10).height(26)
                    .backgroundColor(this.th('#23262B')).fontColor(this.th('#C7CBD1'))
                    .onClick(() => { this.openEditHost(index); })
                  Button(this.t('host.del')).id('host-del/' + index).fontSize(10).height(26)
                    .backgroundColor('#3A2226').fontColor('#E08A8A')
                    .onClick(() => { this.askDeleteHost(index); })
                  }
                .width(250).justifyContent(FlexAlign.End)
                .opacity(this.hoverRow === index ? 1 : 0.3)
                }
                .width('100%').height(60).padding({ left: 10, right: 10 })
                .borderRadius(10)
                .backgroundColor(this.hoverRow === index ? this.th('#22262C') : this.th('#1C1F24'))
                .onHover((isHover: boolean) => {
                  if (isHover) { this.hoverRow = index; }
                  else if (this.hoverRow === index) { this.hoverRow = -1; }
                })
              }
            }
          }, (h: HostItem) => h.id + '|' + h.label + '|' + h.address + '|' + h.user + '|' + h.port + '|' + h.group + '|' + h.tags + '|' + h.color + '|' + h.proto)
        }
      }, (g: string) => g)
      if (this.hosts.length === 0) {
        ListItem() {
          Column({ space: 6 }) {
            Text(this.t('host.empty')).id('hosts/empty').fontSize(13).fontColor(this.th('#6B7078'))
          }.width('100%').padding({ top: 60 })
        }
      }
      if (this.hosts.length > 0) {
        ListItem() {
          Text(this.t('host.noMatch')).id('hosts/no-match').fontSize(13).fontColor(this.th('#6B7078'))
            .width('100%').padding({ top: 20 })
            .visibility(this.anyMatch() ? Visibility.None : Visibility.Visible)
        }
      }
    }
    .id('host-grid/list').layoutWeight(1).width('100%').padding({ left: 22, right: 22, bottom: 16 })
  }

  @Builder
  pcNavItem(label: string, id: string, icon: Resource, enabled: boolean, onTap: () => void) {
    Row({ space: 12 }) {
      Image(icon).width(17).height(17)
        
      Text(label).fontSize(14)
        .fontColor(this.pcNav === label && enabled ? Color.White : this.th('#C7CBD1'))
        .fontWeight(this.pcNav === label && enabled ? FontWeight.Medium : FontWeight.Normal)
      Blank()
    }
    .id(id)
    .width('100%').height(38).padding({ left: 12, right: 12 })
    .borderRadius(8)
    .backgroundColor(this.pcNav === label && enabled ? this.th('#2A2D33') : Color.Transparent)
    .opacity(enabled ? 1 : 0.45)
    .onClick(() => { if (enabled) { onTap(); } })
  }


  @Builder
  pcTopBar() {
    Row({ space: 10 }) {
      // 左：九宫格 + 新建
      Image($r('app.media.ic_grid')).width(16).height(16)
      Image($r('app.media.ic_plus')).width(16).height(16)
      Blank()
      // 右：一排工具图标（占位按钮，id 便于后续接功能）
      Image($r('app.media.ic_sort')).id('top/order').width(16).height(16)
        .onClick(() => {
          this.hostSort = this.hostSort === 'manual' ? 'name' : (this.hostSort === 'name' ? 'ip' : 'manual');
          this.hint('sort: ' + this.hostSort);
          this.savePrefs();
        })
      Image($r('app.media.ic_columns')).id('top/paste').width(16).height(16)
        .onClick(() => { this.pasteIntoInput(); })
      Image($r('app.media.ic_terminal')).id('top/terminal').width(16).height(16)
        .onClick(() => { this.pcNav = '本地终端'; })
      Image($r('app.media.ic_search')).id('top/search').width(16).height(16)
        .onClick(() => { this.openPalette(); })
      Image($r('app.media.ic_sparkles')).id('top/ai').width(16).height(16)
        .onClick(() => { this.aiOpen = true; })
      Image($r('app.media.ic_bell')).id('top/notice').width(16).height(16)
        .onClick(() => { this.pcNav = '会话日志'; this.reloadLogs(); })
      Image($r('app.media.ic_settings')).id('top/settings').width(16).height(16)
      Image($r('app.media.ic_play')).id('top/new-session').width(16).height(16)
        .onClick(() => { this.openNewSessionFromToolbar(); })
      Image($r('app.media.ic_sort')).id('top/refresh').width(16).height(16)
        .onClick(() => { this.reload(); })
      if (this.toolbarHint.length > 0) {
        Text(this.toolbarHint).id('top/hint').fontSize(10).fontColor(this.th('#8A8F98'))
          .onClick(() => { this.dismissHint(); })
      }
    }
    .width('100%').height(38).padding({ left: 14, right: 14 })
    .backgroundColor(this.th('#0C0D10'))
    .border({ width: { bottom: 1 }, color: this.th('#1E2126') })
  }

  @Builder
  pcSidebar() {
    Column({ space: 2 }) {
      // 品牌
      Row({ space: 8 }) {
        Text('M').fontSize(18).fontWeight(FontWeight.Bold).fontColor('#12141A')
          .width(28).height(28).textAlign(TextAlign.Center).borderRadius(8)
          .backgroundColor('#3DDC97')
        Text('motty').fontSize(20).fontWeight(FontWeight.Bold).fontColor(Color.White)
        Blank()
      }.width('100%').padding({ left: 14, right: 14, top: 18, bottom: 18 })

      this.pcNavItem('主机', 'nav/hosts', $r('app.media.ic_hosts'), true, () => { this.pcNav = '主机'; this.showHosts = true; })
      this.pcNavItem('工作区', 'nav/workspace', $r('app.media.ic_workspace'), true, () => { this.pcNav = '工作区'; })
      this.pcNavItem('密钥链', 'nav/keys', $r('app.media.ic_keys'), true, () => { this.pcNav = '密钥链'; })
      this.pcNavItem('跳板路由', 'nav/jump', $r('app.media.ic_jump'), true, () => { this.pcNav = '跳板路由'; })
      this.pcNavItem('快捷命令', 'nav/snippets', $r('app.media.ic_snippets'), true, () => { this.pcNav = '快捷命令'; this.reloadSnippets(); })
      this.pcNavItem('端口转发', 'fwd/open', $r('app.media.ic_forward'), true, () => { this.fwdOpen = true; this.reloadRules(); })
      this.pcNavItem('已知主机', 'known/open', $r('app.media.ic_known'), true, () => { this.openKnownHosts(); })
      this.pcNavItem('调试', 'diag/open', $r('app.media.ic_monitor'), true, () => { this.diagOpen = true; })
      this.pcNavItem('会话日志', 'nav/logs', $r('app.media.ic_logs'), true, () => { this.pcNav = '会话日志'; this.reloadLogs(); })
      this.pcNavItem('笔记', 'nav/notes', $r('app.media.ic_notes'), true, () => { this.pcNav = '笔记'; this.reloadNotes(); })

      Blank()
      // 底部固定项（对照参照图：本地终端 / 设置）
      this.pcNavItem('本地终端', 'nav/local-terminal', $r('app.media.ic_terminal'), true, () => {
        this.pcNav = '本地终端';
      })
      this.pcNavItem('设置', 'nav/settings', $r('app.media.ic_settings'), true, () => { this.settingsOpen = true; })
      Row({ space: 8 }) {
        Button(this.t('top.lang')).id('ui/lang').height(26).fontSize(11)
          .backgroundColor(this.th('#1E2127')).fontColor(this.th('#9AA0A6'))
          .onClick(() => { this.toggleLang(); })
        Blank()
        Text(this.lang === 'zh' ? 'RDP: 实验' : 'RDP: exp').id('rdp/experimental-badge').fontSize(10).fontColor('#E0A458')
      }.width('100%').padding({ left: 12, right: 12, top: 6, bottom: 12 })
    }
    .width(210).height('100%').backgroundColor(this.th('#101114'))
    .border({ width: { right: 1 }, color: this.th('#22252A') })
  }

  @Builder
  pcHeader() {
    Row({ space: 10 }) {
      TextInput({ text: this.hostQuery, placeholder: this.lang === 'zh' ? '搜索主机或 ssh user@hostname…' : 'Search hosts or ssh user@hostname…' })
        .id('hosts/search')
        .layoutWeight(1).height(38)
        .backgroundColor(this.th('#1E2127')).fontColor(this.th('#E8EAED')).placeholderColor(this.th('#6B7078'))
        .borderRadius(8)
        .onChange((v: string) => { this.hostQuery = v; })
      Button(this.t('host.connect')).id('hosts/connect').height(38).fontSize(14)
        .backgroundColor(this.th('#1E2127')).fontColor(this.th('#C7CBD1'))
        .onClick(() => {
          for (let i = 0; i < this.hosts.length; i++) {
            if (this.matchesQuery(this.hosts[i])) { this.openSession(this.hosts[i].label, i); return; }
          }
        })
      Button(this.lang === 'zh' ? '导入/导出' : 'Import/Export').id('hosts/import-export')
        .height(38).fontSize(14).backgroundColor(this.th('#1E2127')).fontColor(this.th('#C7CBD1'))
        .bindMenu([
          { value: this.lang === 'zh' ? '导入目录…' : 'Import catalog…', action: () => { this.importCatalog(); } },
          { value: this.lang === 'zh' ? '导出目录…' : 'Export catalog…', action: () => { this.exportCatalog(); } }
        ])
      Button(this.t('top.newHost')).id('shell/add-host').height(38).fontSize(14)
        .fontWeight(FontWeight.Medium)
        .backgroundColor(this.th('#E8EAED')).fontColor('#12141A')
        .onClick(() => { this.resetForm(); this.showDialog = true; })
    }
    .width('100%').padding({ left: 22, right: 22, top: 16, bottom: 10 })
  }

  @Builder
  pcChips() {
    Row({ space: 10 }) {
      Text(this.selectAll ? '☑' : '☐').id('chips/select-all').fontSize(16).width(20)
        .textAlign(TextAlign.Center).fontColor(this.selectAll ? '#3DDC97' : this.th('#6B7078'))
        
        .opacity(this.selectAll ? 1 : 0.45)
        .onClick(() => {
          this.selectAll = !this.selectAll;
          if (this.selectAll) {
            const ids: string[] = [];
            for (let i = 0; i < this.hosts.length; i++) { ids.push(this.hosts[i].id); }
            this.selectedIds = ids;
          } else {
            this.selectedIds = [];
          }
        })
      Text((this.lang === 'zh' ? '全部 ' : 'All ') + this.hosts.length).id('chip/all').fontSize(12)
        .fontColor(this.groupFilter.length === 0 ? '#12141A' : Color.White)
        .backgroundColor(this.groupFilter.length === 0 ? this.th('#E8EAED') : this.th('#2A2D33'))
        .padding({ left: 12, right: 12, top: 5, bottom: 5 }).borderRadius(14)
        .onClick(() => { this.groupFilter = ''; })
      Text(this.lang === 'zh' ? '全部协议' : 'All proto').id('chips/proto-all').fontSize(12)
        .fontColor(this.protoFilter.length === 0 ? '#12141A' : this.th('#C7CBD1'))
        .backgroundColor(this.protoFilter.length === 0 ? this.th('#E8EAED') : this.th('#1E2127'))
        .padding({ left: 10, right: 10, top: 5, bottom: 5 }).borderRadius(14)
        .onClick(() => { this.protoFilter = ''; })
      Text('SSH ' + this.countProto('ssh')).id('chips/proto-ssh').fontSize(12)
        .fontColor(this.protoFilter === 'ssh' ? '#12141A' : this.th('#C7CBD1'))
        .backgroundColor(this.protoFilter === 'ssh' ? this.th('#E8EAED') : this.th('#1E2127'))
        .padding({ left: 10, right: 10, top: 5, bottom: 5 }).borderRadius(14)
        .onClick(() => { this.protoFilter = 'ssh'; })
      Text('RDP ' + this.countProto('rdp')).id('chips/proto-rdp').fontSize(12)
        .fontColor(this.protoFilter === 'rdp' ? '#12141A' : this.th('#C7CBD1'))
        .backgroundColor(this.protoFilter === 'rdp' ? this.th('#E8EAED') : this.th('#1E2127'))
        .padding({ left: 10, right: 10, top: 5, bottom: 5 }).borderRadius(14)
        .onClick(() => { this.protoFilter = 'rdp'; })
      Text('VNC ' + this.countProto('vnc')).id('chips/proto-vnc').fontSize(12)
        .fontColor(this.protoFilter === 'vnc' ? '#12141A' : this.th('#C7CBD1'))
        .backgroundColor(this.protoFilter === 'vnc' ? this.th('#E8EAED') : this.th('#1E2127'))
        .padding({ left: 10, right: 10, top: 5, bottom: 5 }).borderRadius(14)
        .onClick(() => { this.protoFilter = 'vnc'; })
      ForEach(this.sections(), (g: string) => {
        Text(this.sectionLabel(g) + ' ' + this.countGroup(g)).id('chip/group/' + g).fontSize(12)
          .fontColor(this.groupFilter === this.sectionLabel(g) ? '#12141A' : this.th('#C7CBD1'))
          .backgroundColor(this.groupFilter === this.sectionLabel(g) ? this.th('#E8EAED') : this.th('#1E2127'))
          .padding({ left: 12, right: 12, top: 5, bottom: 5 }).borderRadius(14)
          .onClick(() => { this.groupFilter = this.sectionLabel(g); })
      }, (g: string) => 'chip-' + g)
      if (this.selectedIds.length > 0) {
        Text((this.lang === 'zh' ? '已选 ' : 'Selected ') + this.selectedIds.length).fontSize(12)
          .fontColor('#E0A458').padding({ left: 8 })
        Button(this.lang === 'zh' ? '批量删除' : 'Delete').id('chips/delete-selected').height(24).fontSize(11)
          .backgroundColor('#3A2226').fontColor('#E08A8A')
          .onClick(() => { this.askDeleteSelected(); })
        Button(this.lang === 'zh' ? '清除' : 'Clear').id('chips/clear-selection').height(24).fontSize(11)
          .backgroundColor(this.th('#1E2127')).fontColor(this.th('#C7CBD1'))
          .onClick(() => { this.clearSelection(); })
      }
      Blank()
      Image($r('app.media.ic_chevron_down')).id('chips/collapse').width(15).height(15)
        .onClick(() => { this.collapsedGroups = this.sections(); })
      Image($r('app.media.ic_chevron_right')).id('chips/expand').width(15).height(15)
        .onClick(() => { this.collapsedGroups = []; })
      Image($r('app.media.ic_rows')).id('view/list').width(16).height(16)
        .onClick(() => { this.hostView = 'list'; this.savePrefs(); })
      Image($r('app.media.ic_grid')).id('view/grid').width(16).height(16)
        .onClick(() => { this.hostView = 'grid'; this.savePrefs(); })
      Image($r('app.media.ic_sort')).id('view/sort').width(16).height(16)
        .onClick(() => { this.hostSort = this.hostSort === 'manual' ? 'name' : (this.hostSort === 'name' ? 'ip' : 'manual'); this.savePrefs(); })
      Image($r('app.media.ic_sliders')).id('view/order').width(16).height(16)
        .onClick(() => { this.viewMenuOpen = true; })
    }.width('100%').padding({ left: 22, right: 22, bottom: 8 })
  }

  private anyMatch(): boolean {
    for (let i = 0; i < this.hosts.length; i++) {
      if (this.matchesQuery(this.hosts[i])) { return true; }
    }
    return false;
  }

  private countProto(proto: string): number {
    let n = 0;
    for (let i = 0; i < this.hosts.length; i++) {
      if (this.hosts[i].proto === proto) { n++; }
    }
    return n;
  }


  private hostGroupOf(h: HostItem): string {
    return h.group.length > 0 ? h.group : '';
  }


  private openRenameGroup(g: string): void {
    this.groupRenameOld = g;
    // 不预填旧名：预填后用户/用例直接输入会变成"旧名+新名"（实测 G1 -> G1G2）。
    // 旧名放在 placeholder 里，输入框保持空的"重命名"语义。
    this.groupRenameText = '';
    this.groupRenameError = '';
    this.groupRenameOpen = true;
  }

  private async submitRenameGroup(): Promise<void> {
    const next: string = this.groupRenameText.trim();
    if (next.length === 0) {
      this.groupRenameError = this.lang === 'zh' ? '分组名不能为空' : 'group name required';
      return;
    }
    if (next === this.sectionLabel(this.groupRenameOld)) {
      this.groupRenameOpen = false;
      return;
    }
    this.groupRenameError = '';
    if (this.store === null) { return; }
    const pred = new relationalStore.RdbPredicates('hosts');
    pred.equalTo('grp', this.groupRenameOld);
    await this.store.update({ 'grp': next }, pred);
    this.groupRenameOpen = false;
    await this.settleStore();
    await this.reload();
  }

  private askDeleteGroup(g: string): void {
    this.groupDelName = g;
  }

  private async confirmDeleteGroup(): Promise<void> {
    const g: string = this.groupDelName;
    this.groupDelName = '';
    if (g.length === 0 || this.store === null) { return; }
    // 删除分组 = 把组内主机移回默认组（主机本身不删）
    const pred = new relationalStore.RdbPredicates('hosts');
    pred.equalTo('grp', g);
    await this.store.update({ 'grp': '' }, pred);
    this.pinnedGroups = this.pinnedGroups.filter((x: string) => x !== g);
    this.collapsedGroups = this.collapsedGroups.filter((x: string) => x !== g);
    await this.settleStore();
    await this.reload();
  }


  // 分组上移/下移：按"当前显示顺序"交换相邻两项，并持久化
  private moveGroupFromMenu(dir: number): void {
    const g: string = this.groupMenuTarget;
    this.groupMenu = '';
    if (g.length === 0) { return; }
    this.moveGroup(g, dir);
  }


  // 分组顺序存 DB（不用 preferences：实测 prefs 文件损坏后（.broken）写入不会落盘，
  // 重启读到空值；DB 是应用自己的存储，更可控）
  private async saveGroupOrderToDb(): Promise<void> {
    if (this.store === null) { return; }
    const v: string = this.groupOrder.join('\u0001');
    try {
      const pred = new relationalStore.RdbPredicates('ui_state');
      pred.equalTo('k', 'groupOrder');
      const rs = await this.store.query(pred, ['k']);
      const exists: boolean = rs.goToNextRow();
      rs.close();
      if (exists) {
        const p2 = new relationalStore.RdbPredicates('ui_state');
        p2.equalTo('k', 'groupOrder');
        await this.store.update({ 'v': v } as relationalStore.ValuesBucket, p2);
      } else {
        await this.store.insert('ui_state', { 'k': 'groupOrder', 'v': v } as relationalStore.ValuesBucket);
      }
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'saveGroupOrder failed: %{public}s', JSON.stringify(e));
    }
  }

  private async loadGroupOrderFromDb(): Promise<void> {
    if (this.store === null) { return; }
    try {
      const pred = new relationalStore.RdbPredicates('ui_state');
      pred.equalTo('k', 'groupOrder');
      const rs = await this.store.query(pred, ['v']);
      if (rs.goToNextRow()) {
        const v: string = rs.getString(0);
        this.groupOrder = v.length === 0 ? [] : v.split('\u0001').filter((x: string) => x.length > 0);
      }
      rs.close();
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'loadGroupOrder failed: %{public}s', JSON.stringify(e));
    }
  }


  // 通用设置存取：优先 DB（preferences 在设备上出现过 .broken，写入不落盘），
  // preferences 仅作向后兼容/兜底。
  private async setUiState(k: string, v: string): Promise<void> {
    if (this.store === null) { return; }
    try {
      const pred = new relationalStore.RdbPredicates('ui_state');
      pred.equalTo('k', k);
      const rs = await this.store.query(pred, ['k']);
      const exists: boolean = rs.goToNextRow();
      rs.close();
      if (exists) {
        const p2 = new relationalStore.RdbPredicates('ui_state');
        p2.equalTo('k', k);
        await this.store.update({ 'v': v } as relationalStore.ValuesBucket, p2);
      } else {
        await this.store.insert('ui_state', { 'k': k, 'v': v } as relationalStore.ValuesBucket);
      }
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'setUiState failed k=%{public}s', k);
    }
  }

  private async getUiState(k: string): Promise<string> {
    if (this.store === null) { return ''; }
    try {
      const pred = new relationalStore.RdbPredicates('ui_state');
      pred.equalTo('k', k);
      const rs = await this.store.query(pred, ['v']);
      let v: string = '';
      if (rs.goToNextRow()) { v = rs.getString(0); }
      rs.close();
      return v;
    } catch (e) {
      return '';
    }
  }


  private changeTermFont(delta: number): void {
    const next: number = this.termFontSize + delta;
    if (next < 10 || next > 24) { return; }
    this.termFontSize = next;
    this.savePrefs();
  }

  private moveGroup(g: string, dir: number): void {
    const shown: string[] = this.sections();
    const idx: number = shown.indexOf(g);
    if (idx < 0) { return; }
    const to: number = idx + dir;
    if (to < 0 || to >= shown.length) { return; }
    const next: string[] = shown.slice();
    const tmp: string = next[idx];
    next[idx] = next[to];
    next[to] = tmp;
    this.groupOrder = next;
    this.saveGroupOrderToDb();
    this.savePrefs();
    this.groupMenu = '';
  }

  private isPinned(g: string): boolean {
    return this.pinnedGroups.indexOf(g) >= 0;
  }

  private togglePin(g: string): void {
    if (this.isPinned(g)) {
      this.pinnedGroups = this.pinnedGroups.filter((x: string) => x !== g);
    } else {
      this.pinnedGroups = this.pinnedGroups.concat([g]);
    }
    this.savePrefs();
  }

  private sections(): string[] {
    const out: string[] = [];
    for (let i = 0; i < this.hosts.length; i++) {
      const g = this.hostGroupOf(this.hosts[i]);
      if (!out.includes(g)) { out.push(g); }
    }
    // 排序优先级：固定分组 > 用户顺序（groupOrder）> 原有顺序（稳定排序）
    out.sort((a: string, b: string) => {
      const pa: number = this.isPinned(a) ? 0 : 1;
      const pb: number = this.isPinned(b) ? 0 : 1;
      if (pa !== pb) { return pa - pb; }
      const ia: number = this.groupOrder.indexOf(a);
      const ib: number = this.groupOrder.indexOf(b);
      const va: number = ia < 0 ? this.groupOrder.length + 1000 : ia;
      const vb: number = ib < 0 ? this.groupOrder.length + 1000 : ib;
      return va - vb;
    });
    return out;
  }

  private sectionLabel(g: string): string {
    return g.length > 0 ? g : this.t('host.groupDefault');
  }

  private countGroup(g: string): number {
    let n = 0;
    for (let i = 0; i < this.hosts.length; i++) {
      if (this.hostGroupOf(this.hosts[i]) === g) { n++; }
    }
    return n;
  }

  private tagList(h: HostItem): string[] {
    if (h.tags.length === 0) { return []; }
    return h.tags.split(',').map((t: string) => t.trim()).filter((t: string) => t.length > 0);
  }

  private isCollapsed(g: string): boolean {
    return this.collapsedGroups.includes(g);
  }

  private toggleGroup(g: string): void {
    if (this.isCollapsed(g)) {
      this.collapsedGroups = this.collapsedGroups.filter((x: string) => x !== g);
    } else {
      this.collapsedGroups = this.collapsedGroups.concat([g]);
    }
    // 官方 savedHostGroup.Collapsed 是持久化的：折叠状态要跨重启保持
    this.savePrefs();
  }


  private osIconKey(h: HostItem): string {
    const probe: string = (h.label + ' ' + h.address + ' ' + h.tags).toLowerCase();
    if (probe.includes('oracle')) { return 'os_oraclelinux'; }
    if (probe.includes('ubuntu')) { return 'os_ubuntu'; }
    if (probe.includes('debian')) { return 'os_debian'; }
    if (probe.includes('centos')) { return 'os_centos'; }
    if (probe.includes('redhat') || probe.includes('rhel')) { return 'os_redhat'; }
    if (probe.includes('windows')) { return 'os_windows'; }
    if (probe.includes('nas') || probe.includes('synology')) { return 'os_synology'; }
    if (probe.includes('openwrt')) { return 'os_openwrt'; }
    if (probe.includes('alpine')) { return 'os_alpine'; }
    if (probe.includes('arch')) { return 'os_arch'; }
    if (probe.includes('freebsd')) { return 'os_freebsd'; }
    if (probe.includes('esxi') || probe.includes('vmware')) { return 'os_esxi'; }
    if (probe.includes('proxmox')) { return 'os_proxmox'; }
    if (probe.includes('fedora')) { return 'os_fedora'; }
    if (probe.includes('kali')) { return 'os_kali'; }
    return '';
  }

  // ArkTS 的 @Builder 内对 Resource 判空不可靠，拆成"布尔"与"取值"两个方法
  private hasOsIcon(h: HostItem): boolean {
    return this.osIconKey(h).length > 0;
  }


  private osIcon(h: HostItem): Resource | null {
    const probe: string = (h.label + ' ' + h.address + ' ' + h.tags).toLowerCase();
    if (probe.includes('oracle')) { return $r('app.media.os_oraclelinux'); }
    if (probe.includes('ubuntu')) { return $r('app.media.os_ubuntu'); }
    if (probe.includes('debian')) { return $r('app.media.os_debian'); }
    if (probe.includes('centos')) { return $r('app.media.os_centos'); }
    if (probe.includes('redhat') || probe.includes('rhel')) { return $r('app.media.os_redhat'); }
    if (probe.includes('windows')) { return $r('app.media.os_windows'); }
    if (probe.includes('nas') || probe.includes('synology')) { return $r('app.media.os_synology'); }
    if (probe.includes('openwrt')) { return $r('app.media.os_openwrt'); }
    if (probe.includes('alpine')) { return $r('app.media.os_alpine'); }
    if (probe.includes('arch')) { return $r('app.media.os_arch'); }
    if (probe.includes('freebsd')) { return $r('app.media.os_freebsd'); }
    if (probe.includes('esxi') || probe.includes('vmware')) { return $r('app.media.os_esxi'); }
    if (probe.includes('proxmox')) { return $r('app.media.os_proxmox'); }
    if (probe.includes('fedora')) { return $r('app.media.os_fedora'); }
    if (probe.includes('kali')) { return $r('app.media.os_kali'); }
    return null;
  }

  // 按当前排序返回主机下标（manual 保持插入顺序）
  private sortedHosts(group: string): HostItem[] {
    const list: HostItem[] = this.hosts.filter((h: HostItem) => this.hostGroupOf(h) === group && this.matchesQuery(h));
    if (this.hostSort === 'name') {
      list.sort((a: HostItem, b: HostItem) => a.label.localeCompare(b.label));
    } else if (this.hostSort === 'ip') {
      list.sort((a: HostItem, b: HostItem) => a.address.localeCompare(b.address));
    }
    return list;
  }


  @Builder
  hostGridView() {
    Scroll() {
      Column({ space: 10 }) {
        ForEach(this.sections().filter((g: string) =>
          this.groupFilter.length === 0 || this.sectionLabel(g) === this.groupFilter), (g: string) => {
          // 分组表头
          Row({ space: 8 }) {
            Image(this.isCollapsed(g) ? $r('app.media.ic_chevron_right') : $r('app.media.ic_chevron_down'))
              .width(14).height(14)
            Text(this.sectionLabel(g)).fontSize(13).fontColor(this.th('#C7CBD1')).fontWeight(FontWeight.Medium)
            Text('(' + this.countGroup(g) + ')').fontSize(12).fontColor(this.th('#6B7078'))
            Blank()
          }
          .width('100%').height(34).padding({ left: 6, right: 6 })
          .onClick(() => { this.toggleGroup(g); })
          if (!this.isCollapsed(g)) {
            Flex({ wrap: FlexWrap.Wrap }) {
              ForEach(this.sortedHosts(g), (h: HostItem) => {
                Column({ space: 6 }) {
                  Row({ space: 10 }) {
                    if (this.hasOsIcon(h)) {
                      Image(this.osImage(h)).width(24).height(24)
                    } else {
                      Text(h.label.substring(0, 1).toUpperCase()).fontSize(14).fontWeight(FontWeight.Bold)
                        .fontColor(Color.White).width(32).height(32).textAlign(TextAlign.Center)
                        .borderRadius(16).backgroundColor(h.color.length > 0 ? h.color : this.th('#2A2D33'))
                    }
                    Column({ space: 3 }) {
                      Text(h.label).fontSize(14).fontColor(this.th('#E8EAED')).maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                      Text(h.user).fontSize(11).fontColor(this.th('#8A8F98'))
                      Row({ space: 4 }) {
                        Text(this.iconGlyph(h.icon)).id('host-icon-card/' + h.id).fontSize(11).fontColor('#E0A458')
                        Text(this.lastUsedText(h)).id('host-lastused-card/' + h.id).fontSize(10).fontColor(this.th('#6B7078'))
                      }.width('100%')
                    }.alignItems(HorizontalAlign.Start).layoutWeight(1)
                  }.width('100%')
                  Row({ space: 6 }) {
                    Text(h.address + (h.port.length > 0 ? ':' + h.port : '')).fontSize(11)
                      .fontColor(this.th('#6B7078')).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                      .layoutWeight(1)
                    ForEach(this.tagList(h), (tg: string) => {
                      Text(tg).fontSize(10).fontColor(this.th('#C7CBD1'))
                        .padding({ left: 8, right: 8, top: 2, bottom: 2 })
                        .backgroundColor(this.th('#23262B')).borderRadius(10)
                    }, (tg: string) => h.id + 'g' + tg)
                  }.width('100%')
                }
                .id('host-card/' + h.id)
                .width(280).height(64).padding({ left: 12, right: 12, top: 8, bottom: 8 })
                .borderRadius(10).backgroundColor(this.th('#1C1F24'))
                .margin({ right: 12, bottom: 12 })
                .onClick(() => {
                  const idx = this.hosts.findIndex((x: HostItem) => x.id === h.id);
                  if (idx >= 0) { this.openSession(h.label, idx); }
                })
              }, (h: HostItem) => h.id + '|' + h.label + '|' + h.address + '|' + h.user + '|' + h.port + '|' + h.group + '|' + h.tags + '|' + h.color + '|' + h.proto)
            }.width('100%')
          }
        }, (g: string) => 'grid-' + g)
      }.width('100%').padding({ left: 22, right: 22, bottom: 16 })
    }.id('host-grid/view').layoutWeight(1).width('100%').align(Alignment.Top)
  }


  private osImage(h: HostItem): Resource {
    const k: string = this.osIconKey(h);
    if (k === 'os_oraclelinux') { return $r('app.media.os_oraclelinux'); }
    if (k === 'os_ubuntu') { return $r('app.media.os_ubuntu'); }
    if (k === 'os_debian') { return $r('app.media.os_debian'); }
    if (k === 'os_centos') { return $r('app.media.os_centos'); }
    if (k === 'os_redhat') { return $r('app.media.os_redhat'); }
    if (k === 'os_windows') { return $r('app.media.os_windows'); }
    if (k === 'os_synology') { return $r('app.media.os_synology'); }
    if (k === 'os_openwrt') { return $r('app.media.os_openwrt'); }
    if (k === 'os_alpine') { return $r('app.media.os_alpine'); }
    if (k === 'os_arch') { return $r('app.media.os_arch'); }
    if (k === 'os_freebsd') { return $r('app.media.os_freebsd'); }
    if (k === 'os_esxi') { return $r('app.media.os_esxi'); }
    if (k === 'os_proxmox') { return $r('app.media.os_proxmox'); }
    if (k === 'os_fedora') { return $r('app.media.os_fedora'); }
    if (k === 'os_kali') { return $r('app.media.os_kali'); }
    return $r('app.media.ic_hosts');
  }


  private isSelected(h: HostItem): boolean {
    return this.selectedIds.includes(h.id);
  }

  private toggleSelect(h: HostItem): void {
    if (this.isSelected(h)) {
      this.selectedIds = this.selectedIds.filter((x: string) => x !== h.id);
    } else {
      this.selectedIds = this.selectedIds.concat([h.id]);
    }
  }

  private selectGroup(g: string): void {
    const ids: string[] = [];
    for (let i = 0; i < this.hosts.length; i++) {
      if (this.hostGroupOf(this.hosts[i]) === g) { ids.push(this.hosts[i].id); }
    }
    let merged: string[] = this.selectedIds.slice();
    for (let i = 0; i < ids.length; i++) {
      if (!merged.includes(ids[i])) { merged.push(ids[i]); }
    }
    this.selectedIds = merged;
  }

  private clearSelection(): void {
    this.selectedIds = [];
  }

  // 批量删除：主机 + known_hosts + 保险库口令（照官方 DeleteHost 语义）
  private async deleteSelected(): Promise<void> {
    if (this.store === null || this.selectedIds.length === 0) { return; }
    const ids: string[] = this.selectedIds.slice();
    for (let i = 0; i < ids.length; i++) {
      const idx = this.hosts.findIndex((x: HostItem) => x.id === ids[i]);
      if (idx < 0) { continue; }
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
    }
    this.selectedIds = [];
    await this.reload();
    await this.reloadRules();
  }







  // ---------------- 主机目录导入/导出（官方格式 motty-host-catalog v4） ----------------
  private catalogJson(): string {
    const hosts: CatalogHost[] = [];
    for (let i = 0; i < this.hosts.length; i++) {
      const h = this.hosts[i];
      const tags: string[] = this.tagList(h);
      hosts.push({
        id: h.id, label: h.label, group: h.group, tags: tags,
        color: h.color, address: h.address, user: h.user,
        port: Number.parseInt(h.port, 10) || 0
      } as CatalogHost);
    }
    const groups: CatalogGroup[] = [];
    const seen: string[] = this.sections();
    for (let i = 0; i < seen.length; i++) {
      groups.push({ name: this.sectionLabel(seen[i]), collapsed: this.isCollapsed(seen[i]) } as CatalogGroup);
    }
    const doc: CatalogDoc = {
      format: 'motty-host-catalog', version: 4, hosts: hosts, groups: groups
    };
    return JSON.stringify(doc, null, 2);
  }

  private async exportCatalog(): Promise<void> {
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      const p = new picker.DocumentViewPicker(ctx);
      const opts = new picker.DocumentSaveOptions();
      opts.newFileNames = ['motty-hosts.json'];
      opts.fileSuffixChoices = ['.json'];
      const uris = await p.save(opts);
      if (uris.length === 0) { return; }
      const f = fileIo.openSync(uris[0], fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(f.fd, this.catalogJson());
      fileIo.closeSync(f);
      this.probeText = (this.lang === 'zh' ? '已导出 ' : 'Exported ') + this.hosts.length + ' -> ' + uris[0];
      hilog.info(DOMAIN, TAG, 'catalog exported to %{public}s', uris[0]);
    } catch (e) {
      this.probeText = 'export failed: ' + JSON.stringify(e);
      hilog.error(DOMAIN, TAG, 'catalog export failed: %{public}s', JSON.stringify(e));
    }
  }

  private async importCatalog(): Promise<void> {
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      const p = new picker.DocumentViewPicker(ctx);
      const opts = new picker.DocumentSelectOptions();
      opts.maxSelectNumber = 1;
      opts.fileSuffixFilters = ['.json'];
      const uris = await p.select(opts);
      if (uris.length === 0) { return; }
      const f = fileIo.openSync(uris[0], fileIo.OpenMode.READ_ONLY);
      const stat = fileIo.statSync(f.fd);
      const buf = new ArrayBuffer(stat.size);
      fileIo.readSync(f.fd, buf);
      fileIo.closeSync(f);
      const text: string = util.TextDecoder.create('utf-8').decodeToString(new Uint8Array(buf));
      const doc: Record<string, Object> = JSON.parse(text) as Record<string, Object>;
      const fmt: string = String(doc['format'] ?? '');
      const ver: number = Number(doc['version'] ?? 0);
      if (fmt !== 'motty-host-catalog') {
        this.probeText = this.lang === 'zh' ? '不是 Motty 主机目录文件' : 'not a Motty catalog file';
        return;
      }
      if (ver > 4) {
        this.probeText = this.lang === 'zh' ? '目录版本过新，请先升级' : 'catalog version too new';
        return;
      }
      const list: object[] = (doc['hosts'] ?? []) as object[];
      let added = 0;
      let dup = 0;
      for (let i = 0; i < list.length; i++) {
        const it: Record<string, Object> = list[i] as Record<string, Object>;
        const label: string = String(it['label'] ?? '');
        const address: string = String(it['address'] ?? '');
        const port: string = String(it['port'] ?? 22);
        if (label.length === 0 || address.length === 0 || this.store === null) { continue; }
        let exists = false;
        for (let k = 0; k < this.hosts.length; k++) {
          if (this.hosts[k].label === label && this.hosts[k].address === address &&
              this.hosts[k].port === port) { exists = true; break; }
        }
        if (exists) { dup++; continue; }
        const tagsRaw: object[] = (it['tags'] ?? []) as object[];
        let tags: string = '';
        for (let t = 0; t < tagsRaw.length; t++) {
          tags = tags.length === 0 ? String(tagsRaw[t]) : (tags + ',' + String(tagsRaw[t]));
        }
        const bucket: relationalStore.ValuesBucket = {
          'id': String(Date.now()) + '_' + i,
          'label': label, 'address': address,
          'usr': String(it['user'] ?? ''),
          'port': port, 'proto': 'ssh',
          'grp': String(it['group'] ?? ''),
          'tags': tags,
          'color': String(it['color'] ?? '')
        };
        await this.store.insert('hosts', bucket);
        added++;
      }
      await this.reload();
      this.probeText = (this.lang === 'zh' ? '导入完成：新增 ' : 'imported: ') + added +
        (this.lang === 'zh' ? '，重复 ' : ', duplicates ') + dup;
    } catch (e) {
      this.probeText = 'import failed: ' + JSON.stringify(e);
      hilog.error(DOMAIN, TAG, 'catalog import failed: %{public}s', JSON.stringify(e));
    }
  }


  // 可自动化版本：直接读写应用沙箱文件（供用例驱动），与 UI 版共用同一份 JSON 结构
  private async exportCatalogToSandbox(): Promise<void> {
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      const path: string = ctx.cacheDir + '/motty-hosts.json';
      const f = fileIo.openSync(path, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(f.fd, this.catalogJson());
      fileIo.closeSync(f);
      const stat = fileIo.statSync(path);
      this.catalogResult = 'catalog-export: ' + path + ' (' + stat.size + ' bytes, ' + this.hosts.length + ' hosts)';
    } catch (e) {
      this.catalogResult = 'catalog-export failed: ' + JSON.stringify(e);
    }
  }


  // 会话日志导出到沙箱（JSON）：给"把日志带走分析"一个可用出口
  private exportLogsToSandbox(): void {
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      const path: string = ctx.cacheDir + '/motty-session-logs.json';
      const rows: string[] = [];
      for (let i = 0; i < this.logs.length; i++) {
        const it: LogItem = this.logs[i];
        rows.push('{"id":"' + it.id + '","label":"' + it.label.replace(/"/g, '\\"') +
          '","address":"' + it.address + '","proto":"' + it.proto + '","startedAt":' + it.startedAt + '}');
      }
      const text: string = '{"format":"motty-session-logs","version":1,"count":' + this.logs.length +
        ',"logs":[' + rows.join(',') + ']}';
      const f = fileIo.openSync(path, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(f.fd, text);
      fileIo.closeSync(f);
      const stat = fileIo.statSync(path);
      this.logsExport = 'logs-export: ' + path + ' (' + stat.size + ' bytes, ' + this.logs.length + ' logs)';
    } catch (e) {
      this.logsExport = 'logs-export failed: ' + JSON.stringify(e);
    }
  }

  private async importCatalogFromSandbox(): Promise<void> {
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      const path: string = ctx.cacheDir + '/motty-hosts.json';
      const f = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
      const stat = fileIo.statSync(f.fd);
      const buf = new ArrayBuffer(stat.size);
      fileIo.readSync(f.fd, buf);
      fileIo.closeSync(f);
      const text: string = util.TextDecoder.create('utf-8').decodeToString(new Uint8Array(buf));
      const doc: Record<string, Object> = JSON.parse(text) as Record<string, Object>;
      const fmt: string = String(doc['format'] ?? '');
      const ver: number = Number(doc['version'] ?? 0);
      if (fmt !== 'motty-host-catalog') {
        this.catalogResult = 'catalog-import: bad format ' + fmt;
        return;
      }
      if (ver > 4) {
        this.catalogResult = 'catalog-import: version too new ' + ver;
        return;
      }
      const list: object[] = (doc['hosts'] ?? []) as object[];
      let added = 0;
      let dup = 0;
      for (let i = 0; i < list.length; i++) {
        const it: Record<string, Object> = list[i] as Record<string, Object>;
        const label: string = String(it['label'] ?? '');
        const address: string = String(it['address'] ?? '');
        const port: string = String(it['port'] ?? 22);
        if (label.length === 0 || address.length === 0 || this.store === null) { continue; }
        let exists = false;
        for (let k = 0; k < this.hosts.length; k++) {
          if (this.hosts[k].label === label && this.hosts[k].address === address &&
              this.hosts[k].port === port) { exists = true; break; }
        }
        if (exists) { dup++; continue; }
        const tagsRaw: object[] = (it['tags'] ?? []) as object[];
        let tags: string = '';
        for (let t = 0; t < tagsRaw.length; t++) {
          tags = tags.length === 0 ? String(tagsRaw[t]) : (tags + ',' + String(tagsRaw[t]));
        }
        const bucket: relationalStore.ValuesBucket = {
          'id': 'imp_' + Date.now() + '_' + i,
          'label': label, 'address': address,
          'usr': String(it['user'] ?? ''),
          'port': port, 'proto': 'ssh',
          'grp': String(it['group'] ?? ''),
          'tags': tags,
          'color': String(it['color'] ?? '')
        };
        await this.store.insert('hosts', bucket);
        added++;
      }
      await this.reload();
      this.catalogResult = 'catalog-import: added=' + added + ' dup=' + dup + ' total=' + this.hosts.length;
    } catch (e) {
      this.catalogResult = 'catalog-import failed: ' + JSON.stringify(e);
    }
  }

  private async resetAllHosts(): Promise<void> {
    if (this.store === null) { return; }
    for (let i = 0; i < this.hosts.length; i++) {
      const h = this.hosts[i];
      const key = this.hostKey(h.address, h.port);
      const hp = new relationalStore.RdbPredicates('hosts');
      hp.equalTo('id', h.id);
      await this.store.delete(hp);
      const kp = new relationalStore.RdbPredicates('known_hosts');
      kp.equalTo('host', key);
      await this.store.delete(kp);
      await Vault.remove(key);
      this.creds.delete(key);
    }
    // 同时清空 known_hosts 与会话日志：卸载重装后系统会恢复应用数据（备份扩展），
    // 只清 hosts 会让"首次连接应弹信任框"这类断言永远失败。
    const kpAll = new relationalStore.RdbPredicates('known_hosts');
    await this.store.delete(kpAll);
    const lpAll = new relationalStore.RdbPredicates('session_logs');
    await this.store.delete(lpAll);
    const spAll = new relationalStore.RdbPredicates('snippets');
    await this.store.delete(spAll);
    await this.reloadSnippets();
    const npAll = new relationalStore.RdbPredicates('notes');
    await this.store.delete(npAll);
    await this.reloadNotes();
    this.selectedIds = [];
    await this.reload();
    this.catalogResult = 'catalog-reset: hosts=' + this.hosts.length;
  }


  // ---------------- 偏好持久化（对应官方 state.save()） ----------------
  private async loadPrefs(): Promise<void> {
    // 设置来源：DB ui_state 优先（preferences 在设备上损坏过：.broken 后写入不落盘），
    // preferences 仅作兜底与向后兼容。
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      this.prefs = await preferences.getPreferences(ctx, 'motty-ui');
    } catch (e) {
      this.prefs = null;
    }
    const dbLang: string = await this.getUiState('lang');
    const dbView: string = await this.getUiState('hostView');
    const dbSort: string = await this.getUiState('hostSort');
    const dbCollapsed: string = await this.getUiState('collapsedGroups');
    const dbPinned: string = await this.getUiState('pinnedGroups');
    const dbOrder: string = await this.getUiState('groupOrder');
    const dbFont: string = await this.getUiState('termFontSize');
    const dbTabSide: string = await this.getUiState('tabSide');
    const dbSb: string = await this.getUiState('termScrollback');
    const dbLU: string = await this.getUiState('showLastUsed');
    const dbTC: string = await this.getUiState('showTabCount');
    const dbStart: string = await this.getUiState('startupView');
    const dbScale: string = await this.getUiState('uiScaleKey');
    const dbTheme: string = await this.getUiState('themeMode');
    let lang: string = dbLang;
    let view: string = dbView;
    let sort: string = dbSort;
    let collapsed: string = dbCollapsed;
    let pinned: string = dbPinned;
    if (this.prefs !== null) {
      if (lang.length === 0) { lang = this.prefs.getSync('lang', this.lang) as string; }
      if (view.length === 0) { view = this.prefs.getSync('hostView', this.hostView) as string; }
      if (sort.length === 0) { sort = this.prefs.getSync('hostSort', this.hostSort) as string; }
      if (collapsed.length === 0) { collapsed = this.prefs.getSync('collapsedGroups', '') as string; }
      if (pinned.length === 0) { pinned = this.prefs.getSync('pinnedGroups', '') as string; }
    }
    if (lang === 'zh' || lang === 'en') { this.lang = lang; }
    if (view === 'list' || view === 'grid') { this.hostView = view; }
    if (sort === 'manual' || sort === 'name' || sort === 'ip') { this.hostSort = sort; }
    this.collapsedGroups = collapsed.length === 0 ? []
      : collapsed.split('\u0001').filter((x: string) => x.length > 0);
    this.pinnedGroups = pinned.length === 0 ? []
      : pinned.split('\u0001').filter((x: string) => x.length > 0);
    if (dbOrder.length > 0) {
      this.groupOrder = dbOrder.split('\u0001').filter((x: string) => x.length > 0);
    }
    const fontN: number = Number.parseInt(dbFont, 10);
    if (fontN >= 10 && fontN <= 24) { this.termFontSize = fontN; }
    this.tabSide = dbTabSide === '1';
    const sbN: number = Number.parseInt(dbSb, 10);
    if (sbN >= 0 && sbN <= 100) { this.termScrollback = sbN; }
    this.showLastUsed = dbLU !== '0';
    this.showTabCount = dbTC !== '0';
    if (dbStart === 'logs' || dbStart === 'workspace' || dbStart === 'hosts') { this.startupView = dbStart; }
    if (dbScale === 'small' || dbScale === 'regular' || dbScale === 'large') { this.uiScaleKey = dbScale; }
    if (dbTheme === 'light' || dbTheme === 'dark') { this.themeMode = dbTheme; }
    hilog.info(DOMAIN, TAG, 'settings loaded lang=%{public}s order=%{public}s',
      this.lang, this.groupOrder.join(','));
  }


  // 启动视图：把 loadPrefs 读到的 startupView 落到页面
  private applyStartupView(): void {
    if (this.startupView === 'logs') {
      this.pcNav = '会话日志';
      this.reloadLogs();
    } else if (this.startupView === 'workspace') {
      this.pcNav = '工作区';
    } else {
      this.pcNav = '主机';
      this.showHosts = true;
    }
  }


  // 设置重置为默认（不动语言，避免用户突然看不懂界面）

  // 界面字号（小/标准/大）：只缩放"文字尺寸"，不动布局常量，避免整体塌陷

  // 主题调色：只做"深色/浅色"两套主要表面与文字色，键就是深色字面量，便于逐处替换
  private th(dark: string): string {
    if (this.themeMode !== 'light') { return dark; }
    if (dark === this.th('#17181C')) { return '#F5F6F8'; }
    if (dark === this.th('#0C0D10')) { return '#FFFFFF'; }
    if (dark === this.th('#101114')) { return '#FAFAFB'; }
    if (dark === this.th('#1C1F24')) { return '#FFFFFF'; }
    if (dark === this.th('#1E2127')) { return '#F0F1F3'; }
    if (dark === this.th('#23262B')) { return '#EDEFF2'; }
    if (dark === this.th('#2A2D33')) { return '#E3E6EA'; }
    if (dark === this.th('#E8EAED')) { return '#12141A'; }
    if (dark === this.th('#C7CBD1')) { return this.th('#2A2D33'); }
    if (dark === this.th('#8A8F98')) { return '#5A6068'; }
    if (dark === this.th('#6B7078')) { return '#7A8189'; }
    return dark;
  }

  private fs(base: number): number {
    if (this.uiScaleKey === 'small') { return Math.round(base * 0.9); }
    if (this.uiScaleKey === 'large') { return Math.round(base * 1.15); }
    return base;
  }

  private resetSettings(): void {
    this.hostView = 'list';
    this.hostSort = 'manual';
    this.termFontSize = 13;
    this.termScrollback = 3;
    this.tabNumbers = false;
    this.tabSide = false;
    this.showLastUsed = true;
    this.showTabCount = true;
    this.startupView = 'hosts';
    this.settingsReset = this.lang === 'zh' ? '设置已恢复默认' : 'settings reset to defaults';
    this.savePrefs();
  }

  private async savePrefs(): Promise<void> {
    // 同时写 DB 与 preferences：DB 是可靠来源，preferences 保留给旧数据/其它会话
    await this.setUiState('lang', this.lang);
    await this.setUiState('hostView', this.hostView);
    await this.setUiState('hostSort', this.hostSort);
    await this.setUiState('collapsedGroups', this.collapsedGroups.join('\u0001'));
    await this.setUiState('pinnedGroups', this.pinnedGroups.join('\u0001'));
    await this.setUiState('groupOrder', this.groupOrder.join('\u0001'));
    await this.setUiState('termFontSize', String(this.termFontSize));
    await this.setUiState('tabSide', this.tabSide ? '1' : '0');
    await this.setUiState('termScrollback', String(this.termScrollback));
    await this.setUiState('showLastUsed', this.showLastUsed ? '1' : '0');
    await this.setUiState('showTabCount', this.showTabCount ? '1' : '0');
    await this.setUiState('startupView', this.startupView);
    await this.setUiState('uiScaleKey', this.uiScaleKey);
    await this.setUiState('themeMode', this.themeMode);
    if (this.prefs === null) { return; }
    try {
      this.prefs.putSync('lang', this.lang);
      this.prefs.putSync('hostView', this.hostView);
      this.prefs.putSync('hostSort', this.hostSort);
      this.prefs.putSync('collapsedGroups', this.collapsedGroups.join('\u0001'));
      this.prefs.putSync('pinnedGroups', this.pinnedGroups.join('\u0001'));
      this.prefs.putSync('groupOrder', this.groupOrder.join('\u0001'));
      this.prefs.flushSync();
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'savePrefs(prefs) failed: %{public}s', JSON.stringify(e));
    }
  }





  // 统一按钮样式：主操作 / 次操作 / 危险操作（高度与圆角一致，减少样式漂移）
  @Builder
  btnPrimary(label: string, idName: string, onTap: () => void) {
    Button(label).id(idName).height(30).fontSize(12)
      .backgroundColor('#2F6F4F').fontColor(Color.White)
      .onClick(() => { onTap(); })
  }

  @Builder
  btnSecondary(label: string, idName: string, onTap: () => void) {
    Button(label).id(idName).height(30).fontSize(12)
      .backgroundColor(this.th('#23262B')).fontColor(this.th('#C7CBD1'))
      .onClick(() => { onTap(); })
  }

  @Builder
  menuItem(label: string, idName: string, onTap: () => void) {
    Button(label).id(idName).width('100%').height(30).fontSize(13)
      .backgroundColor(this.th('#23262B')).fontColor(this.th('#C7CBD1'))
      .onClick(() => { onTap(); })
  }

  @Builder
  menuItemDanger(label: string, idName: string, onTap: () => void) {
    Button(label).id(idName).width('100%').height(30).fontSize(13)
      .backgroundColor('#3A2226').fontColor('#E08A8A')
      .onClick(() => { onTap(); })
  }

  @Builder
  btnDanger(label: string, idName: string, onTap: () => void) {
    Button(label).id(idName).height(30).fontSize(12)
      .backgroundColor('#3A2226').fontColor('#E08A8A')
      .onClick(() => { onTap(); })
  }

  @Builder
  settingsSection(title: string) {
    Text(title).fontSize(12).fontColor(this.th('#8A8F98')).width('100%').margin({ top: 4 })
  }

  @Builder
  settingsOpt(label: string, idName: string, active: boolean, onTap: () => void) {
    Button(label)
      .id(idName).height(30).fontSize(12)
      .backgroundColor(active ? '#2F6F4F' : this.th('#23262B'))
      .fontColor(active ? Color.White : this.th('#C7CBD1'))
      .onClick(() => { onTap(); })
  }

  @Builder
  settingsPanel() {
    Column({ space: 10 }) {
      Row() {
        Text(this.lang === 'zh' ? '设置' : 'Settings')
          .fontSize(this.fs(18)).fontWeight(FontWeight.Bold).fontColor(this.th('#E8EAED'))
        Blank()
        Button(this.lang === 'zh' ? '恢复默认' : 'Reset to defaults').id('settings/reset')
          .height(30).fontSize(12).backgroundColor('#3A2226').fontColor('#E08A8A')
          .onClick(() => { this.resetSettings(); })
        Button(this.t('common.close')).id('settings/close').height(30).fontSize(12)
          .backgroundColor(this.th('#23262B')).fontColor(this.th('#C7CBD1'))
          .onClick(() => { this.settingsOpen = false; })
      }.width('100%')
      if (this.settingsReset.length > 0) {
        Text(this.settingsReset).id('settings/reset-result')
          .fontSize(11).fontColor('#0A6C00').width('100%')
      }

      this.settingsSection(this.lang === 'zh' ? '语言' : 'Language')
      Row({ space: 8 }) {
        this.settingsOpt('中文', 'settings/lang-zh', this.lang === 'zh', () => {
          if (this.lang !== 'zh') { this.toggleLangAndSave(); }
        })
        this.settingsOpt('English', 'settings/lang-en', this.lang === 'en', () => {
          if (this.lang !== 'en') { this.toggleLangAndSave(); }
        })
      }.width('100%')

      this.settingsSection(this.lang === 'zh' ? '外观' : 'Appearance')
      Row({ space: 8 }) {
        this.settingsOpt(this.lang === 'zh' ? '深色' : 'Dark', 'settings/theme-dark',
          this.themeMode === 'dark', () => { this.themeMode = 'dark'; this.savePrefs(); })
        this.settingsOpt(this.lang === 'zh' ? '浅色' : 'Light', 'settings/theme-light',
          this.themeMode === 'light', () => { this.themeMode = 'light'; this.savePrefs(); })
      }.width('100%')
      Row({ space: 8 }) {
        this.settingsOpt(this.lang === 'zh' ? '小' : 'Small', 'settings/scale-small',
          this.uiScaleKey === 'small', () => { this.uiScaleKey = 'small'; this.savePrefs(); })
        this.settingsOpt(this.lang === 'zh' ? '标准' : 'Regular', 'settings/scale-regular',
          this.uiScaleKey === 'regular', () => { this.uiScaleKey = 'regular'; this.savePrefs(); })
        this.settingsOpt(this.lang === 'zh' ? '大' : 'Large', 'settings/scale-large',
          this.uiScaleKey === 'large', () => { this.uiScaleKey = 'large'; this.savePrefs(); })
      }.width('100%')

      this.settingsSection(this.lang === 'zh' ? '主机列表' : 'Host list')
      Row({ space: 8 }) {
        this.settingsOpt(this.lang === 'zh' ? '列表' : 'List', 'settings/view-list',
          this.hostView === 'list', () => { this.hostView = 'list'; this.savePrefs(); })
        this.settingsOpt(this.lang === 'zh' ? '网格' : 'Grid', 'settings/view-grid',
          this.hostView === 'grid', () => { this.hostView = 'grid'; this.savePrefs(); })
        this.settingsOpt(this.lang === 'zh' ? '手动排序' : 'Manual', 'settings/sort-manual',
          this.hostSort === 'manual', () => { this.hostSort = 'manual'; this.savePrefs(); })
        this.settingsOpt(this.lang === 'zh' ? '按名称' : 'By name', 'settings/sort-name',
          this.hostSort === 'name', () => { this.hostSort = 'name'; this.savePrefs(); })
        this.settingsOpt(this.lang === 'zh' ? '按地址' : 'By IP', 'settings/sort-ip',
          this.hostSort === 'ip', () => { this.hostSort = 'ip'; this.savePrefs(); })
      }.width('100%')
      Row({ space: 8 }) {
        this.settingsOpt((this.showLastUsed ? '✓ ' : '') + (this.lang === 'zh' ? '最近连接' : 'Last used'),
          'settings/show-lastused', this.showLastUsed, () => { this.showLastUsed = !this.showLastUsed; this.savePrefs(); })
        this.settingsOpt((this.showTabCount ? '✓ ' : '') + (this.lang === 'zh' ? '会话计数' : 'Tab count'),
          'settings/show-tabcount', this.showTabCount, () => { this.showTabCount = !this.showTabCount; this.savePrefs(); })
        this.settingsOpt(this.lang === 'zh' ? '标签编号' : 'Tab numbers',
          'settings/tab-numbers', this.tabNumbers, () => { this.tabNumbers = !this.tabNumbers; this.savePrefs(); })
        this.settingsOpt(this.lang === 'zh' ? '侧栏标签' : 'Side tabs',
          'settings/tab-side', this.tabSide, () => { this.tabSide = !this.tabSide; this.savePrefs(); })
      }.width('100%')

      this.settingsSection(this.lang === 'zh' ? '终端' : 'Terminal')
      Row({ space: 10 }) {
        Button('-').id('settings/font-dec').height(30).width(40).fontSize(13)
          .backgroundColor(this.th('#23262B')).fontColor(this.th('#C7CBD1'))
          .onClick(() => { this.changeTermFont(-1); })
        Text(this.lang === 'zh' ? '字号 ' + this.termFontSize : 'size ' + this.termFontSize)
          .id('settings/font-value').fontSize(12).fontColor(this.th('#C7CBD1'))
        Button('+').id('settings/font-inc').height(30).width(40).fontSize(13)
          .backgroundColor(this.th('#23262B')).fontColor(this.th('#C7CBD1'))
          .onClick(() => { this.changeTermFont(1); })
        Button(this.lang === 'zh' ? '回滚 ' + this.termScrollback : 'scrollback ' + this.termScrollback)
          .id('settings/scrollback').height(30).fontSize(12)
          .backgroundColor(this.th('#23262B')).fontColor(this.th('#C7CBD1'))
          .onClick(() => {
            this.termScrollback = this.termScrollback >= 100 ? 0 : this.termScrollback + 10;
            this.savePrefs();
          })
      }.width('100%')

      this.settingsSection(this.lang === 'zh' ? '启动时打开' : 'On launch')
      Row({ space: 8 }) {
        this.settingsOpt(this.lang === 'zh' ? '主机' : 'Hosts', 'settings/start-hosts',
          this.startupView === 'hosts', () => { this.startupView = 'hosts'; this.savePrefs(); })
        this.settingsOpt(this.lang === 'zh' ? '会话日志' : 'Session logs', 'settings/start-logs',
          this.startupView === 'logs', () => { this.startupView = 'logs'; this.savePrefs(); })
        this.settingsOpt(this.lang === 'zh' ? '工作区' : 'Workspace', 'settings/start-workspace',
          this.startupView === 'workspace', () => { this.startupView = 'workspace'; this.savePrefs(); })
      }.width('100%')

      this.settingsSection(this.lang === 'zh' ? '关于' : 'About')
      Column({ space: 4 }) {
        Text(this.lang === 'zh'
          ? '上游 t8y2/motty（Apache-2.0）；鸿蒙端为 ArkTS + C/C++（NAPI）实现。'
          : 'Upstream t8y2/motty (Apache-2.0); HarmonyOS build in ArkTS + C/C++ via NAPI.')
          .fontSize(11).fontColor(this.th('#8A8F98'))
        Text(this.lang === 'zh'
          ? 'RDP：可连接、可解码、会话视图可预览画面并投递输入（实验性）。'
          : 'RDP: connect, decode and session preview with input delivery (experimental).')
          .fontSize(11).fontColor('#E0A458')
      }.alignItems(HorizontalAlign.Start).width('100%')
    }
    .id('settings/panel')
    .width(520).padding(20).backgroundColor(this.th('#1C1F24')).borderRadius(14)
    .shadow({ radius: 24, color: '#66000000', offsetY: 8 })
  }


  private async recordSession(h: HostItem): Promise<void> {
    if (this.store === null) { return; }
    const bucket: relationalStore.ValuesBucket = {
      'id': 'log_' + Date.now() + '_' + Math.floor(Math.random() * 1000),
      'label': h.label, 'address': h.address, 'proto': h.proto,
      'started_at': Date.now()
    };
    try {
      await this.store.insert('session_logs', bucket);
      // 立刻刷新列表里的"最近连接"（不刷新的话要等下一次 reload 才更新）
      await this.reload();
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'recordSession failed: %{public}s', JSON.stringify(e));
    }
  }

  private async reloadLogs(): Promise<void> {
    if (this.store === null) { return; }
    const pred = new relationalStore.RdbPredicates('session_logs');
    pred.orderByDesc('started_at');
    const rs = await this.store.query(pred, LOG_COLUMNS);
    const out: LogItem[] = [];
    while (rs.goToNextRow() && out.length < 200) {
      out.push({
        id: rs.getString(0), label: rs.getString(1), address: rs.getString(2),
        proto: rs.getString(3), startedAt: rs.getLong(4)
      });
    }
    rs.close();
    this.logs = out;
  }


  // 会话日志过滤：按 label / address / proto 子串（不区分大小写的简单版本）
  private logsHosts(): string[] {
    const out: string[] = [];
    for (let i = 0; i < this.logs.length; i++) {
      const lab: string = this.logs[i].label;
      if (out.indexOf(lab) < 0) { out.push(lab); }
    }
    return out;
  }

  private logsFiltered(): LogItem[] {
    const q: string = this.logsQuery.trim().toLowerCase();
    return this.logs.filter((it: LogItem) => {
      if (this.logsHost.length > 0 && it.label !== this.logsHost) { return false; }
      if (this.logsProto.length > 0 && it.proto !== this.logsProto) { return false; }
      if (q.length === 0) { return true; }
      return it.label.toLowerCase().indexOf(q) >= 0 ||
        it.address.toLowerCase().indexOf(q) >= 0 ||
        it.proto.toLowerCase().indexOf(q) >= 0;
    });
  }

  private async clearLogs(): Promise<void> {
    if (this.store === null) { return; }
    const pred = new relationalStore.RdbPredicates('session_logs');
    await this.store.delete(pred);
    await this.reloadLogs();
  }


  // 密钥链：新增一条凭据（存 Asset Store + 内存）
  private async saveVaultEntry(): Promise<void> {
    const addr: string = this.vaultAddr.trim();
    const portS: string = this.vaultPort.trim();
    if (addr.length === 0 || portS.length === 0 || this.vaultPw.length === 0) {
      this.vaultResult = 'address/port/password are required';
      return;
    }
    const port: number = Number.parseInt(portS, 10);
    if (Number.isNaN(port)) {
      this.vaultResult = 'port must be a number';
      return;
    }
    const key: string = this.hostKey(addr, String(port));
    const ok: boolean = await Vault.save(key, this.vaultPw);
    this.creds.set(key, { address: addr, port: port, user: this.vaultUser.trim(), password: this.vaultPw });
    this.vaultResult = 'saved ' + key + ' -> ' + String(ok);
    this.vaultAddOpen = false;
    this.vaultAddr = ''; this.vaultPort = ''; this.vaultUser = ''; this.vaultPw = '';
    this.vaultSeq = this.vaultSeq + 1;
    await this.savePrefs();
  }

  private credKeys(): string[] {
    const out: string[] = [];
    this.creds.forEach((_v: Cred, k: string) => { out.push(k); });
    return out;
  }


  // ---------------- 会话日志页（NavSessionLogs 的最小实现） ----------------

  // ---------------- 工作区页（最小实现：会话标签概览 + 关闭） ----------------

  // 跳板路由（ProxyJump）：当前明确说明未实现 + 给出可用替代（端口转发隧道）
  @Builder
  jumpPage() {
    Column({ space: 10 }) {
      Row({ space: 10 }) {
        this.pageTitle(this.lang === 'zh' ? '跳板路由' : 'Jump routes', 'jump/title')
        Blank()
      }.width('100%')
      Text(this.lang === 'zh'
        ? '跳板（ProxyJump）需要"在一条 SSH 连接上再建立一条 SSH 连接"。底层库 libssh2 不提供可插拔 transport，'
          + '当前版本无法可靠实现，因此这里不做"能存不能用"的配置。'
        : 'ProxyJump needs one SSH connection tunnelling another. libssh2 has no pluggable transport, so this '
          + 'version cannot do it reliably; we do not ship a config that stores but cannot connect.')
        .id('jump/explain').fontSize(12).fontColor(this.th('#C7CBD1')).width('100%')
      Text(this.lang === 'zh'
        ? '替代方案：用「端口转发」把目标端口经跳板机映射到本机，再用主机 127.0.0.1:<本地端口> 连接。'
        : 'Workaround: use Port Forwarding to map the target through the jump host, then connect to 127.0.0.1:<local port>.')
        .id('jump/workaround').fontSize(12).fontColor(this.th('#8A8F98')).width('100%')
      Row({ space: 10 }) {
        Button(this.lang === 'zh' ? '打开端口转发' : 'Open port forwarding').id('jump/fwd-open')
          .height(32).fontSize(12).backgroundColor('#1A6DD0').fontColor(Color.White)
          .onClick(() => { this.fwdOpen = true; this.reloadRules(); })
        Button(this.lang === 'zh' ? '回到主机' : 'Back to hosts').id('jump/back')
          .height(32).fontSize(12).backgroundColor(this.th('#23262B')).fontColor(this.th('#C7CBD1'))
          .onClick(() => { this.pcNav = '主机'; this.showHosts = true; })
      }.width('100%').justifyContent(FlexAlign.Start)
    }
    .width('100%').height('100%').padding({ left: 22, right: 22, top: 10 })
  }


  // 统一页标题样式（二级页面一致性）
  @Builder
  pageTitle(text: string, idName: string) {
    Text(text).id(idName).fontSize(this.fs(16)).fontWeight(FontWeight.Bold).fontColor(this.th('#E8EAED'))
  }

  // 本地终端页：HarmonyOS 应用沙箱不允许 fork/exec 本地 shell，这里如实说明并给替代
  @Builder
  localTerminalPage() {
    Column({ space: 10 }) {
      Row({ space: 10 }) {
        this.pageTitle(this.lang === 'zh' ? '本地终端' : 'Local terminal', 'localterm/title')
        Blank()
      }.width('100%')
      Text(this.lang === 'zh'
        ? 'HarmonyOS 应用运行在受限沙箱里，不能 fork/exec 本地 shell，因此本版本没有"本地终端"。'
        : 'HarmonyOS apps run in a restricted sandbox and cannot fork/exec a local shell, so this build has no local terminal.')
        .id('localterm/explain').fontSize(this.fs(12)).fontColor(this.th('#C7CBD1')).width('100%')
      Text(this.lang === 'zh'
        ? '替代：连一台本机 SSH 主机（例如 127.0.0.1:2222 的测试夹具），或到调试页用 pty shell 演示。'
        : 'Workaround: connect an SSH host on this machine (e.g. the 127.0.0.1:2222 fixture), or use pty shell on the debug page.')
        .id('localterm/workaround').fontSize(this.fs(12)).fontColor(this.th('#8A8F98')).width('100%')
      Row({ space: 10 }) {
        Button(this.lang === 'zh' ? '打开调试页' : 'Open debug').id('localterm/diag')
          .height(32).fontSize(12).backgroundColor('#1A6DD0').fontColor(Color.White)
          .onClick(() => { this.diagOpen = true; })
        Button(this.lang === 'zh' ? '回到主机' : 'Back to hosts').id('localterm/back')
          .height(32).fontSize(12).backgroundColor(this.th('#23262B')).fontColor(this.th('#C7CBD1'))
          .onClick(() => { this.pcNav = '主机'; this.showHosts = true; })
      }.width('100%').justifyContent(FlexAlign.Start)
    }
    .width('100%').height('100%').padding({ left: 22, right: 22, top: 10 })
  }

  @Builder
  workspacePage() {
    Column({ space: 10 }) {
      Row({ space: 10 }) {
        this.pageTitle(this.lang === 'zh' ? '工作区' : 'Workspace', 'ws/title')
        Text('(' + this.tabs.length + ')').id('ws/count').fontSize(12).fontColor(this.th('#6B7078'))
        Blank()
        Button(this.lang === 'zh' ? '全部关闭' : 'Close all').id('ws/close-all')
          .height(30).fontSize(12).backgroundColor('#3A2226').fontColor('#E08A8A')
          .onClick(() => { this.closeAllTabs(); })
      }.width('100%')
      if (this.tabs.length === 0) {
        Text(this.lang === 'zh' ? '还没有打开的会话' : 'No open sessions').id('ws/empty')
          .fontSize(13).fontColor(this.th('#6B7078')).width('100%').padding({ top: 30 })
      }
      List({ space: 6 }) {
        ForEach(this.tabs, (t: TabInfo, idx: number) => {
          ListItem() {
            Row({ space: 12 }) {
              Text((idx + 1).toString()).fontSize(12).fontColor(this.th('#6B7078')).width(24)
              Text((this.tabNumbers ? (this.tabs.indexOf(t) + 1).toString() + ' ' : '') + t.label).id('ws/tab/' + idx).fontSize(14).fontColor(this.th('#E8EAED')).layoutWeight(1)
                .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
              Button(this.lang === 'zh' ? '关闭其他' : 'Close others').id('ws/close-others/' + idx)
                .height(26).fontSize(11).backgroundColor(this.th('#23262B')).fontColor(this.th('#C7CBD1'))
                .onClick(() => { this.closeOtherTabs(t.id); })
              Button(this.lang === 'zh' ? '重命名' : 'Rename').id('ws/rename/' + idx)
                .height(26).fontSize(11).backgroundColor(this.th('#23262B')).fontColor(this.th('#C7CBD1'))
                .onClick(() => { this.tabRenameId = t.id; this.tabRenameText = ''; this.tabRenameOpen = true; })
              Button(this.lang === 'zh' ? '切换' : 'Switch').id('ws/switch/' + idx)
                .height(26).fontSize(11).backgroundColor('#2F6F4F').fontColor(Color.White)
                .onClick(() => { this.activeId = t.id; this.pcNav = '主机'; this.showHosts = false; })
              Button(this.lang === 'zh' ? '关闭' : 'Close').id('ws/close/' + idx)
                .height(26).fontSize(11).backgroundColor(this.th('#23262B')).fontColor(this.th('#C7CBD1'))
                .onClick(() => { this.closeTab(t.id); })
            }.width('100%').height(44).padding({ left: 10, right: 10 })
            .borderRadius(8).backgroundColor(this.th('#1C1F24'))
          }
        }, (t: TabInfo) => t.id)
      }.id('ws/list').layoutWeight(1).width('100%')
    }
    .width('100%').height('100%').padding({ left: 22, right: 22, top: 10 })
  }

  @Builder
  logsPage() {
    Column({ space: 10 }) {
      Row({ space: 10 }) {
        this.pageTitle(this.lang === 'zh' ? '会话日志' : 'Session logs', 'logs/title')
        Text('(' + this.logs.length + ')').fontSize(12).fontColor(this.th('#6B7078'))
        Blank()
        Button(this.lang === 'zh' ? '刷新' : 'Refresh').id('logs/refresh').height(30).fontSize(12)
          .backgroundColor(this.th('#1E2127')).fontColor(this.th('#C7CBD1'))
          .onClick(() => { this.reloadLogs(); })
        Button(this.lang === 'zh' ? '导出' : 'Export').id('logs/export-file').height(30).fontSize(12)
          .backgroundColor(this.th('#1E2127')).fontColor(this.th('#C7CBD1'))
          .onClick(() => { this.exportLogsToSandbox(); })
        Button(this.lang === 'zh' ? '清空' : 'Clear').id('logs/clear').height(30).fontSize(12)
          .backgroundColor('#3A2226').fontColor('#E08A8A')
          .onClick(() => { this.clearLogs(); })
      }.width('100%')
        Row({ space: 10 }) {
          TextInput({ placeholder: this.lang === 'zh' ? '搜索日志（名称/地址/协议）' : 'Search logs' })
            .id('logs/search').height(34).fontSize(12).layoutWeight(1)
            .onChange((v: string) => { this.logsQuery = v; })
          Text(this.logsFiltered().length + ' / ' + this.logs.length)
            .id('logs/count').fontSize(11).fontColor(this.th('#6B7078'))
        }.width('100%')
      Row({ space: 8 }) {
        Button('ALL').id('logs/proto-all').height(26).fontSize(11)
          .backgroundColor(this.logsProto.length === 0 ? '#2F6F4F' : this.th('#23262B'))
          .fontColor(this.logsProto.length === 0 ? Color.White : this.th('#C7CBD1'))
          .onClick(() => { this.logsProto = ''; })
        Button('SSH').id('logs/proto-ssh').height(26).fontSize(11)
          .backgroundColor(this.logsProto === 'ssh' ? '#2F6F4F' : this.th('#23262B'))
          .fontColor(this.logsProto === 'ssh' ? Color.White : this.th('#C7CBD1'))
          .onClick(() => { this.logsProto = 'ssh'; })
        Button('RDP').id('logs/proto-rdp').height(26).fontSize(11)
          .backgroundColor(this.logsProto === 'rdp' ? '#2F6F4F' : this.th('#23262B'))
          .fontColor(this.logsProto === 'rdp' ? Color.White : this.th('#C7CBD1'))
          .onClick(() => { this.logsProto = 'rdp'; })
        Button('VNC').id('logs/proto-vnc').height(26).fontSize(11)
          .backgroundColor(this.logsProto === 'vnc' ? '#2F6F4F' : this.th('#23262B'))
          .fontColor(this.logsProto === 'vnc' ? Color.White : this.th('#C7CBD1'))
          .onClick(() => { this.logsProto = 'vnc'; })
        Text(this.logsFiltered().length + ' / ' + this.logs.length)
          .id('logs/proto-count').fontSize(11).fontColor(this.th('#6B7078'))
      }.width('100%')
      Row({ space: 8 }) {
        Button(this.lang === 'zh' ? '全部主机' : 'All hosts').id('logs/host-all')
          .height(26).fontSize(11)
          .backgroundColor(this.logsHost.length === 0 ? '#2F6F4F' : this.th('#23262B'))
          .fontColor(this.logsHost.length === 0 ? Color.White : this.th('#C7CBD1'))
          .onClick(() => { this.logsHost = ''; })
        ForEach(this.logsHosts(), (lab: string, hi: number) => {
          Button(lab).id('logs/host/' + hi).height(26).fontSize(11)
            .backgroundColor(this.logsHost === lab ? '#2F6F4F' : this.th('#23262B'))
            .fontColor(this.logsHost === lab ? Color.White : this.th('#C7CBD1'))
            .onClick(() => { this.logsHost = lab; })
        }, (lab: string) => 'loghost-' + lab)
      }.width('100%')
      if (this.logsExport.length > 0) {
        Text(this.logsExport).id('logs/export-result').fontSize(11).fontFamily('monospace')
          .fontColor('#0A6C00').width('100%')
      }
      if (this.logsFiltered().length === 0) {
        Text(this.logsQuery.trim().length > 0
          ? (this.lang === 'zh' ? '没有匹配的会话记录' : 'No matching sessions')
          : (this.lang === 'zh' ? '还没有会话记录' : 'No sessions yet')).id('logs/empty')
          .fontSize(13).fontColor(this.th('#6B7078')).width('100%').padding({ top: 40 })
      }
      List({ space: 6 }) {
        ForEach(this.logsFiltered(), (it: LogItem) => {
          ListItem() {
            Row({ space: 12 }) {
              Text(it.label).fontSize(14).fontColor(this.th('#E8EAED')).layoutWeight(2)
              Text(it.address).fontSize(12).fontColor(this.th('#8A8F98')).layoutWeight(2)
              Text(it.proto.length > 0 ? it.proto.toUpperCase() : 'SSH').fontSize(11).fontColor(this.th('#C7CBD1'))
                .padding({ left: 8, right: 8, top: 3, bottom: 3 }).backgroundColor(this.th('#23262B')).borderRadius(10)
              Text(new Date(it.startedAt).toLocaleString()).fontSize(11).fontColor(this.th('#6B7078')).layoutWeight(2)
            }
            .width('100%').height(44).padding({ left: 10, right: 10 })
            .borderRadius(8).backgroundColor(this.th('#1C1F24'))
          }
        }, (it: LogItem) => it.id)
      }.id('logs/list').layoutWeight(1).width('100%')
    }
    .width('100%').height('100%').padding({ left: 22, right: 22, top: 10 })
  }

  // ---------------- 密钥链页（凭据清单的最小实现） ----------------
  @Builder
  vaultPage() {
    Column({ space: 10 }) {
      Row({ space: 10 }) {
        this.pageTitle(this.lang === 'zh' ? '密钥链' : 'Keychain', 'vault/title')
        Text('(' + this.credKeys().length + ')' + (this.vaultSeq >= 0 ? '' : '')).fontSize(12).fontColor(this.th('#6B7078'))
        Blank()
        Button(this.lang === 'zh' ? '新增凭据' : 'Add credential').id('vault/add-open')
          .height(30).fontSize(12).backgroundColor('#2F6F4F').fontColor(Color.White)
          .onClick(() => { this.vaultAddOpen = true; })
      }.width('100%')
      if (this.vaultResult.length > 0) {
        Text(this.vaultResult).id('vault/result').fontSize(11).fontFamily('monospace').fontColor('#0A6C00').width('100%')
      }
      Text(this.lang === 'zh'
        ? '口令存放在系统 Asset Store，这里只显示已保存凭据的条目（不显示明文）。'
        : 'Passwords live in the system Asset Store; only entry keys are listed here.')
        .fontSize(11).fontColor(this.th('#8A8F98')).width('100%')
      if (this.credKeys().length === 0) {
        Text(this.lang === 'zh' ? '还没有已保存的凭据' : 'No saved credentials').id('vault/empty')
          .fontSize(13).fontColor(this.th('#6B7078')).width('100%').padding({ top: 40 })
      }
      List({ space: 6 }) {
        ForEach(this.credKeys(), (k: string) => {
          ListItem() {
            Row({ space: 12 }) {
              Image($r('app.media.ic_keys')).width(16).height(16)
              Text(k).fontSize(13).fontColor(this.th('#E8EAED')).layoutWeight(1)
              Button(this.lang === 'zh' ? '删除' : 'Delete').id('vault/del/' + k).height(26).fontSize(11)
                .backgroundColor('#3A2226').fontColor('#E08A8A')
                .onClick(() => { this.vaultDelKey = k; })
            }
            .width('100%').height(44).padding({ left: 10, right: 10 })
            .borderRadius(8).backgroundColor(this.th('#1C1F24'))
          }
        }, (k: string) => 'cred-' + k)
      }.id('vault/list').layoutWeight(1).width('100%')
    }
    .width('100%').height('100%').padding({ left: 22, right: 22, top: 10 })
  }

  // relationalStore 在 WAL 下：写入返回后立刻查询有时读到旧值（实测提交后列表偶发为空/旧名）。
  // 统一在这里等一小段时间再刷新，避免 UI 与磁盘状态不一致。
  private async settleStore(): Promise<void> {
    await new Promise<void>((resolve: () => void) => { setTimeout(() => { resolve(); }, 150); });
  }

  private statusOf(index: number): string {
    return index >= 0 && index < this.statuses.length ? this.statuses[index] : '';
  }


  // ---------------- 快捷命令（官方 NavSnippets 的最小实现） ----------------
  private async reloadSnippets(): Promise<void> {
    if (this.store === null) { return; }
    const pred = new relationalStore.RdbPredicates('snippets');
    pred.orderByAsc('sort');
    const rs = await this.store.query(pred, SNIPPET_COLUMNS);
    const out: SnippetItem[] = [];
    while (rs.goToNextRow()) {
      out.push({ id: rs.getString(0), name: rs.getString(1), cmd: rs.getString(2), group: rs.getString(3) });
    }
    rs.close();
    this.snippets = out;
  }

  private openSnippetNew(): void {
    this.snipEditingId = '';
    this.snipName = '';
    this.snipCmd = '';
    this.snippetDialog = true;
  }

  private openSnippetEdit(it: SnippetItem): void {
    this.snipEditingId = it.id;
    this.snipName = it.name;
    this.snipCmd = it.cmd;
    this.snippetDialog = true;
  }

  private async submitSnippet(): Promise<void> {
    const name: string = this.snipName.trim();
    const cmd: string = this.snipCmd.trim();
    if (name.length === 0 || cmd.length === 0 || this.store === null) { return; }
    if (this.snipEditingId.length > 0) {
      const pred = new relationalStore.RdbPredicates('snippets');
      pred.equalTo('id', this.snipEditingId);
      const patch: relationalStore.ValuesBucket = { 'name': name, 'cmd': cmd };
      await this.store.update(patch, pred);
    } else {
      const bucket: relationalStore.ValuesBucket = {
        'id': 'snp_' + Date.now(), 'name': name, 'cmd': cmd, 'grp': '',
        'sort': this.snippets.length
      };
      await this.store.insert('snippets', bucket);
    }
    this.snippetDialog = false;
    this.snipEditingId = '';
    await this.settleStore();
    await this.reloadSnippets();
  }

  private async deleteSnippet(id: string): Promise<void> {
    if (this.store === null) { return; }
    const pred = new relationalStore.RdbPredicates('snippets');
    pred.equalTo('id', id);
    await this.store.delete(pred);
    await this.reloadSnippets();
  }

  // 发送到当前终端：有会话就写进终端输入并发送，没有就给出明确提示
  private sendSnippet(cmd: string): void {
    if (this.tabs.length === 0) {
      this.probeText = this.lang === 'zh' ? '还没有会话可以发送' : 'no session to send to';
      return;
    }
    this.termInput = cmd;
    this.sendTermInput();
  }


  // ---------------- 快捷命令页（NavSnippets） ----------------

  private snippetsFiltered(): SnippetItem[] {
    const q: string = this.snippetsQuery.trim().toLowerCase();
    if (q.length === 0) { return this.snippets; }
    return this.snippets.filter((it: SnippetItem) =>
      it.name.toLowerCase().indexOf(q) >= 0 || it.cmd.toLowerCase().indexOf(q) >= 0);
  }

  private knownFilteredKeys(): string[] {
    const q: string = this.knownQuery.trim().toLowerCase();
    const out: string[] = [];
    for (let i = 0; i < this.knownKeys.length; i++) {
      const k: string = this.knownKeys[i];
      if (q.length === 0 || k.toLowerCase().indexOf(q) >= 0) { out.push(k); }
    }
    return out;
  }

  @Builder
  snippetsPage() {
    Column({ space: 10 }) {
      Row({ space: 10 }) {
        this.pageTitle(this.t('snippet.title'), 'snippet/title')
        Text('(' + this.snippets.length + ' ' + this.t('snippet.count') + ')')
          .fontSize(12).fontColor(this.th('#6B7078'))
        Blank()
        Button(this.t('snippet.add')).id('snippet/add').height(30).fontSize(12)
          .backgroundColor(this.th('#E8EAED')).fontColor('#12141A')
          .onClick(() => { this.openSnippetNew(); })
      }.width('100%')
      Row({ space: 10 }) {
        TextInput({ placeholder: this.lang === 'zh' ? '搜索名称或命令' : 'search name or command' })
          .id('snippet/search').height(34).fontSize(12).layoutWeight(1)
          .onChange((v: string) => { this.snippetsQuery = v; })
        Text(this.snippetsFiltered().length + ' / ' + this.snippets.length)
          .id('snippet/count').fontSize(11).fontColor(this.th('#6B7078'))
      }.width('100%')
      if (this.snippetsFiltered().length === 0) {
        Column({ space: 6 }) {
          Text(this.t('snippet.empty')).id('snippet/empty').fontSize(14).fontColor(this.th('#C7CBD1'))
          Text(this.t('snippet.emptySub')).id('snippet/empty-sub').fontSize(12).fontColor(this.th('#6B7078'))
        }.width('100%').padding({ top: 50 })
      }
      List({ space: 6 }) {
        ForEach(this.snippetsFiltered(), (it: SnippetItem, idx: number) => {
          ListItem() {
            Row({ space: 12 }) {
              Column({ space: 3 }) {
                Text(it.name).fontSize(14).fontColor(this.th('#E8EAED')).maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                Text(it.cmd).fontSize(11).fontFamily('monospace').fontColor(this.th('#8A8F98'))
                  .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
              }.alignItems(HorizontalAlign.Start).layoutWeight(1)
              Button(this.t('snippet.send')).id('snippet/send/' + idx).height(28).fontSize(11)
                .backgroundColor('#2F6F4F').fontColor(Color.White)
                .onClick(() => { this.sendSnippet(it.cmd); })
              Button(this.t('host.edit')).id('snippet/edit/' + idx).height(28).fontSize(11)
                .backgroundColor(this.th('#23262B')).fontColor(this.th('#C7CBD1'))
                .onClick(() => { this.openSnippetEdit(it); })
              Button(this.t('snippet.delete')).id('snippet/del/' + idx).height(28).fontSize(11)
                .backgroundColor('#3A2226').fontColor('#E08A8A')
                .onClick(() => { this.deleteSnippet(it.id); })
            }
            .width('100%').height(52).padding({ left: 12, right: 12 })
            .borderRadius(8).backgroundColor(this.th('#1C1F24'))
          }
        }, (it: SnippetItem) => it.id + '|' + it.name + '|' + it.cmd)
      }.id('snippet/list').layoutWeight(1).width('100%')
    }
    .width('100%').height('100%').padding({ left: 22, right: 22, top: 10 })
  }

  @Builder
  snippetForm() {
    Column({ space: 10 }) {
      Text(this.snipEditingId.length > 0 ? this.t('host.edit') : this.t('snippet.add'))
        .fontSize(16).fontWeight(FontWeight.Bold).fontColor(this.th('#E8EAED')).width('100%')
      Text(this.t('snippet.name')).fontSize(12).fontColor(this.th('#8A8F98')).width('100%')
      TextInput({ placeholder: '例如：重启 nginx', text: this.snipName })
        .id('snippet/dialog-name').width('100%')
        .backgroundColor(this.th('#23262B')).fontColor(this.th('#E8EAED')).placeholderColor(this.th('#6B7078'))
        .onChange((v: string) => { this.snipName = v; })
      Text(this.t('snippet.command')).fontSize(12).fontColor(this.th('#8A8F98')).width('100%')
      TextInput({ placeholder: '例如：systemctl restart nginx', text: this.snipCmd })
        .id('snippet/dialog-cmd').width('100%')
        .backgroundColor(this.th('#23262B')).fontColor(this.th('#E8EAED')).placeholderColor(this.th('#6B7078'))
        .onChange((v: string) => { this.snipCmd = v; })
      Row({ space: 12 }) {
        Button(this.t('hostkey.cancel')).id('snippet/dialog-cancel').backgroundColor(this.th('#23262B')).fontColor(this.th('#C7CBD1'))
          .onClick(() => { this.snippetDialog = false; })
        Button(this.t('snippet.save')).id('snippet/dialog-save').backgroundColor('#3DDC97').fontColor('#12141A')
          .onClick(() => { this.submitSnippet(); })
      }.width('100%').justifyContent(FlexAlign.End)
    }
    .id('snippet/dialog').width(520).padding(20).backgroundColor(this.th('#1C1F24')).borderRadius(14)
    .shadow({ radius: 24, color: '#66000000', offsetY: 8 })
  }


  // ---------------- 命令面板（官方 CommandPalette） ----------------
  private paletteLabels(): string[] {
    const base: string[] = [
      '新建主机', '导入目录…', '导出目录…', '会话日志', '密钥链', '快捷命令',
      '端口转发', '已知主机', '调试', '设置', '主机'
    ];
    const out: string[] = [];
    const q: string = this.paletteQuery.trim();
    // 主机项放最前：面板列表高度有限，放末尾会被滚出可视区（实测 dump 里看不到）
    for (let i = 0; i < this.hosts.length; i++) {
      const h: HostItem = this.hosts[i];
      const label: string = '主机：' + h.label + '  ' + h.address;
      if (q.length === 0 || label.indexOf(q) >= 0) { out.push(label); }
    }
    for (let i = 0; i < base.length; i++) {
      if (q.length === 0 || base[i].indexOf(q) >= 0) { out.push(base[i]); }
    }
    for (let i = 0; i < this.snippets.length; i++) {
      const label: string = '快捷命令：' + this.snippets[i].name;
      if (q.length === 0 || label.indexOf(q) >= 0) { out.push(label); }
    }
    return out;
  }

  private runPalette(label: string): void {
    this.paletteOpen = false;
    this.paletteQuery = '';
    if (label.indexOf('快捷命令：') === 0) {
      const name: string = label.substring('快捷命令：'.length);
      for (let i = 0; i < this.snippets.length; i++) {
        if (this.snippets[i].name === name) { this.sendSnippet(this.snippets[i].cmd); return; }
      }
      return;
    }
    if (label.indexOf('主机：') === 0) {
      // '主机：<label>  <address>' -> 用 label 找到主机并连接
      const rest: string = label.substring('主机：'.length);
      const sep: number = rest.indexOf('  ');
      const want: string = sep > 0 ? rest.substring(0, sep) : rest;
      for (let i = 0; i < this.hosts.length; i++) {
        if (this.hosts[i].label === want) { this.openSession(this.hosts[i].label, i); return; }
      }
      return;
    }
    if (label === '新建主机') { this.resetForm(); this.showDialog = true; return; }
    if (label === '会话日志') { this.pcNav = '会话日志'; this.reloadLogs(); return; }
    if (label === '密钥链') { this.pcNav = '密钥链'; return; }
    if (label === '快捷命令') { this.pcNav = '快捷命令'; this.reloadSnippets(); return; }
    if (label === '主机') { this.pcNav = '主机'; this.showHosts = true; return; }
    if (label === '端口转发') { this.fwdOpen = true; this.reloadRules(); return; }
    if (label === '已知主机') { this.openKnownHosts(); return; }
    if (label === '调试') { this.diagOpen = true; return; }
    if (label === '设置') { this.settingsOpen = true; return; }
    if (label === '导入目录…') { this.importCatalog(); return; }
    if (label === '导出目录…') { this.exportCatalog(); return; }
  }


  @Builder
  commandPalette() {
    Column({ space: 8 }) {
      Row() {
        Text(this.lang === 'zh' ? '命令面板' : 'Command palette').id('palette/title').fontSize(14).fontWeight(FontWeight.Bold).fontColor(this.th('#E8EAED'))
        Blank()
        Button('✕').id('palette/close').height(26).width(30).fontSize(12)
          .backgroundColor(this.th('#23262B')).fontColor(this.th('#C7CBD1'))
          .onClick(() => { this.paletteOpen = false; this.paletteQuery = ''; })
      }.width('100%')
      TextInput({ placeholder: '输入命令…', text: this.paletteQuery })
        .id('palette/input').width('100%').height(36)
        .onChange((v: string) => { this.paletteIndex = 0; })
        .onKeyEvent((e: KeyEvent) => { this.paletteKey(e); })
        .onSubmit(() => { this.runPaletteCurrent(); })
        .backgroundColor(this.th('#23262B')).fontColor(this.th('#E8EAED')).placeholderColor(this.th('#6B7078'))
        .onChange((v: string) => { this.paletteQuery = v; })
      if (this.paletteLabels().length === 0) {
        Text(this.lang === 'zh' ? '没有匹配的命令' : 'No matching commands').id('palette/empty').fontSize(12).fontColor(this.th('#6B7078'))
          .width('100%').padding({ top: 12 })
      }
      List({ space: 2 }) {
        ForEach(this.paletteLabels(), (label: string, idx: number) => {
          ListItem() {
            Row() {
              Text(label).fontSize(13)
                .fontColor(this.paletteIndex === idx ? '#12141A' : this.th('#E8EAED'))
                .layoutWeight(1).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
            }
            .id('palette/item/' + idx)
            .width('100%').height(34).padding({ left: 10, right: 10 })
            .borderRadius(6)
            .backgroundColor(this.paletteIndex === idx ? '#3DDC97'
              : (this.paletteHover === idx ? this.th('#2F343B') : Color.Transparent))
            .onHover((isHover: boolean) => {
              this.paletteHover = isHover ? idx : -1;
            })
            .onClick(() => { this.runPalette(label); })
          }
        }, (label: string) => label)
      }.id('palette/list').layoutWeight(1).width('100%')
    }
    .id('palette/panel')
    .focusable(true)
    .onKeyEvent((e: KeyEvent) => { this.paletteKey(e); })
    .width(520).height(420).padding(16).backgroundColor(this.th('#1C1F24')).borderRadius(12)
    .shadow({ radius: 24, color: '#66000000', offsetY: 8 })
  }


  // 官方色板（与 host_catalog 预设一致）
  private colorChoices(): string[] {
    return ['', '#22c55e', '#eab308', '#f97316', '#ef4444', '#3b82f6', '#a855f7'];
  }

  private tagChoices(): string[] {
    return this.lang === 'zh' ? ['开发', '测试', '生产'] : ['dev', 'test', 'prod'];
  }

  private toggleFormTag(tag: string): void {
    const cur: string[] = this.tagList({ id: '', label: '', address: '', user: '', port: '',
      proto: '', group: '', tags: this.formTags, color: '' } as HostItem);
    const has: boolean = cur.indexOf(tag) >= 0;
    const next: string[] = has ? cur.filter((x: string) => x !== tag) : cur.concat([tag]);
    this.formTags = next.join(',');
  }


  // ---------------- 笔记（自研扩展页：上游导航无此项） ----------------
  private async reloadNotes(): Promise<void> {
    if (this.store === null) { return; }
    const pred = new relationalStore.RdbPredicates('notes');
    pred.orderByDesc('updated_at');
    const rs = await this.store.query(pred, NOTE_COLUMNS);
    const out: NoteItem[] = [];
    while (rs.goToNextRow()) {
      out.push({ id: rs.getString(0), title: rs.getString(1), body: rs.getString(2), updatedAt: rs.getLong(3) });
    }
    rs.close();
    this.notes = out;
  }

  private openNoteNew(): void {
    this.noteEditingId = '';
    this.noteTitle = '';
    this.noteBody = '';
    this.noteDialog = true;
  }

  private openNoteEdit(it: NoteItem): void {
    this.noteEditingId = it.id;
    this.noteTitle = it.title;
    this.noteBody = it.body;
    this.noteDialog = true;
  }

  private async submitNote(): Promise<void> {
    const title: string = this.noteTitle.trim();
    const body: string = this.noteBody.trim();
    if (title.length === 0 || this.store === null) { return; }
    if (this.noteEditingId.length > 0) {
      const pred = new relationalStore.RdbPredicates('notes');
      pred.equalTo('id', this.noteEditingId);
      const patch: relationalStore.ValuesBucket = { 'title': title, 'body': body, 'updated_at': Date.now() };
      await this.store.update(patch, pred);
    } else {
      const bucket: relationalStore.ValuesBucket = {
        'id': 'note_' + Date.now(), 'title': title, 'body': body, 'updated_at': Date.now()
      };
      await this.store.insert('notes', bucket);
    }
    this.noteDialog = false;
    this.noteEditingId = '';
    await this.settleStore();
    await this.reloadNotes();
  }

  private async deleteNote(id: string): Promise<void> {
    if (this.store === null) { return; }
    const pred = new relationalStore.RdbPredicates('notes');
    pred.equalTo('id', id);
    await this.store.delete(pred);
    await this.reloadNotes();
  }


  // ---------------- 笔记页（自研扩展，上游导航无此项） ----------------

  private notesFiltered(): NoteItem[] {
    const q: string = this.notesQuery.trim().toLowerCase();
    if (q.length === 0) { return this.notes; }
    return this.notes.filter((it: NoteItem) =>
      it.title.toLowerCase().indexOf(q) >= 0 || it.body.toLowerCase().indexOf(q) >= 0);
  }

  @Builder
  notesPage() {
    Column({ space: 10 }) {
      Row({ space: 10 }) {
        this.pageTitle(this.lang === 'zh' ? '笔记' : 'Notes', 'note/title')
        Text('(' + this.notes.length + ')').fontSize(12).fontColor(this.th('#6B7078'))
        Blank()
        Button(this.lang === 'zh' ? '新建笔记' : 'New note').id('note/add').height(30).fontSize(12)
          .backgroundColor(this.th('#E8EAED')).fontColor('#12141A')
          .onClick(() => { this.openNoteNew(); })
      }.width('100%')
      Row({ space: 10 }) {
        TextInput({ placeholder: this.lang === 'zh' ? '搜索标题或内容' : 'search title or body' })
          .id('note/search').height(34).fontSize(12).layoutWeight(1)
          .onChange((v: string) => { this.notesQuery = v; })
        Text(this.notesFiltered().length + ' / ' + this.notes.length)
          .id('note/count').fontSize(11).fontColor(this.th('#6B7078'))
      }.width('100%')
      if (this.notesFiltered().length === 0) {
        Text(this.notesQuery.trim().length > 0
          ? (this.lang === 'zh' ? '没有匹配的笔记' : 'No matching notes')
          : (this.lang === 'zh' ? '还没有笔记' : 'No notes yet')).id('note/empty')
          .fontSize(13).fontColor(this.th('#6B7078')).width('100%').padding({ top: 50 })
      }
      List({ space: 6 }) {
        ForEach(this.notesFiltered(), (it: NoteItem, idx: number) => {
          ListItem() {
            Row({ space: 12 }) {
              Column({ space: 3 }) {
                Text(it.title).fontSize(14).fontColor(this.th('#E8EAED')).maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                Text(it.body).fontSize(11).fontColor(this.th('#8A8F98')).maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
              }.alignItems(HorizontalAlign.Start).layoutWeight(1)
              Button(this.t('host.edit')).id('note/edit/' + idx).height(28).fontSize(11)
                .backgroundColor(this.th('#23262B')).fontColor(this.th('#C7CBD1'))
                .onClick(() => { this.openNoteEdit(it); })
              Button(this.t('snippet.delete')).id('note/del/' + idx).height(28).fontSize(11)
                .backgroundColor('#3A2226').fontColor('#E08A8A')
                .onClick(() => { this.deleteNote(it.id); })
            }
            .width('100%').height(52).padding({ left: 12, right: 12 })
            .borderRadius(8).backgroundColor(this.th('#1C1F24'))
          }
        }, (it: NoteItem) => it.id + '|' + it.title + '|' + it.body)
      }.id('note/list').layoutWeight(1).width('100%')
    }
    .width('100%').height('100%').padding({ left: 22, right: 22, top: 10 })
  }

  @Builder
  noteForm() {
    Column({ space: 10 }) {
      Text(this.noteEditingId.length > 0 ? this.t('host.edit') : (this.lang === 'zh' ? '新建笔记' : 'New note'))
        .fontSize(16).fontWeight(FontWeight.Bold).fontColor(this.th('#E8EAED')).width('100%')
      TextInput({ placeholder: this.lang === 'zh' ? '标题' : 'Title', text: this.noteTitle })
        .id('note/dialog-title').width('100%')
        .backgroundColor(this.th('#23262B')).fontColor(this.th('#E8EAED')).placeholderColor(this.th('#6B7078'))
        .onChange((v: string) => { this.noteTitle = v; })
      TextArea({ placeholder: this.lang === 'zh' ? '内容' : 'Body', text: this.noteBody })
        .id('note/dialog-body').width('100%').height(160)
        .backgroundColor(this.th('#23262B')).fontColor(this.th('#E8EAED')).placeholderColor(this.th('#6B7078'))
        .onChange((v: string) => { this.noteBody = v; })
      Row({ space: 12 }) {
        Button(this.t('hostkey.cancel')).id('note/dialog-cancel').backgroundColor(this.th('#23262B')).fontColor(this.th('#C7CBD1'))
          .onClick(() => { this.noteDialog = false; })
        Button(this.t('snippet.save')).id('note/dialog-save').backgroundColor('#3DDC97').fontColor('#12141A')
          .onClick(() => { this.submitNote(); })
      }.width('100%').justifyContent(FlexAlign.End)
    }
    .id('note/dialog').width(520).padding(20).backgroundColor(this.th('#1C1F24')).borderRadius(14)
    .shadow({ radius: 24, color: '#66000000', offsetY: 8 })
  }


  private paletteKey(e: KeyEvent): void {
    const n: number = this.paletteLabels().length;
    if (e.type !== KeyType.Down || n === 0) { return; }
    if (e.keyCode === 2012) {
      this.paletteIndex = (this.paletteIndex + n - 1) % n;
    } else if (e.keyCode === 2013) {
      this.paletteIndex = (this.paletteIndex + 1) % n;
    } else if (e.keyCode === 2070) {
      // Esc = 关闭命令面板（KEYCODE_ESCAPE = 2070，官方文档确认）
      this.paletteOpen = false;
      this.paletteQuery = '';
      this.paletteHover = -1;
    } else if (e.keyCode === 2054) {
      const labels: string[] = this.paletteLabels();
      if (this.paletteIndex >= 0 && this.paletteIndex < labels.length) {
        this.runPalette(labels[this.paletteIndex]);
      }
    }
  }

  private runPaletteCurrent(): void {
    const labels: string[] = this.paletteLabels();
    if (this.paletteIndex >= 0 && this.paletteIndex < labels.length) {
      this.runPalette(labels[this.paletteIndex]);
    }
  }


  private openPalette(): void {
    this.paletteOpen = true;
    this.paletteQuery = '';
    this.paletteIndex = 0;
    // 面板打开后必须把焦点放进输入框，否则 keyEvent 没有接收者（实测回车/方向键都不会触发）
    setTimeout(() => {
      try {
        this.getUIContext().getFocusController().requestFocus('palette/input');
      } catch (e) {
        hilog.error(DOMAIN, TAG, 'requestFocus palette failed: %{public}s', JSON.stringify(e));
      }
    }, 120);
  }


  private askDeleteSelected(): void {
    if (this.selectedIds.length === 0) { return; }
    this.deleteIds = this.selectedIds.slice();
    this.deleteIndex = -1;
    this.deleteDialog = true;
  }


  // 删除已信任主机密钥（官方 KnownHostsDelete* 文案）
  @Builder
  knownDeleteConfirm() {
    Column({ space: 10 }) {
      Text(this.lang === 'zh' ? '删除已信任主机密钥？' : 'Delete trusted host key?')
        .id('knowndel/title').fontSize(16).fontWeight(FontWeight.Bold).fontColor(this.th('#E8EAED')).width('100%')
      Text((this.lang === 'zh'
        ? '要从 known_hosts 删除这条记录吗？此操作无法撤销。'
        : 'Remove this entry from known_hosts? This cannot be undone.'))
        .fontSize(12).fontColor(this.th('#8A8F98')).width('100%')
      Text(this.knownDelKey).fontSize(11).fontFamily('monospace').fontColor(this.th('#C7CBD1')).width('100%')
      Row({ space: 12 }) {
        Button(this.t('hostkey.cancel')).id('knowndel/cancel').backgroundColor(this.th('#23262B')).fontColor(this.th('#C7CBD1'))
          .onClick(() => { this.knownDelKey = ''; })
        Button(this.lang === 'zh' ? '删除记录' : 'Delete entry').id('knowndel/confirm')
          .backgroundColor('#C62828').fontColor(Color.White)
          .onClick(() => { const k = this.knownDelKey; this.knownDelKey = ''; this.deleteKnownHost(k); })
      }.width('100%').justifyContent(FlexAlign.End)
    }
    .id('knowndel/dialog').width(520).padding(20).backgroundColor(this.th('#1C1F24')).borderRadius(12)
    .shadow({ radius: 24, color: '#66000000', offsetY: 8 })
  }

  // 删除已保存凭据（官方 Vault/Key 删除语义）
  @Builder
  vaultDeleteConfirm() {
    Column({ space: 10 }) {
      Text(this.lang === 'zh' ? '删除已保存的密码？' : 'Delete saved password?')
        .id('vaultdel/title').fontSize(16).fontWeight(FontWeight.Bold).fontColor(this.th('#E8EAED')).width('100%')
      Text(this.lang === 'zh'
        ? '它会从这台电脑上删除，下次需要时会再次询问。'
        : 'It will be removed from this device; you will be asked again next time.')
        .fontSize(12).fontColor(this.th('#8A8F98')).width('100%')
      Text(this.vaultDelKey).fontSize(11).fontFamily('monospace').fontColor(this.th('#C7CBD1')).width('100%')
      Row({ space: 12 }) {
        Button(this.t('hostkey.cancel')).id('vaultdel/cancel').backgroundColor(this.th('#23262B')).fontColor(this.th('#C7CBD1'))
          .onClick(() => { this.vaultDelKey = ''; })
        Button(this.lang === 'zh' ? '删除' : 'Delete').id('vaultdel/confirm')
          .backgroundColor('#C62828').fontColor(Color.White)
          .onClick(async () => {
            const k = this.vaultDelKey;
            this.vaultDelKey = '';
            await Vault.remove(k);
            this.creds.delete(k);
            this.probeText = 'credential removed: ' + k;
          })
      }.width('100%').justifyContent(FlexAlign.End)
    }
    .id('vaultdel/dialog').width(520).padding(20).backgroundColor(this.th('#1C1F24')).borderRadius(12)
    .shadow({ radius: 24, color: '#66000000', offsetY: 8 })
  }


  // 把自解码整帧写成 BMP 用于 Image 显示（ArkUI Image 支持 bmp）
  private updateRdpFrame(): void {
    // 帧没变就不重复写 3MB 文件：用 C++ 侧的已解压帧序号判断
    let seq: number = -1;
    try {
      seq = mottynapi.rdpFrameSeq() as number;
    } catch (e) {
      seq = -1;
    }
    if (seq >= 0 && seq === this.rdpFrameLastSeq) {
      this.rdpFrameSkips = this.rdpFrameSkips + 1;
      this.rdpFrameInfo = 'bmp: skip unchanged writes=' + this.rdpFrameWrites + ' skipped=' + this.rdpFrameSkips;
      return;
    }
    this.rdpFrameLastSeq = seq;
    const ctx = getContext(this) as common.UIAbilityContext;
    const dir: string = ctx !== undefined && ctx.cacheDir !== undefined ? ctx.cacheDir : '/data/storage/el2/base/cache';
    const path: string = dir + '/rdp-frame.bmp';
    let rc: number = -99;
    try {
      rc = mottynapi.rdpWriteBmp(path) as number;
    } catch (e) {
      this.rdpFrameInfo = 'bmp: rdpWriteBmp threw';
      return;
    }
    if (rc === 0) {
      this.rdpFrameWrites = this.rdpFrameWrites + 1;
      this.rdpFrameSrc = 'file://' + path + '?v=' + Date.now();
      this.rdpFrameInfo = 'bmp: 1024x768 written writes=' + this.rdpFrameWrites;
    } else {
      this.rdpFrameInfo = 'bmp: rc=' + rc;
    }
  }

  // 按需刷新：1.5s 一次（3MB/帧，太频繁会拖垮 UI；这是"能看"的最小实现）


  // ---------------- RDP 会话视图 ----------------
  private openRdpSession(h: HostItem): void {
    const port: number = Number.parseInt(h.port, 10) || 3389;
    this.rdpSessionOpen = true;
    this.rdpSessionTitle = h.label;
    this.rdpSessionFrame = '';
    this.rdpSessionStatus = 'connecting ' + h.address + ':' + port;
    const key: string = this.hostKey(h.address, h.port);
    const cred = this.creds.get(key);
    const user: string = cred !== undefined ? cred.user : h.user;
    const pass: string = cred !== undefined ? cred.password : '';
    this.rdpSessionHostAddr = h.address;
    this.rdpSessionHostPort = port;
    this.rdpSessionUser = user;
    this.rdpSessionPass = pass;
    this.renderRdpSession(h.address, port, user, pass);
  }

  private renderRdpSession(host: string, port: number, user: string, pass: string): void {
    this.rdpSessionStatus = 'rendering ' + host + ':' + port + ' ...';
    try {
      mottynapi.rdpRender(host, port, user, pass, (err: string, res: string) => {
        const msg: string = (res === undefined || res === null) ? String(err) : String(res);
        this.rdpSessionStatus = 'render: ' + msg;
        this.writeRdpSessionFrame();
      });
    } catch (e) {
      this.rdpSessionStatus = 'render threw: ' + JSON.stringify(e);
    }
  }

  private writeRdpSessionFrame(): void {
    const ctx = getContext(this) as common.UIAbilityContext;
    const dir: string = ctx !== undefined && ctx.cacheDir !== undefined ? ctx.cacheDir : '/data/storage/el2/base/cache';
    const path: string = dir + '/rdp-session.bmp';
    const seq: number = mottynapi.rdpFrameSeq();
    if (seq < 0) {
      this.rdpSessionStatus = this.rdpSessionStatus + ' | no decoded frame yet';
      return;
    }
    const rc: number = mottynapi.rdpWriteBmp(path) as number;
    if (rc === 0) {
      this.rdpSessionFrame = 'file://' + path + '?v=' + Date.now();
      this.rdpSessionStatus = this.rdpSessionStatus + ' | bmp seq=' + seq;
    } else {
      this.rdpSessionStatus = this.rdpSessionStatus + ' | bmp rc=' + rc;
    }
  }

  private closeRdpSession(): void {
    this.rdpSessionOpen = false;
    this.rdpSessionFrame = '';
    this.rdpSessionStatus = 'closed';
  }

  // 会话内投递输入：复用输入探针（连接→发送固定键鼠→回读服务端统计）
  // 这不是"真实桌面鼠标"，只是把输入投递链路打通并给出服务端可见的证据。
  private sendRdpSessionInput(): void {
    const host: string = this.rdpSessionHostAddr;
    const port: number = this.rdpSessionHostPort;
    const user: string = this.rdpSessionUser;
    const pass: string = this.rdpSessionPass;
    this.rdpSessionStatus = 'sending input ...';
    try {
      mottynapi.rdpInputProbe(host, port, user, pass, (err: string, res: string) => {
        const msg: string = (res === undefined || res === null) ? String(err) : String(res);
        this.rdpSessionStatus = msg;
      });
    } catch (e) {
      this.rdpSessionStatus = 'input threw: ' + JSON.stringify(e);
    }
  }

  private stopRdpPreview(): void {
    this.rdpPreviewOn = false;
    if (this.rdpPreviewTimer !== -1) {
      clearInterval(this.rdpPreviewTimer);
      this.rdpPreviewTimer = -1;
    }
  }

  private toggleRdpPreview(): void {
    if (this.rdpPreviewOn) {
      this.rdpPreviewOn = false;
      if (this.rdpPreviewTimer !== -1) {
        clearInterval(this.rdpPreviewTimer);
        this.rdpPreviewTimer = -1;
      }
      this.rdpFrameInfo = 'bmp: paused writes=' + this.rdpFrameWrites;
      return;
    }
    this.rdpPreviewOn = true;
    this.updateRdpFrame();
    this.rdpPreviewTimer = setInterval(() => {
      if (this.rdpPreviewOn) {
        this.updateRdpFrame();
      }
    }, 1500);
  }


  // RDP 预览条：独立容器（避免改动既有按钮行的布局）。
  // 点按钮 -> NAPI 把自解码整帧写成 BMP -> Image 以 file:// 加载显示。
  @Builder
  rdpPreviewStrip() {
    Column({ space: 6 }) {
      Row({ space: 8 }) {
        Button((this.lang === 'zh' ? (this.rdpPreviewOn ? '停止预览' : 'RDP 预览') : (this.rdpPreviewOn ? 'Stop preview' : 'RDP preview')))
          .id('rdp/frame-btn').height(28).fontSize(12)
          .backgroundColor('#0F766E').fontColor(Color.White)
          .onClick(() => { this.toggleRdpPreview(); })
        Text(this.rdpFrameInfo).id('rdp/frame-info').fontSize(10).fontColor(this.th('#8A8F98'))
      }.width('100%').justifyContent(FlexAlign.Start)
      if (this.rdpFrameSrc.length > 0) {
        Image(this.rdpFrameSrc).id('rdp/frame').width(512).height(384)
          .objectFit(ImageFit.Fill).border({ width: 1, color: this.th('#3A3F46') })
      }
    }.width('100%').alignItems(HorizontalAlign.Start)
  }


  // ---------------- 诊断面板 v2：分页（解决 1324px 垂直预算不足）----------------
  @Builder
  diagTabBtn(label: string, key: string) {
    Button(label)
      .id('diag/tab-' + key)
      .height(28).fontSize(12)
      .backgroundColor(this.diagTab === key ? '#1A6DD0' : '#E6E6E6')
      .fontColor(this.diagTab === key ? Color.White : '#1A1A1A')
      .onClick(() => { this.diagTab = key; })
  }

  @Builder
  diagPanelV2() {
    Column({ space: 8 }) {
      Row() {
        Text(this.t('diag.title')).fontSize(16).fontWeight(FontWeight.Bold)
        Blank()
        Button(this.t('common.close')).id('diag/close').backgroundColor('#E6E6E6').fontColor('#1A1A1A')
          .onClick(() => { this.diagOpen = false; this.stopRdpPreview(); })
      }.width('100%')
      Row({ space: 8 }) {
        this.diagTabBtn('RDP', 'rdp')
        this.diagTabBtn('调试', 'debug')
        this.diagTabBtn('快照', 'snap')
      }.width('100%').justifyContent(FlexAlign.Start)

      if (this.diagTab === 'rdp') {
        Text(this.rdpSrvStatus.length > 0 ? this.rdpSrvStatus : 'rdp-server: (idle)')
          .id('rdp/srv-state').fontSize(11).fontFamily('monospace').fontColor('#0A6C00').width('100%')
        Text(this.rdpResult.length > 0 ? this.rdpResult : 'rdp: (not probed)')
          .id('rdp/result').fontSize(11).fontFamily('monospace').fontColor('#37474F').width('100%')
        Row({ space: 8 }) {
          Button(this.t('rdp.srvStart')).id('rdp/srv-start').backgroundColor('#0A6C00').fontColor(Color.White)
            .onClick(() => { this.startRdpServer(); })
          Button(this.t('rdp.srvStop')).id('rdp/srv-stop').backgroundColor('#C62828').fontColor(Color.White)
            .onClick(() => { this.stopRdpServer(); })
          Button(this.t('rdp.srvStatus')).id('rdp/srv-status').backgroundColor('#37474F').fontColor(Color.White)
            .onClick(() => { this.refreshRdpServer(); })
        }.width('100%')
        this.rdpPreviewStrip()
        Row({ space: 8 }) {
          Button(this.t('rdp.local') + ' :13389').id('rdp/probe-local').backgroundColor('#1A6DD0').fontColor(Color.White)
            .onClick(() => { this.rdpProbe(13389, 'tester', 'secret'); })
          Button('RDP render').id('rdp/render').backgroundColor('#1A6DD0').fontColor(Color.White)
            .onClick(() => { this.startRdpRender(); })
          Button('RDP input').id('rdp/input').backgroundColor('#1A6DD0').fontColor(Color.White)
            .onClick(() => { this.probeRdpInput(); })
          Button('TCP').id('rdp/tcpprobe').backgroundColor('#37474F').fontColor(Color.White)
            .onClick(() => {
              const p2: number = Number.parseInt(this.rdpTargetPort, 10);
              this.rdpResult = 'tcp-probe: ' +
                mottynapi.rawTcpProbe(this.rdpTargetHost, Number.isNaN(p2) ? 3389 : p2);
            })
        }.width('100%')
        Row({ space: 8 }) {
          Button('RDP :3390').id('rdp/probe-closed').backgroundColor('#37474F').fontColor(Color.White)
            .onClick(() => { this.rdpProbe(3390); })
          Button('RDP :2222').id('rdp/probe-ssh').backgroundColor('#37474F').fontColor(Color.White)
            .onClick(() => { this.rdpProbe(2222); })
        }.width('100%')
        Row({ space: 6 }) {
          TextInput({ text: this.rdpTargetHost, placeholder: 'host' }).id('rdp/host').width(150)
            .onChange((v: string) => { this.rdpTargetHost = v; })
          TextInput({ text: this.rdpTargetPort, placeholder: 'port' }).id('rdp/port').width(70)
            .onChange((v: string) => { this.rdpTargetPort = v; })
          TextInput({ text: this.rdpTargetUser, placeholder: 'user' }).id('rdp/user').width(110)
            .onChange((v: string) => { this.rdpTargetUser = v; })
          TextInput({ text: this.rdpTargetPass, placeholder: 'password' }).id('rdp/pass').type(InputType.Password).width(110)
            .onChange((v: string) => { this.rdpTargetPass = v; })
          Toggle({ type: ToggleType.Checkbox, isOn: this.rdpUseNla }).id('rdp/nla')
            .onChange((v: boolean) => { this.rdpUseNla = v; })
          Text('NLA').fontSize(11)
        }.width('100%')
      }

      if (this.diagTab === 'debug') {
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
        }.width('100%')
        Row({ space: 8 }) {
          Button('VNC session').id('vnc/session').backgroundColor('#6A1B9A').fontColor(Color.White)
            .onClick(() => { this.diagOpen = false; this.stopRdpPreview(); this.startVnc('secret'); })
          Button('VNC bad pw').id('vnc/session-bad').backgroundColor('#C62828').fontColor(Color.White)
            .onClick(() => { this.diagOpen = false; this.stopRdpPreview(); this.startVnc('wrong-password'); })
        }.width('100%')
        Row({ space: 8 }) {
          Button('catalog export').id('catalog/export-file').fontSize(11).height(28)
            .backgroundColor(this.th('#1E2127')).fontColor(this.th('#C7CBD1'))
            .onClick(() => { this.exportCatalogToSandbox(); })
          Button('catalog import').id('catalog/import-file').fontSize(11).height(28)
            .backgroundColor(this.th('#1E2127')).fontColor(this.th('#C7CBD1'))
            .onClick(() => { this.importCatalogFromSandbox(); })
          Button('catalog reset hosts').id('catalog/reset-hosts').fontSize(11).height(26)
            .backgroundColor('#3A2226').fontColor('#E08A8A')
            .onClick(() => { this.resetAllHosts(); })
        }.width('100%')
        Text(this.catalogResult).id('catalog/result').fontSize(11).fontFamily('monospace')
          .fontColor('#0A6C00').width('100%')
        Row({ space: 8 }) {
          Button(this.t('diag.tcpProbe')).id('net/probe').backgroundColor('#E6E6E6').fontColor('#1A1A1A')
            .onClick(() => { this.probeNet(); })
          Button(this.t('diag.sshProbe')).id('ssh/probe').backgroundColor('#E6E6E6').fontColor('#1A1A1A')
            .onClick(() => { this.probeSsh(); })
          Button(this.t('diag.hostkeyCheck')).id('ssh/hostkey-check').backgroundColor('#E6E6E6').fontColor('#1A1A1A')
            .onClick(() => { this.hostkeyCheck(); })
        }.width('100%')
        Text(this.vncResult.length > 0 ? this.vncResult : 'vnc: (not probed)')
          .id('vnc/result').fontSize(11).fontFamily('monospace').fontColor('#6A1B9A').width('100%')
        Scroll() {
          Text(this.probeText).id('net/probe-result').fontSize(11).fontFamily('monospace')
            .fontColor(this.th('#C7CBD1')).width('100%')
        }.height(80).width('100%').border({ width: 1, color: this.th('#22252A') }).padding(8)
      }

      if (this.diagTab === 'snap') {
        Text(this.rdpSnapInfo).id('rdp/canvas-info').fontSize(11).fontFamily('monospace').fontColor('#0A6C00')
        Text('ticks=' + this.rdpTickCount + ' drawn=' + this.rdpTickDrawn).id('rdp/ticks').fontSize(11).fontColor('#0A6C00')
        Canvas(this.rdpCanvasCtx)
          .id('rdp/canvas')
          .width(512).height(384)
          .backgroundColor('#000000')
        Text(this.lang === 'zh' ? 'RDP：实验性' : 'RDP is experimental')
          .id('rdp/experimental').fontSize(11).fontWeight(FontWeight.Bold)
          .fontColor('#E0A458').width('100%')
        Text(this.lang === 'zh'
          ? '画面已能解码并投递到界面；输入可发送到服务端。仍属实验性。'
          : 'picture is decoded and delivered; input reaches the server. Still experimental.')
          .id('rdp/experimental-note').fontSize(10).fontColor(this.th('#8A8F98')).width('100%')
      }
    }
    .id('diag/panel').width(680).padding(16).backgroundColor(this.th('#1C1F24')).borderRadius(12)
    .shadow({ radius: 24, color: '#33000000', offsetY: 8 })
  }


  // 重命名分组
  @Builder
  groupRenameDialog() {
    Column({ space: 10 }) {
      Text(this.lang === 'zh' ? '重命名分组' : 'Rename group')
        .id('grouprename/title').fontSize(16).fontWeight(FontWeight.Bold).fontColor(this.th('#E8EAED')).width('100%')
      TextInput({ text: this.groupRenameText, placeholder: this.sectionLabel(this.groupRenameOld) })
        .id('grouprename/input').width('100%')
        .onChange((v: string) => { this.groupRenameText = v; })
      if (this.groupRenameError.length > 0) {
        Text(this.groupRenameError).id('grouprename/error').fontSize(11).fontColor('#E08A8A').width('100%')
      }
      Row({ space: 12 }) {
        Button(this.t('hostkey.cancel')).id('grouprename/cancel').backgroundColor(this.th('#23262B')).fontColor(this.th('#C7CBD1'))
          .onClick(() => { this.groupRenameOpen = false; })
        Button(this.lang === 'zh' ? '重命名' : 'Rename').id('grouprename/confirm')
          .backgroundColor('#3DDC97').fontColor('#12141A')
          .onClick(() => { this.submitRenameGroup(); })
      }.width('100%').justifyContent(FlexAlign.End)
    }
    .id('grouprename/dialog').width(420).padding(20).backgroundColor(this.th('#1C1F24')).borderRadius(12)
    .shadow({ radius: 24, color: '#66000000', offsetY: 8 })
  }

  // 删除分组（组内主机移回默认组，主机不删）
  @Builder
  groupDeleteDialog() {
    Column({ space: 10 }) {
      Text(this.lang === 'zh' ? '删除分组？' : 'Delete group?')
        .id('groupdel/title').fontSize(16).fontWeight(FontWeight.Bold).fontColor(this.th('#E8EAED')).width('100%')
      Text(this.lang === 'zh'
        ? '组内主机会回到默认组，主机本身不会被删除。'
        : 'Hosts in this group move to the default group; the hosts themselves are kept.')
        .fontSize(12).fontColor(this.th('#8A8F98')).width('100%')
      Text(this.sectionLabel(this.groupDelName)).fontSize(11).fontColor(this.th('#C7CBD1')).width('100%')
      Row({ space: 12 }) {
        Button(this.t('hostkey.cancel')).id('groupdel/cancel').backgroundColor(this.th('#23262B')).fontColor(this.th('#C7CBD1'))
          .onClick(() => { this.groupDelName = ''; })
        Button(this.lang === 'zh' ? '删除分组' : 'Delete group').id('groupdel/confirm')
          .backgroundColor('#C62828').fontColor(Color.White)
          .onClick(() => { this.confirmDeleteGroup(); })
      }.width('100%').justifyContent(FlexAlign.End)
    }
    .id('groupdel/dialog').width(420).padding(20).backgroundColor(this.th('#1C1F24')).borderRadius(12)
    .shadow({ radius: 24, color: '#66000000', offsetY: 8 })
  }


  // 分组操作菜单（自定义弹出层：bindMenu 不在 uitest dump 里，无法自动化，所以自己做）
  @Builder
  groupMenuPopup() {
    Column({ space: 2 }) {
      this.menuItem(this.lang === 'zh' ? '上移分组' : 'Move group up', 'groupmenu/up', () => { this.moveGroupFromMenu(-1); })
      this.menuItem(this.lang === 'zh' ? '下移分组' : 'Move group down', 'groupmenu/down', () => { this.moveGroupFromMenu(1); })
      this.menuItem(this.lang === 'zh' ? '固定/取消固定' : 'Pin/Unpin', 'groupmenu/pin', () => { this.togglePin(this.groupMenuTarget); this.groupMenu = ''; })
      this.menuItem(this.lang === 'zh' ? '重命名分组' : 'Rename group', 'groupmenu/rename', () => { const g = this.groupMenuTarget; this.groupMenu = ''; this.openRenameGroup(g); })
      this.menuItemDanger(this.lang === 'zh' ? '删除分组' : 'Delete group', 'groupmenu/delete', () => { const g = this.groupMenuTarget; this.groupMenu = ''; this.askDeleteGroup(g); })
      Button(this.t('hostkey.cancel')).id('groupmenu/close').width('100%').fontSize(12)
        .backgroundColor(this.th('#1E2127')).fontColor(this.th('#8A8F98'))
        .onClick(() => { this.groupMenu = ''; })
    }
    .id('groupmenu/panel').width(220).padding(10).backgroundColor(this.th('#1C1F24')).borderRadius(10)
    .shadow({ radius: 20, color: '#66000000', offsetY: 6 })
  }


  // RDP 会话视图：大画面 + 刷新（上游的 RDP 会话窗口的最小实现）
  @Builder
  rdpSessionView() {
    Column({ space: 8 }) {
      Row({ space: 10 }) {
        Text((this.lang === 'zh' ? 'RDP 会话：' : 'RDP session: ') + this.rdpSessionTitle)
          .id('rdp/session-title').fontSize(15).fontWeight(FontWeight.Bold).fontColor(this.th('#E8EAED'))
        Blank()
        Button(this.lang === 'zh' ? '刷新' : 'Refresh').id('rdp/session-refresh')
          .height(30).fontSize(12).backgroundColor('#1A6DD0').fontColor(Color.White)
          .onClick(() => {
            // 重新连接并渲染一帧（对端可能是 shadow 服务端或真实 RDP）
            this.rdpSessionStatus = 'refreshing ...';
            this.renderRdpSession(this.rdpSessionHostAddr, this.rdpSessionHostPort,
              this.rdpSessionUser, this.rdpSessionPass);
          })
        Button(this.lang === 'zh' ? '发送输入' : 'Send input').id('rdp/session-input')
          .height(30).fontSize(12).backgroundColor('#37474F').fontColor(Color.White)
          .onClick(() => { this.sendRdpSessionInput(); })
        Button(this.t('common.close')).id('rdp/session-close')
          .height(30).fontSize(12).backgroundColor(this.th('#23262B')).fontColor(this.th('#C7CBD1'))
          .onClick(() => { this.closeRdpSession(); })
      }.width('100%')
      if (this.rdpSessionFrame.length > 0) {
        Image(this.rdpSessionFrame).id('rdp/session-frame')
          .width(700).height(525).objectFit(ImageFit.Contain)
          .backgroundColor('#000000').border({ width: 1, color: this.th('#3A3F46') })
      } else {
        Column() {
          Text(this.lang === 'zh' ? '正在获取画面…' : 'fetching picture ...')
            .fontSize(13).fontColor(this.th('#8A8F98'))
        }.width(700).height(525).justifyContent(FlexAlign.Center)
        .backgroundColor(this.th('#0B0D10')).border({ width: 1, color: this.th('#3A3F46') })
        .id('rdp/session-placeholder')
      }
      Text(this.rdpSessionStatus).id('rdp/session-status')
        .fontSize(11).fontFamily('monospace').fontColor(this.th('#C7CBD1'))
    }
    .id('rdp/session-view')
    .padding(16).backgroundColor('#12141A').borderRadius(12)
    .shadow({ radius: 28, color: '#88000000', offsetY: 10 })
  }


  // 主机详情（只读信息卡）：从名称列的 ⓘ 打开
  @Builder
  hostDetailPanel() {
    Column({ space: 8 }) {
      Row({ space: 10 }) {
        Text(this.lang === 'zh' ? '主机详情' : 'Host details')
          .id('hostdetail/title').fontSize(16).fontWeight(FontWeight.Bold).fontColor(this.th('#E8EAED'))
        Blank()
        Button(this.t('common.close')).id('hostdetail/close').height(28).fontSize(12)
          .backgroundColor(this.th('#23262B')).fontColor(this.th('#C7CBD1'))
          .onClick(() => { this.hostDetailIndex = -1; })
      }.width('100%')
      if (this.hostDetailIndex >= 0 && this.hostDetailIndex < this.hosts.length) {
        Column({ space: 6 }) {
          this.detailRow('hostdetail/label', this.lang === 'zh' ? '名称' : 'Name', this.hosts[this.hostDetailIndex].label)
          this.detailRow('hostdetail/address', this.lang === 'zh' ? '地址' : 'Address',
            this.hosts[this.hostDetailIndex].address + ':' + this.hosts[this.hostDetailIndex].port)
          this.detailRow('hostdetail/proto', this.lang === 'zh' ? '协议' : 'Protocol',
            this.hosts[this.hostDetailIndex].proto.toUpperCase())
          this.detailRow('hostdetail/user', this.lang === 'zh' ? '用户' : 'User',
            this.hosts[this.hostDetailIndex].user.length > 0 ? this.hosts[this.hostDetailIndex].user : '-')
          this.detailRow('hostdetail/group', this.lang === 'zh' ? '分组' : 'Group',
            this.hosts[this.hostDetailIndex].group.length > 0 ? this.hosts[this.hostDetailIndex].group : '-')
          this.detailRow('hostdetail/tags', this.lang === 'zh' ? '标签' : 'Tags',
            this.hosts[this.hostDetailIndex].tags.length > 0 ? this.hosts[this.hostDetailIndex].tags : '-')
          this.detailRow('hostdetail/icon', this.lang === 'zh' ? '图标' : 'Icon',
            this.hosts[this.hostDetailIndex].icon.length > 0 ? this.hosts[this.hostDetailIndex].icon : '-')
          this.detailRow('hostdetail/color', this.lang === 'zh' ? '颜色' : 'Color',
            this.hosts[this.hostDetailIndex].color.length > 0 ? this.hosts[this.hostDetailIndex].color : '-')
          this.detailRow('hostdetail/lastused', this.lang === 'zh' ? '最近连接' : 'Last used',
            this.lastUsedText(this.hosts[this.hostDetailIndex]))
        }.width('100%').alignItems(HorizontalAlign.Start)
        Row({ space: 10 }) {
          Button(this.t('host.open')).id('hostdetail/open').height(30).fontSize(12)
            .backgroundColor('#2F6F4F').fontColor(Color.White)
            .onClick(() => {
              const idx: number = this.hostDetailIndex;
              this.hostDetailIndex = -1;
              this.openSession(this.hosts[idx].label, idx);
            })
          Button(this.t('host.edit')).id('hostdetail/edit').height(30).fontSize(12)
            .backgroundColor(this.th('#23262B')).fontColor(this.th('#C7CBD1'))
            .onClick(() => {
              const idx: number = this.hostDetailIndex;
              this.hostDetailIndex = -1;
              this.openEditHost(idx);
            })
          Button(this.t('host.del')).id('hostdetail/delete').height(30).fontSize(12)
            .backgroundColor('#3A2226').fontColor('#E08A8A')
            .onClick(() => {
              const idx: number = this.hostDetailIndex;
              this.hostDetailIndex = -1;
              this.askDeleteHost(idx);
            })
        }.width('100%').justifyContent(FlexAlign.End).margin({ top: 6 })
      }
    }
    .id('hostdetail/panel').width(420).padding(18).backgroundColor(this.th('#1C1F24')).borderRadius(12)
    .shadow({ radius: 24, color: '#66000000', offsetY: 8 })
  }

  @Builder
  detailRow(idName: string, k: string, v: string) {
    Row({ space: 10 }) {
      Text(k).id(idName + '-k').fontSize(12).fontColor(this.th('#8A8F98')).width(90)
      Text(v).id(idName).fontSize(12).fontColor(this.th('#E8EAED')).layoutWeight(1)
        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
    }.width('100%')
  }


  // 密钥链：新增凭据对话框（输入框非受控，避免 IME 回填）
  @Builder
  vaultAddDialog() {
    Column({ space: 10 }) {
      Text(this.lang === 'zh' ? '新增凭据' : 'Add credential')
        .id('vaultadd/title').fontSize(16).fontWeight(FontWeight.Bold).fontColor(this.th('#E8EAED')).width('100%')
      TextInput({ placeholder: this.lang === 'zh' ? '地址（如 127.0.0.1）' : 'address' })
        .id('vaultadd/addr').width('100%').height(36)
        .onChange((v: string) => { this.vaultAddr = v; })
      TextInput({ placeholder: this.lang === 'zh' ? '端口（如 22）' : 'port' })
        .id('vaultadd/port').width('100%').height(36)
        .onChange((v: string) => { this.vaultPort = v; })
      TextInput({ placeholder: this.lang === 'zh' ? '用户名（可选）' : 'user (optional)' })
        .id('vaultadd/user').width('100%').height(36)
        .onChange((v: string) => { this.vaultUser = v; })
      TextInput({ placeholder: this.lang === 'zh' ? '密码' : 'password' })
        .id('vaultadd/pw').width('100%').height(36).type(InputType.Password)
        .onChange((v: string) => { this.vaultPw = v; })
      Row({ space: 12 }) {
        this.btnSecondary(this.t('hostkey.cancel'), 'vaultadd/cancel', () => { this.vaultAddOpen = false; })
        this.btnPrimary(this.t('common.save'), 'vaultadd/save', () => { this.saveVaultEntry(); })
      }.width('100%').justifyContent(FlexAlign.End)
    }
    .id('vaultadd/dialog').width(420).padding(18).backgroundColor(this.th('#1C1F24')).borderRadius(12)
    .shadow({ radius: 24, color: '#66000000', offsetY: 8 })
  }


  @Builder
  tabRenameDialog() {
    Column({ space: 10 }) {
      Text(this.lang === 'zh' ? '重命名会话' : 'Rename session')
        .id('tabrename/title').fontSize(16).fontWeight(FontWeight.Bold).fontColor(this.th('#E8EAED')).width('100%')
      TextInput({ placeholder: this.lang === 'zh' ? '新的会话名' : 'new session name' })
        .id('tabrename/input').width('100%').height(36)
        .onChange((v: string) => { this.tabRenameText = v; })
      Row({ space: 12 }) {
        this.btnSecondary(this.t('hostkey.cancel'), 'tabrename/cancel', () => { this.tabRenameOpen = false; })
        this.btnPrimary(this.t('common.save'), 'tabrename/save', () => { this.submitTabRename(); })
      }.width('100%').justifyContent(FlexAlign.End)
    }
    .id('tabrename/dialog').width(420).padding(18).backgroundColor(this.th('#1C1F24')).borderRadius(12)
    .shadow({ radius: 24, color: '#66000000', offsetY: 8 })
  }


  // 主机行"更多"菜单（自绘，保证可被用例点击；对齐上游右键/⋯ 菜单）
  @Builder
  hostMoreMenu() {
    Column({ space: 2 }) {
      this.btnSecondary(this.t('host.open'), 'hostmenu/open', () => { const i = this.hostMenuIndex; this.hostMenuIndex = -1; this.openSession(this.hosts[i].label, i); })
      this.btnSecondary(this.t('host.edit'), 'hostmenu/edit', () => { const i = this.hostMenuIndex; this.hostMenuIndex = -1; this.openEditHost(i); })
      Button(this.lang === 'zh' ? '详情' : 'Details').id('hostmenu/detail').width('100%').fontSize(13)
        .backgroundColor(this.th('#23262B')).fontColor(this.th('#C7CBD1'))
        .onClick(() => { const i = this.hostMenuIndex; this.hostMenuIndex = i; this.hostDetailIndex = i; })
      Button(this.lang === 'zh' ? '复制地址' : 'Copy address').id('hostmenu/copy').width('100%').fontSize(13)
        .backgroundColor(this.th('#23262B')).fontColor(this.th('#C7CBD1'))
        .onClick(() => { const i = this.hostMenuIndex; this.hostMenuIndex = -1; this.copyHostAddress(this.hosts[i]); })
      this.btnDanger(this.t('host.del'), 'hostmenu/delete', () => { const i = this.hostMenuIndex; this.hostMenuIndex = -1; this.askDeleteHost(i); })
      Button(this.t('common.close')).id('hostmenu/close').width('100%').fontSize(12)
        .backgroundColor(this.th('#1E2127')).fontColor(this.th('#8A8F98'))
        .onClick(() => { this.hostMenuIndex = -1; })
    }
    .id('hostmenu/panel').width(200).padding(10).backgroundColor(this.th('#1C1F24')).borderRadius(10)
    .shadow({ radius: 20, color: '#66000000', offsetY: 6 })
  }


  // AI 面板（顶栏 top/ai 的落地）：用当前终端尾部内容作为上下文提问
  @Builder
  aiPanel() {
    Column({ space: 10 }) {
      Row({ space: 10 }) {
        this.pageTitle('AI', 'ai/title')
        Blank()
        Button(this.t('common.close')).id('ai/close').height(28).fontSize(12)
          .backgroundColor(this.th('#23262B')).fontColor(this.th('#C7CBD1'))
          .onClick(() => { this.aiOpen = false; })
      }.width('100%')
      Text(this.lang === 'zh'
        ? '把当前终端最近 200 个字符作为上下文，POST 到设置里的 AI 端点。'
        : 'Sends the last 200 characters of the terminal to the configured AI endpoint.')
        .id('ai/hint').fontSize(this.fs(12)).fontColor(this.th('#8A8F98')).width('100%')
      Row({ space: 10 }) {
        Button(this.lang === 'zh' ? '提问' : 'Ask').id('ai/send').height(32).fontSize(12)
          .backgroundColor('#6A1B9A').fontColor(Color.White)
          .onClick(() => { this.askAI().catch((e: BusinessError) => { this.aiAnswer = 'ai: error'; }); })
        Text(this.aiEndpoint).id('ai/endpoint').fontSize(10).fontFamily('monospace')
          .fontColor(this.th('#6B7078')).layoutWeight(1).maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }.width('100%')
      Scroll() {
        Text(this.aiAnswer.length > 0 ? this.aiAnswer : (this.lang === 'zh' ? '(还没有回答)' : '(no answer yet)'))
          .id('ai/panel-answer').fontSize(12).fontFamily('monospace').fontColor(this.th('#C7CBD1')).width('100%')
      }.height(160).width('100%').border({ width: 1, color: this.th('#22252A') }).padding(8)
      .align(Alignment.TopStart).id('ai/answer-box')
    }
    .id('ai/panel').width(520).padding(18).backgroundColor(this.th('#1C1F24')).borderRadius(12)
    .shadow({ radius: 24, color: '#66000000', offsetY: 8 })
  }


  // 主机页"视图选项"菜单（自绘，可被用例点击）
  @Builder
  viewOptionsMenu() {
    Column({ space: 2 }) {
      this.menuItem(this.lang === 'zh' ? '列表视图' : 'List view', 'viewmenu/list', () => { this.hostView = 'list'; this.savePrefs(); this.viewMenuOpen = false; })
      this.menuItem(this.lang === 'zh' ? '网格视图' : 'Grid view', 'viewmenu/grid', () => { this.hostView = 'grid'; this.savePrefs(); this.viewMenuOpen = false; })
      this.menuItem(this.lang === 'zh' ? '切换排序' : 'Cycle sort', 'viewmenu/sort', () => {
          this.hostSort = this.hostSort === 'manual' ? 'name' : (this.hostSort === 'name' ? 'ip' : 'manual');
          this.savePrefs(); this.viewMenuOpen = false;
        })
      Button((this.showLastUsed ? '✓ ' : '') + (this.lang === 'zh' ? '显示最近连接' : 'Show last used'))
        .id('viewmenu/lastused').width('100%').fontSize(13)
        .backgroundColor(this.th('#23262B')).fontColor(this.th('#C7CBD1'))
        .onClick(() => { this.showLastUsed = !this.showLastUsed; this.savePrefs(); })
      Button((this.showTabCount ? '✓ ' : '') + (this.lang === 'zh' ? '显示会话计数' : 'Show tab count'))
        .id('viewmenu/tabcount').width('100%').fontSize(13)
        .backgroundColor(this.th('#23262B')).fontColor(this.th('#C7CBD1'))
        .onClick(() => { this.showTabCount = !this.showTabCount; this.savePrefs(); })
      Button(this.t('common.close')).id('viewmenu/close').width('100%').fontSize(12)
        .backgroundColor(this.th('#1E2127')).fontColor(this.th('#8A8F98'))
        .onClick(() => { this.viewMenuOpen = false; })
    }
    .id('viewmenu/panel').width(200).padding(10).backgroundColor(this.th('#1C1F24')).borderRadius(10)
    .shadow({ radius: 20, color: '#66000000', offsetY: 6 })
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column() {
      this.pcTopBar()
      Row() {
        this.pcSidebar()
        if (this.tabSide && this.tabs.length > 0) {
          this.tabStripVertical()
        }
        Column() {
          this.pcHeader()
          this.pcChips()
          if (this.tabs.length > 0 && !this.tabSide) {
            this.tabBar()
          }
          if (this.pcNav === '本地终端') {
            this.localTerminalPage()
          } else if (this.pcNav === '跳板路由') {
            this.jumpPage()
          } else if (this.pcNav === '工作区') {
            this.workspacePage()
          } else if (this.pcNav === '笔记') {
            this.notesPage()
          } else if (this.pcNav === '快捷命令') {
            this.snippetsPage()
          } else if (this.pcNav === '会话日志') {
            this.logsPage()
          } else if (this.pcNav === '密钥链') {
            this.vaultPage()
          } else if (this.showHosts || this.tabs.length === 0) {
            if (this.hostView === 'grid') {
              this.hostGridView()
            } else {
              this.hostListView()
            }
          } else {
            this.terminalView()
          }
        }
        .layoutWeight(1).height('100%').backgroundColor(this.th('#17181C'))
      }
      .layoutWeight(1).width('100%').backgroundColor(this.th('#17181C'))
      }

      if (this.noteDialog) {
        Column().width('100%').height('100%').backgroundColor('#66000000').onClick(() => {})
        this.noteForm()
      }
      if (this.paletteOpen) {
        Column().width('100%').height('100%').backgroundColor('#66000000')
          .onClick(() => { this.paletteOpen = false; })
        this.commandPalette()
      }
      if (this.snippetDialog) {
        Column().width('100%').height('100%').backgroundColor('#66000000').onClick(() => {})
        this.snippetForm()
      }
      if (this.settingsOpen) {
        Column().width('100%').height('100%').backgroundColor('#66000000').onClick(() => {})
        this.settingsPanel()
      }
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
        Scroll() {
          this.forwardPanel()
        }.width('100%').height('100%').align(Alignment.Top)
      }
      if (this.filesOpen) {
        Column().width('100%').height('100%').backgroundColor('#66000000').onClick(() => {})
        this.filesPanel()
      }
      if (this.diagOpen) {
        Column().width('100%').height('100%').backgroundColor('#66000000').onClick(() => {})
        Scroll() {
          this.diagPanelV2()
        }.width('100%').height('100%').align(Alignment.Top)
      }
      if (this.keyDialog) {
        Column().width('100%').height('100%').backgroundColor('#66000000').onClick(() => {})
        this.keyConfirm()
      }
      if (this.showDialog) {
        Column().width('100%').height('100%').backgroundColor('#66000000').onClick(() => {})
        this.hostForm()
      }
      if (this.groupRenameOpen) {
        Column().width('100%').height('100%').backgroundColor('#66000000').onClick(() => {})
        this.groupRenameDialog()
      }
      if (this.groupDelName.length > 0) {
        Column().width('100%').height('100%').backgroundColor('#66000000').onClick(() => {})
        this.groupDeleteDialog()
      }
      if (this.groupMenu.length > 0) {
        Column().width('100%').height('100%').backgroundColor('#66000000').onClick(() => { this.groupMenu = ''; })
        this.groupMenuPopup()
      }
      if (this.rdpSessionOpen) {
        Column().width('100%').height('100%').backgroundColor('#CC000000').onClick(() => {})
        this.rdpSessionView()
      }
      if (this.viewMenuOpen) {
        Column().width('100%').height('100%').backgroundColor('#66000000').onClick(() => { this.viewMenuOpen = false; })
        this.viewOptionsMenu()
      }
      if (this.aiOpen) {
        Column().width('100%').height('100%').backgroundColor('#66000000').onClick(() => { this.aiOpen = false; })
        this.aiPanel()
      }
      if (this.hostMenuIndex >= 0) {
        Column().width('100%').height('100%').backgroundColor('#66000000').onClick(() => { this.hostMenuIndex = -1; })
        this.hostMoreMenu()
      }
      if (this.tabRenameOpen) {
        Column().width('100%').height('100%').backgroundColor('#CC000000').onClick(() => {})
        this.tabRenameDialog()
      }
      if (this.vaultAddOpen) {
        Column().width('100%').height('100%').backgroundColor('#CC000000').onClick(() => {})
        this.vaultAddDialog()
      }
      if (this.hostDetailIndex >= 0) {
        Column().width('100%').height('100%').backgroundColor('#CC000000').onClick(() => { this.hostDetailIndex = -1; })
        this.hostDetailPanel()
      }
      if (this.knownDelKey.length > 0) {
        Column().width('100%').height('100%').backgroundColor('#66000000').onClick(() => {})
        this.knownDeleteConfirm()
      }
      if (this.vaultDelKey.length > 0) {
        Column().width('100%').height('100%').backgroundColor('#66000000').onClick(() => {})
        this.vaultDeleteConfirm()
      }
    }
    .width('100%').height('100%')
  }

}
  // 清空已知主机（用于"重新走一次首次信任"，也让用例不依赖历史数据）


