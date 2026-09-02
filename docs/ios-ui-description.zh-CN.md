# Warren iOS UI 说明与查找索引

本文是 Warren iOS 原生界面的源码索引。它描述“用户看到什么、由哪个
SwiftUI/UIKit 组件负责、状态从哪里来”，用于提交 UI 问题和指导 agent 定位。
行号以当前 checkout 为准；源码移动后，应优先用 `rg "组件名" Packages/WarrenIOS/Sources/WarrenIOS`
重新定位。

## 1. 页面层级

```text
IOSRootView
└─ HostDashboardView（首页）
   ├─ 项目 → Workspace → Session
   ├─ Active Agent Sessions
   ├─ Terminal groups
   └─ IOSHostFooter（当前 Host、重连、设置）
      └─ IOSEndpointConfigurationView（Host 管理）

SessionView（某个 Session）
├─ SessionHeader + SessionTabRail
├─ Terminal 或 AgentChatView（二选一，表面保持挂载）
└─ TerminalShortcutBar（仅 Terminal 模式）
```

导航路由定义在 `IOSRootView.swift:9-13` 的 `IOSRoute`。`IOSRootView` 在
`27-107` 建立 `NavigationStack`，`IOSApplicationModel.currentSessionID` 变化时
同步路由；删除当前 Session 后由 model 提供回退到 Workspace/Terminal group 的一次性目标。

## 2. 文件与责任总表

| 文件 | 负责的 UI / UI 状态 |
| --- | --- |
| `IOSRootView.swift` | 首页项目树、Workspace/Group 列表、Session 列表、Host 底栏、Host/Workspace/Session 管理 Sheet |
| `IOSSessionView.swift` | Session 顶栏、同级 Session 标签/切换 Sheet、Terminal/Agent 表面切换、Terminal 快捷键栏 |
| `IOSAgentChatView.swift` | Agent 时间线、消息、折叠活动、状态轨道、交互卡片、Composer、队列、附件、自动滚动 |
| `IOSDesignSystem.swift` | 颜色、字体、间距、圆角、状态标记、按钮、标题和表面修饰器 |
| `IOSMarkdown.swift` | Agent Markdown 的块级解析与渲染（段落、标题、列表、引用、表格、代码） |
| `IOSSwiftTermSurface.swift` | SwiftTerm 真机表面；无 SwiftTerm 时的 UIKit/SwiftUI 预览回退表面 |
| `IOSRelayPairingScanner.swift` | Relay QR 扫描、相机权限提示、粘贴链接和取消按钮 |
| `IOSApplicationModel.swift` | Observable UI projection；连接、Roster、Agent 事件/状态、队列、草稿和 endpoint 操作 |
| `IOSAgentViewModel.swift` | Agent 时间线 reducer、队列/附件值模型、草稿 key、消息复制规则 |
| `IOSAgentInteraction.swift` | Composer 动作判定、model 文案格式化、队列/复制反馈辅助函数 |
| `IOSPersistence.swift` | `IOSNavigationState`、`IOSSessionDisplayMode`、endpoint 元数据、UserDefaults/Keychain 持久化 |

## 3. 首页与 Host 管理（`IOSRootView.swift`）

### 3.1 首页容器和状态

- `IOSRootView`（`27-107`）：深色主题、导航栈、Workspace 管理 Sheet、当前 Session
  路由同步。
- `HostDashboardView`（`134-385`）：首页滚动容器。按 pinned/order/name 排序项目和
  Workspace；显示 Host updating、连接错误、loading、空状态和 mutation 错误；底部插入
  `IOSHostFooter`（`281-285`）。
- `HomeHeader`（`531-606`）：首页标题、连接状态和“一键折叠/展开全部目录”按钮。
- `AgentActivitySummary`（`437-481`）和 `AgentActivitySummaryRow`（`482-530`）：
  首页顶部的活跃 Agent 摘要；使用 `IOSAgentActivityMark`，不属于 Agent 折叠时间线。

### 3.2 项目树和折叠行

- `ProjectSection`（`607-690`）：项目标题/图标、项目内 Workspace 列表及管理入口。
- `ScopeRailSection`（`691-731`）：未归属项目的 Workspace 区域。
- `CollapsibleSectionHeader`（`732-772`）：项目、Workspace、活跃 Agent、Terminal group
  的通用折叠标题；折叠状态存放在 `IOSRootView.collapsedSectionIDs`。
