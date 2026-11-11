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
