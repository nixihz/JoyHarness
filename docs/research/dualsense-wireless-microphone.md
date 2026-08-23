# DualSense 内置麦克风在 macOS 蓝牙模式下的可行性调查

调查日期：2026-08-23

## 结论

在当前公开资料和本机实测范围内，**没有可通过 macOS 设置、麦克风权限或 JoyHarness 应用代码直接开启的 DualSense 蓝牙麦克风方案**。

有线可用与蓝牙不可用并不矛盾：

- USB 连接时，DualSense 是复合 USB 设备，单独暴露标准 USB Audio Class 音频接口；macOS 的 `AppleUSBAudio` 驱动可直接把它注册为 Core Audio 输入设备。
- 蓝牙连接时，macOS 将 DualSense 作为游戏手柄/HID 使用。HID 报告可以传递按键、传感器、静音键状态，以及下发静音灯和音频路由控制，但这些控制字段不是麦克风 PCM 音频流。
- 标准蓝牙音频需要双方协商相应的音频 profile。HID 只负责游戏手柄输入；A2DP 主要用于高质量播放；双向语音通常走 HFP。没有证据表明 DualSense 在连接 Mac 时向系统暴露 HFP/A2DP 麦克风端点。
- PS5 能无线使用手柄麦克风，说明硬件本身具备某种无线音频能力；但 Sony 没有公开这条主机侧协议。若该能力不是标准 HFP，而是 Sony 私有链路，那么实现它需要先逆向无线音频封包、编码、时钟、丢包处理和控制握手，再实现 macOS 虚拟音频输入设备。这不是给现有驱动补一个开关。

因此，现阶段可落地的选择仍是：DualSense 用 USB 数据线；或让手柄继续走蓝牙，语音改用 Mac 内置麦克风、AirPods/蓝牙耳机或独立无线麦克风。

## 证据

### 1. Sony 的官方兼容性边界

PlayStation 官方支持页说明 DualSense 可以通过 USB 或 Bluetooth 连接 Mac，但同时明确写道：

> 内置麦克风与扬声器适用于 Windows PC，在支持的游戏中可用。与 Mac 电脑和移动设备不兼容。

同页还明确说明耳机插孔在 PC 和 Mac 上需要有线连接。

这证明“手柄可以通过蓝牙连接 Mac”只承诺控制器连接，并不等于音频功能也可用。Sony 没有提供适用于 macOS 的蓝牙麦克风驱动、设置或 API。

来源：

