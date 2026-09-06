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
  重连按钮、设置入口；Host 名称本身就是切换入口，不再额外显示上下箭头。
- `IOSEndpointPickerSheet`（`1208-1290`）：Host 列表、Relay/Direct 图标、地址或 Relay
  route、当前连接状态、Token 是否保存、当前 Host 选中标记和 Done。这里是切换 Host
  的信息面板，不是只显示名称的菜单。
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
  时显示 Session 数量和切换按钮。整条 rail 全宽铺开，只保留底部分隔线，不使用左右边框、
  圆角卡片或内嵌 bar。
- `SessionSwitcherSheet`（`608-687`）：完整 Session 列表、当前选中标记和切换中状态。
- `TerminalShortcutBar`（`688-780`）：Terminal 模式底部快捷键。第一行含键盘收起、Esc、
  Tab、Home/End、方向键、Ctrl、Alt、Copy/Paste；展开 Ctrl 后显示 Ctrl-C/D/A/E/U/K/L。

## 5. Agent 页面（`IOSAgentChatView.swift`）

### 5.1 时间线容器与滚动

- `AgentComposerTextField` / `AgentComposerInput` (`21-163`): UIKit `UITextField` wrapper with
  a fixed 42pt input row. Return submits the message while the coordinator keeps responder
  state stable across SwiftUI publications.
- `AgentChatTopOffsetPreferenceKey` (`165-171`) and `AgentChatBottomOffsetPreferenceKey`
  (`173-179`): scroll-top and scroll-bottom sentinel measurements.
- `AgentChatView` (`185-590`): Agent timeline, empty state, history loading, return-to-latest
  action, Attention/
  Working/错误提示和 Composer 的总装配。每个时间线块使用稳定 `.id`。
- `refreshRenderedBlocks`（`530-534`）：把当前 Session 的事件投影成 `AgentDisplayBlock`。
- `handleTopOffset` / `requestOlderHistory`（`540-568`）：下拉到顶部阈值时请求旧历史，并用
  首个 block ID 做锚点。
- `handleNewContent` / `observeAgentRevision`（`570-602`）：刷新事件前先捕获用户是否接近底部，
  等待两轮主线程布局后再滚到底部，避免新增消息后滚动位置停在旧高度。
- `scrollToLatest` / `restoreHistoryScrollAnchor`（`603-642`）：主动回到底部或加载历史后恢复
  原可视位置。

### 5.2 Composer（单行）

`composer` is defined at `826-940`. Its bordered raised surface is a single 50pt row:

1. A 42pt `Message…` field backed by `AgentComposerInput`.
2. The same row contains `attachmentControlsWithPlus`, the optional keyboard-dismiss button,
   and the white `arrow.up` send button. Attachments, queue state, and model/reasoning settings
   are rendered by the metadata tray below the row.

相关位置：

- `attachmentControlsWithPlus` (`1037-1088`): the compact plus menu exposes both PhotosPicker
  and the file importer on iOS; other platforms use the file importer directly.
- `filePickerButton` / `attachmentPlusLabel` (`1090-1118`): file importer and shared plus label.
- `loadPhotos` / `handleFileImporter` (`1335-1425`): read photos or security-scoped file URLs into
  短暂的本地附件数据；附件只在上传期间留在内存。
- `attachmentChip` (`1119-1162`): attachment name, upload progress, retry, and removal. The
  removal control is not a tool-failure marker.
- `composerSettingsButton` (`1507-1578`): provider model and reasoning settings in the metadata
  tray; it is not another input field.
- `sendComposerMessage` (`1208-1334`): sends directly without attachments, or uploads first and
  sends opaque references; failures remain actionable.
- `canSend` (`1632-1635`): send-button eligibility.

附件发送的 View 只负责选择、读取、进度和 opaque reference。iOS 与 Web 都调用
`agent.attachment.prepare/chunk/complete/abort`，完成后再调用 `agent.turn.start`；
Host 会把附件内容写入权限为 `0600` 的临时文件，并在没有 Provider-native bridge 时通过
PTY prompt 告知 Agent 文件名、MIME、大小和 Host 路径。客户端不会发送本地路径，也不会把
文件内容写入 draft 或队列持久化。

### 5.3 队列、提示和辅助行

- `IOSAgentQueueSheet`（`1169-1287`）：Working 时排队消息的查看、编辑、重试、置顶、删除。
- `AgentEmptyState`（`1288-1308`）：没有 Agent 消息时的占位。
- `AgentMarkdownText`（`1309-1322`）：时间线中 Markdown 文本的轻包装。
- `AgentAttentionBanner`（`1323-1415`）：Agent 需要输入/批准/警告时的底部横幅；输入类可
  聚焦 Composer，批准类打开 Terminal。
