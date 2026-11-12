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

---

## Round 5 追加：行复选框点击修复 + 图标渲染确认

### 修掉的
| 问题 | 根因 | 修法 |
|---|---|---|
| 行内复选框点击无效（顶部全选却可用） | `Text` 的点击区在 `Row`/`ListItem` 内被父级命中测试吞掉 | 改成 `Button` + `.hitTestBehavior(HitTestMode.Block)`，并缩小行内右侧列宽避免挤压 |
| 行点击误吞操作 | 整行曾被设了 `onClick(() => {})` | 删除行级 `onClick`，改为只有"名称/用户列"可点开连接 |

### 确认（用 DevEco CLI 判断，不靠肉眼）
- 给头像加 id 后 `devecocli ui layout` 显示：`host-avatar-icon/0`、`host-avatar-icon/1` 都存在
  ⇒ 两行都走了 **OS 图标分支**（不是首字母回退）。
- 之前把 `NAS` 行那个"灰底白 S"误判成首字母回退——**它其实是 Synology 品牌图标本身**。
  结论：OS 图标功能是好的，之前的怀疑来自肉眼误读，不是代码问题。

### 交互验证（脚本点击 + 结构断言）
```
select-all 点击        -> 批量操作条出现 (True)
chips/clear-selection  -> 批量操作条消失 (False)
host-check/0 点击      -> 批量操作条出现 (True)
```

### 记录的一个坑
- 用 PowerShell 写含 `☑/☐` 等符号的 ArkTS 代码时，**编码会把符号写坏**（显示成 `鈽?`）。
  虽未导致编译失败，但会让 `Text(...)` 字面量退化。**含非 ASCII 符号的代码行必须用 Python 以 UTF-8 写入**，
  写完后用 `dump`/编译双重确认。

---

## Round 6 追加：主机目录导入/导出（官方 `motty-host-catalog` v4）+ PC-only 用例机制

### 照官方源码实现的格式
`internal/workbench/host_catalog_transfer.go` + `persist.go`：

```json
{ "format": "motty-host-catalog", "version": 4,
  "hosts": [ { "id","label","group","tags":[],"icon?","color?","address","user","port","system?" } ],
  "groups": [ { "name","collapsed?","explicit?","pinned?","order?" } ] }
```

### 已实现
| 能力 | 入口 | 说明 |
|---|---|---|
| 导出（系统文件选择器） | `hosts/import-export` → 导出目录… | `DocumentViewPicker.save` 写 `.json` |
| 导入（系统文件选择器） | `hosts/import-export` → 导入目录… | `DocumentViewPicker.select` 读，校验 format/version≤4，按 label+address+port 去重 |
| 导出（沙箱，可自动化） | 诊断面板 `catalog/export-file` | 写 `cacheDir/motty-hosts.json`，结果行显示路径/字节数/主机数 |
| 导入（沙箱，可自动化） | 诊断面板 `catalog/import-file` | 回读同一文件，结果 `added=/dup=/total=` |
| 清空主机（仅测试助手） | 诊断面板 `catalog/reset-hosts` | 便于验证"导入新增"，正式 UI 不暴露 |
| 结果常显 | `catalog/result` | 放在按钮旁边（不放进折叠区，否则 dump 抓不到） |

### 实测（脚本 + 用例）
```
catalog-export: /data/storage/el2/base/haps/entry/cache/motty-hosts.json (615 bytes, 2 hosts)
catalog-import: added=0 dup=2 total=2        # 幂等
用例 host.catalog：export -> reset(hosts=0) -> import -> added=2 dup=0 total=2  PASS
```

### 新增的测试基础设施
- `spec/scenarios/host.catalog.yaml` 标 `pcOnly: true`；
- `spec/lint.py` 增加 `pcOnly` 分支（只要求 2in1）+ `schema/scenario.schema.json` 增加 `pcOnly` 字段；
- 原因：目标已改为"只做 PC 端"，但双画像规则仍是默认要求，pcOnly 让 PC 专用用例合法且不假装平板已验证。

### 已知限制
- 系统文件选择器路径无法自动化（需要人工交互），所以证据用的是沙箱版本；
- `groups` 字段已写出但导入时未恢复折叠状态；
- `version > 4` 与非法 JSON 的拒绝路径未加入用例（有代码分支）。

---

## Round 7 追加：窗口尺寸生效 + 布局裁切修复

### 修掉的
| 问题 | 根因 | 修法 |
|---|---|---|
| `mainWin.resize()` 完全没生效 | 用的是**回调式** `getMainWindow((err, win) => …)`，该签名在此 API 版本下不触发 | 改成 Promise：`windowStage.getMainWindow().then(...)`，并在 then/catch 里各打一条 hilog |
| 缩窗口后内容被裁（侧栏底部「本地终端/设置/English」看不到） | 顶栏用 `Stack()` + 内容 `.margin({top:38})` 硬顶下来，高度 100% 再被 margin 顶出可视区 | 顶栏改为**布局内元素**：`Column(){ pcTopBar(); Row(){侧栏, 主区}.layoutWeight(1) }`，不再用 margin 补丁 |
| 窗口偏小 | `resize(1500,860)` 实际得到的窗口反而更小（单位与缩放比不是 vp） | 改为 `resize(2400,1500)`，实测窗口明显变大且内容完整 |

### 实测
```
hilog: resize ok 1500x860        # 旧目标也“成功”，但窗口反而变小
hilog: got main window, resizing # 现在能看到完整链路
截图 win3.png：窗口变大、侧栏底部四项完整可见、无裁切
```

### 学到的一条
- `getMainWindow` 的回调式与 Promise 式行为不一致；**凡是没有日志的“没生效”，先怀疑调用签名**。
- 布局上尽量不用“视觉平移”的 margin 补丁，改成 flex 里真实的兄弟关系，窗口缩放才不会裁切。

### 仍未做
- 设置页（`nav/settings` 目前是禁用态）
- 排序/视图模式的持久化（官方 `state.save()`）

---

## Round 8 追加：设置页 + 偏好持久化（对应官方 `state.save()`）

### 已实现
| 项 | 入口 | 说明 |
|---|---|---|
| 设置面板 | 侧栏 `nav/settings` → `settings/panel` | 语言 / 默认视图 / 排序 / 关于 |
| 语言 | `settings/lang-zh` / `settings/lang-en` | 切换后立即生效并保存 |
| 默认视图 | `settings/view-list` / `settings/view-grid` | 与主区视图按钮同步 |
| 排序 | `settings/sort-manual` / `sort-name` / `sort-ip` | 三态，保存 |
| 关于 | 面板底部 | 上游 Apache-2.0、ArkTS+NAPI 实现、RDP 实验性声明 |
| **持久化** | `@kit.ArkData` preferences（`motty-ui`） | `lang` / `hostView` / `hostSort` 三项 |

### 实测（含重启）
```
改后 grid: True
aa force-stop -> aa start
重启后 grid: True        # 偏好被读回
用例 settings.persist  PASS（先建 persist-a 主机 -> 改网格/排序 -> restart -> 仍能看到 persist-a 与计数条）
```

### 踩坑
1. `loadPrefs` 第一次被插到了 **`confirmDeleteHost()`** 里（字符串替换命中错误位置），导致启动时从未加载偏好；
   改为放进 `initStore()`，并用"改设置 → 重启 → 观察"的方式验证，而不是只看代码。
2. runner 的 `shell` 动作是**宿主命令**，不是设备命令；设备重启要用 `restart` 动作。
   一开始用 `shell: aa force-stop …` 直接报 `'aa' is not recognized`。
3. 网格视图**没有空态文案**（列表才有），所以断言不能用"还没有主机"；改为先建一台主机再断言主机名。

### 仍未做
- 设置项还很少（官方设置页有连接超时/保活/重连/AI 等大量项）
- 偏好文件损坏的回退、导出偏好

---

## Round 9 追加：会话日志页 + 密钥链页（侧栏两项从"禁用"变"可用"）

