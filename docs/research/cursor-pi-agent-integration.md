# JoyHarness 接入 Cursor Agent 与 Pi Agent 的可行性调查

调查日期：2026-08-23

## 结论

本文把用户所说的 `COS` 理解为仓库当前实际支持的 **Codex Desktop / Codex Micro**。仓库中没有 `COS` 产品或协议；当前 Codex 链路由 Codex Micro Vendor HID 执行动作，`codex app-server --stdio` 只读任务名称和顺序。JoyHarness 已移除旧的 Codex hooks/`notify` 生命周期集成，保留的是通用 Unix socket、状态文件和本地 CLI 诊断入口。

结论分三层：

1. **原样复用：不行。** Cursor Agent 和 Pi Agent 都不识别 Codex Micro Vendor HID，也没有 `AG00`-`AG05`、`ACT07`、`ACT08`、`ACT10` 等 Codex Micro 动作。现有 RP2040 固件不能直接替它们完成槽位切换、批准、拒绝、打开任务或按住说话。
2. **只接状态与震动：都可行，改动较小。** Cursor 可用 hooks 或 `stream-json`；Pi 可用 extension 或 JSON event stream，把 busy/waiting/done/error 送入 JoyHarness 现有 Unix socket。
3. **实现类似的完整手柄工作流：都可行，但必须让 JoyHarness 托管 agent 协议。** Cursor 推荐 `agent acp`；Pi 推荐 `pi --mode rpc`，需要同时管理六个活跃会话时再使用 Pi SDK 做 sidecar。手柄动作应由 JoyHarness 直接转换为协议命令，不再绕行 Codex Micro HID。

综合判断：

| 目标 | Cursor Agent | Pi Agent |
| --- | --- | --- |
| 状态震动 PoC | 高，可用 hooks/`stream-json` | 高，可用 extension/JSON events |
| 双向会话控制 | 高，ACP 是 stdio JSON-RPC | 高，RPC 是双向 JSONL，SDK 可嵌入 |
| 手柄批准/拒绝 | **高，ACP 原生 `session/request_permission`** | 中，需要 extension 自建审批闸门 |
| 六槽会话列表 | 高，当前 ACP 声明并实现结构化 `session/list`；仍须按 capability 协商 | 高，session 文件/SDK 可枚举；实验性 server protocol 也有 `list` |
| 安全边界 | 有权限规则、sandbox 和 ACP 审批 | 官方明确无内置权限系统/沙箱 |
| 原有 Codex Desktop UI / PTT | 不可复用 | 不可复用 |

因此，若先追求“像现有 Codex 一样用手柄批准/拒绝”，建议先做 **Cursor ACP 单槽 PoC**；若更重视开源、可定制和六会话托管，Pi 的 SDK/RPC 更适合作为长期 provider，但必须先定义审批超时、默认拒绝和 OS 级隔离策略。

## 当前 Codex 集成的真实基线

JoyHarness 当前不是一个通用 agent 控制器：

- [`README.md`](../../README.md) 明确说明任务槽、审批、打开任务和 PTT 最终由 RP2040 的 `Codex Micro` Vendor HID 送给 Codex Desktop。
- [`CodexThreadProvider.swift`](../../Sources/JoyHarness/CodexThreadProvider.swift) 启动 `codex app-server --stdio`，只调用 `initialize` 和 `thread/list` 获取最近六个任务的 ID、标题与状态。
- [`SocketServer.swift`](../../Sources/JoyHarness/SocketServer.swift) 与本地 CLI 提供通用 Unix socket 状态/诊断入口；它们当前不从 Codex 自动接收任务生命周期。
- [`ButtonBridge.swift`](../../Sources/JoyHarness/ButtonBridge.swift) 的 agent 动作仍是 `microKey` 字符串，槽位是 `AG00`-`AG05`；批准、拒绝、PTT 等由 Codex Micro action code 表达。

这意味着适配新 provider 时可复用的部分是 GameController 输入、按键映射 UI、槽位概念、Unix socket、状态文件和震动；需要新增的是 provider 会话/事件适配器与软件动作出口。现有 `CodexThreadProvider`、`microKey` 和 RP2040/Codex Micro 路径应作为 Codex provider 保留，而不是让 Cursor 复用其控制语义。

## 分层能力对比