- [PlayStation 简体中文支持页](https://www.playstation.com/zh-hans-cn/support/hardware/pair-dualsense-controller-bluetooth/)
- [PlayStation 英文支持页](https://www.playstation.com/en-gb/support/hardware/pair-dualsense-controller-bluetooth/)

证据边界：Sony 的表述甚至没有承诺 USB 麦克风兼容 Mac；本机实际可用属于官方承诺之外的兼容行为。该实测不能反向证明蓝牙音频也存在可开启的标准接口。

### 2. Apple 只承诺游戏手柄连接，不承诺音频端点

Apple 把 DualSense 列入受支持的 PlayStation 控制器，并分别提供蓝牙配对和 USB 数据线连接方法。Apple 的通用说明同时指出，音频插孔、灯等具体功能的支持会因控制器和应用而异。两份页面都没有承诺 DualSense 麦克风或扬声器可作为 macOS 蓝牙音频设备使用。

Apple 的 `GCDualSenseGamepad` 公共 API 只列出触控板按钮、两个触控点、左右自适应扳机，并继承标准扩展手柄输入；没有麦克风采集或音频流 API。这意味着 JoyHarness 当前使用的 GameController 框架没有一条可读取手柄麦克风的公开入口。

来源：

- [Apple：Connect a PlayStation wireless game controller to your Apple device](https://support.apple.com/en-us/111100)
- [Apple：Connect a wireless game controller to your Apple device](https://support.apple.com/en-us/111099)
- [Apple Developer：GCDualSenseGamepad](https://developer.apple.com/documentation/gamecontroller/gcdualsensegamepad)

### 3. 本机 USB 枚举证明有线模式走 USB Audio Class

在本机 macOS 26.5.2（25F84）上、DualSense 通过 USB 连接时，执行 `system_profiler SPAudioDataType` 得到：

```text
DualSense Wireless Controller:
  Default Input Device: Yes
  Input Channels: 2
  Manufacturer: Sony Interactive Entertainment
  Current SampleRate: 48000
  Transport: USB
```

USB 接口枚举显示 VID/PID 为 `054c:0ce6`，并同时出现：

```text
Interface 0: bInterfaceClass = 1, bInterfaceSubClass = 1
Interface 1: bInterfaceClass = 1, bInterfaceSubClass = 2
Interface 2: bInterfaceClass = 1, bInterfaceSubClass = 2
Interface 3: bInterfaceClass = 3, bInterfaceSubClass = 0
```

前三个接口由 `AppleUSBAudio` / `usbaudiod` 接管，第四个由 Apple HID 驱动接管。USB-IF 的官方 class code 表定义 `01h` 为 Audio、`03h` 为 HID。这说明 USB 模式下音频与手柄控制是不同接口，麦克风不是从 HID 按键报告中“提取”出来的。

来源：

- 本机命令：`system_profiler SPAudioDataType`
- 本机命令：`ioreg -r -c IOUSBHostInterface -l -w 0`
- [USB-IF：Defined Class Codes](https://www.usb.org/defined-class-codes)

### 4. Linux 的 Sony 驱动明确区分 HID 控制与蓝牙音频

Linux 主线 `hid-playstation.c` 同时支持 DualSense USB HID 和 Bluetooth HID，源码包含两套输入/输出 report：

- USB 输入报告 `0x01`、蓝牙输入报告 `0x31`
- USB 输出报告 `0x02`、蓝牙输出报告 `0x31`
- 两种传输共享部分音频控制字段，例如耳机/扬声器/麦克风音量、静音灯和音频路由

但驱动在处理插孔状态和创建设备时两次明确注明：

> Bluetooth audio is currently not supported.

它只在 `BUS_USB` 下创建耳机插孔设备和处理插孔状态。源码对内置麦克风静音键的实现，是读取 HID 按键位并通过 HID 输出报告切换硬件静音和 LED；这仍然不是采集音频样本。

来源：

- [Linux 主线 `hid-playstation.c` 固定版本](https://kernel.googlesource.com/pub/scm/linux/kernel/git/torvalds/linux/+/2709dd5ae32f0828f386327c76bba9f39f63a1c6/drivers/hid/hid-playstation.c)
- 关键位置：报告定义约第 81 行、音频控制字段约第 153/269 行、静音键处理约第 1512 行、蓝牙音频限制约第 1530 和 1852 行

证据边界：这只能证明 Linux 主线 HID 驱动没有实现蓝牙音频，不能证明硬件永远无法传输无线音频。反过来，它也没有公开一个可直接移植到 macOS 的音频解码实现。

## USB Audio、Bluetooth HID、HFP 与 A2DP 的区别

| 机制 | 在本问题中的作用 | 能否直接提供麦克风给 Core Audio |
| --- | --- | --- |
| USB Audio Class | USB 复合设备中的独立音频控制和音频流接口 | 可以；本机已由 `AppleUSBAudio` 识别 |
| Bluetooth HID | 游戏手柄按键、摇杆、传感器、状态和控制报告 | 不可以；静音键或 `mic_volume` 控制字段不是音频样本 |
| HFP | 面向耳机/车载免提的双向语音 profile | 原理上可以，但没有证据表明 DualSense 对 Mac 暴露 HFP 服务 |
| A2DP | 从音源向耳机/音箱传输高质量播放音频 | 通常不是麦克风上行通道，不能用来解释 DualSense 麦克风输入 |

Apple 对蓝牙 profile 的官方说明也将 HID 定义为键盘和游戏控制器通信，将 A2DP 定义为向耳机、扬声器或车载系统播放音频，将 HFP 定义为耳机/车载免提与手机通信。该页面针对 iOS/iPadOS，不是 macOS 兼容列表，因此这里只引用其 profile 语义，不把它当成 macOS 支持证明。

来源：[Apple：Bluetooth profiles that iOS and iPadOS support](https://support.apple.com/en-us/102842)

## 软件实现路径评估

### 路径 A：修改 JoyHarness 或切换系统权限

不可行。JoyHarness 只能选择 Core Audio 已注册的输入设备；当蓝牙模式下系统没有创建 DualSense 音频端点时，应用层没有可选择的设备。麦克风隐私权限只控制应用能否读取已有输入设备，不能让 HID 设备变成音频设备。

### 路径 B：使用现成 Apple/Sony 驱动或公开 API

没有发现。Sony 明确把内置麦克风列为不兼容 Mac；Apple 的 GameController API 不含音频；Apple 支持页也不承诺 DualSense 音频。当前资料中没有 Sony 提供的 macOS 驱动或公开无线音频协议。

### 路径 C：自行实现私有无线音频驱动

理论上不能完全排除，但当前不具备可实施条件。至少需要：

1. 捕获并识别 PS5 与 DualSense 之间的无线音频承载方式，确认它走标准 profile、附加 L2CAP 通道，还是 HID 私有报告。
2. 逆向编解码格式、采样率、包序、时钟同步、丢包恢复、加密/认证和启停握手。
3. 在 macOS 上可靠地与系统蓝牙/HID 驱动共存并访问原始传输。
4. 实现 Core Audio 虚拟输入设备，把解码后的 PCM 暴露给 Codex Desktop。

Linux 主线源码目前没有可复用的蓝牙音频实现。这一路径属于独立的协议逆向和驱动项目，风险包括固件版本差异、macOS 私有接口限制、时延和稳定性，不适合作为 JoyHarness 的近期功能。

### 路径 D：外部无线 USB 桥

从 Mac 看仍可保留 USB Audio Class，但需要另一端硬件承接 DualSense USB，再经网络/专有无线链路转发 USB 或 PCM。它不是纯软件方案，也通常会引入延迟、供电和设备重连问题。

## 建议

1. 保留 JoyHarness 当前的事实型提示：DualSense 内置麦克风需要 USB，蓝牙模式使用其他系统输入设备。
2. 若目标只是无线操作体验，优先使用 Mac 内置麦克风、AirPods/蓝牙耳机或独立无线麦克风；这是低风险且能被 Core Audio 原生识别的方案。
3. 若仍要验证私有协议路线，把它拆成独立研究项目。第一阶段只做蓝牙服务枚举和合法的本机抓包，验收条件是找到持续的麦克风音频载荷；在此之前不要投入 macOS 虚拟音频驱动开发。

## 已查范围与未确认项

已查：Sony/PlayStation 官方兼容性页面、Apple 官方控制器支持页面、Apple `GCDualSenseGamepad` API、USB-IF class code、Linux 主线 Sony `hid-playstation` 驱动、本机 macOS USB/音频枚举。

未找到：Sony 发布的 DualSense 蓝牙音频协议、适用于 macOS 的官方音频驱动、Linux 主线或 Apple 公共 API 中可直接读取 DualSense 蓝牙麦克风的实现。

未确认：PS5 无线音频具体使用的承载通道和编解码格式。没有这项证据，不能声称“绝对无法由软件实现”；能下的结论是“没有现成或公开、可直接落地的软件路径”。