### 已实现
| 页面 | 入口 | 内容 |
|---|---|---|
| 会话日志 | `nav/logs` → `logs/list`、`logs/empty`、`logs/refresh`、`logs/clear` | 新表 `session_logs(id,label,address,proto,started_at)`；`openSession()` 在凭据检查**之前**先落一行；按时间倒序最多 200 条 |
| 密钥链 | `nav/keys` → `vault/list`、`vault/empty` | 只列已保存凭据的 key（`address:port`），可删除；显式声明"口令在 Asset Store，这里不显示明文" |
| 路由 | `pcNav` 状态 | 主机 / 会话日志 / 密钥链三页切换；点回「主机」恢复列表或网格 |

### 用例（pcOnly）
- `pages.logs-vault`：建主机 → 点名称列触发连接 → 进会话日志页 → 断言主机名出现在日志里 → 进密钥链页 → 回主机页。**PASS**
- `host.catalog`、`settings.persist` 本轮复跑仍 **PASS**。

### 这轮暴露的一个真问题（重要）
第 2 轮为了让行内操作"悬停才出现"，用了 `opacity(this.hoverRow === index ? 1 : 0)`。
**但 opacity=0 的节点不进 UITest 的 dump**，于是 25 条依赖 `host-open/0`、`host-files/0` 的旧用例全部失效
（复跑 `sftp.manage` 时第一次就失败在这一步）。

处置：**行内操作恢复常显**（与参照的悬停交互存在差异，记在这里）：
- 去掉行内「⋯」按钮（其菜单与右侧按钮重复），按钮宽度 190，图标按钮 24×24；
- 结果：`host-row/0`、`host-files/0`、`host-open/0`、`host-edit/0` 都能被 dump 到；
  `host-del/0` 在 5 个按钮时仍会被挤出，后续要么再收窄、要么把删除挪进菜单。

### 本轮仍未修（下一轮）
- `host.manage`：第 13 步等 `manage-b` 超时（编辑流程或列表刷新时序，待定位）
- `sftp.manage`：第 13 步点不到 `sftp/entry/hello.txt`（可能是夹具未运行或列表渲染变化）
- `host-del/0` 仍会被挤出可见区

### 教训
**"视觉上隐藏"和"自动化可见"是两件事**。以后凡是要靠 dump 断言的控件，不能用 opacity 隐藏；
要用 `visibility` 之外的布局手段（例如抽屉/菜单），或给测试专用 id 放在可见区域。

---

## Round 10 追加：新建/编辑对话框的真实缺陷（回填 + 输入同步）

### 修掉的
| 问题 | 根因 | 修法 |
|---|---|---|
| **编辑主机时表单不回填**（点"编辑"后名称/地址都是空，提交直接返回） | 对话框的 `TextInput` 只写了 `placeholder`，**没有绑 `text`** | 全部字段改为 `text: this.formXxx` |
| 绑 `text` 后**输入不再进状态**（`uiInput inputText` 注入不触发 `onChange`，提交时 `formLabel` 还是旧值） | 单向 `text:` 绑定与 IME 注入的交互问题 | 改为双向绑定 `text: this.formXxx!!`（API 18+ 语法）；用调试文本验证：输入后状态确实变成 `manage-amanage-b` |

### 验证方式（这次没有靠猜）
在对话框里临时插一行 `Text('state=[' + this.formLabel + ']').id('dbg/form-label')`，逐步读 dump：
```
输入 manage-a 后      state=[manage-a]
点编辑回填            state=[manage-a]
再输入 manage-b 后    state=[manage-amanage-b]     ← 双向绑定生效
```
调试文本随后已移除（保留会成为噪声）。

### 仍然失败的两条用例（如实记录，未修复）
- `host.manage`：编辑后断言主机名超时
- `sftp.manage`：第 13 步点不到 `sftp/entry/hello.txt`

排查中发现两个**干扰现象**，会误导判断，记下来：
1. runner 失败信息里的"屏幕文本"**只截取前 120 字符**，看起来像"主区整个消失"，其实只是截断；
2. 某些时刻 dump 抓到的是**桌面（launcher）**而不是应用窗口——应用当时不在前台，
   于是断言文本里没有任何主区内容。这条还没定位到触发条件（可能是窗口 resize 后焦点/层级变化）。

### 附带确认
`pages.logs-vault`、`settings.persist` 在本次改动后**复跑仍 PASS**，说明对话框修复没有破坏既有流程。

---

## Round 11 追加：撤销窗口 resize + 对话框改「种子值」模式 + 夹具生命周期

### 1) 撤销主动 resize
Round 7 打开 `supportWindowMode` + `resize(2400,1500)` 后，出现"有时 dump 抓到桌面"、"主区文本消失"的现象；
Round 11 把 resize **移除**（只保留深色背景设置），让窗口回到系统默认尺寸与位置。
- 结论：**2in1 上主动改窗口尺寸会影响后续点击/焦点归属**，这条能力先不做，比"尺寸好看"重要。

### 2) 对话框改「种子值」模式（真实修复）
`text:` 绑定在重渲染时会把旧状态回灌，覆盖用户输入（runner 的输入路径还会按 ENTER 提交组合）。
改为：
- `seedLabel/seedAddress/…` 只在对话框**创建时**给初值，之后不再变化；
- `onChange` 写入 `formLabel/…`，提交读 `formLabel`；
- 不再使用 `!!` 双向绑定（它在 IME 路径下同样有回灌问题）。
效果：编辑时表单能正确回填，且用户输入不会被回灌覆盖。

### 3) 夹具（sshfixture）生命周期是独立问题
`sftp.manage` 的失败与代码无关：**夹具进程残留旧 hostkey/会话时就会卡在 hello.txt**。
处置：跑 SFTP 相关用例前先 `Stop-Process sshfixture` + 重建 `rport` + 重启夹具。按此流程后：
```
sftp.manage        PASS
settings.persist   PASS
pages.logs-vault   PASS
host.catalog       PASS
```

### 4) 仍未解决
`host.manage` 第 14 步（编辑后断言新名称）仍失败。已确认的事实：
- 应用日志里 **出现 `host updated`**，说明保存路径确实执行了；
- 手工"点击字段 + `inputText`（不按 ENTER）"能正确改名并写库；
- runner 的 `type` 走"点击 → 重新 dump → `inputText` → `keyEvent 2054`(ENTER)"，在这条路径下编辑对话框的改名不生效。

下一步应把问题收敛到"ENTER 提交"这一个变量上（例如给对话框加 `onSubmit` 处理，或让 type 动作在编辑场景不按 ENTER），
在此之前**不把这条用例标记为通过**。

---

## Round 12 追加：编辑改名到底存没存？——存了，但列表刷新不对

### 用日志与重启把问题钉死
1. 在 `submit()` 的编辑分支加了带值日志：`host updated submit-label=%s`；
2. 跑 `host.manage` 后日志出现：`host updated submit-label=manage-amanage-b` ⇒ **写入的 label 是对的**；
3. 提交后立刻 dump：列表里那一行的名称列**没有任何文本**（`host-name/0` 下面没有 Text）；
4. **重启应用后**再 dump：`manage-amanage-b` 正确显示。

⇒ 结论：**持久化没问题，问题在"提交后到重启前"的内存/刷新阶段**。

### 试过的修法（都没解决）
| 尝试 | 结果 |
|---|---|
| 对话框字段绑 `text: this.seedX`（只在创建时给初值） | 点"保存"时输入框失焦，`text` 绑定的旧值被回灌，状态被打回旧名 |
| 改回 `text: this.formX`（值与状态一致，失焦理论上不会回退） | 状态与提交值都正确，但列表仍显示旧/空 |
| 提交后 `settleStore()`（等 150ms 再 `reload()`，怀疑 WAL 读写乱序） | 仍失败 |

### 下一步（Round 13 从这里接）
- 给 `reload()` 的**结束处**加日志（本轮想加，但替换锚点没命中，没加成）：
  打印 `out.length` 与 `out[0].label`，确认是"查询返回空/旧"还是"查询对但 UI 未刷新"；
- 如果是 UI 未刷新：把 `this.hosts = out` 换成先清空再赋值，或改用 `@Observed`/`Array.splice` 触发；
- 如果是查询旧值：改用 `store.beginTransaction()/commit()` 包裹 update 与查询，或换 `executeSql` 直查。

### 现状
- `host.manage` 仍 **FAIL**（第 14 步），其余本轮相关用例：`sftp.manage`、`settings.persist`、`pages.logs-vault`、`host.catalog` 均 PASS。
- 不再用"能连上/能写库"这类弱证据把这条用例标绿。