- `AgentWorkingFooter`（`1416-1436`）：工作中的动态文案（`Fermenting…` 等）。
- `AgentWorkingPhrases`（`1437-1463`）：工作文案循环。
- `AgentHistoryLoadMoreRow`（`1464-1513`）：加载更早消息、失败重试按钮。

### 5.4 事件投影和折叠层级

- `AgentDisplayBlock`（`1514-1524`）：普通事件或一段活动的顶层行。
- `AgentActivityGroup`（`1526-1604`）：统计 reasoning/tool 数量、折叠预览和活动状态。
- `AgentActivityStatus` / `AgentActivityEntry` / `AgentToolBlock`（`1605-1644`）：活动内部
  的值模型。
- `agentDisplayBlocks`（`1645-1724`）：按 sequence 排序、合并结构化事件、把 reasoning 和
  tool call/output 组成活动组；未知事件推进序列但可以不绘制。
- `displayBlockView`（`1798-1818`）：顶层 block 到具体 View 的分派。
- `AgentEventBlock`（`1819-1957`）：用户气泡、助手 Markdown、错误事件、系统/元数据事件和
  结构化事件的分派；纯文本呈现，不再显示编辑重发按钮。

## 6. 折叠组件的视觉约定（当前实现）

### 6.1 状态轨道

`AgentStatusRail`（`1958-1995`）是顶层结构化事件和 ActivityGroup 共用的左侧状态轨道：
圆角竖条、独立的左侧预留列、不可点击，不压在 chevron 或业务图标上。Tool/Thinking 子行
不再调用它。各组件的调用位置：

- `AgentStructuredEventBlock`（`2018-2463`）：Question/Permission/Plan/Todo/Activity/
  Plugin/Subagent/Attachment；展开或失败时绘制，失败使用红色轨道。
- `AgentSecondaryEventBlock`（`2506-2572`）：System/metadata/notice 等次要信息，使用中性
  分隔轨道。
- `AgentActivityGroupBlock`（`2607-2742`）：reasoning/tool 活动组；正常未报错时不绘制颜色轨道避免与展开箭头重叠，仅在失败时绘制红色顶层状态轨道。
- `AgentReasoningEntry`（`2743-2809`）：活动组内的 Thinking 子折叠；不再绘制绿色、红色
  或中性竖线，标题与 Tool 子行使用同一层级缩进。
- `AgentToolBlockView`（`2810-2901`）和 `AgentToolOutputBlock`（`2902-2976`）：工具调用及
  输出；不再绘制状态竖线，失败状态由最右侧无边框红色 `xmark` 表示。

顶层轨道与标题的间隔由独立左侧预留列和 detail indent 共同保证。Tool/Thinking 的标题、
正文和输出共享 ActivityGroup detail 的左侧基线；若出现“竖线压住箭头/图标”，优先检查
顶层 `AgentActivityGroupBlock` 的 rail 列，不要在子标题里临时插入圆点或竖线来补偿。

### 6.2 圆点、圆圈和叉号的区别

| 用户描述 | 代码位置 | 当前规则 |
| --- | --- | --- |
| 条件圆点 / Plan 圆点 | `AgentStructuredEventBlock.detail` 的 Plan/Todo 分支，约 `2232-2246` | 已删除 `circle`、`circle.lefthalf.filled`、`checkmark.circle.fill` 状态图标；条目只显示文字和紧凑状态文案 |
| 折叠标题状态圆点 | `AgentStructuredEventBlock`、`AgentActivityGroupBlock`、`AgentReasoningEntry` 标题 | 不再按 expanded 条件插入 Circle；标题的 chevron 起始位置保持不变 |
| 工具状态圆点 | `AgentToolBlockView` / `AgentToolOutputBlock` 标题 | 不绘制小 Circle；失败使用最右侧无边框红色 `xmark`，完成仍可用绿色 checkmark |
| 运行中的圆点 | `activityStatusMark`（约 `2690-2718`）、`AgentToolStatusMark`（约 `2977-3001`） | 折叠行不显示 trailing pulsing dot；ActivityGroup 仅保留顶层状态轨道，Tool/Thinking 子行保持紧凑 |
| Question/Permission 选项圆圈 | `interactionOptionRow`，约 `2250-2264` | 这是可点击的单选/多选控件，不能按“条件圆点”删除；选中态仍用 `checkmark.circle.fill` |
| 附件删除叉 | `attachmentChip`，约 `860-871` | 这是删除附件动作，不是失败状态，不能删除或替换为失败轨道 |
| 失败红叉 | `AgentToolStatusMark`（`AgentToolBlockView` / `AgentToolOutputBlock` 标题尾部） | `xmark` 无边框、固定在 trailing 位置；颜色为 `IOSTheme.red` |

