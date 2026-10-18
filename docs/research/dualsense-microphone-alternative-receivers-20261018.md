# DualSense 无线内置麦克风：替代接收器与 Linux 中转方案复核

核查日期：2026-10-18（Asia/Shanghai）。只讨论 **DualSense 内置麦克风 → 无线 → Mac 系统输入**。本次只阅读一手文档、GitHub Releases API 与固定 tag 源码；未安装软件、刷写板卡或实测新方案。网页、API 和源码均使用 Python `scrapling` 0.4.15 抓取。

## 结论

有现成可下载方案，但硬件路线仍需要一块带无线的板：**Pico 2 W + DS5Dongle OLED Edition 固件**是本次最具体的备选。稳定版已经包含面向 CoreAudio 的麦克风 USB 供数修正，提供 UF2；无需 OLED 显示屏。它把蓝牙接收和 Opus 解码移到板上，再向 Mac 提供 USB 音频输入，能绕过当前 Mac 原生蓝牙/HID 接收段。它不能直接通过给现有 RP2040 Plus 下载该固件实现；用户板子的品牌及是否另带无线模块尚未确认，不能仅凭 RP2040 名称排除板载无线。

另有两个 Linux 项目提供预编译程序，可把内置麦克风发布为 PipeWire 输入，再用 SonoBus 和 BlackHole 转给 Mac。但这是多个现成组件的组合，**未找到该完整组合的项目方端到端实测记录**，不应称为一键 Mac 方案。

本次核查的 8BitDo / Mayflash 官方材料没有明确承诺 Mac 上 DualSense 内置麦克风无线输入；普通“支持 DualSense / 支持 Mac / 支持蓝牙耳机”不可相乘得出支持本用途。

## 1. Pico 2 W 与 DS5Dongle

### 上游：最新版仍未发布七月的 Mac 麦克风修正