- `ActiveAgentSessionsSection`（`773-826`）：把正在工作的 Agent Session 聚合成可折叠区域。
- `WorkspaceRailRow`（`827-935`）：Workspace 主行、Session 数量、展开箭头和底部细分隔线。
- `WorkspaceSessionRailRow`（`936-997`）：Workspace 下的 Session 子行；Agent Session 用
  `IOSAgentActivityMark`，普通 Shell 用 `IOSStatusDot`。
- `WorkspaceGlyph`（`998-1028`）：合并分支、Agent 活动或普通分支的图标选择。
- `ScopeGroupRow`（`1029-1117`）：Terminal group 主行及其 Session 子行。

这里的 `IOSStatusDot` 是首页/Session 列表的连接或 Shell 状态点，不是 Agent 时间线
里的“条件圆点”。后者见第 4 节。

### 3.3 Host 底栏与 endpoint 页面

- `IOSHostFooter`（`1120-1203`）：当前 Host 名称、Relay/Direct Host 副标题、连接点、
  重连按钮、设置入口；点击 Host 名称打开 `IOSEndpointPickerSheet`。
- `IOSEndpointPickerSheet`（`1208-1290`）：Host 列表、Relay/Direct 图标、当前 Host
  选中标记和 Done。
- `ScopeDetailView`（`1292-1435`）：Workspace/Terminal group 详情、Session 列表、
  管理菜单、删除反馈。
- `IOSBackHeader`（`1436-1498`）：详情页和设置页共用的返回、标题、副标题及操作菜单栏。
- `ScopeSessionRow`（`1499-1549`）：详情页中的 Session 行。
- `WorkspaceView`（`1550-1662`）和 `TerminalGroupView`（`1663-1688`）：两个 Scope
  详情路由的组装层。
- `IOSInlineNotice`（`1689-1716`）：维护、连接、Host action 失败等内联提示。
- `IOSLoadingRow`（`1717-1732`）和 `IOSEmptyState`（`1733-1755`）：加载和无数据占位。
- `IOSSessionCreationSheet`（`1839-1962`）：创建 Shell/Agent Session，包含名称、
  类型、Workspace/Terminal group 选择和创建按钮。
- `IOSWorkspaceManagementSheet`（`1963-2205`）：Workspace 列表、重命名、删除、新建。
- `IOSWorkspaceCreationSheet`（`2206-2308`）：创建 Workspace 的表单。
- `IOSEndpointConfigurationView`（`2309-2575`）：Host 列表、添加 Host、编辑、删除和
  Relay 扫码入口。
- `IOSEndpointDetailView`（`2576-2703`）：单个 Host 的只读连接详情和“使用此 Host”。
- `IOSEndpointEditorView`（`2704-2910`）：Host 名称、URL、Token 表单、保存连接和清除
  Keychain token。

## 4. Session 页面（`IOSSessionView.swift`）

- `SessionView`（`11-335`）：Session 的根容器。Terminal surface 采用小型 LRU 缓存，
  Agent surface 常驻在 ZStack 下方；`IOSSessionDisplayMode` 决定哪个表面可见和可交互。
- `SessionHeader`（`336-449`）：返回、Session 标题、连接状态/Workspace 分支上下文、
  新建和删除菜单。
- `sessionProviderID`（`454-473`）与 `SessionProviderMark`（`474-523`）：根据 Session
  类型和最新事件选择 Claude/Codex/OpenCode/Pi/Shell 图标，并可叠加小型 Agent 活动标记。
- `SessionTabRail`（`524-607`）：同一 Scope 内不超过两个 Session 时显示横向标签；超过两个
  时显示 Session 数量和切换按钮。
- `SessionSwitcherSheet`（`608-687`）：完整 Session 列表、当前选中标记和切换中状态。
- `TerminalShortcutBar`（`688-780`）：Terminal 模式底部快捷键。第一行含键盘收起、Esc、
  Tab、Home/End、方向键、Ctrl、Alt、Copy/Paste；展开 Ctrl 后显示 Ctrl-C/D/A/E/U/K/L。

## 5. Agent 页面（`IOSAgentChatView.swift`）

### 5.1 时间线容器与滚动