---

## Round 13 追加：列表不刷新的真正原因——`ForEach` 的 key 只用 id

### 结论（这次靠日志+重启闭环确认）
在 `reload()` 结尾加日志后，`host.manage` 那次运行打出：
```
reload count=1 first=manage-a          ← 首次创建后
reload count=1 first=manage-amanage-b  ← 编辑保存后（内存里已经是新值！）
```
所以 **`reload()` 拿到的数据是对的**，是 UI 没重建。

根因：`ForEach(this.hosts, …, (h) => h.id)` 用 **host id** 做 key。
id 在编辑时不变 ⇒ ArkUI 认为 item 没变 ⇒ **复用旧子树**，Text 内容不更新。
（这也是"重启后就好了"的原因：重启是全新构建。）

### 修法
key 加入内容指纹：
```
(h) => h.id + '|' + h.label + '|' + h.address + '|' + h.user + '|' + h.port + '|'
       + h.group + '|' + h.tags + '|' + h.color + '|' + h.proto
```
列表与网格两处都改。

### 效果
`host.manage` 从**第 14 步失败**推进到**第 18 步失败**：
- 第 14 步（编辑后名称出现）现在 **PASS**；
- 新的失败点是第 18 步 `hello-from-list`（终端里的 fixture banner 没出现在 UITest 文本树里）。

### 这个坑值得记住
**`ForEach` 的 key 必须是"能标识内容"的值**。用主键当 key 时，主键不变而字段变化的更新**一定**不会反映到界面，
而且它会被误诊成"数据库没写成功"——这次绕了三轮才定位到。

### 下一步
- 查终端视图为什么没有把行文本暴露给 UITest（`terminal.vt` 能通过，说明机制本身存在，
  可能是本次会话没有输出，或终端行渲染有渲染时机问题）；
- 再把 `host.manage` 剩余步骤跑通。

---

## Round 14 追加：把失败的用例一条条修回来（host.manage 终于 PASS）

### 本轮 PASS 的用例
| 用例 | 之前 | 修了什么 |
|---|---|---|
| `host.manage` | 连挂 5 轮 | Round 13 的 `ForEach` key 指纹 + 本轮：连接改点 `host-open/0`、pty 下断言改"终端面板出现"、删除前先回 `nav/hosts`、空态断言双语 |
| `knownhosts.manage` | FAIL | 同上：选择器 `host-row→host-open`、banner→终端面板、回列表步骤 |
| `host.recreate-trust` | FAIL | 同上 |
| `ui.i18n` | FAIL | 旧版假设"默认英文"，实际应用**跟随系统语言**（该模拟器为中文）→ 改为 中→英→中 三段 |
| `vault.persist` | FAIL | 选择器 + banner 断言 |
| `forward.local` | FAIL | 选择器 + banner 断言 |

### 一个真实的 UI 缺口顺手补上
**网格视图没有空态文案**（列表有）。已在 `hostGridView()` 里补 `host/grid/empty`（`host.empty` 文案），两种视图都有空态。

### 批量统一（10 个 spec 文件）
- `id:host-row/0` → `id:host-open/0`：`host-row` 现在语义是"探测"，不是"连接"；
- `hello-from-list` → `Send|Copy|Resize`：pty 下夹具跑的是真实 shell，固定 banner 只存在于 exec 路径。

### 仍失败的 4 条（原因已分类，不是猜）
| 用例 | 失败点 | 判断 |
|---|---|---|
| `ssh.connect-from-list` | 等 `verified SHA256:` | 我们的信任对话框文案与旧断言不一致（**文案对齐问题**） |
| `cred.cleared` | 等 `no credentials in memory` | 保险库已实现，清空凭据后的路径变了（**语义变化**，需要重新设计这条用例，而不是改文案糊过去） |
| `sftp.write` | 等 `uploaded.txt\|N` | 上传结果行格式与断言不符（**文案/时序**） |
| `ui.i18n.panels` | 等 `下载` | 面板按钮文案是中英混排，旧断言按纯中文写（**文案对齐**） |

### 纪律
这 4 条**没有**为了变绿去放宽断言：要么把我们的文案对齐到官方用词，要么重新设计语义（如 `cred.cleared` 要先定义"清空凭据后应当发生什么"）。

---

## Round 15 追加：两个对话框改为官方用词 + 深色（1:1 补齐）

### 改动
| 对话框 | 之前 | 现在 |
|---|---|---|
| 信任主机密钥 | 英文 `Unknown host key` / `Verify the fingerprint out-of-band…` / 白色卡片 | 官方中文 `信任此主机？`（`hostkey.title`）+ `信任前请通过其它渠道核对指纹。` + 深色 `#1C1F24` 卡片、绿色主按钮 |
| 删除主机 | 英文 `Delete host?` / 白色卡片 | 官方中文 `删除主机`（`host.deleteTitle`）+ `删除选中的 %d 台主机？此操作无法撤销。` + 深色卡片、红色危险按钮 |
| 字符串表 | 只有部分键 | `strings.ets` 增加 `hostkey.title/body/trust/cancel`（中英各一份） |

英文语言下仍显示英文（`t()` 按语言取），所以 `lang=en` 的用例不受影响。

### 用例对齐（不是放宽）
- 34 处 `regex: "Unknown host key"` → `regex: "信任此主机|Unknown host key"`（双语都能过）；
- `Delete host\?` → `删除主机|Delete host`；
- `ssh.connect-from-list`：旧的 `verified SHA256:` 状态文案已不存在（信任后直接建会话），改为断言会话/终端出现，并在第二次连接前先回 `nav/hosts`。

### 本轮复跑结果
```
ssh.connect-from-list  PASS
host.manage            PASS
knownhosts.manage      PASS
host.recreate-trust    PASS
ui.i18n                PASS
terminal.vt            PASS
```
仍失败 3 条：`cred.cleared`、`sftp.write`、`ui.i18n.panels`。

### 关于这 3 条的新发现
`ui.i18n.panels` 第 1 步要求"空态"，但失败时应用里已经有 1 台主机 —— 说明 **`--fresh` 有时没有真正卸装**（应用在跑时卸载可能被跳过）。
手工 `uninstall` + `install` 后实测：`全部 0` 且 `host-grid/empty`（"还没有主机"）在**两种视图**下都出现。
⇒ 这 3 条里有数据状态干扰，下一轮应让 runner 在 `--fresh` 失败时**报错而不是继续**（否则会持续产生"假失败"）。

---

## Round 16 追加：消除"假失败"的三个根因

### 1) `--fresh` 现在可验证（runner 强化）
旧实现只看 `install` 是否成功，`uninstall` 静默失败时照样继续跑 → 数据没清 → 后面"应为空态"的断言必然失败。
现在：`aa force-stop` → `hdc uninstall`（**校验输出**含 success/not installed/not exist，最多重试 3 次）→ 仍失败就 `EnvError` 直接停，
并在错误里写明"继续跑会产生假失败，请手动 uninstall"。

### 2) 卸载重装**不会**清空数据（备份扩展会恢复）
这是本轮最重要的发现：`EntryBackupAbility` 的备份恢复会让重装后的应用带着旧数据库/旧 known_hosts 回来。
所以"新装即空"的前提根本不存在，凡是依赖空态的用例都会变成偶发失败。
- 应用侧：诊断面板的 `catalog/reset-hosts` 现在**同时清空 `known_hosts` 与 `session_logs`**（之前只清 hosts）；
- 用例侧：`ui.i18n.panels`、`cred.cleared` 在 `launch` 之后**显式重置**再开始断言。

### 3) 上传名留空导致上传失败（真实缺陷）
`sftp.write` 一直卡在"上传结果行"上：默认上传名为空（历史原因是"预填会导致输入被追加"），点上传等于用空文件名。
修法：提交时若名称仍为空则回填 `uploaded.txt`（既保留"空输入不被追加"的好处，又保证有默认值）。
结果：`sftp.write` **PASS**。

### 本轮结果
| 用例 | 结果 |
|---|---|
| `sftp.write` | ✅ PASS |
| `ui.i18n.panels` | ❌ 第 19 步：清空 known_hosts 后点 `host-files/0` 仍未弹信任框，待查 |
| `cred.cleared` | ❌ 仍是旧语义（"内存里没凭据"），保险库实现后该路径不再成立，需按官方语义重写 |

