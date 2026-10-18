# DualSense 内置麦克风通过无线进入 Mac：协议、软件与接收器调查

调查更新：2026-10-18（Asia/Shanghai）。范围已由用户确认：**PS5 DualSense 内置麦克风 → 无线 → Mac**。

实施规格：[DualSense 无线系统麦克风与 Codex 接入 Spec](../specs/dualsense-bluetooth-microphone.md)。现已实现并安装开发预览，但无线音质验收失败；不是正式可用功能。首版仍优先让 Codex 等外部应用使用系统麦克风，保留 RP2040 Plus 的 USB 控制职责。

## 2026-10-18 补充：可下载替代方案与游戏模式实测

在用户要求重新寻找现成方案后，刷新了 GitHub Releases、源码、issue 与 Apple 官方说明；文章与源码通过 Python pip `scrapling` 获取。以下为新结论，后续 2026-10-17 内容保留为调查历史，不再将其“未做真机测试”理解为当前状态。

### 新发现：macOS 游戏模式显著改变本机音频包供给

[Unravl/dualsense-audio-macos](https://github.com/Unravl/dualsense-audio-macos) 于 2026-10-15 创建，当前固定提交 [`4fbb5f47446ebe2e8e5d8964e822de2cabf6958e`](https://github.com/Unravl/dualsense-audio-macos/tree/4fbb5f47446ebe2e8e5d8964e822de2cabf6958e)。其 README 声称在 Apple Silicon、macOS 26.6 测试过：普通模式约 67 总输入报告/秒、游戏模式约 133/秒，麦克风需游戏模式才能清晰。该项目没有 Releases 资产，需要自行构建；要求 macOS 26+，使用 root helper + HAL，共享内存传音，采音期间独占手柄。其 [Opus 接收源码](https://github.com/Unravl/dualsense-audio-macos/blob/4fbb5f47446ebe2e8e5d8964e822de2cabf6958e/src/engine/ds5_codec.c) 按音频报告 byte 2 的独立八位计数判断缺帧并使用 PLC，不能把它的输出总帧数当成真实到包数，也不能将高四位全报告序号与该计数混为一谈。

[Apple 官方说明](https://support.apple.com/en-us/105118) 确认 Game Mode 会使蓝牙采样率翻倍，同时调整 CPU/GPU 与后台任务优先级。它支持调度影响这一方向，但不保证 DualSense 私有麦克风支持。已核对本机 Xcode 自带 `gamepolicyctl` 的 help/status；原状态为 auto/off。以短时可恢复方式设置 on，实验结束恢复 auto/off；未改配对、固件或系统默认音源。

第一轮在 Joy Harness 中开启模式后，6 秒音频包从 232 增为 432，但应用触发了音频积压保护并停流，之后 11 包的读数不能作为有效的恢复普通模式对照。第二轮退出 Joy Harness，用同一个独立 probe 每轮自行开启和关闭物理流，保持协议/解码/设备不变，得到有效 A/B/A 对照：

| 状态 | 采样时间 | 控制报告 | 音频报告 | 有效 PCM 时长 | 供给比 |
| --- | --- | --- | --- | --- | --- |
| auto/off，切换前 | 6.002592 秒 | 126 | 224 | 2.24 秒 | 37.3% |
| forced on | 6.001287 秒 | 186 | 461 | 4.61 秒 | 76.8% |
| 恢复 auto/off | 6.000285 秒 | 128 | 231 | 2.31 秒 | 38.5% |

三轮 CRC/分类拒绝与解码失败均为零，均成功关闭且确认新鲜中立控制与无音频。日志在 `/tmp/joyharness-alternatives-20261018/standalone-*.jsonl`。**游戏模式对当前收包缺供有可逆影响，已经本机证实；它并未让本机达到完整供给，尚不能承诺清晰或将 M0 判为通过。** 首轮额外暴露的供音队列积压需要单独复现、定位，不能简单扩大队列掩盖。

### 本机试用进展

用户随后要求试用 DualSense Audio for macOS，已在 `/Users/brian/Developer/dualsense-audio-macos` 固定上述提交完成构建，并由用户完成管理员安装；系统已枚举其麦克风。原生系统录音已成功，真人可懂度尚未验收。其独立 CLI 的 6 秒对照为：普通模式 232 个真实音频帧、游戏模式 486 帧、恢复普通模式 176 帧；游戏模式下仍报告 17.9% 缺失并使用 PLC，不能据完整 WAV 时长宣称无线完整。详见[独立试用记录](dualsense-microphone-implementation-validation.md#2026-10-18独立试用-dualsense-audio-for-macos)。下表保留研究时的交付物信息，Unravl 的本机安装状态以本段为准。

### 可下载或构建的替代方案

| 方案 | 可取得的交付物 | 当前判断 |
| --- | --- | --- |
| [ControlDeck v1.1.1](https://github.com/ihansel/control-deck/releases/tag/v1.1.1) | [DMG](https://github.com/ihansel/control-deck/releases/download/v1.1.1/ControlDeck.dmg)、[ZIP](https://github.com/ihansel/control-deck/releases/download/v1.1.1/ControlDeck.zip)，2026-07-27 发布，作者声明 Developer ID 签名及公证 | 是现成 Mac 软件候选，但仍使用 IOHID 接收，不会天然绕过本次调度因素；有 [issue #1](https://github.com/ihansel/control-deck/issues/1) 报告已发布 DMG 因资源 bundle 缺 Info.plist 启动崩溃，不能直接承诺开箱即用。本轮未安装运行，ZIP 下载未完成，不声称独立验证签名或包结构 |
| [DualSense Audio for macOS](https://github.com/Unravl/dualsense-audio-macos) | MIT 源码与 CMake 构建/安装脚本，尚无预编译 Release | 最有针对性的新参考；明确解释游戏模式限制，但需要 root helper 和 HAL 安装。优先移植并验证诊断思路，无须立即并存安装另一套驱动 |
| [DS5Dongle OLED v0.9.4](https://github.com/MarcelineVPQ/DS5Dongle-OLED-Edition/releases/tag/v0.9.4-oled-edition) | Pico 2 W UF2 与 Mac universal 配置程序 | 真正绕开 Mac 蓝牙接收路径；新增 Pico 2 W，固件不可直接刷入 RP2040 Plus；用户板子的品牌及是否另带无线模块尚未确认，OLED 非必需。包含 Mac USB mic pacing 修复，但本机未验证，版本风险与下载详见[接收器研究](dualsense-microphone-alternative-receivers-20261018.md) |
| [dualsense-neo v0.1.0](https://github.com/forgerpl/dualsense-neo/releases/tag/v0.1.0) + Linux 主机 + SonoBus/BlackHole | Linux deb 与两侧音频软件 | 可以让另一台主机接收蓝牙再传音到 Mac；多一台机器和网络环节，完整组合未实测，不作为现有单机首选 |

其他检索结果需排除目标混淆：[Macle57/ds5-virtual-cable](https://github.com/Macle57/ds5-virtual-cable) 有 Windows 安装器，但要求 Windows 10/11 与对应虚拟 USB 驱动，不能装在 macOS 上直接解决；[egicoro/dualsense-ptt](https://github.com/egicoro/dualsense-ptt) 明确仅 USB，不能算无线替代。[tomarai85/dualsense-bridge Releases](https://github.com/tomarai85/dualsense-bridge/releases) 当前为空，仍是源码项目，原依赖/发布设备疑点未因重新搜索消失。

推荐顺序：先对照 Unravl 独立 CLI 的实际到包量、音频计数及补偿策略，结合已证实的游戏模式影响推进现有实现；若坚持不用额外硬件，ControlDeck 可做独立软件对照但并不保证解决；若优先稳定日用且接受新增接收器，Pico 2 W 固件方案比继续换虚拟音频输出后端更有针对性。不要购买仅承诺手柄按键或耳机接口支持的普通蓝牙转接器。

## 2026-10-17 调查历史

本次更新替代 2026-08-23 的旧结论。旧调查正确描述了 Sony/macOS 的原生支持边界，但“没有公开、可实施的软件路径”“需要先从零逆向协议”已不适合继续作为当前结论。这里的部分开源实现及实验记录早于旧调查，不能把新发现全部解释为最近才有的技术突破。

本次核验了官方资料、固定提交的源码、作者实验记录与 Mac 用户问题报告；**没有在本机开启手柄麦克风、录音、安装软件或刷写固件**。文章、README、协议文档及源码使用 Python pip 包 `scrapling 0.4.15` 抓取。Sony 美国支持页抓取被拒绝，改用成功抓取的英国官方页；不把搜索摘要当成已读全文。

## 结论与选择

**可以通过无线把 DualSense 内置麦克风的声音传到 Mac。已有两条有实现依据的路线：Mac 上的软件协议桥，以及 Pico 2 W 专用接收器。单纯在 macOS 蓝牙设置里配对仍不会得到原生麦克风输入。**

| 路线 | 证据与成熟度 | 额外条件 | 建议 |
| --- | --- | --- | --- |
| 普通 macOS 蓝牙配对 | Sony 未提供内置麦克风 Mac 支持；不会因麦克风授权而补出音频设备 | 无 | 不能直接达到目标 |
| ControlDeck 用户态软件桥 | 有完整 Swift IOHID、Opus 解码与 Core Audio 发布代码；作者提供操作和验收流程，本次未复测 | macOS 14.2+；音频相关权限；采集时暂停多数手柄映射 | **优先做零硬件验证；最值得 JoyHarness 参考** |
| Pico 2 W + DS5Dongle | 有 Mac M1/M4 实际采音报告，以及针对 CoreAudio 回声/抖动的修复 | 一块 Pico 2 W、数据线、包含修复的固件 | **接受 Mac 上插接收器时的硬件备选** |
| tomarai85/dualsense-bridge | 有收包/解码代码，但 README、依赖与启动链不完整 | BlackHole、Python 音频依赖、额外修正 | 协议参考，不作为开箱即用推荐 |
| 普通手柄适配器 / Remote Play | 按键支持或主机串流不证明 DualSense 私有 mic 上行支持 | 产品型号与系统组合需另证 | 不为本用途盲买或反复调设置 |

依据：[Sony 兼容性](https://www.playstation.com/en-gb/support/hardware/pair-dualsense-controller-bluetooth/)、[ControlDeck 无线麦克风说明](https://github.com/ihansel/control-deck/blob/4282692787c2c6640946302d45205740e84c3b15/Docs/BluetoothMicrophone.md)、[DS5Dongle Mac 报告 #220](https://github.com/awalol/DS5Dongle/issues/220)、[修复 #232](https://github.com/awalol/DS5Dongle/pull/232)。

## 为什么官方说不支持，开源实现却可以

Sony 的支持页仍把 DualSense 内置麦克风/扬声器列为不兼容 Mac；Apple 的手柄支持页提供蓝牙及 USB 配对方法，并不承诺无线麦克风端点。这是系统现成功能的支持边界，不能用来否认手柄硬件和第三方协议桥的能力。[Sony](https://www.playstation.com/en-gb/support/hardware/pair-dualsense-controller-bluetooth/)、[Apple](https://support.apple.com/en-us/111100)

公开实现显示，这条麦克风链路使用 **Bluetooth Classic HID 内的 Sony 私有音频报文**，不是普通耳机的 HFP，也不是 A2DP 麦克风。主机需要先发开启/路由报文，再把接收到的 Opus 解码为 PCM；要供其他应用选择，还要把 PCM 发布成 macOS 音频输入。[DS5Dongle 接收源码](https://github.com/awalol/DS5Dongle/blob/2f7d045df2f1654245ab02bd4e0a77cf2091c4a9/src/main.cpp)、[解码源码](https://github.com/awalol/DS5Dongle/blob/2f7d045df2f1654245ab02bd4e0a77cf2091c4a9/src/audio.cpp)

```text
纯软件：手柄内置麦克风 → 蓝牙 HID / Opus → Mac 软件解码 → PCM → 系统麦克风或语音模块
接收器：手柄内置麦克风 → 蓝牙 HID / Opus → Pico 2 W 解码 → USB Audio → Mac
```

两条路径的无线段都在手柄与接收主机之间。Pico 方案中接收器插在 Mac 上，手柄无需拖着 USB 线、树莓派主机或电源；这与旧文档讨论的“手柄插远端树莓派，再 USB-over-IP”不是同一种拓扑。

## 路线一：ControlDeck，完整的 Mac 软件实现

核验版本：`ihansel/control-deck`，提交 `4282692787c2c6640946302d45205740e84c3b15`，MIT 许可证。没有运行该项目；下列是源码可见事实及作者说明。

### 实际的数据链

1. `DualSenseHIDService.swift` 通过 IOHID 访问设备，注册原始输入报告回调，发送 microphone state/stream 输出。
2. `DualSenseBluetoothAudioProtocol.swift` 区分普通状态与音频子类型，兼容 IOHID 回调包含 report ID 或单独提供 ID 的布局，提取 71 字节 Opus。
3. `BluetoothMicrophoneService.swift` 通过持久 `libopus` decoder 解码、处理重复和丢帧，将 PCM 放入缓冲。代码有解码错误处理和实际 PCM 电平指标。
4. `BluetoothMicrophoneService.swift` 把 PCM 喂入本进程 `AVAudioSourceNode`；`ProcessTapMicrophoneService.swift` 对本进程创建静音 process tap，再创建公共 aggregate 输入，让其他应用枚举 `DualSense Microphone`。

直接来源：[IOHID](https://github.com/ihansel/control-deck/blob/4282692787c2c6640946302d45205740e84c3b15/Sources/ControlDeck/DualSenseHIDService.swift)、[协议](https://github.com/ihansel/control-deck/blob/4282692787c2c6640946302d45205740e84c3b15/Sources/ControlDeck/DualSenseBluetoothAudioProtocol.swift)、[接收解码](https://github.com/ihansel/control-deck/blob/4282692787c2c6640946302d45205740e84c3b15/Sources/ControlDeck/BluetoothMicrophoneService.swift)、[音频设备发布](https://github.com/ihansel/control-deck/blob/4282692787c2c6640946302d45205740e84c3b15/Sources/ControlDeck/ProcessTapMicrophoneService.swift)。

Apple 官方样例也明确支持把 process tap 放入 aggregate device 作为输入，并可使被 tap 进程的输出不再播放到扬声器。该 API 路线要求 macOS 14.2+ 和系统音频录制授权。因此这里不必先安装自定义 HAL 驱动；仓库内的 HAL prototype 不是它正常运行时的路径。[Apple Core Audio taps](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps)

### 实际使用边界

- 作者流程：蓝牙配对 → ControlDeck Setup 中 Prepare wireless microphone → 在消费端选择 `DualSense Microphone` → L2 按住说话或麦克风按钮切换采集。[操作文档](https://github.com/ihansel/control-deck/blob/4282692787c2c6640946302d45205740e84c3b15/Docs/BluetoothMicrophone.md#setup)
- 由于 process tap，作者要求消费端检查“麦克风”及“屏幕与系统音频录制”权限；可枚举设备不等于已经获准输出样本。此实现 tap 的是自身音频进程，不是以录制整个桌面声音来取得手柄声音。[同上](https://github.com/ihansel/control-deck/blob/4282692787c2c6640946302d45205740e84c3b15/Docs/BluetoothMicrophone.md)
- **采集期间暂停普通指针/按钮映射，只保留经过验证的 L2 松开和麦克风停止控制。** 这是防止音频包被系统游戏控制器路径误解释的处理；不能宣传成“所有手柄操作与麦克风无条件同时工作”。[边界说明](https://github.com/ihansel/control-deck/blob/4282692787c2c6640946302d45205740e84c3b15/Docs/BluetoothMicrophone.md#feature-boundaries)
- 初始缓冲 2,400 samples，按 48 kHz 计为 50 ms。它不是总延迟指标；还要加无线传输、回调调度、音频设备和识别等待。本次没有端到端测量。[数据链说明](https://github.com/ihansel/control-deck/blob/4282692787c2c6640946302d45205740e84c3b15/Docs/BluetoothMicrophone.md#data-path)
- 文档有“从不改默认输入”与“活动 Codex 会话临时改并恢复”两种表述，不应把“绝不改变系统默认麦克风”当成已验证承诺。试用时核对结束/取消后是否恢复；核心能力是可选择的输入，不依赖该宣传句。

最小试验应先退出 JoyHarness 及其他手柄映射程序，按照该项目的构建/安装流程运行，验证真实录音而非只看设备列表。它的完整产品还包含桌面映射、语音和 Codex 操作，不能把它当成完全独立、无其他动作的麦克风小工具。[构建和功能范围](https://github.com/ihansel/control-deck/blob/4282692787c2c6640946302d45205740e84c3b15/README.md)

## 路线二：Pico 2 W + DS5Dongle

### 为什么这条路线证据更直接

DS5Dongle 的 [issue #220](https://github.com/awalol/DS5Dongle/issues/220) 有测试者报告：MacBook Air M4、Mac mini M1、macOS Tahoe 26.5.1，普通 DualSense 与 Pico 2 W，可以采到内置麦克风声音；但 v0.7.2 存在抖动、数字回声和信噪比问题。它证明链路已实际连通，同时也证明不能只凭设备出现就宣称音质合格。

[PR #232](https://github.com/awalol/DS5Dongle/pull/232) 于 2026-07-18 合并，修正面向 CoreAudio 的 USB mic 数据节奏：从大块灌入改为按 USB 主机时钟及 FIFO 空间供应 1 ms 小片，并处理欠载。修复合并提交为 `a66f5cf9eebb1938019eac9ec92f3f1406c99376`。这是针对具体 Mac 问题的补丁；仍需在自己机器验证。

### 固件版本不能随便选

截至本次查询，上游最新正式 release 是 **v0.7.2-hotfix，2026-06-20 发布**，早于上述修复。不能一边让用户下载“最新正式版”，一边说它已经包含七月的 Mac 修复。建议固定使用包含 #232 的上游提交构建，并核对板型；本次检查的上游源码提交是 `2f7d045df2f1654245ab02bd4e0a77cf2091c4a9`。[Releases](https://github.com/awalol/DS5Dongle/releases)、[修复 PR](https://github.com/awalol/DS5Dongle/pull/232)

OLED 分支的稳定版 **v0.9.4-oled-edition** 已含面向 CoreAudio 的 1 ms mic pacing，可作为另一候选；但该 tag 仍默认 320 MHz，不能把更新 master 文档里的 150 MHz 套过来。OLED 显示屏不是无线麦克风所必需；不为此建议追开发预发布。[v0.9.4 发布](https://github.com/MarcelineVPQ/DS5Dongle-OLED-Edition/releases/tag/v0.9.4-oled-edition)、[对应音频源码](https://github.com/MarcelineVPQ/DS5Dongle-OLED-Edition/blob/v0.9.4-oled-edition/src/audio.cpp)、[对应构建配置](https://github.com/MarcelineVPQ/DS5Dongle-OLED-Edition/blob/v0.9.4-oled-edition/CMakeLists.txt)

### 最少需要什么、怎么连

材料：**Raspberry Pi Pico 2 W**，一根接 Mac 的 USB 数据线。普通 Pico 2 没有无线功能；官方 Pico 2 W 是 Micro USB B 接口，Mac 可用 USB-C→Micro-B 数据线。兼容板接口可能不同，按实际板型购买。[官方产品](https://www.raspberrypi.com/products/raspberry-pi-pico-2/?variant=pico-2-w)、[官方数据手册](https://datasheets.raspberrypi.com/picow/pico-2-w-datasheet.pdf)

按照 [DS5Dongle 指南](https://github.com/awalol/DS5Dongle#flashing-firmware)：

1. 固定包含 Mac mic 修复、与 Pico 2 W 板型匹配的 UF2 固件。
2. 按住 BOOTSEL 把 Pico 插入 Mac，将 UF2 拖入出现的磁盘，等待重启。
3. DualSense 按 Create+PS 进入配对，让手柄配到 Pico；避免已配对的 Mac 抢先回连。
4. Pico 经 USB 提供 HID 与 Audio 接口；在 Mac 的录音应用中选择对应 DualSense/USB 输入。
5. 先录真实语音，再测试 10 分钟连续录音、静音及重连；不要只看声音设置中出现名称。

这条路线不需要手柄接 USB 线。它通过固件把 Sony 无线协议转换为标准 USB 音频，从架构上避开了 Mac 本机 Bluetooth HID 驱动对音频子类型的处理；手柄与 JoyHarness 的枚举及功能仍应实测。

## 已知协议：不需要再从零猜

不同独立项目交叉支持以下接收流程：[DS5Dongle](https://github.com/awalol/DS5Dongle/blob/2f7d045df2f1654245ab02bd4e0a77cf2091c4a9/src/audio.cpp)、[dualsense-neo](https://github.com/forgerpl/dualsense-neo/blob/8af78981115167affec777a134070fce7e90ab3d/SPEC.md)、[LinuxAudio4Dualsense5](https://github.com/GeorgLegato/LinuxAudio4Dualsense5/blob/54c543ad78e17dd957d71051a5950327c09bb499/src/ds5_membrane_sink.c)。

| 项目 | 已核实的实现行为 |
| --- | --- |
| 无线承载 | Bluetooth Classic HID 中的厂商自定义报文 |
| 音频输入报告 | 外层 ID `0x31`；flags bit 1 标记 mic；ControlDeck 还校验低半字节音频类型 `0x02` |
| 编码 | 一包 71 字节 Opus；持久 mono decoder 配置为 48,000 Hz |
| 解码帧 | 通常每包 480 samples，即名义 10 ms |
| 启停 | `0x32` 音频控制 + 普通 audio state/mute/volume 设置；必须发送关闭包 |
| 音频输出设备 | 可供应用内部直接消费 PCM，或发布虚拟 Core Audio 输入，或由硬件提供 USB Audio |

偏移必须区分传输层：L2CAP 数据还包含 `0xA1` HIDP 前缀时，Opus 从 `data+4` 开始；普通 HID 缓冲包含 report ID 时从 `+3` 开始；IOHID 单独给 report ID、剥掉该字节时从 `+2` 开始。不能复制另一平台的偏移而不核验长度和头部。[DS5Dongle 接收](https://github.com/awalol/DS5Dongle/blob/2f7d045df2f1654245ab02bd4e0a77cf2091c4a9/src/main.cpp)、[ControlDeck 解析](https://github.com/ihansel/control-deck/blob/4282692787c2c6640946302d45205740e84c3b15/Sources/ControlDeck/DualSenseBluetoothAudioProtocol.swift)

不同版本开关包不能混搭：ControlDeck 使用 142-byte `0x32` 的 `0xFF/0xFE` 控制体；本次上游 DS5Dongle 已用更小的有效子包、`0x03/0x02`。这些并不等于“任何位置写1都能开启”；序号、Sony CRC、音频路由及状态还必须匹配。最新上游能够独立开启 mic，不需要一边播放扬声器声音才能录音。[上游 `update_mic_status()`](https://github.com/awalol/DS5Dongle/blob/2f7d045df2f1654245ab02bd4e0a77cf2091c4a9/src/audio.cpp)

## 音质、延迟与实证的边界

- 48 kHz 是实现的解码/音频设备采样率；不证明麦克风有效声学带宽或录音质量达到专业麦克风水平。内部解码为单声道，部分系统出口复制成双声道，并非立体声录音。
- 71 字节、每秒约100包，对应压缩载荷约56.8 kbit/s；这是根据帧格式的算术估计，不含蓝牙/HID开销，不是本次测量的无线吞吐。
- 10 ms 是帧时长。ControlDeck 有50 ms初始缓冲，其他 Linux 实现甚至有100 ms预缓冲，端到端延迟必须另外测。
- neo 作者的实验记录有约99 mic包/秒、恢复环境声的结果，也保留了实际采样时钟尚待完全确认的疑问。扬声器路径的45 kHz时钟结论不可直接套到麦克风上行。
- 没有获得可比的本机 SNR、频响、语音识别准确率或续航实测，不能量化承诺“无线和USB音质相同”或“几毫秒延迟”。

来源：[neo 协议与实验记录](https://github.com/forgerpl/dualsense-neo/blob/8af78981115167affec777a134070fce7e90ab3d/SPEC.md)、[ControlDeck 缓冲设计](https://github.com/ihansel/control-deck/blob/4282692787c2c6640946302d45205740e84c3b15/Docs/BluetoothMicrophone.md)、[Linux 输入源码](https://github.com/GeorgLegato/LinuxAudio4Dualsense5/blob/54c543ad78e17dd957d71051a5950327c09bb499/src/ds5_membrane_sink.c)。

## 为什么不优先推荐 tomarai85/dualsense-bridge

检查提交 `9472c8aebcba7c21b0e3a87c2423593c80f66b98` 后发现：

1. README 说运行后出现 `DualSense Mic`，源码实际查找已安装的 BlackHole/同名设备并向其输出，没有自带创建/重命名这个设备的完整步骤。
2. `requirements.txt` 只有 `hid` 和 `pyobjc-framework-Quartz`，而 mic 路径还需要 `sounddevice`、`opuslib`、libopus 与 BlackHole。
3. `src/micstream.py` 导入 `mic_receiver`，该文件在 `scripts/`；README 默认 `src/dsread.py` 启动路径没有相应模块搜索路径设置，干净安装会遇到导入问题。
4. 实验脚本的部分成功门槛是“有音频标记包/存活/帧数量”，不是必须得到非空、可听的真实PCM；不能把离线正弦波编解码自测当成真实麦克风验证。
5. 作者记录过 HID 写入阻塞和需要重启手柄恢复的问题。其单独 mic 脚本会暂停自己的桌面控制服务，不是可随意与另一个映射应用并行的组件。

以上是静态核查，不是断言该作者从未录成功；它足以否定“按README就一定开箱即用”。该仓库为GPL-3.0；若未来复用代码，应与其他来源的许可分别处理。[README](https://github.com/tomarai85/dualsense-bridge/blob/9472c8aebcba7c21b0e3a87c2423593c80f66b98/README.md)、[micstream](https://github.com/tomarai85/dualsense-bridge/blob/9472c8aebcba7c21b0e3a87c2423593c80f66b98/src/micstream.py)、[依赖](https://github.com/tomarai85/dualsense-bridge/blob/9472c8aebcba7c21b0e3a87c2423593c80f66b98/requirements.txt)、[实验脚本](https://github.com/tomarai85/dualsense-bridge/blob/9472c8aebcba7c21b0e3a87c2423593c80f66b98/scripts/mic_experiment.py)

## 对 JoyHarness 的具体影响与最小验证顺序

当前工作区为已有功能开发状态，本次只读取代码，没有改动功能、依赖、设计或测试。项目已有 `DESIGN.md`。

### 当前不能直接并行开麦

`Sources/JoyHarness/DualSenseHIDOutput.swift` 的 `DualSenseInputReport.isHomeButtonPressed` 对 Bluetooth 只检查 report ID `0x31`，然后取 `report[11]` 当 PS；`psInputSample` 取 `report[6]` 当 L2，没有先排除 mic 音频子类型。外部程序启用无线mic后，若这些音频报告同时交给 JoyHarness，就可能把 Opus 字节解释成 PS/L2。因此需要先分流原始报告，也要门控 GameController / IOHID value 回调，不能只在最终音频解码处过滤。

这是当前源码与协议的组合推论，不是本次已经观察到的误触发。ControlDeck 自身也通过采集期间暂停大多数控制映射处理同类问题。

### 项目已有可利用的基础

- `RemoteMicrophoneOutput.swift` 和 `Drivers/JoyHarnessMicrophone/Driver.c` 已有遥控器虚拟麦克风通道。首版规格选择扩展HAL，新增独立DualSense设备；小米播放入口为16 kHz单声道，HAL本身为48 kHz双声道Float32，新路径保持48 kHz并适配通道与独立生命周期。
- `AIVoiceAudio.swift` 当前从系统默认输入通过 AVAudioEngine 录音，再转换成16 kHz单声道。直接PCM接入可供后续内部AI语音复用；用户明确优先Codex等外部应用，这条内部路线不作为首版前置。
- `Package.swift` 当前最低系统是macOS13。ControlDeck 的 process tap 方案要求14.2+，如采用要加能力判断/回退，不能无条件替换所有系统上的现有HAL方案。

### 以系统麦克风优先推进

1. **先打通无线音频到Codex**：退出未做输入隔离的JoyHarness及其他映射程序，用受控探针验证蓝牙解码和真实声源，再经独立HAL设备供外部录音与Codex使用。本地WAV、电平或设备名称只是中间证据；Codex实际收到手柄人声才完成端到端门槛。
2. **完成首版日常使用**：提供显式手动供音，协调用户的按住说话映射与Codex Micro ACT10；验证首尾字、可信实体键释放、断连/停流/睡眠/退出、消费者常开时的残音处理、组件升级与小米共存。外部应用拥有录音和转写，停止供音不能撤回已交付的音频。
3. **后续再接内部AI语音**：直接PCM与L2+PS交互单独适配，不阻塞系统麦克风。具体生命周期、工程选择与验收以[实施规格](../specs/dualsense-bluetooth-microphone.md)为准。

不需先投入PS5链路抓包、猜测加密、开发内核驱动或USB-over-IP。已有公开协议足够开始一个小范围、可证伪的Mac真机验证；若本机IOHID路径不稳定，再切到含Mac音频修复的Pico方案。

## 复用现有 Codex Micro RP2040：2026-10-17 追加核验

用户希望优先复用已连 Mac、承担 Codex Micro 功能的开发板，而不另运行 ControlDeck。**同一块板兼任 Codex 控制与无线麦克风桥在架构上可以设计；现有物理板能否做到，要先确认无线硬件。**

本机只读 USB 枚举确认 `Codex Micro` 已连接，VID/PID 为 `303a:8360`，序列号为 `CODEXPAD-RP2040-01`。但这些字段均由 `firmware/rp2040/src/usb_descriptors.c` 写死，不能据此识别实际板型、是否有无线模块。没有触发重启或 BOOTSEL，没有打开录音或刷写。

当前固件及构建证据：

- `firmware/rp2040/build/CMakeCache.txt` 为 `PICO_BOARD=pico`、`PICO_PLATFORM=rp2040`，生成头文件包含 `boards/pico.h`。这证明构建目标，不足以证明物理板一定不是 Pico W。
- `firmware/rp2040/CMakeLists.txt` 仅链接 `pico_stdlib`、`tinyusb_device`、`tinyusb_board`，没有蓝牙协议栈或无线驱动。
- USB 描述符只有 CDC 与 Codex 私有 HID；`tusb_config.h` 未启用 Audio。主循环目前执行 USB task、CDC 命令读取和 HID 队列发送，不存在麦克风数据接收。

RP2040 是微控制器型号，本身没有蓝牙射频。普通 Pico 与 Pico W 都使用 RP2040，但后者额外带无线模块；官方规格明确把 Bluetooth 限定于 W/WH。[Raspberry Pi 官方规格](https://www.raspberrypi.com/products/raspberry-pi-pico/)

用户随后确认名称为 **RP2040 Plus**。若是常见的 Waveshare RP2040-Plus，厂家列出的增强项是4MB/16MB Flash、USB-C、电池充电接口和供电芯片；该型号并非无线板。不要与 RP2350B-Plus-W 等无线型号混淆。[Waveshare 产品规格](https://www.waveshare.com/rp2040-plus.htm)、[型号 Wiki](https://www.waveshare.com/wiki/RP2040-Plus)（已通过 Python scrapling 成功抓取，厂商品牌尚未由用户明确确认。）

USB只承担开发板与Mac之间的连接，不会自动将Mac蓝牙控制器共享给开发板。如果不加硬件，可保留原板做Codex Micro，改由Mac内置蓝牙与JoyHarness接收、解码手柄麦克风；无需安装完整ControlDeck应用。若先由Mac收音再经USB发给RP2040，数据已经到Mac，板子对本次收音目标不再提供必要能力。

| 实际板型 | 复用判断 |
| --- | --- |
| 普通 RP2040/Pico，无无线模块 | 无法仅靠升级固件直接接收手柄蓝牙；需加具备 Bluetooth Classic 能力的模块或换无线板 |
| Pico W / 带合适无线模块的 RP2040 | 有无线硬件基础，但必须开发协议接收与转发；不承诺现成 DS5Dongle 完整音频固件可直接用 |
| Pico 2 W（RP2350 + 无线模块） | 更接近 DS5Dongle 的完整参考平台；仍需将本项目 Codex Micro 固件功能合并移植 |

DS5Dongle 的 Pico W 小节只承诺 haptics、没有 speaker，不足以证明 Pico W 已有完整麦克风支持。Pico 2 W 固件也不能直接刷给 RP2040。对资源较小的无线 RP2040，可优先评估**只接收并转发压缩 Opus，留给 Mac 解码**，避免先把实时 Opus 解码及 USB Audio 时钟都放到板上；这是设计建议，尚无本项目实现或实测。[DS5Dongle Pico W 说明](https://github.com/awalol/DS5Dongle#pico-w-version)

建议的合并架构是：保留 Codex Micro HID Report 6、灯效 Feature Report 7 和现有 CDC 控制契约；新增独立音频二进制通道，把带序号/长度的 Opus 包送到 JoyHarness，再接现有语音/虚拟麦克风模块。不能把二进制音频直接塞进当前按换行解析的 CDC 命令流，也不能用音频占满 Codex HID 队列。若选择板端解码，可另加 USB Audio 输入，但需要验证端点、缓冲、CPU 与 Codex 识别兼容性。

还必须处理**手柄连接归属**：不能按“手柄仍直连 Mac 发按键、同时连板子发音频”来设计。Sony 的四个配对槽是切换连接目标，不是同时双主机分流。改由开发板连接 DualSense 后，应由板子同时回传所需按键/摇杆/传感器数据，并接收 Mac 发回的灯光/扳机控制；否则会让现有 JoyHarness 控制路径失去手柄。[Sony 配对槽与切换说明](https://www.playstation.com/en-gb/support/hardware/pair-dualsense-controller-bluetooth/)

USB 身份也需适配：`CodexMicroMirror.swift` 匹配设备 `303a:8360`，`DualSenseHIDOutput.swift` 则匹配 Sony `054c:0ce6`。单个 USB 复合设备只有一对设备级 VID/PID，不能简单拼接两套原始描述符并期待现有匹配都不变。保留 Codex 身份后，JoyHarness 需要新增接收转发手柄状态的路径。

因此，先确认板型，再选择“原板增加接收转发”或“迁移到带无线硬件的板”。不要将现有板直接刷成 DS5Dongle 来试，因为该固件不包含本项目 Codex Micro 身份与协议，会替换掉现有 Codex 功能。

## 不应混为一谈的替代品

- 8BitDo USB Adapter 2 的Mac/DualSense手册不支持audio jack；即使按键可用，也不能据此承诺内置mic。[官方手册](https://support.8bitdo.com/Manual/USB-Adapter-2/ps5-others.html)（本次全文请求未成功，此项只作官方索引可见的限制线索，不作为核心结论支柱。）
- Mayflash产品提到A2DP/HFP是独立蓝牙耳机功能，不能与“支持DualSense按键”拼成Sony私有mic协议支持。[厂家页面](https://www.mayflash.com/product/magic_s_ultimate.html)
- Sony Remote Play 的PC/Mac要求使用电脑端麦克风；它不会自动把未被Mac识别的手柄蓝牙mic转成输入。[官方要求](https://www.playstation.com/en-us/support/games/playstation-remote-play-on-pc-and-mac/)
- DS4专用历史USB无线接收器不是DualSense内置麦克风的解决方案；本次不把DS4耳麦路径作为推荐。

## 研究方法与后续更新

本次使用技能：`research`。改进空间：技能应明确要求对协议研究区分输入/输出方向、官方支持/源码/作者实测/本机实测，并同时固定源码提交与推荐发布版本；README宣称、主分支修复及旧release不能互相替代。特别要防止“搜不到官方API”被写成“硬件做不到”。

本报告没有宣称任何方案已经在用户当前Mac/手柄固件上通过验收。下一步最有价值的是上述阶段一的真实无线WAV验证，而不是继续更改macOS麦克风权限或购买普通蓝牙适配器。