- `AgentComposerInput`（`34-143`）：UIKit `UITextView` 封装。固定控制高度，内部可滚动；
  placeholder、输入文字和 caret 以相同垂直内边距居中。`AgentComposerTextView.caretRect`
  只缩短插入光标，不改变输入行为。
- `AgentChatTopOffsetPreferenceKey`（`146-151`）和 `AgentChatBottomOffsetPreferenceKey`
  （`154-159`）：滚动顶部/底部哨兵的位置测量。
- `AgentChatView`（`166-511`）：Agent 时间线、空状态、历史加载、回到底部按钮、Attention/
  Working/错误提示和 Composer 的总装配。每个时间线块使用稳定 `.id`。
- `refreshRenderedBlocks`（`512-516`）：把当前 Session 的事件投影成 `AgentDisplayBlock`。
- `handleTopOffset` / `requestOlderHistory`（`522-550`）：下拉到顶部阈值时请求旧历史，并用
  首个 block ID 做锚点。
- `handleNewContent` / `observeAgentRevision`（`552-584`）：刷新事件前先捕获用户是否接近底部，
  等待两轮主线程布局后再滚到底部，避免新增消息后滚动位置停在旧高度。
- `scrollToLatest` / `restoreHistoryScrollAnchor`（`585-625`）：主动回到底部或加载历史后恢复
  原可视位置。

### 5.2 Composer（固定两行）

`composer` 位于 `626-760`，外层是一个带边框的 raised surface，结构固定为：

1. 第一行（44pt）：`Message…` placeholder 和 `AgentComposerInput`。长文本在 UITextView
   内部滚动，不把 Composer 无限撑高。
2. 第二行（44pt）：`attachmentControlsWithPlus`、附件 chip（若有）、Agent 类型/Model
   元数据、右侧白色 `arrow.up` 发送按钮。

相关位置：

- `attachmentControlsWithPlus`（`761-789`）：加号入口；iOS 使用 PhotosPicker，其他平台
  使用 file importer。
- `filePickerButton` / `photoPickerButton`（`790-824`）：文件/照片选择器。
- `attachmentChip`（`825-870`）：附件名称、上传进度、失败重试和删除附件。这里的
  `xmark.circle.fill` 是“删除附件”按钮，不能误认为失败红叉。
- `agentComposerMetadata` / `agentTypeLabel`（`1091-1116`）：第二行的 provider + model
  文案，不是新的输入框。
- `sendComposerMessage`（`915-1007`）：无附件直接发送；有附件先上传，再用 opaque reference
  发送；失败显示反馈。
- `canSend`（`1153-1156`）：发送按钮是否启用。

### 5.3 队列、提示和辅助行

- `IOSAgentQueueSheet`（`1158-1276`）：Working 时排队消息的查看、编辑、重试、置顶、删除。
- `AgentEmptyState`（`1277-1297`）：没有 Agent 消息时的占位。
- `AgentMarkdownText`（`1298-1311`）：时间线中 Markdown 文本的轻包装。
- `AgentAttentionBanner`（`1312-1404`）：Agent 需要输入/批准/警告时的底部横幅；输入类可
  聚焦 Composer，批准类打开 Terminal。
- `AgentWorkingFooter`（`1405-1425`）：工作中的动态文案（`Fermenting…` 等）。
- `AgentWorkingPhrases`（`1426-1452`）：工作文案循环。
- `AgentHistoryLoadMoreRow`（`1453-1502`）：加载更早消息、失败重试按钮。

### 5.4 事件投影和折叠层级

- `AgentDisplayBlock`（`1503-1513`）：普通事件或一段活动的顶层行。
- `AgentActivityGroup`（`1515-1593`）：统计 reasoning/tool 数量、折叠预览和活动状态。
- `AgentActivityStatus` / `AgentActivityEntry` / `AgentToolBlock`（`1594-1633`）：活动内部
  的值模型。
- `agentDisplayBlocks`（`1634-1713`）：按 sequence 排序、合并结构化事件、把 reasoning 和
  tool call/output 组成活动组；未知事件推进序列但可以不绘制。
- `displayBlockView`（`1787-1807`）：顶层 block 到具体 View 的分派。
- `AgentEventBlock`（`1808-1945`）：用户气泡、助手 Markdown、错误事件、系统/元数据事件和
  结构化事件的分派；用户最后一条消息可显示编辑重发按钮。

