# 82 个 e2e 脚本的转译批次计划

> 输入：upstream `tools/e2e/*.txt`（**82 个**，实测）+ 1 个已改编样例。
> 输出：`spec/scenarios/*.yaml`（schema 见 [scenario.schema.json](./schema/scenario.schema.json)）。
> 判定：每个 spec 必须能由 runner 在 **2in1 与 tablet 双画像**上跑出机器判定结果。

## 0. 三条已被实测钉死的前提

1. **不能直接跑**：原脚本内嵌 POSIX 路径（`/tmp/...`）、UTF-8 BOM、且依赖 TAB 焦点顺序。三类缺陷已在 `host_menu_move` 上全部遇到并修好（见 [A-PRIME-ENGINEERING.md](../A-PRIME-ENGINEERING.md) §7.2）。
2. **选择器只允许 `id:` / `role:` / `label:`**，**禁止坐标**——坐标在双画像与不同 DPI 下必然失效。稳定 id 由 `tree` 命令直接取（实测可用，例如 `shell/dialog-address`）。
3. **网络通则**：设备 → 宿主用 `hdc rport tcp:2222 tcp:2222`。M0.5 已把这条固化进脚本，spec 里用 `network.hdcReversePort` 声明。

## 1. 批次划分（按依赖夹具聚簇，而不是按字母序）

| 批次 | 主题 | 数量 | 依赖夹具 | 预计 |
|---|---|---|---|---|
| B0 | 已完成样例 | 1 | 无 | 已完成 |
| B1 | 主机与认证 | 11 | `e2esshd`（pty/证书/agent） | 最先做，是 M1 的门 |
| B2 | 终端 | 8 | `e2esshd` | 与 B1 并行 |
| B3 | 文件与传输 | 5 | `e2esshd`（SFTP/SCP-only 开关） | M2 |
| B4 | 会话/标签/IME/剪贴板 | 8 | 无外部夹具 | M1 后段 |
| B5 | 网络与安全确认 | 4 | `e2esshd` 远端转发 | M2 |
| B6 | AI 与 agent | 4 | MCP 客户端夹具 + `e2esshd` agent | M4 |
| B7 | 数据/同步/保险库 | 8 | `fakes3` + 本地 WebDAV/Gist stub | M4 |
| B8 | 远程桌面 | 3 | `tools/live` 的 VNC/RDP 容器 | M3（单独立项） |
| B9 | 远端工具/监控 | 5 | 远端 Linux 工具集 | 后段 |
| B10 | 设置/片段/杂项 | 11 | 无 | 随功能 |
| B11 | **不适配为 spec** | 14 | — | 只登记，不转译 |

---

## B0 已完成（1）

| 脚本 | 可移植性 | 备注 |
|---|---|---|
| `host_menu_move_e2e` | ✅ 已改编通过 | 三类缺陷的修复样例；作为转译器的黄金用例 |

## B1 主机与认证（11）

| 脚本 | 可移植性 | 备注 |
|---|---|---|
| `host_test_e2e` | ✅ | 需 `e2esshd` pty |
| `host_cert_e2e` | ✅ | 需 `e2esshd` 主机证书模式 |
| `user_cert_e2e` | ✅ | OpenSSH 用户证书 |
| `credentials_e2e` | ✅ | 多问题 keyboard-interactive |
| `ppk_e2e` | ✅ | Argon2id ppk；**格式必须与原版字节兼容** |
| `host_filter_chips_e2e` | ✅ | 纯 UI |
| `host_group_tree_e2e` | ✅ | 纯 UI |
| `host_shared_destination_e2e` | ✅ | 纯 UI |
| `issue602_multi_delete_e2e` | ✅ | 批量删除回归 |
| `otp_paste_e2e` | ✅ | TOTP 粘贴 |
| `autofill_e2e` | ✅ | 规则默认停用，首次询问 |

## B2 终端（8）

