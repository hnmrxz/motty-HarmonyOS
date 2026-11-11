# UI 1:1 对照（PC 端 / 2in1）

> 目标：**只做 PC（2in1）**，平板特性暂停。以官方源码与运行中的 Windows 版 motty 为唯一参照。
> 每轮更新「已对齐 / 未对齐」，未对齐项必须写清差异与下一步。

## 一、参照来源（本轮建立）

| 来源 | 位置 | 用途 |
|---|---|---|
| Windows 版 motty（运行中） | 进程 `motty.exe`，窗口截图 `harmonyos/.bin/ui/motty-windows.png` | 像素级视觉参照 |
| 官方 UI 框架 Viva | `E:\viva`（`git clone https://github.com/vivaui/viva`，HEAD `95802a9`） | 组件度量、交互规则 |
| 上游 motty 源码 | `git fetch upstream`（`t8y2/motty` HEAD `54dab1c`） | UI 文案（`internal/i18n/`）、主机页逻辑 |
| 本 fork 源码 | `internal/workbench/host_*.go` | 数据模型与布局常量 |
| DevEco CLI 文档 | `devecocli docs search/read` | ArkUI 布局与交互最佳实践 |

### 从官方源码抄到的确定性事实

- **主机数据模型**（`internal/workbench/host_catalog.go`）：`Host{Label, Group, Tags, Icon, Color, Address, User, Port, Protocol}`；
  分组空名 = 默认组（`HostGroupDefault`），标签为逗号分隔字符串。
- **颜色调色板**（`host_color.go`）：`["", #22c55e, #eab308, #f97316, #ef4444, #3b82f6, #a855f7]`，
  行左缘 3px 圆角竖条做标记（`paintHostColorMark`：x+3、宽 3、高 height-20、圆角 1.5）。
- **卡片度量**（`host_grid.go`）：卡片最小宽 280、高 64、间距 12；分组表头 42；
  列表/网格两种视图共用同一行数据与 id。
- **分组行**：chevron（▸/▾）+ 分组名（Semibold）+ 数量（淡色）。
- **标签预设**（`host_tags.go`）：开发 / 测试 / 生产。
- **官方中文文案**（`internal/i18n/chinese.go`）：
  `SearchPlaceholder = 搜索主机或 ssh user@hostname…`、`NavHosts = 主机`、`NavKnownHosts = 已知主机`、
  `NewHost = 新建主机`、`EditHost = 编辑`、`DeleteHost = 删除`、`HostGroupDefault = 主机`、
  `DeleteHostTitle = 删除主机`、`DeleteHostDescriptionFmt = 删除选中的 %d 台主机？此操作无法撤销。`

## 二、本轮已对齐（可验证）

| 项 | 实现 | 证据 |
|---|---|---|
| 深色主题 + 左侧导航栏杆（品牌 + 10 项） | `pcSidebar()` | `app-pc7.png` |
| 主区顶栏：搜索框（官方占位文案）+ 连接 + 新建主机 | `pcHeader()` | 同上 |
| 筛选 chips：全部 / SSH / RDP / VNC（带计数） | `pcChips()` | 同上 |
| 主机会话模型扩展：分组 / 标签 / 颜色（含老库迁移） | `HostItem` + `migrateHosts()` | 建/编辑表单与列表 |
| 分组渲染（名称 + 数量 + 折叠） | `sections()` / `toggleGroup()` | 截图两组 |
| 行样式：颜色竖条 + 圆形首字母头像 + 名称/用户 + 右对齐地址 + 标签 chip | `hostListView()` | 截图两行 |
| 行内操作改为**悬停显示**（默认隐藏，id 仍保留在树上供用例使用） | `.onHover` | 截图 |
| 默认中文界面 | `lang = 'zh'` | 截图 |

## 三、未对齐（下一步）