## 6. 折叠组件的视觉约定（当前实现）

### 6.1 状态轨道

`AgentStatusRail`（`1947-1978`）是所有折叠行共用的左侧状态轨道：圆角竖条、独立的左侧
预留列、不可点击，不压在 chevron 或业务图标上。各组件的调用位置：

- `AgentStructuredEventBlock`（`2007-2452`）：Question/Permission/Plan/Todo/Activity/
  Plugin/Subagent/Attachment；展开或失败时绘制，失败使用红色轨道。
- `AgentSecondaryEventBlock`（`2495-2561`）：System/metadata/notice 等次要信息，使用中性
  分隔轨道。
- `AgentActivityGroupBlock`（`2596-2722`）：reasoning/tool 活动组；展开、运行或失败时绘制，
  运行是琥珀色，失败是红色，完成是绿色。
- `AgentReasoningEntry`（`2723-2789`）：活动组内的 Thinking 子折叠，展开时使用中性轨道。
- `AgentToolBlockView`（`2790-2881`）和 `AgentToolOutputBlock`（`2882-2956`）：工具调用及
  输出的状态轨道；成功绿色、运行琥珀色、中断黄色、失败红色。

轨道与标题的间隔由各行的 `.padding(.leading, 8)` 和 `AgentStatusRail` 的 leading inset
共同保证。若出现“竖线压住箭头/图标”，优先检查上述五个组件和 `AgentStatusRail`，不要在
单个标题里临时插入圆点来补偿。

### 6.2 圆点、圆圈和叉号的区别

| 用户描述 | 代码位置 | 当前规则 |
| --- | --- | --- |
| 条件圆点 / Plan 圆点 | `AgentStructuredEventBlock.detail` 的 Plan/Todo 分支，约 `2214-2231` | 已删除 `circle`、`circle.lefthalf.filled`、`checkmark.circle.fill` 状态图标；条目只显示文字和紧凑状态文案 |
| 折叠标题状态圆点 | `AgentStructuredEventBlock`、`AgentActivityGroupBlock`、`AgentReasoningEntry` 标题 | 不再按 expanded 条件插入 Circle；标题的 chevron 起始位置保持不变 |
| 工具状态圆点 | `AgentToolBlockView` / `AgentToolOutputBlock` 标题 | 不绘制小 Circle；状态由左侧轨道表示 |
| 运行中的圆点 | `activityStatusMark`（约 `2652-2680`）、`AgentToolStatusMark`（约 `2957-2980`） | 折叠行不显示 trailing pulsing dot；保留轨道和 VoiceOver 语义 |
| Question/Permission 选项圆圈 | `interactionOptionRow`，约 `2250-2264` | 这是可点击的单选/多选控件，不能按“条件圆点”删除；选中态仍用 `checkmark.circle.fill` |
| 附件删除叉 | `attachmentChip`，约 `849-860` | 这是删除附件动作，不是失败状态，不能删除或替换为失败轨道 |
| 失败红叉 | 旧实现位于 `activityStatusMark` / `AgentToolStatusMark` | 当前为 `EmptyView()`；失败只用红色状态轨道表示 |

### 6.3 结构化卡片和交互

- `AgentStructuredEventBlock` 的标题包含 chevron、事件图标、标题和非失败状态文案；失败时
  隐藏右侧 Failed 文案，只保留红色轨道。
- Question/Permission pending 时显示描述、选项、自定义回答、Submit/Cancel；提交先进入
  submitting，最终状态必须由 Host 事件确认。
- Plan/Todo 是只读条目，使用紧凑文字状态；展开/折叠只改变本地 View，不改变 Agent 执行。
- `AgentSecondaryEventBlock` 用于可展开的系统/元数据预览。
- `AgentCompactionMarker`（`2562-2595`）是时间线中的单行压缩标记，不属于可展开卡片。
- `AgentActivityGroupBlock` 内部按 Thinking → Tools 顺序显示；`AgentReasoningEntry`、
  `AgentToolBlockView`、`AgentToolOutputBlock` 是第二级折叠。
- `AgentToolStatusMark` 仍为 VoiceOver 提供状态语义；视觉失败分支是 `EmptyView()`。

## 7. Markdown 渲染（`IOSMarkdown.swift`）

