// A′ ArkTS ↔ NAPI ↔ C 契约草案（v0，2026-11-10）
//
// 位置约定：本文件是**契约真源**，实现后应逐字复制为
//   ohos/libs/contract/src/main/ets/motty-native.d.ts
// 并由 CI 断言两份一致（见 A-PRIME-ENGINEERING.md §1）。
//
// 纪律：
//  - 每个入口都必须携带句柄；没有句柄的入口不得新增。
//  - 不提供 exec(cmd)/eval/任意路径读写/全局 env/任意 .so 加载。
//  - native 不做策略判断、不开文件系统、不新增监听（MCP 例外，且在 ArkTS 侧）。
//  - 字节一律 ArrayBuffer；字段只增不改；每类载荷带 v。
//
// 状态：草案。§3.2 的通用约定（句柄/线程/错误/背压）优先于本文件。

export type Handle = number; // 1..0x7fffffff，绝不复用

export const enum Cap {
  Shell = 0x0001,
  Exec = 0x0002,
  Sftp = 0x0004,
  Forward = 0x0008,
  Desktop = 0x0010,
  Vault = 0x0020,
  Agent = 0x0040,
}

export type MottyCode =
  | 'E_HANDLE' | 'E_STALE' | 'E_CAP' | 'E_CLOSED'
  | 'E_AUTH' | 'E_HOSTKEY' | 'E_IO' | 'E_TIMEOUT'
  | 'E_FORMAT' | 'E_LIMIT' | 'E_UNSUPPORTED' | 'E_BACKPRESSURE'
  | 'E_NOTFOUND' | 'E_EXISTS' | 'E_DENIED' | 'E_KDF';

export interface MottyError extends Error {
  code: MottyCode;
  errno?: number; // 仅日志
  op?: string;    // 仅日志
}

export interface Endpoint { host: string; port: number; user: string }

// ───────────────────────────── P1 Transport ─────────────────────────────

export interface SessionOptions {
  endpoint: Endpoint;
  jumps?: Endpoint[];          // 外层 → 内层，每跳独立验钥/认证
  knownHostsPath: string;      // 沙箱路径，由 libs/platform 决定
  auth: {
    methods: number;           // 位掩码：公钥/口令/kbdint/agent
    identityFiles: string[];
    storedKeys: string[];      // 应用内密钥引用
    agent: boolean;            // 无外部 agent 时为 false（见 D3）
  };
  keepAlive?: { intervalMs: number; timeoutMs: number };
  timeouts?: { connectMs: number; bannerMs: number; kexMs: number; authMs: number };
  algorithms?: { kex?: string[]; cipher?: string[]; mac?: string[]; hostKey?: string[] };
}

export type Phase =
  | 'connecting' | 'banner' | 'kex' | 'auth' | 'ready' | 'closing' | 'closed';

export interface PhaseEvent    { v: 1; h: Handle; seq: number; kind: 'phase'; phase: Phase }
export interface HostKeyEvent   { v: 1; h: Handle; seq: number; kind: 'hostkey'
                                  address: string; type: string; fingerprint: string
                                  known: string[]; file: string }
export interface QuestionEvent  { v: 1; h: Handle; seq: number; kind: 'question'
                                  attempt: number; identityPath?: string
                                  questions: Array<{ text: string; secret: boolean }> }
export interface NegotiatedEvent{ v: 1; h: Handle; seq: number; kind: 'negotiated'
                                  kex: string; cipher: string; mac: string; hostKey: string; compression: string }
export interface BannerEvent    { v: 1; h: Handle; seq: number; kind: 'banner'; text: string }
export interface SystemEvent    { v: 1; h: Handle; seq: number; kind: 'system'
                                  os?: string; shell?: string; home?: string }
export interface ClosedEvent    { v: 1; h: Handle; seq: number; kind: 'closed'; reason: string }
export interface ErrorEvent     { v: 1; h: Handle; seq: number; kind: 'error'; code: MottyCode; message: string }

export type SessionEvent =
  | PhaseEvent | HostKeyEvent | QuestionEvent | NegotiatedEvent
  | BannerEvent | SystemEvent | ClosedEvent | ErrorEvent;

