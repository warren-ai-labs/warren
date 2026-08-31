# RFC 0010：Agent View 在 iOS/Web 的能力对齐

- 状态：Proposed
- Owner：Warren Agent View（iOS/Web）
- 创建日期：2026-08-31
- 范围：Warren iOS 与 Web 的 Agent View 层
- 参考实现：Paseo、Lody
- 协议基线：Warren protocol 2.0

## 摘要

Warren 已经能够通过 `agent` 批量事件、`agent.history`、`agent.status` 和
`agent.turn` 展示基本的 Agent 对话、工具调用、reasoning、历史和运行状态。
但 iOS 和 Web 的 View 仍缺少 Paseo、Lody 已具备的几类直接影响日常使用的
能力：结构化交互卡片、停止当前 turn、附件、丰富的时间线事件、排队消息管理、
草稿恢复和消息操作。

本 RFC 为 iOS 与 Web 定义同一套 Agent View 语义和最小支撑协议，覆盖以下七项：

1. Question / Permission / Plan；
2. Cancel / Interrupt；
3. 附件上传；
4. 新的结构化协议事件；
5. 排队消息管理；
6. 草稿持久化；
7. 消息操作。

“View 层”在本文中指用户看到的 Agent 时间线、composer、交互卡片及其本地
状态。为让 View 能够显示事实并提交用户选择，Host/Transport 可以增加对应的
最小事件、请求和上传生命周期；这些是 View 的支撑契约，不扩展为新的模型控制、
会话管理或 Desktop UI 产品能力。

## 动机与现状

当前 Warren 的缺口如下：

| 能力 | Warren iOS | Warren Web | Paseo / Lody 参考 |
| --- | --- | --- | --- |
| Question / Permission / Plan | 无结构化卡片和响应 | 无结构化卡片和响应 | 两者均有交互卡片；Paseo 还支持多问题表单和 Plan/Todo 展示 |
| Cancel / Interrupt | composer 通过 PTY 发送文本，没有语义化 stop | 同样没有 Agent stop 控件 | Paseo 支持 cancel 和 `Send now`；Lody 有 session cancel |
| 附件上传 | 无 Agent attachment 上传链路 | 只有文本 composer | Paseo/Lody 支持选择、拖放、校验、上传和失败重试 |
| 新协议事件 | 主要消费 `user`、`assistant`、`reasoning`、tool、usage 等已有事件 | 可显示少量已有事件 | Paseo/Lody 有 permission、question、plan、todo、activity、plugin 等结构化视图 |
| 排队消息管理 | 只有按 Session 的文本队列和 `Queued N` | 无 Agent 消息队列 | Lody 支持查看、编辑、删除、排序和 Steer；Paseo 支持 queue 与 Send now |
| 草稿持久化 | draft 是 View 的 `@State` | draft 不按 Session 持久化 | 两者均在 composer 生命周期中保留 draft |
| 消息操作 | 缺少统一的 copy/edit/retry 语义 | 缺少统一的 copy/edit/retry 语义 | Paseo/Lody 支持复制和用户消息编辑/重发等操作 |

参考代码位置（以各仓库当前实现为准）：

- Paseo：`packages/app/src/agent-stream/view.tsx`、
  `packages/app/src/composer/`、`packages/app/src/components/question-form-card.tsx`、
  `packages/app/src/components/message.tsx`。
- Lody：`packages/components/src/components/sessions/`、
  `packages/components/src/components/chat/`、
  `packages/components/src/components/ai-gui/`、
  `packages/components/src/lib/session-file-upload.ts`。
- Warren：`Packages/WarrenIOS/Sources/WarrenIOS/`、
  `Packages/Transport/Sources/WarrenTransport/`、`Web/src/agent.jsx`。

## 目标

- iOS 与 Web 具有一致的 Agent View 功能语义，交互方式符合各自平台习惯。
- 使用现有的 `agent` 批量事件、`agent.history` 回放、`epoch` 和单调序列号，
  不另造第二套 transcript 或时间线。
- Question、Permission、Plan 以及新的时间线事件由 Host 明确提供事实，客户端
  不从问号、文本内容或工具耗时推断。
- 队列和 draft 等纯 View 状态由客户端按 endpoint 与 Session 隔离。
- 在能力不支持、连接中断、上传失败或事件字段不完整时，按字段安全降级。
- 保持 protocol 2.0，通过 capability 协商增量支持新能力。

