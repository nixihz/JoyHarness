# DualSense 的 L2 + PS 组合键可行性

调查日期：2026-10-17（Asia/Shanghai）

范围：DualSense 连接 Mac 后，由 Joy Harness 识别输入并执行本地操作。本文不讨论修改 PS5 主机系统的按键行为。

初始调查代码基线：`c61ba10`，`codex/joycon-analog-stick`，含调查时工作区已有修改。下方“初始项目接入位置”保留当时快照；后续产品交互以 [AI 语音规格 v0.4](../specs/joy-harness-ai-voice.md) 为准。

证据状态：初始调查核查了一手驱动源码、Apple 官方 API 和项目实现，未进行硬件按压验证。**后续用户实测持续按 PS 会导致手柄关机，已据此废除 PS 长按语音方案。** 新的“按住 L2、短点 PS、松 L2 发送”交互尚未完成硬件不关机与完整语音实机验收；协议可区分输入不等于已经验证系统或硬件无副作用。

## 结论

**可以区分“按住 L2，再按 PS”和“单独按 PS”，并据此执行不同操作。** L2 与 PS 是独立输入；软件在 PS 从松开变成按下的瞬间，读取同一手柄的 L2 状态即可。它不是手柄额外生成的一个专用快捷键，而是应用解释两个输入的组合。

这里的“按 L2 再按 PS”要求 PS 按下时 L2 仍然按住。如果先松开 L2，之后再按 PS，需要另行设计时间窗口和顺序手势，不能直接当作同一个组合键。若先按 PS 再按 L2，同时要求 PS 单按立即响应，也无法事后撤回已经执行的单按操作。

**初始调查时 Joy Harness 尚未区分 L2 + PS，也未暴露为独立映射。** 后续产品决定将它作为固定的独立 AI 语音入口，而非任意可配置映射：AI 语音开启时，先按住同一手柄的物理 L2，再短点 PS，在 PS 按下沿开始准备；立即松开 PS，继续按住 L2 说话，正常松开 L2 发送。AI 关闭时组合消费为空动作。

普通 PS 无论 AI 开关均按下立即打开 Harness 切换浮层。新语音入口不设 600 ms 等待，也不要求保持 PS；原生模式返回、已有浮层取消及所选设备校准仍优先处理。组合取消该次体感快速定位，松 L2 不补发定位。识别后的语音由已登记能力执行，当前并未开放任意脚本；本地、混合和云端处理路线见规格。

## 协议层：同一份输入报告包含两个独立状态

Linux 主线 `hid-playstation.c` 定义 L2 为 `buttons[1]` 的 bit 2，PS/Home 为 `buttons[2]` 的 bit 0；报告结构还包含 L2 的模拟量 `z`。解析器分别上报左扳机轴、L2 按钮和 PS/Home 按钮，三者没有合并成同一个输入。USB 报告与蓝牙扩展报告经过各自包头偏移后，使用同构的输入状态结构。

这说明应用拿到完整报告时，可以在**同一份报告内**判断“PS 按下时 L2 是否已经按住”，无需等待手柄发送一个额外的组合键码。Linux 是协议实现证据，不代表 macOS 的事件转发策略与 Linux 相同。

SDL 官方 PS5 HID 驱动进一步交叉验证：它在简短报告和扩展报告中均分别解析 `SDL_GAMEPAD_BUTTON_GUIDE` 与 `SDL_GAMEPAD_AXIS_LEFT_TRIGGER`。初始调查时 Joy Harness 的 HID 兜底只处理 USB `0x01` 与蓝牙扩展 `0x31` 的 PS 位，不应把“SDL 能解析简短报告”写成“本项目已经支持这一路”。