1. **导航图标**：现在是首字符占位，官方是线性图标 → 接入 `SymbolGlyph`（API 26 系统符号）或自绘图标。
2. **列表/网格双视图 + 排序**（官方 `paintHostViewToggle`）：需加右上角视图切换与排序按钮。
3. **行内操作菜单**：官方是悬停「⋯」菜单 + 右键上下文菜单（多选、全选当前分组、批量删除）。
4. **分组表头**：需支持嵌套分组（`hostGroupWithin`）、置顶（Star）、分组级全选。
5. **窗口尺寸**：`mainWin.resize(1500,860)` 在 2in1 模拟器上未生效，需查 `window` 尺寸限制或改用
   `setWindowLimits` + `windowStage` 的默认尺寸配置。
6. **应用标题**：窗口标题仍是 `label`（应为 `Motty`），需改 `module.json5`/`app.json5` 的 label 资源。
7. **图标与标志**：官方顶部还有九宫格/新建按钮、右侧排序与设置入口。

## 四、验证方式（每轮）

```powershell
# 截图对照
devecocli ui screenshot --device 127.0.0.1:10100 --path harmonyos/.bin/ui/app-pc.png
# 结构核对
devecocli ui layout --device 127.0.0.1:10100
# 用例
python harmonyos/spec/run.py harmonyos/spec/scenarios/<spec>.yaml --serial 127.0.0.1:10100 --profile 2in1
```

> 说明：`harmonyos/.bin/ui/motty-windows.png` 是 Windows 版字体渲染的参照，仅用于对比布局与颜色，
> 不作为测试断言（像素级比对不入 CI，避免字体差异造成假失败）。

---

## Round 2 追加：补齐「顶部工具栏 / 侧栏底部 / 主区右侧按钮 / 分组 chips / 行内复选框与状态」

### 新增对齐项（对照用户提供的完整窗口截图）

| 区域 | 官方（截图） | 现在 |
|---|---|---|
| 顶部工具栏 | 左：九宫格 + ＋；右：排序/粘贴/终端/搜索/AI/通知/设置 | `pcTopBar()`，id `top/*` |
| 侧栏品牌 | M 标 + `motty` 词标 | 已有 |
| 侧栏导航 | 10 项 + 底部「本地终端 / 设置」 | 10 项 + `nav/local-terminal`、`nav/settings` |
| 导航图标 | 线性图标（lucide） | **直接取上游 `internal/workbench/icons/*.svg`**（34 个） |
| 主区顶栏右侧 | 导入/导出 + 新建主机（浅色主按钮） | `hosts/import-export` + `shell/add-host`（浅色） |
| 筛选行 | 全选复选框 + 全部/个人/求是物业（带计数）+ 右侧展开收起/列表/网格/排序 | `chips/select-all`、`chip/all`、`chip/group/*`、`chips/collapse|expand`、`view/*` |
| 分组表头 | 复选框 + chevron + 名称 + 数量 + 行尾「⋯」 | 已对齐，`group/menu/<组名>` |
| 数据行 | 复选框 + 颜色条 + 圆形头像 + 名称/用户 + 地址 + 生产/测试标签 + 未连接 | 已对齐，`host-check/i`、`host-status-text/i` |
| 窗口标题 | `Motty` | `EntryAbility_label` 已改为 `Motty` |

### 关键技术点（踩坑记录）

1. **lucide 图标是描边图标**（`fill="none" stroke="currentColor"`），ArkUI `Image.fillColor()` 对描边无效
   → 把 SVG 里的 `stroke="currentColor"` 批量替换为固定色 `#C7CBD1`，代码里不再用 `fillColor`。
2. 隐藏行内操作时**不能用 `opacity(0)`**：它仍占布局，把标题挤成 `Ora…`；
   → 给操作区固定宽度 + 标题列 `layoutWeight(3)`，地址/状态列收窄。
3. 之前一次脚本因锚点断言失败**整轮改动未落盘**，日志里却显示"构建成功"；
   → 每轮改完必须**截图验证**，不能只看 BUILD SUCCESSFUL。

### 尚未对齐（下一轮）
- 列表/网格**真实切换**（目前只有图标占位）
- 分组「⋯」与行「⋯」的**上下文菜单**（多选、全选当前分组、批量删除）
- 行的 **OS 图标**（官方按 Linux 发行版显示彩色图标；我们现在是首字母）
- 导入/导出、排序、设置等按钮的**实际功能**
- 窗口默认尺寸（`resize(1500,860)` 在 2in1 模拟器未生效）