- `IOSMarkdownBlock`、`IOSMarkdownListItem`、`IOSMarkdownTable`（`9-53`）：块级中间模型。
- `IOSMarkdownParser`（`58-511`）：有限 GFM 解析；支持 fenced code、ATX heading、分隔线、
  表格、无序/有序列表、task marker、引用和自然段；不认识的语法降级为普通段落。
- `IOSMarkdownView`（`512-591`）：按块分派字体、颜色、间距。
- `IOSMarkdownInlineText`（`592-641`）：Foundation Markdown 的强调、链接、行内 code。
- `IOSMarkdownListView`（`642-678`）：列表深度、marker 和 task 状态布局。
- `IOSMarkdownTableView`（`679-732`）：表头、列对齐和横向滚动表格。
- `IOSMarkdownCodeBlock`（`733-765`）：等宽字体代码块和语言标签。

## 8. 设计系统（`IOSDesignSystem.swift`）

- `IOSCopy`（`9-19`）：连接状态的本地化 key。
- `IOSTheme`（`26-91`）：深色背景、raised/input/muted surface、文本、accent、amber/green/
  yellow/red、分隔线和通用几何 token。
- `IOSTypography`（`98-148`）：页面标题、导航、正文、Agent 对话、Composer、metadata、
  code 等 Dynamic Type 字体。
- `IOSSurfaceModifier` 与 `View.iosSurface`（`150-207`）：统一圆角表面、边框和 Sheet 安全区。
- `IOSStatusDot`（`210-225`）：仅用于首页/Session 列表的 Shell 或连接状态点。
- `IOSPresetIcon`（`230-260`）：Agent provider 资产图标。
- `IOSAgentActivityMark`（`265-347`）：首页/Session provider 标记的 Agent 活动点和工作脉冲；
  不应直接用于 Agent 折叠行的 trailing 状态。
- `IOSShimmerText`（`359-414`）：Working footer 动态高光。
- `IOSIconButton`（`418-440`）与 `IOSKeyboardDismissButton`（`445-463`）：44pt 原生触控按钮。
- `IOSSectionLabel`（`465-493`）、`IOSProjectIcon`（`497-525`）、`IOSScreenHeading`
  （`529-565`）、`IOSBrandMark`（`567-624`）：页面标题和品牌/项目视觉。
- `IOSModeToggle`（`625-680`）：Terminal/Agent 模式切换。
- `IOSKeyCap`（`681-727`）：Terminal 快捷键按钮。

## 9. Terminal 与 Relay UI

### Terminal（`IOSSwiftTermSurface.swift`）

- `SwiftTermTerminalSurface`（`12-72`）：Terminal 表面容器、恢复时保持旧网格、未准备好时
  显示 Connecting terminal。
- 真机 `PlatformTerminalView`（`73-255`）：SwiftTerm `TerminalView`，负责 ANSI/PTY 输入输出、
  resize、复制粘贴和首击获取键盘。
- UIKit 回退 `PlatformTerminalView`（`256-290`）：没有 SwiftTerm 时使用只读 `UITextView`。
- SwiftUI 回退 `PlatformTerminalView`（`292-314`）：预览/测试中的可滚动等宽文本。

### Relay 扫码（`IOSRelayPairingScanner.swift`）

- iOS `IOSRelayPairingScannerView`（`9-69`）：UIViewControllerRepresentable 和 delegate 回调。
- `RelayQRScannerViewController`（`77-271`）：相机预览、QR 识别、扫描框、标题、Paste link、
  Cancel、相机权限失败提示。
- 非 iOS 回退 View（`277-304`）：说明仅 iPhone/iPad 可扫码，并提供粘贴/关闭按钮。

## 10. UI 状态来源与操作边界

### `IOSApplicationModel.swift`

`IOSApplicationModel`（约 `64` 起）是主线程 Observable projection。UI 主要读取：

- `roster`、`connectionState`、`connectionError`、`maintenanceMessage`：首页和 Session 顶栏。
- `currentSessionID`、`displayMode`、`hasControlLease`：路由、Terminal/Agent 表面和输入能力。
- `agentEventsBySessionID`、`agentEventRevisionBySessionID`：Agent 时间线与刷新触发。
- `agentStatusBySessionID`、`agentTurnBySessionID`、`agentAttention(for:)`：工作/中断/Attention。
- `agentQueueBySessionID`、`agentQueuedMessageCountBySessionID`：队列 Sheet 与队列提示。
- `historyLoadingBySessionID`、`historyErrorBySessionID`：历史加载行。
- `agentCapabilities`、`agentActionError`：交互、附件和错误降级。