刷新 [上游 Releases API](https://api.github.com/repos/awalol/DS5Dongle/releases?per_page=5) 后，最新正式版仍为 **v0.7.2-hotfix，2026-06-20 UTC（上海时间 06-21）**。

- [现成 UF2](https://github.com/awalol/DS5Dongle/releases/download/v0.7.2-hotfix/ds5-bridge-v0.7.2-hotfix.uf2) 确实存在。
- [Issue #220](https://github.com/awalol/DS5Dongle/issues/220) 是用户实测：MacBook Air M4 / Mac mini M1、macOS Tahoe 26.5.1、普通 DualSense、Pico 2 W、v0.7.2；内置 mic 和耳麦 mic 均有 jitter、随机回声和信噪比问题。它证明采到声音，未证明质量合格。
- [PR #232](https://github.com/awalol/DS5Dongle/pull/232) 于 **2026-07-18 18:53 UTC（上海时间 07-19）**合并，commit `a66f5cf9eebb1938019eac9ec92f3f1406c99376`，将 USB mic 输出改为按主机 FIFO 空间供应 1 ms 片段，增加缓冲与欠载处理。
- 所以不能把上游“latest UF2”直接当成包含上述修复的版本。若选上游，应固定包含修复的源码自行构建。

### OLED Edition：稳定 UF2 已有 Mac 音频节奏修正

刷新 [OLED Releases API](https://api.github.com/repos/MarcelineVPQ/DS5Dongle-OLED-Edition/releases?per_page=30)：

| 项目 | 最新稳定版 | 最新开发预发布 |
|---|---|---|
| Tag | `v0.9.4-oled-edition` | `v0.9.5-dev.19-oled-edition` |
| 发布时刻（上海） | 2026-10-13 03:14 | 2026-10-18 11:43 |
| 板用 UF2 | 有 | 有 |
| Mac 配置应用 | universal ZIP | universal ZIP |
| 默认 Pico 2 W 时钟 | 320 MHz / 1.20 V | 150 MHz |
| 状态 | stable | 明确标记 prerelease |

稳定版下载：

- [稳定版 Release](https://github.com/MarcelineVPQ/DS5Dongle-OLED-Edition/releases/tag/v0.9.4-oled-edition)
- [稳定版 UF2](https://github.com/MarcelineVPQ/DS5Dongle-OLED-Edition/releases/download/v0.9.4-oled-edition/ds5-bridge-oled-v0.9.4-oled-edition.uf2)
- [稳定版 Mac 配置应用](https://github.com/MarcelineVPQ/DS5Dongle-OLED-Edition/releases/download/v0.9.4-oled-edition/DS5Dongle-OLED-Edition-Configurator-0.9.4-mac-universal.zip)
- [校验和](https://github.com/MarcelineVPQ/DS5Dongle-OLED-Edition/releases/download/v0.9.4-oled-edition/SHA256SUMS.txt)

核查固定 tag 的 [audio.cpp](https://github.com/MarcelineVPQ/DS5Dongle-OLED-Edition/blob/v0.9.4-oled-edition/src/audio.cpp)：有 71B Opus mic 接收、core1 解码、按 USB host FIFO 空间供应 1 ms / 192B stereo int16 片段；源码明确注明用于 macOS CoreAudio。固定 tag 的 [README](https://github.com/MarcelineVPQ/DS5Dongle-OLED-Edition/blob/v0.9.4-oled-edition/README.md)明确说内置 mic 经蓝牙接收后表现为 USB capture device，OLED 是可选件，无屏时正常运行。

**局限必须保留：**稳定版发布说明只写 Linux / Windows 实测；Mac ZIP 存在不等于该版本已完成 Mac 真人收音验收。稳定 tag 的 [CMakeLists.txt](https://github.com/MarcelineVPQ/DS5Dongle-OLED-Edition/blob/v0.9.4-oled-edition/CMakeLists.txt)默认 320 MHz，不能套用最新分支的 150 MHz 宣传。

最新开发版 [dev.19 Release](https://github.com/MarcelineVPQ/DS5Dongle-OLED-Edition/releases/tag/v0.9.5-dev.19-oled-edition)有以下相关变更：

- 重开 mic 时清空上次会话残留帧，关闭后停止继续 PLC。
- 修复 dev.9 配置迁移会把 PC sleep 参数误当 mic level 的错误。
- [对应 CMake](https://github.com/MarcelineVPQ/DS5Dongle-OLED-Edition/blob/v0.9.5-dev.19-oled-edition/CMakeLists.txt)默认 150 MHz。
- 发布说明写 Apple Silicon Mac 运行过配置应用 smoke test；**这个声明不等于麦克风音质经过实测**。

开发版资产路径为 [dev.19 UF2](https://github.com/MarcelineVPQ/DS5Dongle-OLED-Edition/releases/download/v0.9.5-dev.19-oled-edition/ds5-bridge-oled-v0.9.5-dev.19-oled-edition.uf2)。它适合单独受控对照，不能仅因更新就承诺更稳定。

### 硬件与接入成本

- 一块 **Raspberry Pi Pico 2 W（RP2350 + CYW43）**与 USB 数据线；项目稳定版 README 给板价参考约 US$7，实际本地售价/税运费未核验。Pico 2 W 原板是 Micro-USB 接口，勿照抄该 README 的 USB-C 线表格。[官方硬件](https://www.raspberrypi.com/products/raspberry-pi-pico-2/)
- OLED 不必购买。稳定版超频条件下项目建议散热片；开发版默认已改为额定时钟。
- 手柄需改配到板上；板以 USB 向 Mac 转发按键和音频。需要重新验证 Joy Harness 的按键匹配、灯效和 PTT 路径。
- 保留用户现有 RP2040 Plus 的 Codex Micro 固件。尚未确认用户实物板的品牌及无线模块配置。若为 Waveshare RP2040-Plus 标准板，则没有板载无线；USB 连接本身不会赋予蓝牙接收能力。无论是否另带无线模块，都不能直接刷入 Pico 2 W UF2。

### 容易被误认为新 Mac mic 修复的另一下载

[NSEvent/ds5dongle-pico2w-macos](https://github.com/NSEvent/ds5dongle-pico2w-macos)提供 [master-fa83c77 UF2](https://github.com/NSEvent/ds5dongle-pico2w-macos/releases/download/master-fa83c77/ds5-bridge-pico2w.uf2)，发布于 **2026-06-25 UTC**。README 明确针对 **扬声器静音/lock_volume**；源自上游 `fa83c77`，早于七月 Mac mic pacing 修复。作者称 mic works fine，是作者自述；不能据此优先于包含 #232 的版本，也不能把扬声器修复说成当前麦克风问题的修复。

## 2. Linux 接收后送到 Mac

### 有现成二进制的接收端

**dualsense-neo v0.1.0，2026-07-22 UTC（上海 07-23）**：

- [Release](https://github.com/forgerpl/dualsense-neo/releases/tag/v0.1.0)
- [Ubuntu 24.04 amd64 .deb](https://github.com/forgerpl/dualsense-neo/releases/download/v0.1.0/dualsense-neo_0.1.0-1_ubuntu24.04_amd64.deb)
- [Ubuntu 26.04 amd64 .deb](https://github.com/forgerpl/dualsense-neo/releases/download/v0.1.0/dualsense-neo_0.1.0-1_ubuntu26.04_amd64.deb)
- [通用 Linux x86_64 tar.gz](https://github.com/forgerpl/dualsense-neo/releases/download/v0.1.0/dualsense-neo-v0.1.0-x86_64-unknown-linux-gnu.tar.gz)

固定 tag [README](https://github.com/forgerpl/dualsense-neo/blob/v0.1.0/README.md)明确提供 `DualSense Microphone (Bluetooth)` PipeWire source，支持单独 `dualsense-neo source`，有实际消费者时才开启 mic。需要 Linux + BlueZ + PipeWire + libopus；预编译包只有 x86_64/amd64，树莓派 ARM 需自行编译。其内核电量误报/实时调度限制仍存在。

**LinuxAudio4Dualsense5 0.6，2026-06-30 UTC**：

- [Release](https://github.com/GeorgLegato/LinuxAudio4Dualsense5/releases/tag/0.6)
- [Linux x86_64 tar.gz](https://github.com/GeorgLegato/LinuxAudio4Dualsense5/releases/download/0.6/ds5-bt-audio-0.6-x86_64.tar.gz)
- 固定 tag [README](https://github.com/GeorgLegato/LinuxAudio4Dualsense5/blob/0.6/README.md)提供 `microphone = on` 和 `DualSense BT Mic` source；作者列出 Ubuntu 24.04.4、kernel 6.8、PipeWire 1.0.5、普通 DualSense 的测试配置。
- README 明确承认开 mic 会让内核/Steam 把 mic 报告误判成摇杆输入。此缺点关系到用户同时控制 Codex 的需求，不宜忽略。

### 拼接成 Mac 系统输入的具体路线

```text
DualSense 内置 mic
  → Linux 主机蓝牙 + dualsense-neo
  → PipeWire 的 DualSense Microphone (Bluetooth)
  → Linux SonoBus 输入
  → 局域网 PCM
  → Mac SonoBus 输出到 BlackHole 2ch
  → Codex 选择 BlackHole 2ch 输入
```

[SonoBus 项目](https://github.com/sonosaurus/sonobus)提供 Linux / Mac 成品应用，支持 P2P 局域网音频与 16/24/32-bit PCM，避免本次对照再加一轮有损编码。[官方下载](https://sonobus.net/) / [Linux 安装](https://sonobus.net/linux.html)。BlackHole 官方 [Virtual Microphone 指南](https://github.com/ExistentialAudio/BlackHole/wiki/Use-BlackHole-as-a-Virtual-Microphone)说明可作为其他应用的 mic 输入。

这是依据组件接口提出的**可行组合设计**，不是本轮已验证的完整方案；需要 Linux 机器持续开机、局域网、音频路由配置，并新增网络缓冲延迟。已有闲置 Linux PC / Steam Deck 时值得作为独立接收栈对照；为此专买电脑不划算。Linux 虚拟机若没有独占的蓝牙 USB 设备，不能默认绕过 Mac 蓝牙栈问题。SonoBus 公开文档说明音频 P2P 且未加密，本地对照应限定受控局域网。

## 3. 商用普通 dongle 核查

- [8BitDo USB Adapter 2 DualSense/macOS 官方手册](https://support.8bitdo.com/Manual/USB-Adapter-2/ps5-others.html)：本轮已成功抓全文；macOS 表明确不支持 touchpad、adaptive triggers、haptic feedback、audio jack。未承诺内置 mic。audio jack 限制本身不是内置 mic 的直接证明，但整页只有控制器映射，不能据此推荐其用于 mic。
- [MAYFLASH MAGIC NS 2 官方页](https://mayflash.com/product/showproduct.php?id=45)：支持 macOS 控制器连接，同时说明 Bluetooth headset **仅用于 Switch 模式**，A2DP 支持、HFP 不支持。该耳机功能不是 DualSense 私有 Opus-in-HID mic 上行，未找到厂家针对 Mac 内置 mic 的承诺。
- 搜索到 Brook 下载页中的“headset microphone 改善”等条目，但未能绑定到本题的 **DualSense 内置 mic + 无线 + Mac** 三项组合，因此不作购买推荐。

## 推荐顺序与验收边界

1. 若 Mac 原生软件对照仍无法恢复完整收包，新增硬件的首选是 **独立 Pico 2 W + 已核对固定 tag 的 DS5Dongle OLED 固件**；可下载、能绕过当前蓝牙接收栈，成本比另一台主机低。
2. 若已有 Linux 主机，先用 **dualsense-neo** 做当地录音，再接 SonoBus → BlackHole；先证明 Linux 上的原始 PCM 连续，才有必要加网络层。
3. 不盲买 8BitDo / Mayflash 这类只证明按键或耳机兼容的 dongle。

两条路线都需同样验收：真人连续说话、对齐真实时间与解码时长、检查空档/削波、回听，再测 Codex 转写。下载资产存在、README 勾选支持和程序能运行，都不能代替本机质量验收。

使用 SKILL：`research`。改进建议：技能可明确要求把发布资产、固定 tag 源码、作者实测和本机实测分开标注，避免以最新分支文档替代稳定下载版本能力。