## 非目标

本 RFC 不包含：

- Desktop UI 或 Terminal View 的改造；
- model、thinking、mode、feature 或 Agent profile 选择；
- Rewind、Fork、删除或改写远端历史；
- Host 跨设备同步的消息队列或 CRDT 队列；
- 打开远端 Workspace 文件、远端文件编辑或文件 diff；
- voice、dictation、上下文窗口百分比、cost meter；
- 与 View 无关的 provider、Session 生命周期或权限策略重构。

## 总体设计

```text
Provider transcript / Host state
              │
              ▼
       normalized agent events
              │  agent / agent.history
              ▼
       iOS / Web transport model
              │
              ▼
       Agent View projection
        ├── timeline blocks
        ├── interaction cards
        ├── turn metadata
        └── local composer state

       local only: queue / draft / upload progress
```

Host 负责 Agent 的事实和生命周期；客户端负责把事实投影成 View，并管理尚未
交给 Host 的本地输入。新的 Host 请求只负责明确的 View 交互，例如提交回答、
停止 turn 或完成附件上传，不应让客户端承担 provider 解析。

### 责任边界

| 状态或行为 | 责任方 | 规则 |
| --- | --- | --- |
| Agent 事件、`agent.status`、`agent.turn`、history | Host/Transport | Host 是事实来源；客户端只合并和展示 |
| Question/Permission 的 pending/resolved | Host | 使用稳定 `requestId`；客户端不根据本地点击直接宣告完成 |
| Plan/Todo/Activity/Plugin/Subagent 详情 | Host 事件投影 | 只展示 Host 提供的字段；未知类型安全忽略 |
| 当前 turn 的 cancel/interrupt | Host | 由 Host 返回接受/失败，并以最终 turn 状态为准 |
| 附件上传会话 | Host/Transport | 返回 opaque ID；客户端不构造远端路径或 URL 作为身份 |
| 排队消息 | iOS/Web 各自的 View model | 本期不跨设备同步，不写入远端 transcript |
| composer draft | iOS `IOSLocalStore` / Web 本地存储 | 按 endpoint identity + Session 隔离 |
| Copy、队列编辑、队列排序 | 客户端 | 只影响本地 View 状态或系统剪贴板 |
| 用户消息编辑后重发 | 客户端调用现有发送路径 | 生成新消息，不修改历史记录 |

### 事件合并原则

1. 以 `epoch + seq` 确定事件流位置；Warren Swift model 中的 `sequence` 继续
   映射 wire 字段 `seq`。
2. 事件按序列号排序，不按 provider timestamp 排序。timestamp 只用于展示。
3. `id` 是同一结构化对象后续更新的稳定身份；每次更新仍有新的 `seq`。
4. history 与 live batch 使用同一事件模型。重连先按 `epoch` 判断是否需要清空
   projection，再用现有 history anchor 补齐。
5. 结构化事件更新发送完整 payload；不要求客户端对任意 JSON 做增量合并。
   现有 `contentDelta` 语义只用于已有文本事件。
6. 客户端必须保留未知事件对序列推进的影响，但可以不渲染未知事件。未知字段
   不能导致旧客户端解码失败。
7. UI identity 应由 `epoch`、`seq` 和稳定 `id` 共同构成，避免 live 事件被
   history 版本替换时出现跳动或重复行。

## Capability 协商

继续使用 protocol 2.0 的 capability 字段，不做主版本升级。第一批 capability
名称如下：

| Capability | 表示的能力 |
| --- | --- |
| `agent-timeline-v1` | 新的结构化 Agent 事件可出现在 `agent` 和 `agent.history` |
| `agent-interactions-v1` | `question`/`permission` 卡片及 `agent.interaction.respond` |
| `agent-interrupt-v1` | `agent.turn.interrupt`，包括可选的原子 interrupt + send |
| `agent-attachments-v1` | attachment prepare/chunk/complete/abort 及带附件发送 |

capability 通过现有认证/hello 协商字段声明，客户端只使用 Host 和客户端共同
支持的能力。未知 capability 忽略；缺少 capability 时：

- 不显示不可执行的交互按钮；
- 已收到的结构化事件可以降级为只读详情，不能伪造提交入口；
- 不把 PTY 的 Ctrl-C、问号、工具等待时间等当作 interrupt 或 interaction 的
  协议替代品。