| 脚本 | 可移植性 | 备注 |
|---|---|---|
| `terminal_protocols_e2e` | ✅ | 协议矩阵（DECSET/备用屏等） |
| `terminal_flood_e2e` | ✅ | **性能数字必须在目标设备重标定**，模拟器数字不可引用 |
| `terminal_drag_scroll_e2e` | ✅ | 触控拖动 = 滚轮回滚 |
| `terminal_menu_e2e` | ✅ | 触控下右键→长按（deviation 必写） |
| `terminal_link_bell_e2e` | ✅ | OSC 8 链接 + bell |
| `terminal_find_button_hover` | ⚠️ | hover-only 入口 → 触控形态改常显（deviation 必写） |
| `terminal_find_keeps_rail` | ✅ | 查找栏保持 |
| `word_separators_e2e` | ✅ | 文本选择分词 |

## B3 文件与传输（5）

| 脚本 | 可移植性 | 备注 |
|---|---|---|
| `sftp_only_e2e` | ✅ | 只开 SFTP 子系统的对端 |
| `sftp_search_e2e` | ✅ | 远端搜索 |
| `scp_e2e` | ✅ | 无 SFTP 时的 SCP 回退 |
| `editor_open_e2e` | ✅ | 内置编辑器 1 MiB 上限 |
| `terminal_drop_upload_e2e` | ⚠️ | 拖放：PC 系统拖拽；平板改 filePicker 入口（deviation） |

## B4 会话/标签/IME/剪贴板（8）

| 脚本 | 可移植性 | 备注 |
|---|---|---|
| `tab_move_e2e` | ⚠️ | PC 多窗口 vs 平板分屏内移动 → 双画像要分别断言 |
| `tab_title_e2e` | ✅ | 标题规则 |
| `login_command_e2e` | ✅ | 会话后命令 |
| `preedit_e2e` | ✅ | 输入法 preedit |
| `preedit_width_e2e` | ✅ | 宽字符 preedit |
| `clipboard_osc52_e2e` | ⚠️ | **鸿蒙版默认改 ask**（R13）→ 断言随之改，deviation 必写 |
| `paste_image_e2e` | ✅ | 图片粘贴；读剪贴板可能需用户手势 |
| `paste_key_e2e` | ✅ | 按键粘贴 |

## B5 网络与安全确认（4）

| 脚本 | 可移植性 | 备注 |
|---|---|---|
| `local_proxy_e2e` | ✅ | 只绑 loopback |
| `proxy_start_stop_e2e` | ✅ | 规则生命周期 |
| `remote_http_consent_e2e` | ✅ | "允许不安全的远程 HTTP"确认框 |
| `session_link_e2e` | ⚠️ | 桌面 `url_schemes` → 鸿蒙用 **App Linking**（域名校验），不裸 scheme（SEC-02） |

## B6 AI 与 agent（4）

| 脚本 | 可移植性 | 备注 |
|---|---|---|
| `agent_mcp_setup_e2e` | ✅ | MCP 默认关闭、开启后才监听 |
| `agent_mcp_activity_e2e` | ✅ | observe/ask 模式行为 |
| `ai_provider_import_e2e` | ⚠️ | 导入源本是文件路径 → 改成内置样例 + filePicker |
| `agent_forward_e2e` | ❌→需先决策 | **鸿蒙无 ssh-agent**（实测），需"应用内 agent 桥"才能过；D3 未定前不得标记为可移植 |

## B7 数据/同步/保险库（8）

| 脚本 | 可移植性 | 备注 |
|---|---|---|
| `vault_e2e` | ✅ | 解锁/超时/拒绝不回退文件 |
| `vault_kbi_e2e` | ✅ | 保险库 + keyboard-interactive |
| `cloudsync_e2e` | ✅ | `fakes3` |
| `cloudsync_e2e_b` | ✅ | 同上（另一路径） |
| `cloudsync_samehost_a` | ✅ | 同主机双端合并 |
| `cloudsync_samehost_b` | ✅ | 同上 |
| `ssh_config_sync_e2e` | ✅ | SSH config 同步 |
| `reverse_sync_old_bash_e2e` | ✅ | 终端→文件栏目录同步 |

## B8 远程桌面（3）

| 脚本 | 可移植性 | 备注 |
|---|---|---|
| `vnc_e2e` | ✅ | `tools/live` VNC 容器 |
| `rdp_e2e` | ✅ | `tools/live` RDP；证书 pin + MinVersion ≥1.2 |
| `rdp_files_e2e` | ✅ | 文件拖放通道 |