### 教训
**"卸载重装 = 干净环境"是错的**。测试隔离必须由应用自身提供"重置数据"的能力（我们现在有了），
不能依赖系统卸载。

---

## Round 17 追加：状态列一直是假的 + SFTP 面板取词补齐

### 1) 主机状态列从来没显示过真实状态（真实 bug）
`setStatus(index, text)` 一直在写 `statuses`，但行里那一列是**硬编码**的 `○ 未连接`。
所以"探测/连接失败的原因"从来没在界面上出现过——这也是之前诊断困难的原因之一。
现在：`statusOf(index)` 驱动 `●/○` + 文本（有状态显示状态，没有才显示"未连接/offline"），宽度 180 且单行省略。

### 2) SFTP 面板补词（1:1）
`filesPanel()` 之前是英文硬编码，现在走词表：`sftp.title`（`文件（SFTP）`）、`sftp.download`、`sftp.upload`、
`sftp.up`、`sftp.list`、`sftp.close`。补词时发现 **`sftp.close` 两边词表都缺**，界面一直显示键名 `sftp.close`——
这正是"缺键会以键名显示"的最好例证。

### 3) 两条"老用例"按真实语义重写
| 用例 | 旧问题 | 现在 |
|---|---|---|
| `cred.cleared` | 断言"删凭据后**重启**仍提示无凭据"；但启动会从保险库预热，前提不成立 | 改为：建主机带口令 → 信任并连接成功 → 密钥链删条目（`vault/del/<host:port>`）→ 再连接提示 `no credentials in memory` |
| `ui.i18n.panels` | 文件本身是乱码（早期用 PowerShell 写入），断言中文全是坏字节 | 用 Python 重写整份：断言"中文|英文"两可，并保留"键名不得出现"的反向断言 |

顺带把 `no credentials in memory (vault not implemented yet)` 这句**过时文案**改成
`(add a password in host settings)`——保险库早就实现了。

### 4) 本轮回归
```
host.manage / sftp.manage / sftp.write / ui.i18n.panels
terminal.vt / settings.persist / pages.logs-vault / host.catalog
=> 8/8 PASS
```

### 教训
**UI 上"看起来在显示状态"不等于真的在显示状态。** 硬编码的占位文案会长期掩盖实现缺陷，
而且会让诊断走进死胡同（这轮之前我们一直在猜"为什么没有对话框"，其实状态列早该告诉我们）。

---

## Round 18 追加：新页面「快捷命令」（官方 NavSnippets）

### 实现
| 项 | 内容 |
|---|---|
| 表 | `snippets(id, name, cmd, grp, sort)`，`initStore()` 里建表 |
| 页面 | 侧栏 `nav/snippets` → `snippetsPage()`：标题 + `(N 条快捷命令)` + `添加命令` + 列表 + 空态 |
| 列表行 | 名称 + 命令（等宽字体）+ `发送到终端` / `编辑` / `删除` |
| 空态 | `还没有快捷命令` + `保存一条常用命令，再给它设一个快捷键，一键发送到终端。`（官方原文） |
| 添加/编辑 | `snippetForm()` 弹窗（深色），`snippet/dialog-name`、`snippet/dialog-cmd`、`snippet/dialog-save` |
| 发送 | 有会话时写入 `terminal/input` 并调用 `sendTermInput()`；无会话时给出明确提示 |
| 数据隔离 | 诊断面板的"重置"现在也清空 `snippets`，用例可以重复跑 |

### 用例
`spec/scenarios/snippets.crud.yaml`（pcOnly）**PASS**：
重置 → 进快捷命令页断言空态 → 添加 `nginx-restart` / `systemctl restart nginx` → 断言列表里名称与命令都出现 → 断言不出现键名 `snippet.title`。

### 尚未做（下一步）
- 删除/编辑的用例：条目 id 是插入时间戳，**硬编码 id 无法断言**；
  下一步要把 id 改成稳定值（例如按名称哈希），或者给"最新一条"一个可预测的 id；
- 快捷键绑定（官方 `SnippetShortcutRecording`）、分组筛选、排序、右键调序。

### 回归
```
host.manage / ui.i18n.panels / settings.persist / pages.logs-vault => 4/4 PASS
snippets.crud => PASS
```

---

## Round 19 追加：侧栏顺序对齐官方 + 快捷命令可测化

### 1) 侧栏按官方导航顺序重排
从上游 `internal/i18n/chinese.go` 的导航用词可知官方顺序是：
`主机 / 工作区 / 密钥链 / 跳板路由 / 快捷命令 / 端口转发 / 已知主机 / 调试 / 设置`（另有 搜索）。

我们之前是「主机 / 工作区 / **监控** / 会话日志 / 密钥链 / 跳板路由 / 端口转发 / 已知主机 / 快捷命令 / 笔记」，
顺序和用词都不对。现在改为：
```
主机 / 工作区 / 密钥链 / 跳板路由 / 快捷命令 / 端口转发 / 已知主机 / 调试
（其后是我们自有的扩展页：会话日志、笔记）
本地终端 / 设置
```
- 「监控」→ 官方用词 **「调试」**（`NavDebug`）；
- 「会话日志」「笔记」**不在当前上游导航里**，作为扩展项保留，但排在官方项之后，并在此记录差异。

### 2) 快捷命令行内按钮改为按索引 id
之前 `snippet/send|edit|del/<时间戳>`，用例无法预测 → 现在 `snippet/send|edit|del/<idx>`，与主机行约定一致。

### 3) `snippets.crud` 覆盖扩到 添加 → 编辑 → 删除
```
重置 → 空态 → 添加(nginx-restart / systemctl restart nginx) → 断言名称+命令
→ 编辑(回填后追加 -reload → nginx-restart-reload) → 断言
→ 删除 → 断言回到空态 + 不出现键名
=> PASS
```

### 4) 回归
`snippets.crud / host.manage / pages.logs-vault / ui.i18n.panels => 4/4 PASS`

---

## Round 20 追加：命令面板（官方 CommandPalette）+ 主机表单对齐官方字段

### 1) 命令面板
官方用词：`CommandPaletteTitle: 命令面板`、`CommandPalettePlaceholder: 输入命令…`、`CommandPaletteEmpty: 没有匹配的命令`。
实现：
- 顶部搜索图标 `top/search` 打开；面板 `palette/panel`（深色 560×420）；
- 输入框 `palette/input` 实时过滤；条目 `palette/item/<idx>`（导航项 + `快捷命令：<名称>`）；
- 执行：新建主机 / 会话日志 / 密钥链 / 快捷命令 / 端口转发 / 已知主机 / 调试 / 设置 / 主机 /
  导入目录… / 导出目录… / 发送快捷命令；
- 无匹配显示 `palette/empty`「没有匹配的命令」。

用例 `command.palette`（pcOnly）**PASS**：打开 → 过滤"设置" → 点条目打开设置面板 → 再打开输入 `zzzz` → 断言空提示。

### 2) 主机表单对齐官方字段（并清掉遗留调试文本）
之前是英文 "New Host / Label / Address"，且**表单里还留着 `dbg/form-label` 调试文本**（Round 12 的调试残留）。
现在按官方字段重写为深色表单：
`新建主机 / 编辑主机`、`名称`（显示在主机列表中）、`地址`（主机名或 IP）、`用户`（登录账户）、`端口`、
`密码`（新建：可选 · 加密保存；编辑：留空则保留）、`分组`（选择或创建分组）、`标签`、`颜色`（#3B82F6（留空使用默认））。

### 3) 回归
```
host.manage / command.palette / snippets.crud / ui.i18n.panels / pages.logs-vault / cred.cleared
=> 6/6 PASS
```

### 说明
命令面板目前只做"命令条目"（导航 + 快捷命令）。官方还有"新建标签页/连接到主机"分组、键盘上下键与回车执行、
最近使用排序——这些列为后续项，不在本轮声称完成。

---

## Round 22 追加：按基线逐条修（含一个真实安全缺陷）