| 能力层 | Cursor Agent | Pi Agent | 对 JoyHarness 的影响 |
| --- | --- | --- | --- |
| 通用手柄输入 | Agent 本身不读取手柄 | Agent 本身不读取手柄 | 继续由 macOS `GameController` 读取；agent 动作改走 provider adapter |
| 状态与震动 | hooks 可观察 session/tool/stop；`stream-json` 和 ACP 有结构化事件 | extension 有 agent/tool/session 事件；JSON/RPC 输出完整生命周期事件 | 可统一映射 `idle/busy/waiting/done/error` |
| 会话列表/恢复 | CLI 支持 `ls`、`resume`、`--resume=<id>`；当前 ACP 还声明 `sessionCapabilities.list`，可用分页 `session/list` 发现并以 `session/load` 恢复 | 会话保存在按 cwd 组织的 JSONL；CLI、SessionManager、RPC `switch_session` 均可恢复 | Cursor 与 Pi 都可构建结构化槽位；Cursor 必须先协商 capability，并缓存自己正在控制的 active session |
| 审批控制 | ACP 原生请求 `session/request_permission`，客户端从服务端给出的 options 中选择；但协议不保证每次工具调用都发审批请求 | 无内置权限系统；extension 的异步 `tool_call` 可在执行前 block | Cursor 能直接复刻交互式 approve/deny，但静态 deny 与 sandbox 仍是安全底线；Pi 需自研待决请求表和策略 |
| 六槽并行 | ACP 设计允许一条连接承载多个并发 session；Cursor 六 prompt 并发仍需压测，必要时按槽拆进程 | 一个 RPC 进程控制一个当前 session，可用六进程；SDK 可在一个 sidecar 中创建多个 `AgentSession` | 槽位变为 JoyHarness 自己维护的 provider session，不再等同桌面 UI 槽位 |
| PTT/语音 | 无公开的本地 PTT agent 协议 | 无公开的本地 PTT agent 协议 | `ACT10` 不能复用；需另做 macOS 录音/转写，再以 prompt 提交 |

### 通用输入

两者都可以继续使用当前 DualSense/Xbox 输入层，但必须新增逻辑动作，例如 `approvePermission`、`rejectPermission`、`cancelRun`、`selectProviderSession` 和 `submitPrompt`。直接继续发送 `ACT07`/`ACT08` 只会让 RP2040 向 Codex Desktop 发 HID 报告，对 Cursor/Pi 没有效果。

RP2040 仍可保留为 Codex provider 的输出设备，或未来重新定义为 JoyHarness 可读取的通用输入设备；这属于固件协议变更，不是 Cursor/Pi CLI 配置能解决的问题。

### 状态震动

Cursor hooks 是双向 JSON stdio 脚本，覆盖 `sessionStart`、`sessionEnd`、`preToolUse`、`postToolUse`、`postToolUseFailure`、`stop` 等事件，适合把事件映射到 JoyHarness 现有 Unix socket 状态入口。所有 agent hook 都带跨多轮稳定的 `conversation_id`，`sessionStart.session_id` 与它相同，因此旁路适配器可识别和关联**已经触发过 hook** 的会话；但 hooks 是事件流，不是冷启动时的会话枚举 API。`agent -p --output-format stream-json` 也会输出 system、user、assistant、tool call/result 和最终 result 事件，但它是一次性 headless run，更适合脚本任务而不是长期交互控制。

命令 hooks 默认失败放行：脚本崩溃、超时或输出无效 JSON 时，动作仍会继续。安全相关 hook 必须配置 `failClosed: true`。用户级 hooks 不会进入 Cloud Agent，云端早期只读阶段也不运行 hooks，因此本地旁路不能被表述为覆盖 Cursor Cloud Agent 的完整控制面。

来源：