普通文本在没有新 capability 时继续走现有 Agent 输入路径。带附件的消息、
`Send now` 和结构化 interaction 必须走对应的新契约，不能混用两个路径造成
重复发送。

## 结构化 Agent 事件

沿用现有 `agent` 消息和 `agent.history`：

```json
{
  "t": "agent",
  "session": "session-1",
  "epoch": 4,
  "events": [
    {
      "seq": 123,
      "turn": 7,
      "id": "question-42",
      "provider": "codex",
      "type": "question",
      "timestamp": "2026-08-31T10:00:00Z",
      "payload": {}
    }
  ]
}
```

已有公共字段（`seq`、`turn`、`id`、`provider`、`type`、`timestamp`）继续保留；
新事件增加可选的 JSON object `payload`。具体实现可以在 Swift/Go/TypeScript
中使用类型化结构，但 wire 上必须保留未知字段可跳过的兼容性。

第一批事件定义如下：

| `type` | payload 最小字段 | View 表现 |
| --- | --- | --- |
| `question` | `requestId`、`title`、`questions[]`、`state` | Question card；支持单选、多选、自定义回答、提交和取消 |
| `permission` | `requestId`、`title`、`description`、`action`、`options[]`、`state` | Permission card；展示脱敏后的工具/动作摘要和允许的选项 |
| `plan` | `planId`、`title`、`items[]`、`state` | 可折叠 Plan；条目有 `pending`、`in_progress`、`completed`、`cancelled` |
| `todo` | `todoId`、`items[]`、`state` | Checklist 或 Plan 内的 Todo 进度 |
| `activity` | `activityId`、`label`、`state`、可选 `detail` | 时间线中的活动/进度行 |
| `plugin` | `pluginId`、`name`、`state`、可选 `summary` | Plugin 活动卡片或折叠行 |
| `subagent` | `subagentId`、`label`、`state`、可选 `summary` | 子 Agent 摘要行；不在本期展开独立 Session UI |
| `attachment` | `attachmentId`、`name`、`mime`、`size`、`state` | 消息或活动中的附件行 |

### Question payload

`questions[]` 至少支持以下字段：

```json
{
  "id": "q1",
  "prompt": "Which option should be used?",
  "options": [
    { "id": "a", "label": "Option A", "description": "..." }
  ],
  "selection": "single",
  "required": true,
  "allowCustom": true
}
```

`selection` 为 `single` 或 `multiple`。客户端按 Host 给出的选项和约束校验，
不能从自然语言重新解析问题，也不能在没有 `requestId` 时生成回答。

### Permission payload

Permission 的 `action` 只放可向用户展示的脱敏摘要，例如工具名、动作标题和
有界的说明；命令参数、token、文件内容等敏感信息由 Host 在事件生成前过滤。
`options[]` 由 Host 决定，客户端不自行增加 `allow` 或 `deny` 选项。

`plan`、`todo`、`activity`、`plugin` 和 `subagent` 都是只读事件。本 RFC 不
要求客户端编辑它们，也不允许客户端从 tool call 的等待时间推导这些事件。

## 七项功能设计

### 1. Question / Permission / Plan

#### Question

- iOS 使用 SwiftUI card/sheet；Web 使用可键盘操作的 card/dialog。
- 支持一个请求包含多个问题，并保留单选、多选、自定义回答和分页能力。
- card 显示 `pending`、`submitting`、`resolved`、`cancelled` 或 `failed` 状态。
- 提交后先显示 `submitting`；只有收到 Host 的响应事件或明确的失败响应才改变
  最终状态。
- 取消也是结构化响应，不向 PTY 写入自然语言，不把取消误显示成 Agent error。

#### Permission

- 显示请求标题、脱敏动作摘要、必要的说明和 Host 提供的 action options。
- 允许用户明确选择一次允许、持续允许、拒绝或其他 Host 声明的选项；具体 label
  和决策值以 payload 为准。
- pending permission 置于时间线可见区域，并在 Agent status 的 `attention` 为
  `approval` 时保持可发现。
- 用户打开 Session 不自动清除 pending permission。

#### Plan