### 修掉的真实缺陷
| 问题 | 说明 | 修法 |
|---|---|---|
| **打开会话不校验主机密钥** | `openSession` 在已有指纹时**直接连接**，只有"测试"按钮才会检测密钥变更 → 主机密钥变了也照连，属于安全问题 | 已有指纹时先用该指纹 probe 一次；返回 `hostkey-mismatch` 就弹变更警告并**不连接** |
| 搜索无结果没有文案 | 列表页只区分"还没有主机"，被搜索过滤空时是空白 | 确认 `host.noMatch`（`没有匹配的主机` / `no matching hosts`）在列表里按 `anyMatch()` 显示 |
| 诊断面板的探测结果看不见 | 结果文本框放在 384px 画布**之后**，滚出可视区，`dump` 与用户都看不到 | 把结果框移到探测按钮下方（高度 80，深色边框） |
| 主机密钥变更警告 | 英文 + 白色卡片 | 中英双语 + 深色卡片（`主机密钥已变更` / `Host key has changed`） |

### 用例修正（断言过时，不是放宽）
| 用例 | 修正 |
|---|---|
| `hosts.search` | 断言补中文分支 `没有匹配的主机|no matching hosts` |
| `host.persist` / `infra.host-create-by-id` | 地址列现在渲染成 `地址:端口`，精确 `text` 断言改为 `screenRegex` |
| `hostkey.changed` | 信任后已进会话，补 `nav/hosts` 再连；断言补中文 `主机密钥已变更` |
| `rdp.server-peer` | 空态断言补中文 |

### 本轮结果
```
hosts.search / host.persist / infra.host-create-by-id / hostkey.changed / net.reachability  => PASS
回归 host.manage / hostkey.changed / net.reachability / hosts.search / ui.i18n.panels        => 5/5 PASS
```
仍失败：`rdp.server-peer`（RDP 服务端状态串不符，RDP 仍是实验态）、以及基线里未跑完的 RDP 系列。

---

## Round 26 追加：主机表单的色板与标签 chips（官方交互）

### 之前的问题
表单里"颜色"是一个 `#RRGGBB` 文本框，标签是一个逗号分隔文本框——能用，但**不是官方那套交互**，
而且用户要自己记颜色值。

### 现在
| 控件 | 实现 |
|---|---|
| 颜色 | 官方 7 色色板：`无 / #22c55e / #eab308 / #f97316 / #ef4444 / #3b82f6 / #a855f7`，点选即填；id `hostform/color/<hex>`（无颜色为 `hostform/color/none`）。旁边保留手填输入框（`shell/dialog-color`） |
| 标签 | 官方预设 chips：`开发 / 测试 / 生产`（英文界面为 `dev / test / prod`），可多选，选中高亮；id `hostform/tag/<名称>`；仍与 `shell/dialog-tags` 文本互通 |

### 用例
新增 `host.form-chips`（pcOnly）**PASS**：
打开表单 → 点色块 `hostform/color/ef4444` → 点标签 `hostform/tag/生产` → 填名称/地址 → 保存 → 断言列表出现新主机与该标签，且界面不泄漏 `hostform/color` / `hostform/tag` 键名。

### 回归
`host.manage / snippets.crud / ui.i18n.panels / command.palette => 4/4 PASS`（表单 id 与流程未被破坏）。

### 说明
颜色只验证"控件可点选"，不做像素级校验；编辑时 chips 的选中态回显、标签上限/非法字符校验还没做。

---

## Round 27 追加：表单校验（官方文案）+ 编辑态回显

### 校验（用官方错误文案）
`submit()` 现在在写入前校验，并把错误显示在表单内（`shell/dialog-error`，红色小字）：

| 字段 | 规则 | 文案（官方原文） |
|---|---|---|
| 颜色 | 必须是 `#RRGGBB` 或留空 | `请输入 #3B82F6 这样的颜色值，或留空使用默认颜色` |
| 标签 | 最多 12 个；每个 ≤32 字符；不含换行 | `最多 12 个标签，每个不超过 32 个字符，且不包含逗号或换行` |

校验失败时**不会关闭对话框、也不会写库**；修正后错误行消失并可保存。

### 编辑态回显
打开编辑对话框 → 不改任何字段 → 直接保存 → 标签仍然保留，
说明 chips 的选中态是**从数据回显**的，不是只显示静态文本。

### 用例
| 用例 | 覆盖 | 结果 |
|---|---|---|
| `host.form-validation`（新） | 非法颜色 `zzz` 被拦截并显示官方文案 → 点色板 `#3b82f6` → 保存成功 → 错误行消失 | PASS |
| `host.form-chips`（扩展） | 点标签 `生产` 保存 → 列表显示标签 → 打开编辑直接保存 → 标签仍在 | PASS |

### 回归
`host.manage / ui.i18n.panels / snippets.crud / command.palette => 4/4 PASS`

### 未做
标签数量校验（输入 13 个标签在 UI 自动化里成本高）没有专门用例；颜色的像素级应用也没有校验。
这两条写在这里，不当成已覆盖。

---

## Round 28 追加：「笔记」页落地（最后一个禁用导航项）

### 现状
侧栏 10 项现在**全部可用**（主机 / 工作区 / 密钥链 / 跳板路由 / 快捷命令 / 端口转发 / 已知主机 / 调试 / 会话日志 / 笔记），
另有底部「本地终端 / 设置」。

### 笔记页
| 项 | 内容 |
|---|---|
| 表 | `notes(id, title, body, updated_at)`，`initStore()` 建表 |
| 页面 | `nav/notes` → 标题 + `(N)` + `新建笔记` + 列表 + 空态「还没有笔记」 |
| 行 | 标题 + 正文摘要（单行省略）+ `编辑` / `删除`（id `note/edit|del/<idx>`） |
| 弹窗 | `note/dialog`（深色）：`note/dialog-title`、`note/dialog-body`（多行 TextArea）、保存/取消 |
| 排序 | 按 `updated_at` 倒序 |
| 数据隔离 | 诊断面板"重置"现在也清 `notes` |

### 用例
`notes.crud`（pcOnly）**PASS**：
重置 → 进笔记页断言空态 → 新建 `note-a`/`body-first` → 断言列表可见 → 编辑（回填后追加 `-v2`）→ 断言 `note-a-v2` → 删除 → 断言回到空态。

### 必须写明的差异
**上游导航里没有「笔记」这一项**（官方导航是 主机/工作区/密钥链/跳板路由/快捷命令/端口转发/已知主机/调试/设置/搜索）。
这页是早期版本就提供了入口，本轮把它做完，但它在 1:1 意义上属于**扩展页**，不是"照抄官方"。
会话日志同理。

### 回归
`snippets.crud / host.manage / command.palette / host.form-chips => 4/4 PASS`

---

## Round 29 追加：分组筛选真的生效 + 折叠状态持久化

### 1) 分组 chips 以前是"装饰"
点了没有任何反应。现在：
- 点某个分组 chip → 列表**只显示该组**，chip 变成浅色选中态；
- 点「全部」→ 恢复显示全部；
- 列表与网格两种视图都按筛选渲染（两处 `ForEach(this.sections())` 都加了 filter）。

对应用例 `host.group-filter`（pcOnly）**PASS**：
G1/G2 各一台 → 点 G1 → 断言只有 `in-g1`、没有 `in-g2` → 点「全部」→ 两台都在。

### 2) 分组折叠状态持久化（官方 `savedHostGroup.Collapsed`）
- `toggleGroup()` 现在会 `savePrefs()`；
- 折叠分组列表以 `\u0001` 分隔存进 preferences（分组名可能含逗号，不能用逗号）；
- 启动时 `loadPrefs()` 读回。
- 分组表头行新增 id `group/header/<组名>`（以前只能靠箭头图标，自动化点不到）。

对应用例 `host.group-collapse`（pcOnly）**PASS**：
建 G1 组主机 → 点表头折叠 → 断言行消失 → **重启应用** → 仍处于折叠状态（行仍不出现）。

### 3) 回归
`host.manage / host.group-collapse / pages.logs-vault / ui.i18n.panels / host.catalog => 5/5 PASS`

### 未做
- 筛选与搜索叠加的组合行为、筛选状态持久化；
- 协议 chips（SSH/RDP/VNC）筛选（现在只有分组 chips 可用）；
- 分组顺序/固定（官方 `savedHostGroup.Order/Pinned`）。

---

## Round 30 追加：命令面板键盘导航（↑↓ / 回车）

