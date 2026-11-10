/**
 * Motty HarmonyOS —— M1 切片 3：主机列表可直接连接。
 *
 * 相对上一版的实质变化：
 *   1) 主机条目带协议/用户/端口，列表行可点击发起连接（不再只有"连接固定 fixture"按钮）
 *   2) 连接走完整的 TOFU：未知主机 -> 弹确认 -> 用户信任 -> 落盘 known_hosts -> 才认证
 *   3) 每行有自己的状态回显（host-status/<i>），不再是全局一行文本
 *
 * 安全相关的刻意选择（不要"优化"掉）：
 *   * 密码**只存在内存**（this.creds），不写数据库、不写文件。
 *     保险库（AES-256-GCM + HUKS/Asset）是 M1-b 的工作，这里不假装已经做了。
 *   * 主机密钥变更不提供任何"仍要信任"入口（PLAN §7.4 P1）。
 *   * 指纹落盘表 known_hosts 的键是 address:port。
 *
 * 仍未做：终端渲染、SFTP、转发、会话复用、凭据保险库、分组/标签。
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
  @State termVisible: boolean = false;
  @State termText: string = '';
  private pendingAction: string = 'connect';   // connect | terminal
  private termIndex: number = -1;
  private shellId: number = 0;
  @State termInput: string = '';
  @State vtStatus: string = '';

  // 密码只在内存：键为 address:port。进程退出即失，这是刻意的。
  private creds: Map<string, Cred> = new Map<string, Cred>();
  private store: relationalStore.RdbStore | null = null;
  private readonly fixtureKey: string = '127.0.0.1:2222';

  aboutToAppear(): void {
    // 固定 fixture 的凭据也放内存，便于诊断按钮使用
    this.creds.set(this.fixtureKey, { address: '127.0.0.1', port: 2222, user: 'tester', password: 'secret' });
    this.initStore();
  }

  private hostKey(address: string, port: string): string {
    return address + ':' + port;
  }

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
      // 密码只留内存，不落库
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

  // ---- 终端视图（最小闭环：字节流 -> 文本网格区域）----
  // 注意：这一版**没有 VT 解析**，只把远端字节流追加成文本，用于证明终端数据通路成立。
  private async openTerminal(index: number): Promise<void> {
    if (index >= this.hosts.length) {
      return;
    }
    this.pendingAction = 'terminal';
    this.termIndex = index;
    const h = this.hosts[index];
    const key = this.hostKey(h.address, h.port);
    const cred = this.creds.get(key);
    if (cred === undefined) {
      this.setStatus(index, 'no credentials in memory (vault not implemented yet)');
      return;
    }
    const stored = await this.lookupFp(key);
    if (stored.length > 0) {
      this.startTerminal(index, cred, stored);
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

  private startTerminal(index: number, cred: Cred, fp: string): void {
    this.termVisible = true;
    this.termText = '';
    this.setStatus(index, 'terminal streaming...');
    mottynapi.vtReset(80, 24);
    this.vtStatus = mottynapi.vtStatus();
    const id: number = mottynapi.openShell(cred.address, cred.port, cred.user, cred.password, fp,
      (chunk: string) => {
        mottynapi.vtFeed(chunk);
        this.termText = mottynapi.vtScreen();
        this.vtStatus = mottynapi.vtStatus();
      },
      (status: string) => {
        this.termText = this.termText + '\n[status] ' + status;
        this.setStatus(index, 'terminal: ' + status);
        this.shellId = 0;
      });
    this.shellId = id;
    if (id === 0) {
      this.termText = 'failed to open interactive shell';
    }
  }

  // 诊断用：一次性流式 exec（term-demo，多块到达）。与交互式 openShell 覆盖不同性质：
  //   - exec: 一条命令、多块输出、无输入
  //   - openShell: 长通道、可写入、远端回显
  // 两个诊断入口，覆盖不同性质：
  //   terminal/demo -> term-demo：原始流式多块（不依赖 VT 语义）
  //   terminal/vt   -> vt-demo  ：最小 VT 子集（清屏/定位/擦行/颜色）
  private openVtDemo(): void {
    this.openDemoWith('vt');
  }

  private openTerminalDemo(): void {
    this.openDemoWith('demo');
  }

  private openDemoWith(action: string): void {
    this.pendingAction = action;
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
      const cmd: string = this.pendingAction === 'vt' ? 'vt-demo' : 'term-demo';
      this.runDemo(cred, fp, cmd);
    });
  }

  private runDemo(cred: Cred, fp: string, command: string): void {
    this.termVisible = true;
    this.termText = '';
    mottynapi.vtReset(80, 24);
    this.vtStatus = mottynapi.vtStatus();
    mottynapi.exec(cred.address, cred.port, cred.user, cred.password, command, fp,
      (chunk: string) => {
        // 字节流先进 VT 引擎，再由网格文本渲染——这一步是"终端"与"日志"的区别
        mottynapi.vtFeed(chunk);
        this.termText = mottynapi.vtScreen();
        this.vtStatus = mottynapi.vtStatus();
      },
      (status: string) => {
        this.termText = mottynapi.vtScreen();
        this.vtStatus = mottynapi.vtStatus();
        this.setStatus(0, command + ': ' + status);
      });
  }

  private sendTermInput(): void {
    if (this.shellId === 0) {
      this.termText = this.termText + '\n[no session]';
      return;
    }
    const text = this.termInput;
    if (text.length === 0) {
      return;
    }
    this.termText = this.termText + text + '\n';
    mottynapi.sendInput(this.shellId, text);
    this.termInput = '';
  }


  // ---- 连接：未知主机先取指纹并要用户确认，已知则直接连 ----
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
        this.termIndex = index;
        this.keyDialog = true;
        this.setStatus(index, 'waiting for user to trust ' + this.pendingFp);
      });
  }

  private runProbe(index: number, cred: Cred, fp: string): void {
    mottynapi.probe(cred.address, cred.port, cred.user, cred.password, 'echo hello-from-list', fp,
      (result: string) => {
        this.setStatus(index, result);
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
      for (let i = 0; i < this.hosts.length; i++) {
        if (this.hostKey(this.hosts[i].address, this.hosts[i].port) === key) {
          this.setStatus(i, 'trusted ' + fp + ', connecting...');
          if (this.pendingAction === 'vt') {
            this.runDemo(cred, fp, 'vt-demo');
          } else if (this.pendingAction === 'demo') {
            this.runDemo(cred, fp, 'term-demo');
          } else if (this.pendingAction === 'terminal') {
            this.startTerminal(i, cred, fp);
          } else {
            this.runProbe(i, cred, fp);
          }
          return;
        }
      }
    });
  }

  // ---- 诊断按钮：网络 / SSH / 主机密钥三步自检（保留，供既有 spec 使用）----
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

  private connectFixture(): void {
    this.probeText = 'ssh: connecting fixture...';
    mottynapi.probe('127.0.0.1', 2222, 'tester', 'secret', 'echo hello-from-ssh', '',
      (first: string) => {
        const m = new RegExp('SHA256:[A-Za-z0-9+/]+').exec(first);
        if (m === null) {
          this.probeText = 'ssh: no fingerprint, got ' + first;
          return;
        }
        const fp: string = m[0];
        mottynapi.probe('127.0.0.1', 2222, 'tester', 'secret', 'echo hello-from-ssh', fp,
          (result: string) => { this.probeText = 'ssh: ' + result; });
      });
  }

  @Builder
  hostForm() {
    Column({ space: 10 }) {
      Text('New Host').fontSize(20).fontWeight(FontWeight.Bold).width('100%')

      Text('Label').fontSize(12).fontColor('#666666').width('100%')
      TextInput({ placeholder: 'my server' })
        .id('shell/dialog-label')
        .width('100%')
        .onChange((v: string) => { this.formLabel = v; })

      Text('Address').fontSize(12).fontColor('#666666').width('100%')
      TextInput({ placeholder: '10.0.0.1' })
        .id('shell/dialog-address')
        .width('100%')
        .onChange((v: string) => { this.formAddress = v; })

      Row({ space: 10 }) {
        Column({ space: 6 }) {
          Text('User').fontSize(12).fontColor('#666666').width('100%')
          TextInput({ placeholder: 'root' })
            .id('shell/dialog-user')
            .width('100%')
            .onChange((v: string) => { this.formUser = v; })
        }.layoutWeight(1)

        Column({ space: 6 }) {
          Text('Port').fontSize(12).fontColor('#666666').width('100%')
          TextInput({ placeholder: '22' })
            .id('shell/dialog-port')
            .width('100%')
            .type(InputType.Number)
            .onChange((v: string) => { this.formPort = v; })
        }.layoutWeight(1)
      }.width('100%')

      Text('Password (memory only, not stored)').fontSize(12).fontColor('#666666').width('100%')
      TextInput({ placeholder: 'password' })
        .id('shell/dialog-password')
        .width('100%')
        .type(InputType.Password)
        .onChange((v: string) => { this.formPassword = v; })

      Row({ space: 12 }) {
        Button('Cancel')
          .id('shell/dialog-cancel')
          .backgroundColor('#E6E6E6')
          .fontColor('#1A1A1A')
          .onClick(() => { this.showDialog = false; this.resetForm(); })
        Button('Add Host')
          .id('shell/dialog-submit')
          .onClick(() => { this.submit(); })
      }.width('100%').justifyContent(FlexAlign.End)
    }
    .id('host-form/dialog')
    .width(560)
    .padding(20)
    .backgroundColor(Color.White)
    .borderRadius(12)
    .shadow({ radius: 24, color: '#33000000', offsetY: 8 })
  }

  @Builder
  terminalPanel() {
    Column({ space: 8 }) {
      Row() {
        Text('Terminal (fixture)').fontSize(16).fontWeight(FontWeight.Bold).fontColor(Color.White)
        Blank()
        Button('Close')
          .id('terminal/close')
          .backgroundColor('#E6E6E6')
          .fontColor('#1A1A1A')
          .onClick(() => {
            if (this.shellId !== 0) {
              mottynapi.closeShell(this.shellId);
              this.shellId = 0;
            }
            this.termVisible = false;
          })
      }.width('100%')
      Scroll() {
        Text(this.termText.length > 0 ? this.termText : '(no output yet)')
          .id('terminal/output')
          .fontSize(13)
          .fontColor('#D4D4D4')
          .fontFamily('monospace')
          .width('100%')
      }
      .layoutWeight(1)
      .width('100%')
      .align(Alignment.TopStart)
      .border({ width: 1, color: '#CCCCCC' })
      .padding(8)

      Text(this.vtStatus.length > 0 ? this.vtStatus : 'vt: (idle)')
        .id('terminal/vt-status')
        .fontSize(11)
        .fontColor('#8A8A8A')
        .width('100%')

      Row({ space: 8 }) {
        TextInput({ text: this.termInput, placeholder: 'type a line and press Send' })
          .id('terminal/input')
          .layoutWeight(1)
          .onChange((v: string) => { this.termInput = v; })
        Button('Send')
          .id('terminal/send')
          .onClick(() => { this.sendTermInput(); })
      }.width('100%')
    }
    .id('terminal/panel')
    .width(680)
    .height(420)
    .padding(16)
    .backgroundColor('#1E1E1E')
    .borderRadius(12)
  }

  @Builder
  keyConfirm() {
    Column({ space: 12 }) {
      Text('Unknown host key').fontSize(18).fontWeight(FontWeight.Bold).width('100%')
      Text('The authenticity of this host cannot be established. Verify the fingerprint out-of-band before trusting it.')
        .fontSize(12).fontColor('#666666').width('100%')
      Text(this.pendingFp).id('hostkey/fingerprint').fontSize(13).fontFamily('monospace').width('100%')
      Row({ space: 12 }) {
        Button('Cancel')
          .id('hostkey/cancel')
          .backgroundColor('#E6E6E6')
          .fontColor('#1A1A1A')
          .onClick(() => {
            this.keyDialog = false;
            this.pendingFp = '';
            this.pendingKey = '';
            this.probeText = 'cancelled, nothing trusted';
          })
        Button('Trust')
          .id('hostkey/trust')
          .onClick(() => this.trustAndConnect())
      }.width('100%').justifyContent(FlexAlign.End)
    }
    .id('hostkey/dialog')
    .width(520)
    .padding(20)
    .backgroundColor(Color.White)
    .borderRadius(12)
    .shadow({ radius: 24, color: '#33000000', offsetY: 8 })
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      Column() {
        Row({ space: 8 }) {
          Text('Motty').fontSize(20).fontWeight(FontWeight.Bold)
          Blank()
          Button('Term Demo').id('terminal/demo').backgroundColor('#E6E6E6').fontColor('#1A1A1A')
            .onClick(() => { this.openTerminalDemo(); })
          Button('VT Demo').id('terminal/vt').backgroundColor('#E6E6E6').fontColor('#1A1A1A')
            .onClick(() => { this.openVtDemo(); })
          Button('SSH Test').id('ssh/probe').backgroundColor('#E6E6E6').fontColor('#1A1A1A')
            .onClick(() => { this.probeSsh(); })
          Button('Hostkey Check').id('ssh/hostkey-check').backgroundColor('#E6E6E6').fontColor('#1A1A1A')
            .onClick(() => { this.hostkeyCheck(); })
          Button('Probe Net').id('net/probe').backgroundColor('#E6E6E6').fontColor('#1A1A1A')
            .onClick(() => { this.probeNet(); })
          Button('New Host').id('shell/add-host')
            .onClick(() => { this.resetForm(); this.showDialog = true; })
        }
        .width('100%').padding({ left: 16, right: 16, top: 12, bottom: 12 }).backgroundColor('#F5F5F5')

        Text(this.probeText)
          .id('net/probe-result')
          .fontSize(12)
          .fontColor('#0A6C00')
          .width('100%')
          .padding({ left: 16, right: 16, top: 6, bottom: 0 })

        Text('Hosts').fontSize(13).fontColor('#666666')
          .width('100%').padding({ left: 16, top: 10, bottom: 4 })

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
                  Button('Term')
                    .id('host-term/' + index)
                    .backgroundColor('#0A6C00')
                    .fontColor(Color.White)
                    .onClick(() => { this.openTerminal(index); })
                  Button('Connect')
                    .id('host-row/' + index)
                    .backgroundColor('#1A6DD0')
                    .fontColor(Color.White)
                    .onClick(() => { this.connectRow(index); })
                }.width('100%')

                if (this.statuses.length > index && this.statuses[index].length > 0) {
                  Text(this.statuses[index])
                    .id('host-status/' + index)
                    .fontSize(11)
                    .fontColor('#0A6C00')
                    .width('100%')
                }
              }
              .width('100%').padding(12).backgroundColor(Color.White).borderRadius(8)
            }
          }, (h: HostItem) => h.id)
        }
        .id('host-grid/list')
        .layoutWeight(1).width('100%').padding({ left: 16, right: 16, bottom: 16 })

        if (this.hosts.length === 0) {
          Text('No hosts yet').id('host-grid/empty').fontSize(13).fontColor('#999999')
            .width('100%').textAlign(TextAlign.Center).padding({ bottom: 24 })
        }
      }
      .width('100%').height('100%').backgroundColor('#FAFAFA')

      if (this.termVisible) {
        Column().width('100%').height('100%').backgroundColor('#99000000').onClick(() => {})
        this.terminalPanel()
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