- Plan 使用稳定 `planId`，更新同一 Plan 时不产生重复卡片。
- 条目按 Host 的顺序显示，状态只由事件驱动；客户端不按文本判断完成。
- iOS 默认折叠，Web 可使用紧凑条或侧边/顶部折叠区域，但不要求固定侧栏。
- Plan 的展开、折叠、跳转都是 View 操作，不改变 Agent 执行状态。

#### 交互响应请求

所有 Question/Permission 响应使用同一个请求：

```json
{
  "t": "request",
  "id": "request-1",
  "method": "agent.interaction.respond",
  "params": {
    "session": "session-1",
    "requestId": "question-42",
    "kind": "question",
    "response": {
      "answers": {
        "q1": ["a"]
      }
    }
  }
}
```

Permission 的 `response` 使用 payload 声明的 decision/action ID；Question 的
`response` 使用问题 ID 到选项 ID/自定义文本的映射。请求必须可幂等或能安全
拒绝重复 `requestId`。过期请求返回失败并要求客户端刷新 history，客户端不能
乐观地把旧卡片标为已解决。

### 2. Cancel / Interrupt

新增语义化请求：

```json
{
  "t": "request",
  "id": "interrupt-1",
  "method": "agent.turn.interrupt",
  "params": {
    "session": "session-1",
    "turn": 7,
    "reason": "cancel"
  }
}
```

`reason` 至少支持 `cancel` 和 `send_now`。请求可以带可选的
`replacement`：

```json
{
  "reason": "send_now",
  "replacement": {
    "clientMessageId": "message-9",
    "text": "Use the other approach.",
    "attachments": []
  }
}
```

规则如下：

- `cancel` 停止当前 turn，保留已产生的事件和客户端本地队列。
- Agent 工作中普通发送仍进入队列，不隐式 interrupt。
- `send_now` 必须由 Host 原子完成“停止当前 turn + 接受 replacement”。成功或
  失败都必须明确返回；客户端不能用两个独立请求模拟该动作。
- replacement 被 Host 接受前，队列项保持可恢复；超时不能当作已发送。
- 最终 UI 以 `agent.turn`、`agent.status` 和事件回放为准，不以本地按钮点击
  直接把 Agent 改成 ready。
- 没有 `agent-interrupt-v1` 时隐藏 Cancel/Send now；队列控制只能提供排序和
  “下一个发送”，不能把它命名为 `Send now`。

iOS 可将 Cancel 放在 composer 的工作态按钮；Web 可放在 composer 内或 turn
footer。两端都必须防止重复点击造成多个 interrupt request。

### 3. 附件上传

#### 客户端入口

- iOS：`PhotosPicker` 和 `fileImporter`。
- Web：`<input type="file">`、拖放和粘贴入口（浏览器能力允许时）。

两端使用同一组本地状态：`selected`、`uploading`、`ready`、`failed`、
`aborted`。composer 显示文件名、大小、MIME、进度、失败原因和重试/移除操作。

#### 上传生命周期

```text
agent.attachment.prepare
          │  attachmentId / uploadId / chunk policy
          ▼
       binary chunks
          │
agent.attachment.complete  ──► ready attachment reference
          │
agent.attachment.abort     ──► aborted
```

`prepare` 至少接收：文件名、MIME、大小、hash（若客户端可计算）。返回
opaque `attachmentId`、`uploadId`、允许的 chunk 大小、过期时间和服务端限制。
chunk 必须带 `uploadId`、序号、长度和校验信息；同一序号重试不能产生重复数据。
`complete` 校验服务端收到的长度/hash，失败时客户端可重试或 abort。

上传控制可以复用现有认证的 WebSocket binary 通道，或由 Host 返回认证后的
HTTP 上传地址；这属于 Transport 实现选择，但 View model 只能看到统一的
prepare/progress/complete/failed 状态。

消息发送使用 opaque 引用：

```json
{
  "method": "agent.message.send",
  "params": {
    "session": "session-1",
    "clientMessageId": "message-9",
    "text": "Please inspect these files.",
    "attachments": [
      { "attachmentId": "att-1", "name": "report.pdf", "mime": "application/pdf" }
    ]
  }
}
```

带附件的消息必须在 attachment 为 `ready` 后发送。Host 返回接受确认，之后
由 `user`/`attachment` 事件进入时间线。客户端不把大文件内容、临时路径或本地
token 放进消息和 draft；上传中的附件不能被当作已发送。

