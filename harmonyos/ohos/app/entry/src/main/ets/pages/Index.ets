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
import { socket } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
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
  @State filesOpen: boolean = false;
  @State sftpPath: string = '.';
  @State sftpFile: string = 'hello.txt';
  @State sftpList: string = '';
  @State sftpEntries: string[] = [];
  @State sftpPreview: string = '';
  @State sftpStatus: string = '';

  private creds: Map<string, Cred> = new Map<string, Cred>();
  private store: relationalStore.RdbStore | null = null;
  private readonly fixtureKey: string = '127.0.0.1:2222';
  private shellId: number = 0;
  private tabSeq: number = 0;
  private pendingAction: string = 'connect';
  private pendingLabel: string = '';

  aboutToAppear(): void {
    this.creds.set(this.fixtureKey, { address: '127.0.0.1', port: 2222, user: 'tester', password: 'secret' });
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
      await this.reload();
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

  private async submit(): Promise<void> {
    const label = this.formLabel.trim();
    const address = this.formAddress.trim();
    if (label.length === 0 || address.length === 0 || this.store === null) {
      return;
    }
    const port = this.formPort.trim().length > 0 ? this.formPort.trim() : '22';
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
      this.creds.set(this.hostKey(address, port), {
        address: address,
        port: Number.parseInt(port, 10),
        user: this.formUser.trim(),
        password: this.formPassword
      });
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
          this.refreshTab(vtId);
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
          this.refreshTab(vtId);
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

  private downloadFile(cred: Cred, fp: string): void {
    this.sftpStatus = 'reading ' + this.sftpFile;
    mottynapi.sftp(cred.address, cred.port, cred.user, cred.password, fp, 'read', this.sftpFile,
      (result: string) => {
        this.sftpPreview = result;
        this.sftpStatus = 'read ' + this.sftpFile + ' (' + result.length + ' chars)';
      });
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
      (result: string) => { this.setStatus(index, result); });
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
      Text('New Host').fontSize(20).fontWeight(FontWeight.Bold).width('100%')
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
          .onClick(() => { this.showDialog = false; this.resetForm(); })
        Button('Add Host').id('shell/dialog-submit').onClick(() => { this.submit(); })
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
      Row({ space: 8 }) {
        TextInput({ text: this.sftpPath, placeholder: '.' }).id('sftp/path')
          .layoutWeight(1).onChange((v: string) => { this.sftpPath = v; })
        Button('List').id('sftp/list-btn').onClick(() => {
          const cred = this.creds.get(this.fixtureKey);
          if (cred !== undefined) {
            this.lookupFp(this.fixtureKey).then((fp: string) => { this.refreshListing(cred, fp); });
          }
        })
      }.width('100%')
      Scroll() {
        Column({ space: 2 }) {
          Text(this.sftpList.length > 0 ? this.sftpList : '(empty)')
            .id('sftp/list').fontSize(11).fontFamily('monospace').fontColor('#888888').width('100%')
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
        }.width('100%').alignItems(HorizontalAlign.Start)
      }.height(140).width('100%').border({ width: 1, color: '#DDDDDD' }).padding(8)
        .align(Alignment.TopStart)
      Row({ space: 8 }) {
        TextInput({ text: this.sftpFile, placeholder: 'hello.txt' }).id('sftp/file')
          .layoutWeight(1).onChange((v: string) => { this.sftpFile = v; })
        Button('Download').id('sftp/download').onClick(() => {
          const cred = this.creds.get(this.fixtureKey);
          if (cred !== undefined) {
            this.lookupFp(this.fixtureKey).then((fp: string) => { this.downloadFile(cred, fp); });
          }
        })
      }.width('100%')
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
  diagPanel() {
    Column({ space: 10 }) {
      Row() {
        Text('Diagnostics').fontSize(16).fontWeight(FontWeight.Bold)
        Blank()
        Button('Close').id('diag/close').backgroundColor('#E6E6E6').fontColor('#1A1A1A')
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
      }.width('100%')
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
      }.width('100%')
      Text(this.ptyStatus.length > 0 ? this.ptyStatus : 'pty: (idle)')
        .id('terminal/pty-status').fontSize(11).fontColor('#0A6C00').width('100%')
      Text('history tail: ' + (this.vtHistory.length > 0 ? this.vtHistory.replace(/\n/g, ' | ') : '(empty)'))
        .id('terminal/history').fontSize(11).fontColor('#999999').width('100%')
      Text(this.vtStatus.length > 0 ? this.vtStatus : 'vt: (idle)')
        .id('terminal/vt-status').fontSize(11).fontColor('#999999').width('100%')
      Scroll() {
        Text(this.termText.length > 0 ? this.termText : '(no output yet)')
          .id('terminal/output').fontSize(13).fontFamily('monospace').fontColor('#D4D4D4')
          .width('100%')
      }
      .layoutWeight(1).width('100%').align(Alignment.TopStart)
      .border({ width: 1, color: '#333333' }).padding(8).backgroundColor('#1E1E1E')
    }
    .id('terminal/panel').layoutWeight(1).width('100%').padding(16)
  }

  @Builder
  hostListView() {
    Column() {
      Text('Hosts').fontSize(13).fontColor('#666666').width('100%')
        .padding({ left: 16, top: 10, bottom: 4 })
      List({ space: 8 }) {
        ForEach(this.hosts, (h: HostItem, index: number) => {
          ListItem() {
            Column({ space: 4 }) {
              Row({ space: 12 }) {
                Column({ space: 4 }) {
                  Text(h.label).fontSize(16).fontWeight(FontWeight.Medium).width('100%')
                  Row({ space: 2 }) {
                    Text(h.address).fontSize(12).fontColor('#666666')
                    Text(':' + h.port).fontSize(12).fontColor('#999999')
                  }.width('100%')
                }.layoutWeight(1).alignItems(HorizontalAlign.Start)
                Button('Test').id('host-row/' + index).backgroundColor('#E6E6E6').fontColor('#1A1A1A')
                  .onClick(() => { this.connectRow(index); })
                Button('Files').id('host-files/' + index).backgroundColor('#E6E6E6').fontColor('#1A1A1A')
                  .onClick(() => { this.openFiles(index); })
                Button('Open').id('host-open/' + index).backgroundColor('#1A6DD0').fontColor(Color.White)
                  .onClick(() => { this.openSession(h.label, index); })
              }.width('100%')
              if (this.statuses.length > index && this.statuses[index].length > 0) {
                Text(this.statuses[index]).id('host-status/' + index).fontSize(11).fontColor('#0A6C00').width('100%')
              }
            }.width('100%').padding(12).backgroundColor(Color.White).borderRadius(8)
          }
        }, (h: HostItem) => h.id)
      }
      .id('host-grid/list').layoutWeight(1).width('100%').padding({ left: 16, right: 16, bottom: 16 })

      if (this.hosts.length === 0) {
        Text('No hosts yet').id('host-grid/empty').fontSize(13).fontColor('#999999')
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
          Button('Diagnostics').id('diag/open').backgroundColor('#E6E6E6').fontColor('#1A1A1A')
            .onClick(() => { this.diagOpen = true; })
          Button('New Host').id('shell/add-host')
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