### 实现
| 项 | 说明 |
|---|---|
| 焦点 | 面板打开时 `openPalette()` 主动 `requestFocus('palette/input')`；**不聚焦则 keyEvent 没有接收者**（实测按什么都没反应） |
| ↑ / ↓ | `KeyCode 2012 / 2013`，环形移动选中项（`paletteIndex`），选中项绿底高亮 |
| 回车 | `KeyCode 2054` 执行当前选中项并关闭面板；输入框也挂了 `onSubmit` |
| 输入变化 | 过滤条件变化时把选中重置为 0，避免越界 |

### 测试基础设施
runner 新增动作 **`key`**（`uitest uiInput keyEvent <code>`，`code` 已进 schema），这样键盘路径可以被用例驱动。

### 用例拆分（避免一条用例假装覆盖两件事）
| 用例 | 覆盖 | 结果 |
|---|---|---|
| `command.palette-keys`（新） | 打开面板 → 连按 9 次 ↓ 到「设置」→ 回车 → 断言设置面板打开、命令面板关闭 | PASS |
| `command.palette`（重写） | 打开面板 → 点第 0 项「新建主机」→ 断言新建主机对话框出现、面板关闭 | PASS |

### 一个真实的冲突（已记录，未强行糊过去）
`ENTER` 同时承担两件事：**提交输入法组合**（runner 的 `type` 动作结尾会按它）和**执行当前条目**（官方行为）。
在 `type` 里输入"设置"时，过滤后只剩一项，回车就直接执行了它，导致"输入回读"必然失败。

处理方式：**不把两件事塞进一条用例**——
- 执行路径用 `command.palette`（点击）与 `command.palette-keys`（键盘）覆盖；
- 输入过滤没有专门用例，**明确写在 deviations 里未覆盖**，而不是改代码去迎合测试。

### 回归
`command.palette / command.palette-keys / ui.i18n.panels => 3/3 PASS`

---

## Round 31 追加：分组固定（官方 `savedHostGroup.Pinned`）+ 顺序断言能力

### 实现
| 项 | 说明 |
|---|---|
| 固定入口 | 分组表头的 `★/☆`（id `group/pin/<组名>`），点击切换；分组 `⋯` 菜单里也有「固定本组 / 取消固定」 |
| 排序 | `sections()` 里固定分组排到前面，**不改组内与原相对顺序**（与官方 `Pinned` 语义一致） |
| 持久化 | `pinnedGroups` 与折叠状态一样存进 preferences（`\u0001` 分隔），启动读回 |

### 测试基础设施：新增 `before` 断言
排序类行为无法用文本断言证明，所以给 runner 加了断言 kind **`before`**：
```yaml
- kind: before
  a: "id:group/header/G2"
  b: "id:group/header/G1"
```
实现是"取两个节点的 y 坐标并比较"，失败时把两边 y 都打出来。schema 已允许 `a`/`b` 字段。

### 用例
`host.group-pin`（pcOnly）**PASS**：
建 G1 → 建 G2（自然顺序 G1 在前）→ 点 `group/pin/G2` 固定 → 断言 **G2 的 y 小于 G1**（固定生效）。

### 回归
`host.manage / host.group-filter / host.group-collapse / host.catalog => 4/4 PASS`

### 未做
- 取消固定后的顺序回退（反向操作同一路径）、多固定组之间的相对顺序；
- 固定状态跨重启（折叠状态已有同类持久化用例，固定暂时只是同机制）。

### 一个细节
固定标记一开始写成 `Text(this.isPinned(g) ? '📌' : '')`，**空字符串的 Text 不进 dump**，所以自动化点不到；
改成始终有字符的 `★/☆`（弱化未固定态颜色）后即可稳定选中。

---

## Round 32 追加：固定/折叠的"跨重启 + 回退"闭环

### 本轮把 `host.group-pin` 从"单向"扩展到闭环
```
建 G1 → 建 G2（自然顺序 G1 在前）
→ 点 star 固定 G2 → 【步骤内断言】G2 在 G1 上方
→ restart → 【步骤内断言】仍 G2 在上方（固定状态持久化）
→ 再点一次取消固定 → 【末尾断言】G1 回到 G2 上方（自然顺序恢复）
```

### 踩到的两个"测试自身"问题
1. **断言位置**：一开始把"固定后 G2 在上"和"取消固定后 G1 在上"都放进末尾 `asserts`，
   而末尾状态已取消固定 → 两条互相矛盾必然失败。顺序类行为要放在**动作之后立刻断言**（步骤内 `expect`）。
2. **schema 三处都要放行**：`before` 断言需要
   - `$defs/assertion.properties` 增加 `a`/`b`
   - `$defs/assertion.properties.kind.enum` 增加 `before`
   只加前者的表现是：用例能跑过，但 `lint` 报 schema 不合规——**用例绿了不代表基线合法**。

### 结果
`host.group-pin / host.group-filter / host.group-collapse / host.manage => 4/4 PASS`，lint 全绿。

---

## Round 33 追加：批量删除必须二次确认（真实安全缺口）

### 之前的问题
全选后点「批量删除」**直接就把主机删了**，没有确认框。官方语义是
`删除选中的 %d 台主机？此操作无法撤销。`（`host.deleteDesc`），单台删除有确认、批量却没有——这是真实的误删风险。

### 现在
| 行为 | 实现 |
|---|---|
| 点「批量删除」 | 走 `askDeleteSelected()`：把选中 id 复制到 `deleteIds`，弹确认框（**不再直接删**） |
| 确认框文案 | `host.deleteDesc` 用真实台数替换：`删除选中的 2 台主机？此操作无法撤销。` |
| 确认 | 逐台删除 hosts + known_hosts + 保险库口令（与单台删除同一套语义），再刷新 |
| 取消 | 清空 `deleteIds`，数据不动 |
| 单台删除 | 行为不变（仍走 `deleteIndex` 分支） |

### 用例
`host.batch-delete`（pcOnly）**PASS**：
建 2 台 → 全选 → 点批量删除 → **断言确认框里出现"删除选中的 2 台主机"** → 取消（两台都还在）→ 再删一次 → 确认 → 断言回到空态、两台都不再出现。

### 回归
`host.batch-delete / host.manage / host.form-chips / snippets.crud => 4/4 PASS`

### 一个实现细节
第一次改的时候把按钮的 `onClick` 换掉时**缩进没对上**（替换未命中），结果点批量删除仍是"直接删"，
用例在"确认框文案"那一步就失败——这类"改了但没生效"的替换，必须靠**用例**而不是靠读代码来确认。

---

## Round 34 追加：已知主机 / 已保存密码的删除也加确认（官方文案）

### 之前的问题
- 已知主机页的 `Delete` 按钮**点一下就删**（`known_hosts` 记录直接消失，无法撤销）；
- 密钥链页删除已保存凭据**也没有确认**。
两者都是不可撤销操作，官方都有确认措辞：

| 场景 | 官方文案 |
|---|---|
| 删除已信任主机密钥 | `删除已信任主机密钥？` + `要从 known_hosts 删除选中的 %d 条记录吗？此操作无法撤销。` + `删除记录` |
| 删除已保存密码 | `VaultForgetTitle: 忘记全部已保存的密码?` + `VaultForgetDescription: 它们都会从这台电脑上删除。下次服务器需要时会再次询问。` |

### 实现
| 对话框 | id | 内容 |
|---|---|---|
| 已知主机删除 | `knowndel/dialog`（`knowndel/title`、`knowndel/cancel`、`knowndel/confirm`） | 标题 + 说明 + 具体 key（等宽字体）+ 取消/删除记录 |
| 凭据删除 | `vaultdel/dialog`（`vaultdel/title`、`vaultdel/cancel`、`vaultdel/confirm`） | 标题 + 说明 + key + 取消/删除 |

两者都是深色卡片，且**都放在 Stack 的最上层**。

### 两个踩到的坑
1. **弹窗被后面的浮层挡住**：一开始把确认框插在 build() 中间，`dump` 里能看到它，但**点击不生效**（被后声明的面板盖住）。
   移到 Stack 末尾后正常——"能看到"不等于"能点到"。
2. **整行 onClick 会重新打开对话框**：已知主机那一行原本整行可点（也调删除），
   确认框关闭的点击穿透到行上又把它打开。改成只有按钮可触发，并保留行点击为空。