## B9 远端工具/监控（5）

| 脚本 | 可移植性 | 备注 |
|---|---|---|
| `remote_tools_e2e` | ⚠️ | 需远端 Linux 工具集（ps/docker 等） |
| `remote_tools_legacy_e2e` | ⚠️ | 老版本兼容路径 |
| `tools_e2e` | ⚠️ | 同上 |
| `docker_create_e2e` | ⚠️ | 需远端 docker；模拟器内不可验 |
| `gpu_stats_e2e` | ⚠️ | GPU 统计，平台相关 → 需重标定或降为 T2 |

## B10 设置/片段/杂项（11）

| 脚本 | 可移植性 | 备注 |
|---|---|---|
| `snippet_multiline_e2e` | ✅ | |
| `snippet_send_e2e` | ✅ | |
| `snippet_shortcut_e2e` | ✅ | |
| `snippet_sort_e2e` | ✅ | |
| `snippet_toolbar_e2e` | ✅ | 工具栏可停靠：平板改长按菜单 |
| `scheme_drawer_e2e` | ✅ | 配色抽屉 |
| `history_e2e` | ✅ | 历史搜索 |
| `ghost_e2e` | ✅ | 行内建议 |
| `relaunch_setting_e2e` | ✅ | **注意 epoch 23 不得抬**（R18） |
| `share_e2e` | ⚠️ | 系统分享行为不同 → T2 |
| `shell_relay_e2e` | ✅ | 中继转发 |

## B11 不转译为 spec（14）—— 只登记，并在能力矩阵里标 T3/T2

| 脚本 | 原因 |
|---|---|
| `local_shell_windows_e2e` | Windows 本地 shell → **T3**（沙箱禁 exec，已实测 EACCES） |
| `monitor_macos_e2e` | macOS 专用监控 → **T3** |
| `tray_e2e` | 托盘：PC 待验证 T2 / 平板无 → **T3** |
| `readme_desktop` | 截图专用（README 素材），非验收 |
| `readme_forward` | 同上 |
| `readme_forward_light` | 同上 |
| `readme_hero` | 同上 |
| `readme_hosts` | 同上 |
| `readme_hosts_light` | 同上 |
| `readme_monitor` | 同上 |
| `readme_settings_colors` | 同上 |
| `readme_sftp` | 同上 |
| `readme_sftp_light` | 同上 |
| `hero_shot` | 同上 |

> 这 14 个占 82 的 17%。它们不是"被砍掉的功能"，而是**本来就不是行为验收**（12 个）或**已判 T3**（3 个）。B11 必须在验收报告里逐条列出，不能默默忽略。

---

## 2. 转译器工作流（半自动）

1. `tree` 抓一次真实界面 → 得到 `role/id/label/state`
2. 把原脚本的 `click "文案"` 映射为 `click id:<stable-id>`；映射表落 `spec/mappings/<script>.json` 备审
3. 生成 `spec/scenarios/<id>.yaml`，`deviations` 自动预填三类（路径/BOM/TAB）与人工补充项
4. `spec-lint`：schema 校验 + `profile` 必须含两画像 + `asserts` 非空 + `capabilities` 必须存在于注册表 + `evidence.limits` 非空
5. runner 在 2in1 与 tablet 各跑一遍，产出 PNG + tree + testSurface dump

**验收判定**：一个 spec 只有同时满足「schema 绿 + 双画像绿 + limits 已填」才算转译完成。

## 3. 与里程碑的挂接

| 里程碑 | 需要的批次 | 门 |
|---|---|---|
| M0.5 | B0 + B1(前 3 个) + 转译器 + lint | 10 个 spec 可跑 |
| M1 | B1 + B2 + B4 | 10 spec 等价 + 双画像 + 触控核心路径 |
| M2 | B3 + B5 | 文件与转发等价 |
| M3 | B8 | 桌面等价（单独立项） |
| M4 | B6 + B7 | AI/同步等价 |
| M5 | B9 收尾 + B10 | 打包与合规 |

**B6 的 `agent_forward_e2e` 与 `session_link_e2e` 依赖未决项 D3 与 D2**，在决策前不得排期。