- [Cursor Hooks 官方文档](https://cursor.com/docs/hooks)
- [Cursor CLI 输出格式](https://cursor.com/docs/cli/reference/output-format)
- [Cursor CLI Headless / CI](https://cursor.com/docs/cli/headless)

Pi 的 `--mode json` 输出 session header、`agent_start/end`、`turn_start/end`、message delta 和 `tool_execution_start/update/end` 等 JSONL 事件。保留现有 Pi TUI 时，extension 还能监听相同的 agent/tool/session 生命周期并把状态写入 JoyHarness socket。

来源：

- [Pi JSON Event Stream Mode](https://pi.dev/docs/latest/json)
- [Pi Extensions：事件生命周期](https://pi.dev/docs/latest/extensions)

### 会话列表与槽位

Cursor CLI 官方支持 `agent ls`、`agent resume`、`--continue` 和 `--resume=<chat-id>`；`agent create-chat` 可创建并返回 ID。更重要的是，本机 `agent 2026.08.11-e8db854` 的 ACP `initialize` 响应明确返回 `sessionCapabilities.list: {}`，实际 `session/list` 请求也成功。稳定版 ACP v1 定义了结构化 `session/list`：可按绝对 `cwd` 过滤、用不透明 cursor 分页，并返回 `sessionId`、`cwd`、可选 `title` 与 `updatedAt`；选择后再用 `session/load` 恢复。

因此 Cursor 六槽不再需要只靠 JoyHarness 自建 chat ID 台账。实现应在每次启动时读取 `initialize` 的 capability：有 `sessionCapabilities.list` 才调用 `session/list`，无则降级为仅展示本次由 JoyHarness 创建/观察到的会话。仍不应扫描 `~/.cursor/chats` 等内部文件。当前一手资料没有承诺返回集合一定横跨 Cursor Desktop、交互 CLI、headless 与所有工作区，所以“列出该 agent 已知 session”不能扩大解释成“Cursor 全产品全量 recent chats”。

来源：

- [Cursor CLI Overview：Sessions](https://cursor.com/docs/cli/overview#sessions)
- [Cursor CLI Parameters](https://cursor.com/docs/cli/reference/parameters)
- [Cursor ACP：Sessions](https://cursor.com/docs/cli/acp#sessions-modes-and-permissions)
- [ACP v1 Session List（官方规范）](https://agentclientprotocol.com/protocol/session-list)
- [ACP 官方源码：Session List（调查提交）](https://github.com/agentclientprotocol/agent-client-protocol/blob/1c00740ec19622527f2483a95ea15ddb7604885c/docs/protocol/v1/session-list.mdx)
- [ACP 官方架构：每条连接可承载多个并发 session（调查提交）](https://github.com/agentclientprotocol/agent-client-protocol/blob/1c00740ec19622527f2483a95ea15ddb7604885c/docs/get-started/architecture.mdx)

Pi 会话原生保存为 `~/.pi/agent/sessions/` 下按工作目录组织的 JSONL，并支持 `-c`、`-r`、`--session <path|id>`、命名、fork 和 clone。RPC 可 `get_state`、`switch_session`、`set_session_name`，SDK 的 `SessionManager` 可 list/open/create 会话，因此更容易实现六槽列表。

Pi 0.84.2 还发布了实验性的 `@earendil-works/pi-protocol`、`pi-server` 和 `pi-client`：协议已有 `list/create/attach/prompt/steer/abort`、多 session snapshot 和 Unix socket transport，形状非常接近 JoyHarness 所需控制面。但官方同时声明协议无兼容保证、server 不提供现成 CLI/coding-agent service，应用必须自己实现 `PiServerService`，所以不建议第一版直接依赖。

来源：

- [Pi Sessions](https://pi.dev/docs/latest/sessions)
- [Pi RPC Mode](https://pi.dev/docs/latest/rpc)
- [Pi SDK](https://pi.dev/docs/latest/sdk)
- [Pi protocol README（固定调查提交）](https://github.com/earendil-works/pi-mono/blob/a69bef789bc95abf0acee16f7b4660b70b650bb9/packages/protocol/README.md)
- [Pi server README（固定调查提交）](https://github.com/earendil-works/pi-mono/blob/a69bef789bc95abf0acee16f7b4660b70b650bb9/packages/server/README.md)

### 审批控制

Cursor 的完整方案应使用 ACP。`agent acp` 在 stdio 上运行换行分隔的 JSON-RPC 2.0；标准流程包含 `initialize`、认证、`session/list`/`session/new`/`session/load`、`session/prompt`、流式 `session/update`，权限请求通过 `session/request_permission` 反向调用客户端。JoyHarness 可在收到请求时设置 `waiting`、震动，并让手柄 A/B 选择服务端本次请求实际提供的 allow/reject option；当前 Cursor 常见 option ID 是 `allow-once`、`allow-always`、`reject-once`，实现不能假定每次三者都存在。`session/cancel` 可对应 interrupt。

ACP 托管端不能只实现工具权限。Cursor 还会发两类阻塞扩展请求：`cursor/ask_question` 要求用户回答或跳过问题，`cursor/create_plan` 要求接受、拒绝或取消计划；客户端不响应时 agent 同样会阻塞。`cursor/update_todos`、`cursor/task`、`cursor/generate_image` 是非阻塞通知，可先记录或忽略，但必须正确区分 request 与 notification。第一版至少要为两类阻塞请求提供 JoyHarness UI 或明确的保守取消响应，不能把它们误当作普通状态事件。

Cursor 官方最小客户端在 `initialize` 中把客户端文件读写与终端能力都声明为 `false`，仍可建立 session 和 prompt。这说明 JoyHarness 的 Swift 侧可以保持为窄 ACP 编排器，无需替 Cursor 实现 terminal/filesystem host；实际代码执行仍由 Cursor agent 自己负责。初始化返回的 capability 才是运行时契约，不应仅凭 ACP 规范存在某方法就调用。

本机当前 capability 还显示：支持 `loadSession`、session list 和图片 prompt，不支持音频 prompt，也没有声明 `session/resume`、`session/close`、`session/delete` 或 `additionalDirectories`。因此恢复先用 `session/load` 并处理历史 replay；这组能力随版本协商，不能写死。Cursor ACP 可读取项目级/用户级 `.cursor/mcp.json`，但官方明确不支持 Dashboard 下发的 team-level MCP servers。

Cursor hooks 的 `preToolUse` 能对所有工具直接返回 allow/deny；脚本也可以把 pending request 发给 JoyHarness 后，在自身 timeout 内等待手柄结果，再返回决定。因此 hooks 路线**可以**实现有限的实时手柄审批，不只是通知。不过它不是带 request ID/response 的长期会话协议：`preToolUse` 的 `ask` 当前虽被 schema 接受却不执行，失败默认放行，必须设置合理 timeout、`failClosed: true`，并按 `conversation_id + tool_use_id` 关联并发请求。`beforeShellExecution`/`beforeMCPExecution` 虽支持 `ask`，那是转交 Cursor 原生客户端询问，不等同 JoyHarness 已接管审批。Headless `--force` 会直接放行未显式 deny 的动作，也不应被当作“手柄批准”。

来源：

- [Cursor ACP](https://cursor.com/docs/cli/acp)
- [Cursor Permissions](https://cursor.com/docs/cli/reference/permissions)
- [Cursor Hooks：preToolUse](https://cursor.com/docs/hooks#pretooluse)
- [ACP Tool Calls：permission request 为可选（调查提交）](https://github.com/agentclientprotocol/agent-client-protocol/blob/1c00740ec19622527f2483a95ea15ddb7604885c/docs/protocol/v1/tool-calls.mdx)

Pi 官方明确说明没有内置 permission system 或 sandbox，进程默认拥有启动用户的文件、进程、网络和凭据权限。`--approve` 只表示信任项目本地配置/extension，不是批准每次工具调用。

Pi extension 的 `tool_call` 事件发生在工具执行前，异步 handler 可返回 `{ block: true, reason, terminate }`。因此可实现一个全局 JoyHarness extension：把 tool name/input 和 session ID 发到本地 socket，等待手柄决定后返回继续或 block，并在超时、断连或 JoyHarness 退出时默认 block。这是 JoyHarness 自建审批机制，不是 Pi 原生的 allow-once/always 契约；“永久允许”需要另存策略，且不能把 project trust 当安全沙箱。

来源：

- [Pi Security](https://pi.dev/docs/latest/security)
- [Pi Extensions：tool_call 可阻断](https://pi.dev/docs/latest/extensions#tool-call)
- [Pi 官方 README：Permissions & Containerization（固定调查提交）](https://github.com/earendil-works/pi-mono/blob/a69bef789bc95abf0acee16f7b4660b70b650bb9/README.md#permissions--containerization)

### PTT 与“打开任务”

现有 PTT 是 Codex Desktop 对 `ACT10` 的原生解释，Cursor CLI/ACP 和 Pi RPC/SDK 都没有对应的本地录音开始/结束方法。手柄按住说话若要跨 provider 工作，需要另建语音层：JoyHarness 或独立服务录音、转写，松开后将文本作为 `session/prompt`/RPC `prompt` 提交。该方案还要处理麦克风权限、取消、空转写和录音状态，不能计入第一阶段的“直接兼容”。

“打开任务”同样不能再表示双击 Codex Micro 槽位。ACP/RPC 托管模式下应改为切换 JoyHarness 自己的会话详情；若希望跳到 Cursor Desktop 或 Pi TUI，必须另行确认官方 deep link/attach 能力，当前一手资料不足以承诺。

## 两种 Cursor 接入路线

### 路线 C1：hooks + stream-json，先做状态适配

适用：保留用户现有 Cursor CLI/编辑器习惯，只要求震动和控制台状态。

1. 安装用户级 Cursor hooks，将 session/tool/stop 事件映射到现有 socket。
2. 对由 JoyHarness 启动的 headless task，解析 `stream-json` 获得更细的 tool/result/error 状态。
3. 若要手柄审批，让 `preToolUse` hook 通过本地 socket 等待 `allow`/`deny`，按 `conversation_id + tool_use_id` 匹配，配置超时和 `failClosed: true`。
4. hooks 只登记观察到的会话；冷启动列表优先另开 ACP 进程调用 `session/list`，不能从 hook 事件反推出完整历史。

优点是改动小、能保留 Cursor Desktop/CLI 的现有交互界面；缺点是仍没有 prompt/cancel/load 的统一双向所有权，审批脚本受 hook 超时和生命周期约束，也不能处理 ACP 的问题/计划交互。

### 路线 C2：ACP 托管，推荐完整方案

1. JoyHarness 启动一个 `agent acp` sidecar，通过 JSON-RPC 初始化和认证。
2. 从 `initialize` 协商 capability；用 `session/list` 分页发现会话，再以 `session/load` 或 `session/new` 建立槽位。
3. 每个槽保存 provider、`sessionId`、cwd、标题、运行状态和 pending request。
4. `session/update` 映射 busy/done/error，`session/request_permission`、`cursor/ask_question`、`cursor/create_plan` 映射不同的 waiting 子状态。
5. approve/deny 直接返回 permission response，interrupt 发 `session/cancel`；问题和计划必须返回各自的 Cursor 扩展 response schema。
6. 先按 ACP 设计用一条连接管理多个 session，并压测六个并发 prompt、交错审批与取消；若 Cursor 实现出现串行化或故障传播，再回退到每个活跃槽一个进程。

这是功能上最接近现有 Codex 控制面的 Cursor 方案，但 UI 属于 JoyHarness 自己，不是控制 Cursor Desktop 的六个原生槽。

## 两种 Pi 接入路线

### 路线 P1：保留现有 Pi 交互进程 + extension

适用：用户继续在 Pi TUI 内工作，JoyHarness 只旁路观察和有限控制。

1. 安装用户级 extension，监听 `agent_start/end/settled`、tool execution、session change。
2. extension 连接 JoyHarness socket，上报状态与会话 ID。
3. 在 `tool_call` handler 中等待 JoyHarness 审批；超时/断连默认 block。
4. 可由 extension 自建 socket command，调用 Pi extension API 注入消息或 abort；这部分是自定义协议，应独立测试 TUI 生命周期和并发。

优点是保留现有 TUI；缺点是 JoyHarness 并不拥有进程，重连、多个 Pi 进程识别、审批等待和槽位绑定都要由 extension 自己解决。

### 路线 P2：RPC/SDK 托管，推荐完整方案

1. 简单版本由 JoyHarness 启动 `pi --mode rpc --session <id>`，用 JSONL 发送 `prompt`、`steer`、`follow_up`、`abort`、`get_state` 和 `switch_session`。
2. 六个任务需要真正同时运行时，使用六个 RPC 子进程，或写一个很薄的 Node/Bun sidecar，以 Pi SDK 创建六个 `AgentSession`。
3. sidecar 统一加载审批 extension、维护 session list，并向 Swift 暴露一个本地、版本化的 JSON 协议。
4. 在没有 OS 级隔离或严格工具 allowlist 时，不允许无人值守自动批准写入/bash。

RPC 已经足够完成单槽 PoC；SDK sidecar 更适合长期多槽，能隔离 Swift 与 Pi TypeScript API 的版本变化。

## 推荐实施顺序

1. 先抽象 `AgentProvider`，让 Codex、Cursor、Pi 分别实现 capability/list/select/prompt/respond/cancel/events；会话主键使用 `(provider, sessionId)`，保留 `PadState` 和震动层。Codex 继续走现有 Micro/app-server，Cursor 使用独立 hook/ACP 配置与子进程，两者可以同时存在。
2. 做 Cursor ACP 单槽 PoC，验收 permission waiting -> 手柄 approve/deny、cancel、完成/失败震动和 session reload。
3. 做 Pi RPC 单槽 PoC，验收 prompt/abort/state/session switch；同时完成默认拒绝的 `tool_call` approval extension。
4. 将槽位从 `AG00`-`AG05` 重构为 provider session ID；Codex provider 仍可继续使用 RP2040 Micro，Cursor/Pi provider 走软件协议。
5. 单槽稳定后才扩到六槽并发；Cursor 先验证单 ACP 连接多 session，失败再采用进程隔离；Pi 先采用多 RPC 进程，再视资源占用升级 SDK sidecar。
6. PTT 独立立项，不与 agent provider 适配捆绑。

## 风险与必须实测项

- **Cursor 会话发现**：当前版本有结构化 `session/list`，但必须按 capability 协商；还要实测其集合是否包含 Desktop/CLI 创建的全部会话，以及 `session/load` 在升级、退出和跨 cwd 后的稳定性。
- **Cursor ACP 并发**：ACP 官方架构允许每条连接承载多个并发 session，但 Cursor 没有承诺数字上限、公平调度或六 prompt 稳定性；先按标准形态实现，压测失败再按活跃槽拆进程。
- **Cursor 审批边界**：ACP 中 agent 只是 `MAY` 发起 permission request，不能假定每个工具调用都经过手柄；禁用 `--force`，保留 deny 优先的静态权限、sandbox 和超时默认拒绝，并从每次请求给出的 options 选择，不硬编码 option ID。
- **Cursor 阻塞请求**：除了 permission，还要处理 `cursor/ask_question` 和 `cursor/create_plan`；未知阻塞 extension 必须保守失败并显示，不得静默挂起。
- **Cursor hook 边界**：要实测同一用户 hooks 在 Cursor Desktop、Cursor CLI interactive、headless 和 ACP 中的触发差异，避免重复上报；用户 hooks 不覆盖 Cloud Agent。
- **多 provider 共存**：必须用 `(provider, sessionId)` 隔离同名 ID、pending request 和状态事件；安装 Cursor hooks 时合并现有 `~/.cursor/hooks.json`，不得覆盖用户已有 hook。Codex Micro 动作只路由到 Codex provider。
- **Pi 审批竞态**：并行 tool call 会逐个 preflight 后并发执行；pending decision 必须按 session ID + toolCallId 关联，拒绝一个调用不能误放行同批兄弟调用。
- **Pi 安全**：project trust 不是 sandbox；应使用工具 allowlist、容器/VM 或 policy sandbox，并让断连默认拒绝。
- **进程恢复**：应用重启后要重新关联 provider process、session ID 和 pending request；无法确认旧 request 仍有效时必须清空并拒绝。
- **协议版本**：Cursor ACP、Pi RPC 与尤其 Pi experimental server protocol 都会变化；sidecar 与 Swift 之间应定义自己的窄协议并做 capability negotiation。

## 调查版本与证据边界

本机核验命令：

```text
agent --version   # 2026.08.11-e8db854
agent --help
agent acp --help
agent acp initialize -> agentCapabilities.sessionCapabilities.list = {}
agent acp session/list（带 cwd 过滤）-> 成功返回 sessions 数组
pi --version      # 0.84.2（在 JoyHarness 工作目录）
pi --help
```

Pi 源码核验固定在提交 `a69bef789bc95abf0acee16f7b4660b70b650bb9`。ACP 规范核验固定在提交 `1c00740ec19622527f2483a95ea15ddb7604885c`。Cursor CLI 是闭源分发，官方 GitHub 仓库不包含 CLI 实现，因此 Cursor 的实现判断以官方文档、本机 CLI help 和运行时 `initialize` capability 为准，不把第三方 ACP adapter 当作支持证据。

没有证据、不能承诺的事项：Cursor/Pi 识别 Codex Micro HID；复用 Codex Desktop 六槽 UI；复用 `ACT10` PTT；Cursor `session/list` 覆盖所有 Desktop/CLI/Cloud 历史且跨版本语义不变；Pi 原生提供逐工具审批或 sandbox；Cursor 单连接稳定并发六个 prompt；每个 Cursor 工具调用都触发 ACP permission；ACP 能直接跳转或控制 Cursor Desktop 现有 UI。