第一版 draft 只强制持久化文本。已完成附件引用若能安全恢复可以一起保存，未
完成上传和本地临时文件不得持久化；否则恢复 draft 时只恢复文本并提示附件需
重新选择。

### 4. 新的结构化协议事件

`agent-timeline-v1` 下，上一节定义的 `question`、`permission`、`plan`、
`todo`、`activity`、`plugin`、`subagent`、`attachment` 都可同时出现在 live
batch 和 history page。两端必须：

- 用同一 reducer 处理 live/history，避免刷新后卡片形态不同；
- 对同一稳定 ID 的更新替换投影，不重复绘制；
- 对未知 `type` 保持 sequence 前进并跳过渲染；
- 允许字段缺失，按字段隐藏，而不是用空值或推断内容填充；
- 不把 reasoning、tool input/output、system marker 混入 assistant copy。

`agent.status` 仍是轻量摘要：`blocked + attention=input/approval` 可以帮助
客户端定位未解决的卡片，但 status 本身不是 Question/Permission 的详细数据。
客户端必须从事件取得 `requestId` 和表单内容。

### 5. 排队消息管理

队列是 iOS/Web 各自的本地 View 状态，不作为 Host transcript 或跨端数据。每
个队列项至少包含：

```text
id                  客户端生成的稳定 ID
text               文本
attachments        已完成或上传中的 opaque 引用
createdAt          本地创建时间
status             queued | sending | failed
```

队列 key 为 `endpointIdentity + sessionID`。endpoint identity 必须能区分不同
Host/账号，但不能使用 token 本身作为 UI key。

行为要求：

- Agent `working` 时发送普通消息进入 FIFO 队列；不会打断当前 turn。
- 队列入口显示数量，点击后能查看完整文本和附件状态。
- 用户可以编辑、删除、拖动排序；iOS 提供移动到队首的操作，Web 支持拖放
  排序。编辑必须按稳定 item ID 定位，不能因排序更新错消息。
- 删除需要确认（至少对已有附件或较长文本如此），发送中的 item 不允许静默
  删除。
- Agent ready 后按队列顺序发送；成功得到 Host 接受确认后才移除。
- 发送失败保留 item 和失败原因，支持重试；重试复用 `clientMessageId` 或
  明确生成不会重复投递的幂等 ID。
- 当 Agent working 且存在 `agent-interrupt-v1` 时，可以对某一项显示 `Send
  now`，它必须走原子 interrupt + replacement。没有该 capability 时只能
  “Move to front”，下次 ready 后发送。
- 切换 Session 时不能把队列消息带到另一 Session；断线重连不丢本地队列，也
  不应在 Host 是否已接受不确定时自动重复发送。

本 RFC 不要求进程重启后恢复队列。若未来要持久化队列，必须另行定义附件
生命周期、幂等投递和隐私策略，不能把当前 draft 存储顺手升级成远端队列。

### 6. 草稿持久化

draft 是 composer 的设备本地便利状态，不是 Agent 消息记录。逻辑 key 为：

```text
warren.agent-draft.<endpoint-identity>.<session-id>
```

要求：

- 进入同一 endpoint/Session 时恢复文本；切换 Session 不串 draft。
- 输入变化使用短 debounce 保存；iOS 在 scene 进入 background 时 flush，Web
  在 `pagehide` 或 visibility change 时 flush。
- 提交到发送路径或本地队列后清空 composer draft；队列项保留自己的文本副本。
- 设定并记录文本上限（建议 64 KiB）；超过上限时保留 live editor 内容，但
  不写入持久化存储，并给出非阻塞提示。
- Session 被删除或本地身份失效时清理对应 draft。
- 持久化失败不能阻塞当前编辑和发送；下次恢复为空或最近一次成功保存的值。
- 不保存 endpoint token、完整 transcript、远端文件内容、本地临时文件和未完成
  上传。

实现建议：

- iOS 使用 `IOSLocalStore` 和 `UserDefaults`，由 `IOSApplicationModel` 提供
  按 endpoint/Session 的读写 API。
- Web 使用现有应用存储边界；小文本可用 `localStorage`，若需要附件引用和
  版本字段则使用 IndexedDB。认证 token 不得因为 draft 持久化而迁移到明文存储。

### 7. 消息操作

本 RFC 将“消息操作”限定为不改写远端历史的 View 操作：