### 6.3 结构化卡片和交互

- `AgentStructuredEventBlock` 的标题包含 chevron、事件图标、标题和非失败状态文案；失败时
  隐藏右侧 Failed 文案，只保留红色轨道。
- Question/Permission pending 时显示描述、选项、自定义回答、Submit/Cancel；提交先进入
  submitting，最终状态必须由 Host 事件确认。
- Plan/Todo 是只读条目，使用紧凑文字状态；展开/折叠只改变本地 View，不改变 Agent 执行。
- `AgentSecondaryEventBlock` 用于可展开的系统/元数据预览。
- `AgentCompactionMarker`（`2562-2595`）是时间线中的单行压缩标记，不属于可展开卡片。
- `AgentActivityGroupBlock` 内部按 Thinking → Tools 顺序显示；`AgentReasoningEntry`、
  `AgentToolBlockView`、`AgentToolOutputBlock` 是第二级折叠。三者取消子级竖线，详情内容
  共享同一左侧基线；顶层 ActivityGroup 状态轨道仍保留。
- `AgentToolStatusMark` 仍为 VoiceOver 提供状态语义；失败视觉是最右侧无边框红色 `xmark`。

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
| “条件圆点没删” | `AgentStructuredEventBlock` Plan/Todo 分支（约 `2232`） | 现在应没有状态 Circle；不要改 `interactionOptionRow` 的单选圆圈 |
| “折叠前没有最左对齐” | `AgentStatusRail`（`1958`）、`AgentActivityGroupBlock` 和 `SessionTabRail` | 先区分顶层状态轨道与 Session 全宽切换条；Tool/Thinking 子行不再自行添加 rail |
| “展开后缩进太深” | `AgentStructuredEventBlock` detail（约 `2074`）、`AgentActivityGroupBlock` detail（约 `2650`）、reasoning/tool detail | 优先调固定 indent，不要插入状态圆点 |
| “右侧红叉” | `AgentToolStatusMark`（由 `AgentToolBlockView` / `AgentToolOutputBlock` 调用） | 失败显示无边框红色 `xmark`，用固定宽度 frame 放在最右侧；不要改成圆形按钮 |
| “红/绿色竖线压住箭头” | `AgentStatusRail` + `AgentStructuredEventBlock` / `AgentActivityGroupBlock` overlays | Tool/Thinking 子行已经不画竖线；若仍重叠，先查顶层 ActivityGroup 的独立 rail 列与 detail indent |
| “Message 输入框太高/placeholder 不居中” | `AgentComposerInput`（`43-163`）与 `composer`（`826-940`） | `UITextField` 固定 42pt；单行输入和 placeholder 垂直居中，Return 触发发送 |
| “Composer 应该两行” | `composer`（`826-940`）与 `composerMetadataTray`（`941-1034`） | 输入控件是单行 50pt；附件、队列和 model/reasoning 设置位于下方 metadata tray |
| “发送按钮椭圆/颜色不对” | `composer` 的 `Button`（约 `900-918`） | 当前是无背景的白色 `arrow.up`，44pt hit area；键盘收起按钮仅在聚焦时显示 |
| “+ 按钮” | `attachmentControlsWithPlus`（`1037-1088`） | 直接呈现 PhotosPicker/fileImporter，点击后真正打开选择器 |
| “Model 文案” | `composerSettingsButton`（`1507-1578`）与 `IOSAgentInteraction.formatAgentModel` | metadata tray 中的 model/reasoning 胶囊，优先完整展示模型名称 |
| “新增消息没有自动下滚” | `observeAgentRevision`（`585`）、`handleNewContent`（`570`）、底部哨兵（约 `304`） | 刷新前捕获 `isNearLatest`，等待两轮布局后滚动 |
| “Working/正在思考” | `shouldShowWorking`（`1603`）、`AgentWorkingFooter`（`2212`） | 文案动画来自 `IOSShimmerText` |
| “需要我回答/权限” | `AgentAttentionBanner`（`1323`）、`AgentStructuredEventBlock` Question/Permission 分支 | input 可聚焦 Composer，approval 引导 Terminal |
| “思考步骤” | `AgentActivityGroupBlock` + `AgentReasoningEntry`（`2607`、`2743`） | 第二级折叠，不是普通 assistant 消息 |
| “工具调用/工具输出” | `AgentToolBlockView` / `AgentToolOutputBlock`（`2810`、`2902`） | 看 status rail、summary、output/error 文本 |
| “Plan/Todo” | `AgentStructuredEventBlock.detail` Plan/Todo（约 `2232`） | 只读、无状态圆点，使用文字状态 |
| “队列消息” | `IOSAgentQueueSheet`（`1953`）、`makeProtocolQueueItems`（`1647`）与 model 队列 API | 同时显示本地队列和 Host/provider queue events；两者都保持稳定 item ID |
| “历史加载/上拉” | `AgentHistoryLoadMoreRow`（`1464`）、顶部哨兵和 `requestOlderHistory` | 使用 anchor 保持原可视位置 |
| “Session 顶栏/Terminal-Agent 切换” | `SessionHeader`、`IOSModeToggle`、`SessionView` | `IOSSessionDisplayMode` 是每个 Session 的本地偏好 |
| “Session 切换条有左右边框” | `SessionTabRail` | 改为全宽 rail；删除 rounded rectangle stroke 和左右外边距，只保留底部分隔线 |
| “Terminal 快捷键” | `TerminalShortcutBar`（`688`）与 `IOSKeyCap`（`681`） | 不要在 Agent Composer 中复用 Terminal 快捷键栏 |
| “首页项目/Workspace 折叠” | `HostDashboardView`、`CollapsibleSectionHeader`、`WorkspaceRailRow` | 这是首页目录折叠，不是 Agent 时间线折叠 |
| “Host 设置/扫码” | `IOSEndpointConfigurationView`、`IOSEndpointEditorView`、`IOSRelayPairingScannerView` | token 只显示存在性，不从 UI state 读取明文 |
| “Host 切换按钮/箭头” | `IOSHostFooter`、`IOSEndpointConfigurationView` | Host 名称行可点击切换；不添加 `chevron.up.chevron.down` 之类提示图标 |
| “Host 切换面板信息太少” | `IOSEndpointPickerSheet` | 检查类型、地址/route、连接状态、Token 状态和当前选中标记 |
| “iOS/Web 附件发不出去” | iOS `IOSApplicationModel.uploadAgentAttachment` / `sendAgentMessage`、Web `uploadAgentAttachments` / `agent.turn.start`、Host `Headless/internal/server/agent_view.go` | 先查 capability，再查 prepare/chunk/complete，最后查 Host 的临时文件 PTY bridge；不要把本地路径直接放进协议 |