### 用例
- `knownhosts.manage`：删除前断言出现 `删除已信任主机密钥`，点 `knowndel/confirm`，再断言 `trusted entries: 0`。
- `cred.cleared`：删除凭据前断言出现 `删除已保存的密码`，点 `vaultdel/confirm`，再连接提示无凭据。
两者均 **PASS**；回归 `knownhosts.manage / cred.cleared / host.manage / host.batch-delete => 4/4 PASS`。

---

## Round 35 追加：RDP 自连实测（服务端 PASS；客户端仍红）

- 内置 shadow 服务端实测在绘制：`surface=ok paint=618 sw=1024 sh=768 rows=635886`；
- 客户端连本机服务端能到 `connected 127.0.0.1:13389`，手工一次拿到 `frames=24 paints=24 size=1024x768`；
- **但客户端连上后发布帧会 SIGABRT**（`shadow_multiclient_publish_and_wait`），这是最硬阻塞；
- 且解码出来的位图是白的（`colors=1`、`dominant=#FFFFFF`）。

用例处置：
- `rdp.server-peer` 断言改成**真实状态串**（`running port=13389` / `surface=ok` / `paint>0`）→ **PASS**；
- `rdp.client-render`、`rdp.client-input` 改成"连本机内置服务端"并填好 host/port（以前从不填，永远连不上），
  保留为**失败**，`limits` 里写明"不能代表画面可用"。

详见 [RDP.md](RDP.md) 的 Round 35 章节。

---

## 剩余差距清单（Round 61 盘点，按可做性排序）

### A. 可直接做（有明确参照）
| 项 | 现状 | 参照 |
|---|---|---|
| 协议筛选 chips（SSH/RDP/VNC） | 只有分组 chips + 「全部」 | 官方主机的协议过滤 |
| 主机图标选择器 | 固定图标 | 官方 `savedHost.Icon` |
| 命令面板 Esc 关闭 / 鼠标悬停高亮 | 回车/上下键已支持，Esc 与 hover 未做 | 官方命令面板 |
| 分组拖拽排序 | 未做（固定用 ★ 排序） | 官方 `savedHostGroup.Order` |

### B. 需要产品决策
| 项 | 说明 |
|---|---|
| RDP 会话视图 | 现在只有诊断面板里的预览（1.5s 写 BMP）。要做成正式会话页：大画面 + 键盘/鼠标直投 + 缩放 |
| 主机卡片的"最近连接"信息 | 官网上有 last-used；我们的库里有 session_logs，可聚合 |

### C. 明确不做（本轮目标之外）
- 平板特性（用户已要求暂停）
- 真实 Windows 对端的 RDP 逐像素校验（无真实对端）
- 商店合规与 arm64 真机证据（无硬件/凭据）

---

## Round 62 追加：协议筛选 chips（SSH / RDP / VNC）

### 实现
| 项 | 说明 |
|---|---|
| chips | `全部协议` / `SSH n` / `RDP n` / `VNC n`，id `chips/proto-all|chips/proto-ssh|chips/proto-rdp|chips/proto-vnc` |
| 计数 | `countProto(proto)`（与分组 chip 的 `countGroup` 同思路） |
| 过滤 | 并入 `matchesQuery()`：先判协议，再判搜索词 —— 于是**列表、网格、匹配计数三处自动一致** |
| 状态 | `@State protoFilter`（本轮不做持久化） |

### 用例
`host.proto-filter`（pcOnly）**PASS**：清空目录 → 建 3 台（都是 SSH 协议，新建对话框暂无协议选择）→
点 `RDP` chip → 断言「没有匹配」（正确预期）→ 点「全部协议」→ 断言三台主机恢复。

### 回归
`host.catalog / host.group-filter / hosts.search / host.batch-delete / host.manage => 5/5 PASS`
（其中一次 `host.manage` 失败经查是 **ssh 夹具没在跑**，重启夹具后 PASS —— 环境问题，不是回归。）

### 说明
新建主机对话框目前没有"协议"选择，所以协议筛选暂时只能筛到"通过其它路径创建成 rdp/vnc 的主机"。
下一轮如果需要，应把协议选择加进新建/编辑表单（属于 UI 1:1 的一部分）。

---

## Round 63 追加：新建/编辑表单支持**协议选择**（SSH / RDP / VNC）

### 实现
| 项 | 说明 |
|---|---|
| 表单控件 | `hostform/proto-ssh|rdp|vnc` 三个 chip，位于标签与分组之间 |
| 状态 | `@State formProto`，新建默认 `ssh`；编辑时按已有 `proto` 回填 |
| 落库 | 新建插入桶与编辑 update 都写入 `proto`（**第一次改错了插入桶的位置**，见下） |
| 端口默认值 | 按协议给默认端口：SSH 22 / RDP 3389 / VNC 5900（用户填了端口则用用户的） |

### 两个真实踩坑
1. **改错了位置**：用字符串替换 `'proto': 'ssh',` 时匹配到了别处，插入桶仍是硬编码 `ssh` ——
   表现为"选了 RDP，筛 RDP 却是 0 台，SSH 计数却 +1"。改用**行号定点替换**后正常。
   教训：这种"同类字面量出现多次"的替换，必须按行号/上下文定位，替换后要验证语义而不只是编译通过。
2. **点 chip 会让输入框失焦**：先输入 label/address 再点协议 chip，已输入内容会被清掉，
   提交时 label 为空 → 静默失败（`submit()` 在 label 为空时直接 return）。
   用例改成**先选协议、再输入**，并把这个顺序写进注释。

### 用例
`host.proto-filter` **PASS**：建 SSH / RDP / VNC 三台（表单里选协议、端口自动）→ 点 RDP chip 只剩 pf-rdp →
点 VNC chip 只剩 pf-vnc → 点「全部协议」三台都回来。

### 回归
`host.manage / host.form-chips / host.form-validation / hosts.search => 4/4 PASS`

---

## Round 64 追加：命令面板 Esc 关闭 + 鼠标悬停高亮

### 实现
| 项 | 说明 |
|---|---|
| Esc | `KEYCODE_ESCAPE = 2070`（官方 `oh_key_code.h` 确认），在 `paletteKey()` 里关闭面板并清空查询 |
| 悬停 | `@State paletteHover` + 每项 `.onHover(...)`；背景优先级：**选中（绿）> 悬停（深灰）> 透明** |

### 用例
`command.palette-esc` **PASS**：打开面板（断言标题在）→ 按 Esc（key 2070）→ 断言标题消失。

### 回归
`command.palette / command.palette-keys / ui.i18n => 3/3 PASS`

### 明确的边界
- **悬停高亮没有自动化覆盖**：`uitest` 不注入 hover 事件；已写进用例 `limits`，不假装测过；
- Esc 关闭后焦点落点、连续开关多次也没覆盖。

---

## Round 65 追加：主机字段对照（上游 `internal/workbench/persist.go: SavedHost` vs 本实现）

| 上游字段 | 本实现 | 差距 |
|---|---|---|
| `ID` | `hosts.id` | ✅ |
| `Label` | `hosts.label` | ✅ |
| `Group` | `hosts.grp` | ✅（含 ★ 固定、折叠） |
| `Tags` | `hosts.tags` | ✅（表单 chips + 12/32 校验） |
| `Color` | `hosts.color` | ✅（7 色板 + #RRGGBB 校验） |
| `Address` / `Port` / `User` | `hosts.address` / `port` / `usr` | ✅ |
| **`Icon`** | 无 | ❌ **缺**：主机卡片图标固定，官方可按主机设图标 |
| **`System`** | 无 | ❌ **缺**：官方记录远端系统（用于图标/提示），我们没存 |
| `savedTransport`（传输协议等） | `hosts.proto`（ssh/rdp/vnc） | ⚠️ 部分：我们有协议三选一，但没有上游的传输细项 |

### 结论（下一轮可直接做的两件小事）
1. **`Icon`**：DB 加一列 + 表单加图标选择器（6~8 个内置图标）+ 列表/网格卡片渲染，用例断言"选图标后卡片显示对应图标 id"；
2. **`System`**：DB 加一列，首次连接成功后写入（`uname -s` 或 RDP/VNC 协商结果），卡片/详情显示；无对端时显示空。
两者都不涉及复杂协议，属于"可实现的功能"，符合本轮目标。