| 对象 | 操作 | 语义 |
| --- | --- | --- |
| User message | Copy | 只复制用户文本；不复制内部事件和附件原始内容 |
| Assistant turn | Copy | 只复制该 turn 的 assistant prose；排除 reasoning、tool input/output、system marker 和 metadata |
| 最后一个已提交的 User message | Edit & resend | 打开编辑器，以新 `clientMessageId` 重新发送；旧消息保留 |
| 本地发送失败的 message | Retry | 重试未被 Host 接受的发送；不重放已确认消息 |
| queued message | Edit/Delete/Reorder | 见队列章节，只操作本地未交付项 |

iOS 使用系统 pasteboard；Web 使用 Clipboard API，并在权限失败时保留可选的
手动复制降级。复制操作只写入剪贴板，不读取已有剪贴板内容。成功后显示短暂
的本地确认，不改变 Agent status。

编辑重发不支持修改任意历史消息，也不包含 Rewind/Fork。正在 streaming 的
assistant turn 可以复制当前已显示内容，但不能宣称其已经完成。

## iOS 与 Web 的呈现差异

语义和状态必须一致，控件形态可以平台化：

| 场景 | iOS | Web |
| --- | --- | --- |
| Interaction | SwiftUI card、sheet、confirmation dialog | React card、dialog、键盘导航 |
| Composer | `TextEditor`、键盘 accessory、scene lifecycle | textarea、快捷键、`pagehide`/visibility lifecycle |
| Attachment | `PhotosPicker`、`fileImporter`、系统权限 | file input、拖放、粘贴 |
| Queue | sheet/list、长按或 swipe 编辑/删除/排序 | popover/panel、drag-and-drop、快捷操作 |
| Copy | `UIPasteboard` | `navigator.clipboard` |
| Draft store | `IOSLocalStore`/`UserDefaults` | `localStorage`/IndexedDB |
| 窄屏策略 | 不增加常驻侧栏；Plan/Queue 用 sheet | 可用紧凑 panel，但不能改变事件和队列语义 |

两端都需要支持 Dynamic Type/浏览器字体缩放、VoiceOver/屏幕阅读器、键盘焦点、
高对比度和明确的 loading/failed 状态。图标按钮必须有可访问名称；卡片的
pending/resolved 状态必须对辅助技术可见。

## 状态、兼容与失败恢复

### 状态机

```text
Interaction: pending → submitting → resolved
                         └────────→ cancelled / failed

Upload:      selected → uploading → ready
                                  └→ failed → uploading
                                  └→ aborted

Queue:       queued → sending → delivered
                    └────────→ failed → queued (retry)

Turn:        ready → working → blocked → ready
                    │          └──────→ interrupted → ready
                    └────────────────→ completed / failed / aborted
```

状态机中的最终 Agent 状态由 Host 事件确认。网络失败、请求超时或客户端重启
不能被客户端单方面解释为 Host 已完成操作。

### 兼容规则

- 旧 Host 不认识新请求时返回明确错误；客户端隐藏相应控件并保持普通文本路径。
- 旧客户端收到新事件时忽略未知 `type`/`payload`，仍可继续处理已知事件和
  `seq`，不能因解码失败断开连接。
- 缺少 `turn` 时使用稳定的本地 event/block identity，绝不因为文本相同而合并
  不相关事件。
- 缺少或非法 timestamp、duration、usage、files 时只隐藏对应字段；不显示
  0、空卡片或伪造的 stopwatch。
- 重连发现 epoch 改变时清空远端事件 projection 并重新拉 history；draft、队列
  和当前上传状态是独立的本地状态，按各自失败策略恢复。
- interaction response 过期时保留事件中的 pending/resolved 事实，提示用户刷新；
  不删除本地队列。
- attachment 过期时允许重新 prepare；原始本地文件不可用时显示失败并要求重选。

## 安全与隐私

- Permission/action 的敏感参数由 Host 脱敏；客户端不根据原始 transcript 自行
  生成允许/拒绝按钮。
- 上传前后都校验大小、MIME、文件名、hash、chunk 序号和服务端配额；禁止通过
  文件名或路径形成远端文件身份。
- attachment ID、upload ID、client message ID 都是不透明标识；日志和 UI 不
  打印 token、签名上传 URL 或完整文件内容。