// 主机密钥决策里**没有** force 分支（不变量 P1）
export type HostKeyDecision = 'accept-new' | 'keyed-accept' | 'abort';
export interface HostKeyAnswer  { kind: 'hostkey'; decision: HostKeyDecision }
export interface QuestionAnswer { kind: 'question'; answers: string[] }

export interface ExecRequest  { command: string; pty?: { cols: number; rows: number; term: string };
                                env?: Record<string, string>; timeoutMs?: number; grantId: string }
export interface ExecResult   { v: 1; exitStatus: number; stdout: ArrayBuffer; stderr: ArrayBuffer }
export interface ShellRequest { cols: number; rows: number; term: string; env?: Record<string, string> }
export interface TcpipRequest { dstHost: string; dstPort: number; srcHost: string; srcPort: number }
export interface BindRequest  { bindHost: '127.0.0.1'; bindPort: number }

// ───────────────────────────── P2 RemoteFs ─────────────────────────────

export interface DirEntry {
  name: string;
  kind: 'file' | 'dir' | 'link' | 'other';
  size: number; mode: number; mtimeMs: number; uid: number; gid: number;
  linkTarget?: string;
}
export interface DirPage { v: 1; entries: DirEntry[]; more: boolean }
export interface ReadDirRequest { path: string; start: number; limit: number }
export interface OpenFileRequest { path: string; flags: 'r' | 'w' | 'a' | 'rw'; mode?: number }

// ───────────────────────────── P3 Vault ─────────────────────────────

export interface VaultHeader { v: 1; version: number
  kdf?: { name: string; time: number; memoryKiB: number; threads: number; salt: ArrayBuffer }
  hasWrapped: boolean }
export interface VaultRecordMeta { name: string; stamp: string; deleted: boolean }
export interface VaultChange { name: string; value?: string; delete?: boolean }

// ─────────────────────────── P4 DesktopSession ───────────────────────────

export interface VncOptions {
  host: string; port: number;
  auth: { kind: 'none' | 'vnc'; password?: string };
  tunnel?: { session: Handle; dstHost: string; dstPort: number };
}
export interface RdpOptions {
  host: string; port: number; user: string; domain?: string; password?: string;
  tlsMin: '1.2' | '1.3';
  certPinSha256: string;               // 变更即断（不变量 P7）
  tunnel?: { session: Handle; dstHost: string; dstPort: number };
}
export interface FrameEvent { v: 1; h: Handle; seq: number; kind: 'frame'
  x: number; y: number; width: number; height: number
  encoding: 'rgba'; data: ArrayBuffer }
export type DesktopEvent = FrameEvent
  | { v: 1; h: Handle; seq: number; kind: 'bell' }
  | { v: 1; h: Handle; seq: number; kind: 'clipboardText'; text: string }
  | { v: 1; h: Handle; seq: number; kind: 'sizeChanged'; width: number; height: number }
  | { v: 1; h: Handle; seq: number; kind: 'certPrompt'; sha256: string; subject: string }
  | { v: 1; h: Handle; seq: number; kind: 'closed'; reason: string }
  | { v: 1; h: Handle; seq: number; kind: 'error'; code: MottyCode; message: string };

// ──────────────────────────────── 门面 ────────────────────────────────

export interface MottyNative {
  readonly abi: { abi: string; version: string; caps: number };

  // 事件总线：每模块一个 TSFN；seq 按句柄单调；progress 可合并，数据/错误不可丢
  events: {
    on(cb: (e: SessionEvent | DesktopEvent) => void): number;
    off(id: number): void;
  };