## 12. UI 问题描述模板

为了让 agent 一次处理多个问题，建议报告包含：

1. 页面：`首页`、`Session`、`Agent`、`Terminal`、`Host 设置` 或 `Relay 扫码`。
2. 组件：从上表选择名称，例如 `AgentToolBlockView`、`Composer 第二行`、`SessionTabRail`。
3. 状态：折叠/展开、running/completed/failed、是否有附件、是否键盘弹出、是否正在流式输出。
4. 位置：左/右、标题/正文/状态轨道/按钮，是否只在 iPhone 小屏出现。
5. 期望：明确“删除/保留/移动/压缩/自动滚动”，并说明是否影响交互和 VoiceOver。

示例：

> Agent → ActivityGroup 展开 → Tool 子行：失败时右侧红色 x 要无边框并贴在最右侧；
> 不要给 Tool/Thinking 子行添加竖线，标题、正文和输出沿同一层级基线对齐。

这类描述可以直接定位到 `AgentActivityGroupBlock`、`AgentToolBlockView`、
`AgentToolStatusMark` 和 `AgentStatusRail`，不会误改附件删除按钮或 Question 选项圆圈。

## 13. 验证清单

- 构建/单元测试：`swift test --package-path Packages/WarrenIOS`。
- 真机构架构编译：使用 `xcodebuild ... -sdk iphoneos -destination 'generic/platform=iOS'`
  并带 `-skipPackagePluginValidation`。
- 真机验收：至少检查 1 个普通对话、1 个展开活动组、1 个失败工具、1 个 Plan/Todo、1 个
  Question/Permission、长消息输入、键盘弹出时新增消息和历史上拉。
- 视觉验收时不要用测试数据替代真实 SwiftUI 表面；尤其确认轨道没有盖住 chevron/图标，
  Composer 保持单行输入，metadata tray 不遮挡键盘和底部滚动，流式新增消息仍贴近底部。