关键操作方法：`setDisplayMode`（`648`）、`selectSession`（`740`）、`focusTerminal`（`893`）、
`sendAgentMessage`（`1083`）、队列操作（`1113-1174`）、草稿操作（`1177-1221`）、
`cancelAgentTurn`（`1299`）、`sendAgentMessageNow`（`1342`）、
`respondToAgentInteraction`（`1459`）、`uploadAgentAttachment`（`1494`）、
`loadOlderAgentHistory`（`2198`）。这些方法负责协议和持久化，View 不应绕过它们直接写 Host。

### `IOSAgentViewModel.swift`

- `IOSAgentStructuredEventKind`（`6-8`）：Question/Permission/Plan/Todo/Activity/Plugin/
  Subagent/Attachment 白名单。
- `IOSAgentTimelineReducer`（`35-95`）：按 epoch/sequence 去重、重置、保留未知事件序列并
  生成结构化事件。
- `IOSAgentLocalAttachment`（`108-139`）：附件的本地数据、上传进度、失败和 opaque reference。
- `IOSAgentQueueItem` / `IOSAgentMessageQueue`（`141-258`）：本地队列的编辑、移动、删除、
  sending、失败和重试。
- `IOSAgentMessageActions`（`260-287`）：复制/编辑重发只取 user/assistant prose。
- `IOSLocalStore` 的 Agent draft API（`289-333`）：按 endpoint + Session 隔离草稿 key。

### `IOSAgentInteraction.swift` 与 `IOSPersistence.swift`

- `agentComposerAction`（`IOSAgentInteraction.swift:51-79`）：根据 Agent activity、control
  lease、attention 和文本决定 send/interrupt/unavailable。
- `formatAgentModel`（`IOSAgentInteraction.swift:19-49`）：把 provider/model identifier 转成
  Composer 可读文案。
- `IOSNavigationState` / `IOSSessionDisplayMode`（`IOSPersistence.swift:9-39`）：恢复 Scope、
  Session 和 Terminal/Agent 偏好。
- `IOSEndpointMetadata`（`IOSPersistence.swift:45-91`）：只向 UI 暴露 Host 名称、URL、类型和
  token 是否存在；token 本身只进 Keychain。

## 11. 用户描述 → 代码位置速查