  // P1
  ssh_open(o: SessionOptions): Promise<Handle>;
  ssh_answer(h: Handle, a: HostKeyAnswer | QuestionAnswer): Promise<void>;
  ssh_exec(h: Handle, r: ExecRequest): Promise<ExecResult>;
  ssh_shell(h: Handle, r: ShellRequest): Promise<Handle>;          // ChannelHandle
  ssh_grant_exec(h: Handle, o: { ttlMs: number }): Promise<string>; // 防御性接线检查，非安全边界
  chan_write(c: Handle, data: ArrayBuffer): Promise<void>;
  chan_resize(c: Handle, cols: number, rows: number): Promise<void>;
  chan_signal(c: Handle, name: string): Promise<void>;
  chan_eof(c: Handle): Promise<void>;
  chan_close(c: Handle): Promise<void>;
  direct_tcpip(h: Handle, r: TcpipRequest): Promise<Handle>;        // ChannelHandle
  remote_forward(h: Handle, r: BindRequest): Promise<Handle>;       // ForwardHandle
  cancel_remote_forward(f: Handle): Promise<void>;
  ssh_status(h: Handle): Promise<{ v: 1; gen: number; phase: Phase; openChannels: number }>;
  ssh_close(h: Handle): Promise<void>;

  // P2（哑管道：编排、续传、原子替换在 ArkTS）
  sftp_open(h: Handle, o: { mode: 'sftp' | 'scp' }): Promise<Handle>;
  fs_readdir(fs: Handle, r: ReadDirRequest): Promise<DirPage>;
  fs_stat(fs: Handle, path: string): Promise<DirEntry>;
  fs_lstat(fs: Handle, path: string): Promise<DirEntry>;
  fs_realpath(fs: Handle, path: string): Promise<string>;
  fs_mkdir(fs: Handle, path: string, mode?: number): Promise<void>;
  fs_rmdir(fs: Handle, path: string): Promise<void>;
  fs_remove(fs: Handle, path: string): Promise<void>;
  fs_rename(fs: Handle, from: string, to: string, replace: boolean): Promise<void>;
  fs_posix_rename(fs: Handle, from: string, to: string): Promise<void>;
  fs_chmod(fs: Handle, path: string, mode: number): Promise<void>;
  fs_symlink(fs: Handle, target: string, linkPath: string): Promise<void>;
  fs_readlink(fs: Handle, path: string): Promise<string>;
  fs_open(fs: Handle, r: OpenFileRequest): Promise<Handle>;
  fs_read(fh: Handle, offset: number, length: number): Promise<ArrayBuffer>; // ≤512 KiB
  fs_write(fh: Handle, offset: number, data: ArrayBuffer): Promise<number>;
  fs_fstat(fh: Handle): Promise<DirEntry>;
  fs_fsync(fh: Handle): Promise<void>;
  fs_truncate(fh: Handle, size: number): Promise<void>;
  fs_fclose(fh: Handle): Promise<void>;
  fs_close(fs: Handle): Promise<void>;

  // P3（数据密钥从不以文件形态落地；Asset 拒绝 → 每次口令）
  vault_open(path: string): Promise<Handle>;
  vault_header(h: Handle): Promise<VaultHeader>;
  vault_unlock_passphrase(h: Handle, pass: ArrayBuffer): Promise<void>;
  vault_unlock_keystore(h: Handle, secret: ArrayBuffer): Promise<void>;
  vault_secret_for_storage(h: Handle): Promise<ArrayBuffer>;
  vault_list(h: Handle): Promise<VaultRecordMeta[]>;
  vault_apply(h: Handle, changes: VaultChange[]): Promise<void>;
  vault_rotate_passphrase(h: Handle, next: ArrayBuffer): Promise<void>;
  vault_lock(h: Handle): Promise<void>;
  vault_close(h: Handle): Promise<void>;

  // P4
  vnc_open(o: VncOptions): Promise<Handle>;
  rdp_open(o: RdpOptions): Promise<Handle>;
  desk_input(h: Handle, e:
    | { kind: 'pointer'; x: number; y: number; button?: number; action: 'down' | 'up' | 'move'; modifiers?: number }
    | { kind: 'key'; keysym: number; action: 'down' | 'up'; modifiers?: number }
    | { kind: 'clipboardText'; text: string }): void;
  desk_expect_size(h: Handle, o: { width: number; height: number; dpr: number }): void;
  desk_close(h: Handle): Promise<void>;
}

declare const native: MottyNative;
export default native;