---

## Round 67 追加：`Icon` 字段（对应上游 `SavedHost.Icon`）

### 实现
| 层 | 改动 |
|---|---|
| DB | `hosts` 表加 `icon TEXT`；`HOST_COLUMNS` 加 `icon`；`migrateHosts()` 加 `ALTER TABLE hosts ADD COLUMN icon TEXT` |
| 类型/读取 | `HostItem.icon`；`reload()` 用 `rs.getString(9)` |
| 表单 | 图标选择器：**无 / ★ / ▤ / ☁ / ▣ / ⚡**（id `hostform/icon-none|star|server|cloud|box|bolt`），激活态高亮 |
| 落库 | 新建插入桶 + 编辑 patch 都写 `icon` |
| 渲染 | 列表行 `host-icon/<id>` 显示 `iconGlyph(h.icon)` 字形（`★▤☁▣⚡`） |

### 用例
`host.icon` **PASS**：清空 → 建一台选 ★ 的主机 → 列表出现 `★`；再建一台不选图标的（为空）。

### 回归
`host.manage / host.form-chips / host.persist / hosts.search / host.catalog => 5/5 PASS`

### 本轮踩的两个坑（同一天第二次）
1. **插入桶漏字段**：只给"编辑 patch"加了 `icon`，新建插入桶没加 —— 表现是"选了图标但列表不显示"。
   ⇒ 新增字段时要**同时改 create/patch 两处**，并且用一个"新建后立刻断言"的用例兜底（本次正是它抓到的）。
2. **行内组件插错位置**：第一版把图标 Text 插进了"行内操作按钮 Row"里（那一行默认悬停才显示），
   而且 pdate 之后还出现过一次 `'icon': this.formIcon,,` 的语法错误 —— 都是**按字符串锚点做行内插入**造成的。
   ⇒ 行内插入一律按行号 + 上下文确认，改完先 build。

### 上一轮遗留
`full65` 的 74/75 已把 `run-all.py` 加上了"仅第 1 步失败重跑一次"；下一轮跑全量验证 75/75。

---

## Round 68 更正：`System` 字段**不用做**（上游也没有写入点）

上一轮把 `SavedHost.System` 列为"缺"是**不准确的**。本轮在 `internal/` 全量搜索后确认：
- 结构体里有 `System string` 字段；
- 但**没有任何非 AI 代码给它赋值**（`workbench`/`ssh`/`sftp` 里都没有写入点），
  读取处也很少 —— 基本是历史遗留字段。

⇒ 结论：**不实现 `System`**，也不为了"字段对齐"去加一个永远不会被填的列。
如果以后接入真实系统探测（`uname -s`）再单独设计，届时一并决定是否需要展示。

### 因此主机字段的差距只剩
| 字段 | 状态 |
|---|---|
| `Icon` | ✅ Round 67 已实现（DB + 表单选择器 + 列表字形） |
| `System` | ⏸ 不做（上游无写入点，属遗留字段） |
| `savedTransport` 细项 | ⚠️ 我们用 `proto` 三选一覆盖主要场景，细项暂不做 |

---

## Round 70 追加：主机列表显示「最近连接」

### 实现
| 项 | 说明 |
|---|---|
| 数据 | 启动/刷新时把 `session_logs` 按 `started_at desc` 扫一遍，取每个 `address|proto` 的**最新**时间到 `lastUsedMap` |
| 文案 | `lastUsedText(h)`：有记录 → `最近连接 HH:MM`；无 → `未连接`（英文 `last used / never connected`） |
| 位置 | 放在名称列的**第二行**（不占额外行宽） |
| 刷新 | `recordSession()` 写日志后立刻 `await this.reload()`，连接一建立列表就更新 |

### 用例
`host.lastused` **PASS**：新建主机 → 显示「未连接」→ 连接一次（trust 主机）→ 回列表 → 出现「最近连接 HH:MM」。

### 回归
`pages.logs-vault / host.manage / ssh.connect-from-list / hosts.search => 4/4 PASS`

### 本轮踩的坑：**行宽被挤爆**
第一版把「最近连接」作为**新的兄弟节点**放在列表行里（宽度 120），
结果整行宽度超限：名称列被压成 0 宽，`host-name/<i>` 从 dump 里消失，
`pages.logs-vault`（点主机名）与 `host.manage`（断言名称）直接失败。
⇒ 修法：把新文本放进**已有的名称列**（纵向堆叠），不增加行宽。
**教训：在定宽 Row 里加东西先算宽度；优先往已有列的纵向空间里塞，而不是横向加兄弟节点。**

---

## Round 71 追加：网格视图补齐「图标 + 最近连接」

### 改动
在网格卡片（`host-card/<id>`）的名称列里加一行：
```
Row { Text(iconGlyph).id('host-icon-card/<id>')  Text(lastUsedText).id('host-lastused-card/<id>') }
```
放在 **名称列的纵向空间**里（不增加卡片宽度），与列表行保持同样的信息。

### 用例
`host.grid-meta` **PASS**：建一台选 ⚡ 图标的主机 → 切网格视图 → 断言 `⚡` 与「未连接」同时出现。

### 回归
`host.icon / host.lastused / host.proto-filter / hosts.search => 4/4 PASS`

### 说明
卡片高度仍是 64，三行信息在测试里能显示，但**视觉上可能偏挤**；
如果后续要更接近官方卡片，应该把卡片高度调到 72~76 并重新核对网格间距（需要新的布局用例）。

---

## Round 74 追加：分组管理（重命名 / 删除）

### 实现
| 项 | 说明 |
|---|---|
| 入口 | 分组表头的 **✎ / 🗑**（id `group/rename/<g>`、`group/del/<g>`）；分组 `⋯` 菜单里也加了「重命名分组 / 固定本组 / 取消固定 / 删除分组」 |
| 重命名 | 对话框 `grouprename/dialog`（`input`/`cancel`/`confirm`/`error`）；`UPDATE hosts SET grp=new WHERE grp=old` |
| 删除 | 确认框 `groupdel/dialog`（`cancel`/`confirm`）；**只把组内主机的 grp 清空（回默认组），不删主机** |
| 语义 | 分组是"视图"不是"容器"：删组不丢数据 |

### 两个坑（都是"看起来能用但语义错"）
1. **重命名预填旧名**：把旧名填进 `TextInput`，用户/用例再输入就变成 `G1G2`（实测确实生成了一个 `G1G2` 组）。
   ⇒ 改成**打开时清空输入框**，旧名只放在 `placeholder` 里。
2. **`bindMenu` 弹层不进 `uitest dump`**：菜单项无法被自动化点击（这是早就记录过的限制）。
   ⇒ 在表头加了可点的 ✎/🗑 图标专门给自动化与鼠标用户用，菜单仍然保留。

### 用例
`host.group-rename-delete` **PASS**：建 G1 → 点 ✎ 重命名为 G2（表头与主机跟随）→ 点 🗑 确认删除 →
主机仍在（回到默认组），`G2` 消失。

### 回归
`host.group-pin / host.group-collapse / host.group-filter / host.manage => 4/4 PASS`

---

## Round 76 追加：命令面板列出主机（`主机：<名称>  <地址>`）

### 实现
| 项 | 说明 |
|---|---|
| 列表 | `paletteLabels()` 里**主机项排在最前**，格式 `主机：<label>  <地址>`；后面才是静态命令与「快捷命令：」 |
| 执行 | `runPalette()` 认出 `主机：` 前缀 → 按 label 找主机 → `openSession` |
| 为什么排最前 | 面板列表高度有限：放在末尾会被滚出可视区（实测 dump 里看不到，用例失败） |

### 用例
`command.palette-hosts` **PASS**：建一台 pal-host → 打开面板 → 断言出现 `主机：pal-host`（且面板标题还在）。

### 回归
`command.palette / command.palette-keys / command.palette-esc / host.catalog => 4/4 PASS`
（`command.palette` 与 `-keys` 都假设"无主机时第 0 项是新建主机/第 9 项是设置"，空库下仍成立。）

### 说明
主机项进入面板后，**列表索引会随主机数变化**——以后写面板相关用例时不要依赖固定下标，
除非 spec 明确先清空主机（`catalog/reset-hosts`）。