---

## Round 3 追加：列表/网格双视图 + 排序 + OS 彩色图标

### 已对齐
| 项 | 实现 |
|---|---|
| 视图切换（真实生效） | `view/list` / `view/grid` 切换 `hostView`；网格用官方度量：卡片 280×64、间距 12 |
| 排序（三态循环） | `view/sort`：manual → name → ip（官方 `hostSort` 的 name/IP/手动语义） |
| 分组内排序 | `sortedHosts(group)` 只对当前分组过滤+排序，符合官方"按分组渲染"的顺序 |
| **OS 彩色图标** | 从上游 `internal/workbench/icons/` 取 18 个发行版图标（`os_oraclelinux/ubuntu/debian/centos/redhat/windows/synology/openwrt/alpine/arch/freebsd/esxi/proxmox/fedora/kali/…`），按标签/地址关键词匹配 |
| 网格卡片内容 | OS 图标 + 名称 + 用户 + 地址 + 标签 chips，点击连接 |
| 列表行图标 | 有 OS 图标显示图标，否则颜色圆底首字母 |

### 已知问题（下一轮修）
1. `NAS` 行仍显示首字母而非 synology 图标：`osIcon()` 命中判断在列表里未生效（网格里正常），
   怀疑 ArkTS 在 `if (this.osIcon(h) !== null)` 分支对 Resource 的判空行为与网格分支不同 → 改用
   `hasOsIcon(h): boolean` + `osIconRes(h): Resource` 两个方法分离。
2. 网格卡片在窗口很窄时不会自动降到单列（现在固定 280 宽 + wrap，窗口 < 600 时会溢出）。
3. 排序未持久化（官方会 `state.save()`）。

### 证据
`harmonyos/.bin/ui/app-grid.png`（网格 + Oracle/NAS/测试/求是）、`app-list2.png`（列表 + OS 图标）。

---

## Round 4 追加：多选 / 批量删除 / 行与分组「⋯」上下文菜单

### 已对齐
| 项 | 实现 | 证据 |
|---|---|---|
| 行「⋯」上下文菜单 | `bindMenu`：连接 / 文件 / 编辑 / 删除（id 仍在树上，老用例不受影响） | 代码 |
| 分组「⋯」菜单 | 全选本组 / 取消全选 / 折叠本组 / 展开本组 | 代码 |
| **多选** | `selectedIds` + 行复选框 + 顶部全选按钮（真正联动） | `app-batch2.png` 中 `已选 2` |
| **批量操作条** | 选中后出现「已选 N / 批量删除 / 清除」（`chips/delete-selected`、`chips/clear-selection`） | 同上 |
| 批量删除语义 | 逐台删除 hosts + known_hosts + 保险库口令（与官方 DeleteHost 一致） | `deleteSelected()` |
| OS 图标判定拆分 | `osIconKey()/hasOsIcon()/osImage()` 三个方法，避免 `@Builder` 内 Resource 判空差异 | 代码 |

### 本轮踩坑
- ArkTS **`@Builder` 里对 `Resource` 做 `!== null` 判空不可靠**（列表不生效、网格生效），
  必须拆成"布尔方法 + 取资源方法"。
- 用 `opacity(0)` 隐藏的操作区仍参与布局，会把标题挤断（Round 2 已记）。
- 批量替换 `.opacity(this.selectAll …)` 时**误伤了分组表头与全选按钮**（那里没有 `h` 变量），
  编译报 `Cannot find name 'h'`；已按上下文回退。

### 待验证（下一轮）
- 列表行里 `NAS` 是否显示 synology 图标（网格已确认能显示 Oracle 图标）；需要用 `devecocli ui layout`
  精确取到该行头像节点再判断是"图标没渲染"还是"分支没走"。
- 行复选框被行级 `onClick` 吞掉点击的问题（当前用顶部全选作为可靠入口）。