- draft、队列和上传临时状态不保存认证 token。浏览器存储遵循现有同源和清理策略。
- Copy 不读取用户已有剪贴板；Permission 的默认操作不能是自动允许。
- 取消、interrupt、上传 abort 和 interaction cancel 都必须检查 Session/turn/
  requestId 所属关系，防止旧 View 操作影响新 turn。

## 分阶段实施

### Phase 1：契约和事件基础

- 在 Headless/Transport 中补齐 capability、`payload` 解码和结构化事件模型。
- 为 `agent.history`、live batch 和重连回放增加相同的事件覆盖。
- 加入 `agent.interaction.respond`、`agent.turn.interrupt` 的请求/响应模型。
- 先用 contract tests 固定序列号、稳定 ID、未知事件和幂等错误语义。

### Phase 2：iOS/Web 共同 View 语义

- 建立跨端对齐的事件 reducer、interaction 状态、turn metadata 和 accessibility
  文案。
- 加入 Question/Permission/Plan/Todo/Activity/Plugin/Subagent/Attachment 的
  基础呈现，以及 status 与 pending card 的关联。
- 为 copy、edit & resend、retry 建立统一 action 规则。

### Phase 3：interrupt、附件和 composer

- 实现 cancel、原子 `Send now` 和失败恢复。
- 实现 prepare/chunk/complete/abort 及 iOS/Web 上传入口。
- 将 composer 抽象为 text-only fallback 与 structured message send 两条明确路径。

### Phase 4：本地状态和验收

- iOS/Web 队列查看、编辑、删除、排序、失败重试和 Session 隔离。
- iOS/Web draft debounce、background/pagehide flush、大小限制和清理。
- 完成窄屏、键盘、辅助功能、重连和能力缺失场景的验收。

## 验收标准

1. iOS 和 Web 都能展示 Question、Permission、Plan；Question/Permission 能提交
   或取消，最终状态来自 Host 事件，Plan 更新不重复。
2. Agent working 时可 Cancel；有 `agent-interrupt-v1` 时 `Send now` 使用一次
   原子 interrupt + send；无 capability 时不显示该操作。
3. iOS 和 Web 都能选择/拖放附件，看到进度和失败重试，完成后以 opaque reference
   发送；不会把临时路径或文件内容写入消息/draft。
4. 新结构化事件能通过 live batch 和 history 回放，旧客户端遇到未知事件不崩溃，
   新客户端遇到未知事件安全跳过。
5. 队列消息能查看完整内容、编辑、删除、排序、移到队首和失败重试；编辑/排序
   不会打断 working Agent，队列按 Session 隔离。
6. draft 能按 endpoint/Session 恢复、debounce 保存、background/pagehide flush，
   提交后清空且不跨 Session 泄漏。
7. 用户消息和 assistant turn 可分别复制；最后一个用户消息可编辑后以新消息重发；
   不提供隐含的历史改写、Rewind 或 Fork。
8. 现有对话、tool/reasoning 展示、history pagination、streaming follow、
   return-to-latest 和 Agent/Terminal 切换不回归。
9. 不增加 Desktop UI，不因本 RFC 引入 model/profile 控制、远端队列同步或远端
   文件编辑。

## 验证计划

- Headless contract tests：capability 交集、事件 payload、history/live 一致性、
  requestId/clientMessageId 幂等、interrupt 原子性、上传 chunk 校验。
- Transport tests：新旧事件解码、未知字段/类型、epoch/sequence 恢复和错误映射。
- iOS unit/UI tests：interaction reducer、Plan 更新、队列 edit/delete/reorder、
  draft 隔离与 flush、pasteboard、Dynamic Type、VoiceOver labels、附件失败恢复。
- Web tests：事件 projection、Clipboard API fallback、drag/drop、local storage
  隔离、pagehide flush、队列状态机和 responsive/keyboard interaction。
- 手工验证至少覆盖：Host 缺 capability、断线重连、旧 Host、旧客户端、过期 upload、
  过期 interaction、working Agent 的普通发送与 Send now、Session 快速切换。

## 后续事项

以下不属于本 RFC 的交付验收范围：Desktop 对齐、Rewind/Fork、远端文件打开、
远端队列/CRDT、model/thinking/mode 控制、上下文窗口/cost 统计和 voice mode。
若这些能力需要新的 Host 语义，应分别提交 RFC。