来源：Linux 主线 [hid-playstation.c](https://github.com/torvalds/linux/blob/master/drivers/hid/hid-playstation.c) 的 `DS_BUTTONS1_L2`、`DS_BUTTONS2_PS_HOME`、`dualsense_input_report`、`dualsense_parse_report`；SDL 官方 [SDL_hidapi_ps5.c](https://github.com/libsdl-org/SDL/blob/main/src/joystick/hidapi/SDL_hidapi_ps5.c) 的 `HIDAPI_DriverPS5_HandleSimpleStatePacket` 与 `HIDAPI_DriverPS5_HandleStatePacketCommon`。源码按 2026-10-17 抓取内容核查，主分支链接可能继续变化。

## Apple API 的依据与边界

| 已确认的事实 | 对本问题的意义 | 一手来源 |
| --- | --- | --- |
| `GCExtendedGamepad.buttonHome` 提供独立 Home 按钮，macOS 11.0 起可用 | 可以注册 PS/Home 的按下与松开回调；它是可选属性，运行时仍需检查是否存在 | [buttonHome](https://developer.apple.com/documentation/gamecontroller/gcextendedgamepad/buttonhome) |
| `leftTrigger` 是独立的模拟扳机输入 | 可读取 L2 是否越过选定阈值；阈值由应用决定，不是 Apple 定义的组合键规则 | [leftTrigger](https://developer.apple.com/documentation/gamecontroller/gcextendedgamepad/lefttrigger) |
| `GCDualSenseGamepad` 自 macOS 11.3 起可用 | DualSense 支持有明确的系统版本下限；本项目最低 macOS 13 已覆盖这些基础 API | [GCDualSenseGamepad](https://developer.apple.com/documentation/gamecontroller/gcdualsensegamepad)、[Package.swift](../../Package.swift) |
| `pressedChangedHandler` 在按下或松开状态变化时回调 | 应以 PS 按下沿触发一次，持续按住不重复执行 | [pressedChangedHandler](https://developer.apple.com/documentation/gamecontroller/gccontrollerbuttoninput/pressedchangedhandler) |
| `shouldMonitorBackgroundEvents` 从 macOS 11.3 起默认 `false` | Joy Harness 在后台接收输入需要显式开启；后台监听不代表独占系统 Home 行为 | [shouldMonitorBackgroundEvents](https://developer.apple.com/documentation/gamecontroller/gccontroller/shouldmonitorbackgroundevents) |

### 能识别组合，不代表一定能屏蔽系统 PS 行为

Apple 对 `buttonHome` 明确说明：系统没有处理 Home 事件时才将它交给应用。`preferredSystemGestureState = .disabled` 可以请求系统不运行该元素的手势识别器、直接把输入交给应用，但 Apple 同时明确表示系统不保证遵从该偏好。

因此不能承诺“设置这一行后，所有 macOS 版本、前后台状态和用户设置下，都不会再触发系统行为”。读取原始 HID 可以补充输入观察路径，也不等于取消系统另一条输入路径的响应。用户后来报告 PS 长按导致手柄关机，进一步说明应用事件可见性不能证明硬件行为可被屏蔽；该反馈已推翻旧长按语音方案。新入口只短点 PS，把持续保持转移到 L2，但是否实际避免关机仍需分别验证 USB、蓝牙及前后台场景。

来源：[buttonHome](https://developer.apple.com/documentation/gamecontroller/gcextendedgamepad/buttonhome)、[preferredSystemGestureState](https://developer.apple.com/documentation/gamecontroller/gccontrollerelement/preferredsystemgesturestate)、[SystemGestureState.disabled](https://developer.apple.com/documentation/gamecontroller/gccontrollerelement/systemgesturestate/disabled)。

## 初始项目接入位置（历史快照）

以下描述初始调查时的代码，不代表 v0.4 当前实现；保留用于说明为什么当时不能只在设置中增加一条映射。

- [ButtonBridge.swift](../../Sources/JoyHarness/ButtonBridge.swift) 中 `attachStandardController` 已设置 Home 的 `.disabled` 偏好，并接收 GameController Home 输入；`HomeButtonPressMerger` 合并 GameController 与原始 HID 产生的重复报告。
- 同文件 `updateHomeButton` 在合并后直接走原生模式返回或 `onHarnessSwitcherPresent`，没有根据 L2 分派；其他按键的功能层逻辑并不会自动覆盖此入口。
- 初始基线中 L2 作为 `.functionModifier` 时使用 `value >= 0.55` 判定功能层。这是可复用的项目阈值，不宜为 PS 另设相互矛盾的按压标准。
- [ControllerMapping.swift](../../Sources/JoyHarness/ControllerMapping.swift) 没有 `functionHome` 输入，且 `isReservedForHarnessSwitcher` 把游戏手柄的 `.home` 标为保留输入。因此仅写入一条 Home 自定义映射不会让现有 PS 路径执行它。
- [DualSenseHIDOutput.swift](../../Sources/JoyHarness/DualSenseHIDOutput.swift) 的 `DualSenseInputReport.isHomeButtonPressed` 只提取 PS 位，回调仅传递 `Bool`；它尚未把同一报告的 L2 值一起传上来。
- 初始 [CONTEXT.md](../../CONTEXT.md) 要求映射模式下 PS/Home 立即打开浮层、原生模式下返回映射模式。后续已同步领域约定、[DESIGN.md](../../DESIGN.md) 与映射说明，普通 PS 继续即时响应，L2 + PS 另走语音或空消费。

## 后续采用的识别规则（v0.4）

以下是当前产品契约；硬件验收状态单独记录，不把契约当作已经通过的实测。

1. 以**同一控制器**的 PS 按下沿为判定时刻，读取同一原始报告中的物理 L2。L2 ≥ 0.55 时选择组合，否则普通 PS 立即打开浮层；跨设备的 L2 与 PS 不拼成组合，也不随自定义功能层键改变。
2. AI 语音开启时，组合在 PS 按下即开始准备，无长按等待阈值。用户短点后立即松开 PS，继续按住 L2；音源就绪并提示后说话，正常松开 L2 提交一次。松开 PS 不结束会话；准备中松开 L2 则取消。L2 采用迟滞：进入时需 ≥ 0.55，会话期间回落至 0.40 仍继续，≤ 0.10 才视为释放／恢复中立，避免手指轻微放松误提交。
3. AI 语音关闭时组合消费为空动作。组合不会在 L2 或 PS 松开后补发普通 PS；先 PS 后 L2 也不会撤回普通 PS 或追加语音。L2 + PS 一经识别就取消本次 MotionJump，松开 L2 不再提交定位。
4. 首版录音仅开放给单只可唯一关联、连续原始 HID 报告可靠的 DualSense。多设备无法唯一匹配或报告不可靠时不录音，保留普通 PS 即时切换。输入邮箱中的 PS 按下事件必须距捕获不超过 250 ms，且后续报告未显示 L2 已释放，才可启动，不能用排队的旧事件补启录音。双路报告不得重复发起；结束音频使用输入源捕获的真实 L2 松开时刻。
5. 原生模式返回映射、已打开 Harness 浮层的取消与所选设备校准保持优先消费。断连、输入停流、取消或模式变化均结束未提交语音，不把合成释放当作发送；恢复后先确认中立。

PS 长按语音曾被作为 v0.3 方案实现，但已被用户的关机反馈取代。不要继续用旧“持续按 PS 说话”方式验收或指导用户；目前也不能承诺新组合已经消除了所有硬件或系统副作用。

## 仍需完成的实机验证

| 场景 | 必须观察的结果 |
| --- | --- |
| AI 开关两种状态下单独按 PS | 均在按下时立即打开 Harness 浮层一次，不录音、不等待松开 |
| AI 开启，按住 L2 后短点并松开 PS，继续按 L2 说话 | PS 按下进入准备，松 PS 后不中断，不打开 Harness 浮层；正常松 L2 只提交一次 |
| AI 关闭时 L2 + PS；准备中松 L2；先 PS 后 L2 | 分别空消费、取消、保持普通 PS 分支；不补发浮层或语音 |
| USB 与蓝牙；Joy Harness 前台与后台 | 采用短点 PS、只保持 L2 的新交互，分别验证手柄保持连接、不关机及系统 PS 副作用；**尚未验收** |
| L2 行程由 ≥ 0.55 回落至 0.40，再降至 ≤ 0.10 | 轻微回落不中断，达到释放阈值才提交一次；真实手感仍需验证 |
| 同一按压从 GameController 与 HID 到达，含延迟与松开丢失 | 不重复派发；超过 250 ms 或后续 L2 已释放的旧按下事件不补启录音，L2 松开后不收录新声音，下一次真实组合不会被吞掉 |
| 原生模式、已有浮层、体感校准与 MotionJump | 保持优先消费；语音或空组合均取消该次定位，松 L2 不移动光标 |
| 断连与重连、多只手柄、输入停流 | 不跨设备组合，不提交半段录音，不复活旧按压 |

这些仍是功能验收项；本次文档修订未进行新硬件测试、网络调研或构建。

## 资料取得与复现

Apple 网页正文通过本机 pip 安装的 `scrapling 0.4.15`、`Fetcher.get` 读取官方 DocC JSON 内容接口；抓取的 10 个有效 API 页面均返回 HTTP 200，其中本笔记采用与基础组合识别直接相关的证据。Linux 与 SDL 上游源码也通过 Python Scrapling 抓取。SDK 头文件用于核对可用版本与接口约束，未把接口存在当作实际按键测试通过。

本地可复现脚本与结构化摘录保存在已被 Git 忽略的 `.build/research/dualsense-ps-button-chords/`：`fetch_apple_sources.py`、`apple-evidence.json`，以及 `drivers/` 下的 `fetch_driver_sources.py`、驱动源码与 `manifest.json`。该构建缓存可能被清理，本文保留关键结论和官方页面链接。探索时两个推测的 DocC URL 返回 404，未作为证据；最终来源使用已成功抓取的规范路径。驱动抓取清单另记录 `robots.txt` 返回 404，源码自身均为 HTTP 200。

使用的 Skill：`research`、`scrapling`。改进建议：`research` 可补充“协议／API 可行、当前产品已支持、实机已验证”三个证据层级；`scrapling` 可补充 Apple DocC JSON 的提取示例，处理代码片段、引用节点和平台起始版本，避免把页面 JavaScript 壳或缺失布尔值的纯文本误当完整正文。本次未修改 Skill。