| 用户说法 | 先查这里 | 备注 |
| --- | --- | --- |
| “条件圆点没删” | `AgentStructuredEventBlock` Plan/Todo 分支（约 `2214`） | 现在应没有状态 Circle；不要改 `interactionOptionRow` 的单选圆圈 |
| “折叠前没有最左对齐” | `AgentStatusRail`（`1947`）及五个折叠 View 的 `.padding(.leading, 8)` | 检查 rail inset、标题 chevron 起点和嵌套 detail padding |
| “展开后缩进太深” | `AgentStructuredEventBlock` detail（约 `2065`）、`AgentActivityGroupBlock` detail（约 `2637`）、reasoning/tool detail | 优先调固定 indent，不要插入状态圆点 |
| “右侧红叉” | `activityStatusMark`、`AgentToolStatusMark` | 失败分支必须是 `EmptyView()`，红色只从 `AgentStatusRail` 来 |
| “红/绿色竖线压住箭头” | `AgentStatusRail` + `AgentStructuredEventBlock` / `AgentActivityGroupBlock` / `AgentReasoningEntry` / `AgentToolBlockView` / `AgentToolOutputBlock` overlays | 轨道要在保留左列间距的位置，不能直接覆盖标题 HStack |
| “Message 输入框太高/placeholder 不居中” | `AgentComposerInput`（`34-143`）与 `composer` 第一行（约 `650-705`） | 固定 44pt；UITextView 内部滚动；placeholder 与 caret 使用同一垂直 inset |
| “Composer 应该两行” | `composer`（`626-760`） | 第一行 Message，第二行 +/附件/Model/发送箭头；不要把两行合并成 HStack |
| “发送按钮椭圆/颜色不对” | `composer` 第二行的 `Button`（约 `728-751`） | 当前是无背景的白色 `arrow.up`，44pt hit area |
| “+ 按钮” | `attachmentControlsWithPlus`（`761-789`） | PhotosPicker/fileImporter 入口 |
| “Model 文案” | `agentComposerMetadata`（`1094`）与 `IOSAgentInteraction.formatAgentModel` | 这是第二行 metadata，不是 Message 输入框 |
| “新增消息没有自动下滚” | `observeAgentRevision`（`567`）、`handleNewContent`（`552`）、底部哨兵（约 `286`） | 刷新前捕获 `isNearLatest`，等待两轮布局后滚动 |
| “Working/正在思考” | `shouldShowWorking`（约 `1124`）、`AgentWorkingFooter`（`1405`） | 文案动画来自 `IOSShimmerText` |
| “需要我回答/权限” | `AgentAttentionBanner`（`1312`）、`AgentStructuredEventBlock` Question/Permission 分支 | input 可聚焦 Composer，approval 引导 Terminal |
| “思考步骤” | `AgentActivityGroupBlock` + `AgentReasoningEntry`（`2596`、`2723`） | 第二级折叠，不是普通 assistant 消息 |
| “工具调用/工具输出” | `AgentToolBlockView` / `AgentToolOutputBlock`（`2790`、`2882`） | 看 status rail、summary、output/error 文本 |
| “Plan/Todo” | `AgentStructuredEventBlock.detail` Plan/Todo（约 `2214`） | 只读、无状态圆点，使用文字状态 |
| “队列消息” | `IOSAgentQueueSheet`（`1158`）与 model 队列 API | 队列是本地 View 状态，不是 transcript event |
| “历史加载/上拉” | `AgentHistoryLoadMoreRow`（`1453`）、顶部哨兵和 `requestOlderHistory` | 使用 anchor 保持原可视位置 |
| “Session 顶栏/Terminal-Agent 切换” | `SessionHeader`、`IOSModeToggle`、`SessionView` | `IOSSessionDisplayMode` 是每个 Session 的本地偏好 |
| “Terminal 快捷键” | `TerminalShortcutBar`（`688`）与 `IOSKeyCap`（`681`） | 不要在 Agent Composer 中复用 Terminal 快捷键栏 |
| “首页项目/Workspace 折叠” | `HostDashboardView`、`CollapsibleSectionHeader`、`WorkspaceRailRow` | 这是首页目录折叠，不是 Agent 时间线折叠 |
| “Host 设置/扫码” | `IOSEndpointConfigurationView`、`IOSEndpointEditorView`、`IOSRelayPairingScannerView` | token 只显示存在性，不从 UI state 读取明文 |

## 12. UI 问题描述模板

为了让 agent 一次处理多个问题，建议报告包含：

1. 页面：`首页`、`Session`、`Agent`、`Terminal`、`Host 设置` 或 `Relay 扫码`。
2. 组件：从上表选择名称，例如 `AgentToolBlockView`、`Composer 第二行`、`SessionTabRail`。
3. 状态：折叠/展开、running/completed/failed、是否有附件、是否键盘弹出、是否正在流式输出。
4. 位置：左/右、标题/正文/状态轨道/按钮，是否只在 iPhone 小屏出现。
5. 期望：明确“删除/保留/移动/压缩/自动滚动”，并说明是否影响交互和 VoiceOver。

示例：

> Agent → ActivityGroup 展开 → Tool 子行：失败时右侧还有红叉；删除右侧图标，保留左侧
> 红色轨道；工具标题与轨道保持至少 6pt 间距。

这类描述可以直接定位到 `AgentActivityGroupBlock`、`AgentToolBlockView`、
`AgentToolStatusMark` 和 `AgentStatusRail`，不会误改附件删除按钮或 Question 选项圆圈。

## 13. 验证清单

- 构建/单元测试：`swift test --package-path Packages/WarrenIOS`。
- 真机构架构编译：使用 `xcodebuild ... -sdk iphoneos -destination 'generic/platform=iOS'`
  并带 `-skipPackagePluginValidation`。
- 真机验收：至少检查 1 个普通对话、1 个展开活动组、1 个失败工具、1 个 Plan/Todo、1 个
  Question/Permission、长消息输入、键盘弹出时新增消息和历史上拉。
- 视觉验收时不要用测试数据替代真实 SwiftUI 表面；尤其确认轨道没有盖住 chevron/图标，
  Composer 确实是两行，流式新增消息仍贴近底部。
