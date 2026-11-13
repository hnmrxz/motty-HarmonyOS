# Motty HarmonyOS 移植：阶段报告（Round 128）

## 1. 交付概览

| 项 | 数值 |
|---|---|
| 仓库 | `E:\motty-HarmonyOS`（fork，全部新增在 `harmonyos/`） |
| 用例总数 | **108**（`spec/scenarios/*.yaml`） |
| 最近一次完整全量 | **91/91 全绿**（full107，此前连续 15 次全绿） |
| 当前构建 | `BUILD SUCCESSFUL` |
| 静态校验 | `lint.py` / `check-ids.py` / `check-paging.py` 全绿 |

## 2. 已实现（PC 端 / 2in1）

- **主机**：增删改、分组、标签、颜色、图标、最近连接、详情（含打开/编辑/删除）、协议筛选、网格/列表、批量删除
- **分组**：折叠、固定、重命名、删除、上移/下移排序（DB 持久化）
- **终端**：PTY、VT 解析、滚回、选区复制、改尺寸、方向键、字号/回滚行数设置
- **SFTP**：列举/读写/删除/改名/建目录/中文名/缺失文件
- **端口转发**：local/SOCKS5/HTTP，规则持久化、启停、编辑、清空
- **VNC**：RFB 3.8、None/DES、Raw+Hextile、指针/键盘、剪贴板、DesktopSize、**从主机打开进会话**
- **RDP**：协商+TLS、自解码位图、BMP 预览与会话视图、输入投递探针、内嵌 shadow 服务端
- **命令面板**：模糊过滤、↑↓、回车、Esc、悬停高亮、主机直达
- **设置**：语言、视图、排序、终端字号、回滚行数、标签编号、侧栏标签、显示最近连接/会话计数、启动打开什么、恢复默认
- **其他**：会话日志（搜索/协议筛选/主机筛选/导出/清空）、密钥链（新增/删除）、已知主机（清空/导入/导出）、工作区（会话列表/切换/关闭/关闭其他/重命名）、调试面板三页

## 3. 唯一阻塞：模拟器无法启动（需一次提权）

- 现象：`Emulator.exe` 有进程、`-list -details` 显示 `isRunning=true`，但 `-instance motty_pc -uiLayout` 报
  *"emulator is not started"*，`qemu` 进程不存在，`hdc list targets` 为空
- 根因：`Hyper-V 主机计算服务 vmcompute` = `Manual/Stopped`；`sc start vmcompute` → **Access is denied**
- `systeminfo`：**hypervisor 已检测到**，所以只差启动服务
- 需要：**管理员身份**的 DevEco Studio 启动 `motty_pc`，或管理员 PowerShell `Start-Service vmcompute`

## 4. 待补 E1（13 条，设备恢复后一条命令）

```
--only vault,settings.tab,settings.scrollback,settings.display,settings.startup,settings.reset,
       jump,knownhosts,logs,workspace
```

## 5. 未完成（按成本，非阻塞）

| 项 | 说明 |
|---|---|
| 浅色主题 | 需全量颜色主题化，成本最高 |
| pane 分屏（上游 workspace deck） | 需布局引擎改造 |
| RDP 常驻会话 + 真键鼠映射 | 需 render worker 常驻并暴露 SendInput |
| ProxyJump 跳板 | libssh2 无可插拔 transport，需自建 socket 抽象 |
| arm64 真机 / 上架合规 | 需设备/证书/账号 |
| 平板形态 | 按目标暂停 |

## 6. 诚实性说明

- E1 = 模拟器实测通过；E2 = 编译/静态通过；E3 = 未验证
- 设备不可用期间新增的 13 项一律标注 **E2**，清单在 `docs/E1-BACKLOG.md`
- 本轮起静态校验三件套（schema / id / 分页）作为提交前门禁

## 附：Round 129~138 的 UI 一致性收尾（均 E2）

| 轮次 | 内容 |
|---|---|
| 129~130 | 顶栏按钮全部接行为：新会话/刷新/排序切换/粘贴/本地终端/AI/通知 + 提示行 |
| 132 | 主机行「⋯」自绘菜单（打开/编辑/详情/复制/删除）—— bindMenu 不进 dump，故自绘 |
| 133 | 主机行操作区 hover 显隐（opacity 0.3→1，保持可点击） |
| 131 | `check-all.ps1`：build + lint + check-ids + check-paging 一条命令 |
| 134 | 设置「界面字号」三档（fs() 只缩放文字尺寸） |
| 135~137 | i18n 清理：端口转发/已知主机/终端工具条的英文标签、表单字段、命令面板、顶栏提示、设置/转发结果全部双语 |
| 138 | 空态统一：`known/empty` 双语，其余 7 处确认已双语 |

**门禁**：`build SUCCESSFUL`，`lint 全部通过`，`check-ids: dup 0 / 缺失 0`，`check-paging: 0 违规`。

