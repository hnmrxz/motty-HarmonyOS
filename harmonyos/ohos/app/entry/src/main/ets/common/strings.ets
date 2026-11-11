// strings.ets —— 中英双语文案表
//
// 设计取舍：
//   - 不使用资源限定符目录（resources/en_US/element/string.json）而是代码内表：
//     应用是"工具类"产品，文案集中在少数几处，代码内表更好做**机器可断言的切换**；
//     同时避免初期就把所有文案拆到资源文件导致大量样板。
//   - 键名用点分命名空间（top.* / host.* / sftp.* / fwd.* / vnc.* / term.*），
//     与 INDEX/RUNBOOK 里的用例 id 命名保持一致，便于排查。
//
// 未做（诚实记录）：复数形式、日期/数字本地化、从系统语言自动跟随（当前默认 en，
// 由用户点按钮切换）。这些在多语言扩展时需要补。
export class Strings {
  private static readonly en: Map<string, string> = new Map<string, string>([
    ['top.known', 'Known'],
    ['top.forward', 'Forward'],
    ['top.diag', 'Diagnostics'],
    ['top.newHost', 'New Host'],
    ['top.lang', '中文'],
    ['host.title', 'Hosts'],
    ['host.search', 'search label or address'],
    ['host.empty', 'No hosts yet'],
    ['host.noMatch', 'no matching hosts'],
    ['host.test', 'Test'],
    ['host.edit', 'Edit'],
    ['host.del', 'Del'],
    ['host.files', 'Files'],
    ['host.open', 'Open'],
    ['term.title', 'Terminal'],
    ['term.send', 'Send'],
    ['term.resize', 'Resize'],
    ['term.copy', 'Copy'],
    ['term.selAll', 'Sel all'],
    ['sftp.title', 'Files (SFTP)'],
    ['sftp.download', 'Download'],
    ['sftp.upload', 'Upload'],
    ['sftp.delete', 'Delete'],
    ['sftp.rename', 'Rename'],
    ['sftp.mkdir', 'Mkdir'],
    ['sftp.up', 'Up'],
    ['sftp.list', 'List'],
    ['fwd.title', 'Port forwarding'],
    ['fwd.save', 'Save rule'],
    ['vnc.title', 'VNC (RFB 3.8)'],
    ['vnc.readClip', 'Read clip'],
    ['vnc.sendClip', 'Send clip'],
    ['diag.title', 'Diagnostics'],
    ['common.close', 'Close'],
    ['common.cancel', 'Cancel'],
    ['common.save', 'Save'],
    ['common.add', 'Add Host'],
    ['sftp.preview', 'preview'],
    ['sftp.path', 'path'],
    ['fwd.mode', 'mode'],
    ['fwd.listen', 'listen port'],
    ['fwd.target', 'target host:port'],
    ['fwd.start', 'Start'],
    ['fwd.stop', 'Stop'],
    ['fwd.test', 'Test tunnel'],
    ['rdp.experimental', 'RDP is experimental: connect works, picture/input are not delivered yet.'],
    ['vnc.stop', 'Stop'],
    ['vnc.pointer', 'Send pointer (10,10)'],
    ['vnc.key', 'Send key a'],
    ['vnc.clipEmpty', 'clip: (empty)'],
    ['vnc.send', 'Send'],

    ['term.history', 'history tail'],

  ]);

  private static readonly zh: Map<string, string> = new Map<string, string>([
    ['top.known', '信任主机'],
    ['top.forward', '端口转发'],
    ['top.diag', '诊断'],
    ['top.newHost', '新建主机'],
    ['top.lang', 'English'],
    ['host.title', '主机'],
    ['host.search', '搜索名称或地址'],
    ['host.empty', '还没有主机'],
    ['host.noMatch', '没有匹配的主机'],
    ['host.test', '测试'],
    ['host.edit', '编辑'],
    ['host.del', '删除'],
    ['host.files', '文件'],
    ['host.open', '打开'],
    ['term.title', '终端'],
    ['term.send', '发送'],
    ['term.resize', '调整大小'],
    ['term.copy', '复制'],
    ['term.selAll', '全选'],
    ['sftp.title', '文件（SFTP）'],
    ['sftp.download', '下载'],
    ['sftp.upload', '上传'],
    ['sftp.delete', '删除'],
    ['sftp.rename', '重命名'],
    ['sftp.mkdir', '新建目录'],
    ['sftp.up', '上级'],
    ['sftp.list', '列出'],
    ['fwd.title', '端口转发'],
    ['fwd.save', '保存规则'],
    ['vnc.title', 'VNC（RFB 3.8）'],
    ['vnc.readClip', '读剪贴板'],
    ['vnc.sendClip', '发剪贴板'],
    ['diag.title', '诊断'],
    ['common.close', '关闭'],
    ['common.cancel', '取消'],
    ['common.save', '保存'],
    ['common.add', '添加主机'],
    ['sftp.preview', '预览'],
    ['sftp.path', '路径'],
    ['fwd.mode', '模式'],
    ['fwd.listen', '监听端口'],
    ['fwd.target', '目标 主机:端口'],
    ['fwd.start', '启动'],
    ['fwd.stop', '停止'],
    ['fwd.test', '测试隧道'],
        ['diag.tcpProbe', 'TCP 探测'],
    ['diag.sshProbe', 'SSH 探测'],
    ['diag.hostkeyCheck', '主机密钥检查'],
    ['rdp.srvStart', 'RDP 服务启动'],
    ['rdp.srvStop', 'RDP 服务停止'],
    ['rdp.srvStatus', 'RDP 服务状态'],
    ['rdp.local', 'RDP 本机'],
    ['rdp.experimental', 'RDP 为实验性功能：可连接，但画面与输入尚未打通。'],
    ['vnc.stop', '停止'],
    ['vnc.pointer', '发送指针 (10,10)'],
    ['vnc.key', '发送按键 a'],
    ['vnc.clipEmpty', '剪贴板: (空)'],
    ['vnc.send', '发送'],

    ['term.history', '历史尾部'],

  ]);

  static get(lang: string, key: string): string {
    const table = lang === 'zh' ? Strings.zh : Strings.en;
    const value = table.get(key);
    // 缺键时回退到键名本身：让缺失在界面上立刻可见，而不是静默显示英文
    return value === undefined ? key : value;
  }

  static isKnown(lang: string, key: string): boolean {
    const table = lang === 'zh' ? Strings.zh : Strings.en;
    return table.has(key);
  }

  static keyCount(): number {
    return Strings.en.size;
  }
}
