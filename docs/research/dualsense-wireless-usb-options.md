# DualSense 麦克风的无线 USB / USB-over-IP 方案调查

调查日期：2026-08-23

## 结论

针对 **DualSense 通过 USB 连接时可用的内置麦克风，目标端为 macOS**，目前没有找到一套有厂商正式支持、可以购买后直接使用的“无线 USB”方案。

最接近的架构是：

```text
DualSense --USB 线--> 树莓派或 USB 设备服务器 --Wi-Fi/LAN--> Mac
```

它不是插在手柄上的无源 USB 无线接收器。手柄仍要用 USB 线连接一台有供电的远端主机或设备服务器；网络只替代远端设备到 Mac 之间的那段线。若要随身移动，还需要树莓派、移动电源和短 USB 线一起携带。

关键阻塞点不在带宽，而在 **macOS 客户端是否能接收 USB 等时传输并把远端 USB Audio Class 端点交给 `AppleUSBAudio`**：

- VirtualHere 当前正式下载页明确注明，macOS 客户端上的麦克风和摄像头不能工作。因此“树莓派 + VirtualHere”不能作为本问题的可用方案。
- Linux 主线 USB/IP 协议包含等时传输字段，但它采用服务端导出、客户端虚拟主控制器导入的架构。树莓派可以做 Linux 服务端，macOS 端却仍需要一套可用的虚拟 USB 主控制器/客户端；Linux 上游资料没有提供 macOS 客户端。
- 已核查的商业设备服务器 SEH utnserver Pro 在硬件产品页承诺等时 USB 音视频传输，但其当前 macOS 客户端下载页又明确注明“不支持 USB isochronous mode”，所以同样不能承诺麦克风可用。

因此不建议为这个用途购买 USB 设备服务器或 VirtualHere 许可证。若目标是“手柄操作无线、语音也无线”，低风险方案仍是 DualSense 走蓝牙，麦克风改用 AirPods、无线领夹麦克风或其他被 Core Audio 原生识别的无线输入设备。

## 方案分级

| 等级 | 方案 | 对 Mac + DualSense 麦克风的判断 | 依据 |
| --- | --- | --- | --- |
| A：可落地 | DualSense 蓝牙 + 独立无线麦克风 | 可用，但声音不来自手柄内置麦克风 | macOS 只需读取已有 Core Audio 输入设备 |
| B：仅建议零成本验证 | 树莓派 + VirtualHere Server + Mac Client | 官方明确说 Mac Client 的 microphone 不工作；不应采购后尝试 | VirtualHere Mac 客户端正式下载页 |
| C：协议上有基础、产品上缺客户端 | 树莓派 + Linux USB/IP + Mac | USB/IP 协议描述了 ISO 包，但 Linux 上游没有提供 macOS 导入端；需要另行开发系统级虚拟 USB 客户端 | Linux USB/IP 官方协议文档 |
| D：商业硬件，不满足当前 Mac 音频条件 | SEH utnserver Pro | 服务器支持 isochronous audio/video，但当前 macOS UTN Manager 明确不支持 isochronous mode | SEH 产品页与下载页 |
| E：独立研发项目 | 自研 USB-over-IP macOS 客户端或改为 PCM 网络流 + 虚拟音频设备 | 理论上可做，但已超出 JoyHarness 应用层修改范围 | 需要 DriverKit/系统扩展或 Core Audio 虚拟设备、时钟与丢包处理 |

## 1. VirtualHere：网络可替代 USB 线，但 Mac 客户端排除麦克风

VirtualHere 官方首页把产品描述为 USB over IP / USB over Wi-Fi：USB 设备插在远端 Server 上，通过网络呈现在 Client 上，表现得像本地连接。其 Linux Server 支持 Raspberry Pi 等 ARM/ARM64 设备；Generic Server 试用版可长期共享一个 USB 设备，足够做不购买许可证的验证。局域网运行不需要互联网，默认使用 TCP 7575 和 Bonjour 发现。

但目标端是 Mac 时，正式 Client 页面有直接限制：

> VirtualHere Client for Intel/Apple Silicon MacOS 12 or later (Note Microphones/webcams wont work via VirtualHere)

这条限制直接覆盖当前用途。VirtualHere 的版本记录确实出现过 isochronous、microphone、speaker 和 macOS Server 的修复或改进，说明其协议并非只转发 HID；但必须区分方向：

- “MacOS Server” 的音频 passthrough 改进，是把插在 Mac 上的设备分享给别的客户端。
- 当前问题需要 Mac 作为 Client，仍受正式 Client 页“麦克风不工作”的限制。
- 官方只写“most USB devices”，没有对 DualSense 这种 USB 复合设备作兼容承诺。

因此，“树莓派 + VirtualHere”可以用来理解无线 USB 的工作方式，却不能列为 Mac 上使用 DualSense 麦克风的解决方案。

来源：

- [VirtualHere 首页](https://www.virtualhere.com/)
- [VirtualHere USB Client](https://www.virtualhere.com/usb_client_software)
- [VirtualHere Linux USB Server](https://www.virtualhere.com/usb_server_software)
- [VirtualHere Client 版本记录](https://www.virtualhere.com/node/955)
- [VirtualHere Server 版本记录](https://www.virtualhere.com/node/958)
- [VirtualHere 购买与授权](https://www.virtualhere.com/purchase)

## 2. Linux USB/IP 与树莓派路线：协议支持 ISO，不等于 Mac 可直接使用

Linux 内核官方 USB/IP 文档定义了服务端/客户端架构：服务端导出 USB 设备，客户端导入，实际设备驱动运行在客户端。成功导入后，TCP 连接保持开启，用于传输 USB URB。

协议格式包含 `start_frame`、`number_of_packets` 和 `iso_packet_descriptor`，并明确说明 ISO transfer 的处理。这证明 Linux USB/IP 的协议层并非天然排除 USB Audio 所需的等时传输。

但这条路线还有两个不可跳过的条件：

1. Mac 端必须存在能创建虚拟 USB Host Controller、导入远端设备并与当前 macOS 兼容的客户端。Linux 官方文档和上游工具只构成 Linux 实现证据，不能当作 macOS 支持证明。
2. 即使找到第三方 Mac 客户端，也必须实测完整复合设备是否同时呈现 Audio 与 HID 接口、`AppleUSBAudio` 是否绑定、输入流是否稳定。协议“有 ISO 字段”不等于特定实现和设备组合已经兼容。

网络风险也高于普通 HID：官方协议说明 URB 流量承载在持续 TCP 连接上。由此可推断，Wi-Fi 丢包、重传、漫游和省电造成的抖动会直接影响实时音频；这属于工程风险，不是官方对 DualSense 的兼容结论。

来源：

- [Linux Kernel：USB/IP protocol](https://docs.kernel.org/usb/usbip_protocol.html)
- [Linux 主线 USB/IP 工具 README](https://github.com/torvalds/linux/blob/master/tools/usb/usbip/README)

## 3. 商业 USB 设备服务器：必须同时核对 ISO 与 macOS 客户端

SEH utnserver Pro 是已找到且有官方资料覆盖关键字段的商业例子：

- 产品页写明 `Isochronous USB mode: transfer of audio-video data`，有两个 USB 3.2 Gen 1 端口，并通过网络建立虚拟 USB 连接。
- 当前 SEH UTN Manager for macOS 下载说明支持 macOS 15 和 26，但脚注明确写着 `USB isochronous mode not supported`。

所以不能只看到硬件页的“支持音视频”就下单；最终能力由目标操作系统上的客户端驱动决定。对 DualSense 麦克风而言，当前 Mac 客户端限制已经足以否决这一产品路径。

来源：

- [SEH utnserver Pro 产品页](https://www.seh-technology.com/products/usb-deviceserver/utnserver-pro.html)
- [SEH utnserver Pro 下载页](https://www.seh-technology.com/services/downloads/download-deviceserver/utnserver-pro.html)

没有把其他无线 USB 产品列入候选，是因为现有官方资料不足以同时证明以下四点：当前 macOS 版本支持、USB 2.0 复合设备透明转发、等时音频输入支持、DualSense 兼容。零售页中的“支持 USB”或“支持 Mac”不能替代这四项证明。

## 必要条件与风险

任何未来候选方案都必须同时满足：

1. 远端硬件是 USB Host，能给 DualSense 稳定供电，并转发整个复合设备而非只转发 HID。
2. 传输实现支持 USB 2.0 isochronous IN，且不是只支持存储、打印机等 bulk/control 设备。
3. macOS 客户端明确支持等时输入和 USB Audio，而不是只写“支持 macOS”。
4. 导入后 `AppleUSBAudio` 能绑定远端 Audio 接口，Core Audio 出现输入设备；同时 HID 接口仍正常。
5. 5 GHz/6 GHz Wi-Fi 或稳定有线回程能把持续延迟和抖动控制在可接受范围。

主要风险：

- **兼容性**：DualSense 是复合设备；厂商对普通 USB 音频支持不等于对该复合描述符和接口切换支持。
- **实时性**：等时 USB 本来依赖周期调度；经 TCP/Wi-Fi 转发后会遇到重传和队头阻塞。
- **重连**：手柄休眠、USB 重新枚举、Wi-Fi 切换都可能导致虚拟设备消失，Core Audio 输入随之变化。
- **系统版本**：macOS 的驱动和系统扩展模型会变化；旧产品写的“Mac 支持”不能推导到 macOS 26。
- **便携性**：远端设备、供电和短 USB 线仍要跟随手柄，体验并非真正无线。

## 推荐的最小验证步骤

鉴于官方已经否定 Mac Client 麦克风，不建议购买任何设备来验证。若手边已有树莓派，并希望取得本机实证，可以只做以下零成本实验：

1. 先把 DualSense 直接接 Mac，记录 `system_profiler SPAudioDataType` 与 `ioreg` 中的 Audio/HID 接口，确认基线输入确实可录音。
2. 在树莓派运行 VirtualHere Generic Linux Server，DualSense 通过短 USB 数据线接树莓派；Mac 安装当前 VirtualHere Client，局域网优先使用稳定的 5 GHz Wi-Fi。
3. 导入整台 DualSense 后，只检查三项：`system_profiler SPUSBDataType` 是否出现远端复合设备、`system_profiler SPAudioDataType` 是否出现 DualSense 输入、录制 60 秒是否连续。
4. 若 USB 枚举存在但 Audio 输入不存在，结论就是命中 VirtualHere 官方的 Mac microphone 限制，立即停止，不购买许可证、不继续调整 JoyHarness。
5. 只有当厂商以后书面取消 Mac microphone 限制，或提供明确支持 macOS 26 等时输入的版本时，才重新验证延迟、丢包、休眠重连和 HID/Audio 并用。

这些步骤只能验证当前机器组合，不能把一次偶然成功提升为厂商支持结论。

## 已证实与必须实测

已由官方资料证实：

- VirtualHere 支持以网络替代 USB 线，Linux Server 可运行在 Raspberry Pi 类平台。
- VirtualHere 当前 Mac Client 明确不支持 microphones/webcams。
- Linux USB/IP 协议包含等时传输结构。
- SEH utnserver Pro 硬件支持等时音视频模式，但当前 macOS UTN Manager 不支持 USB isochronous mode。

没有被证实、必须通过具体版本和硬件实测：

- DualSense 整个复合 USB 设备能否被某一未来的 Mac USB-over-IP 客户端完整导入。
- 导入后 `AppleUSBAudio` 能否绑定、麦克风 PCM 是否连续、HID 是否可同时使用。
- Wi-Fi 环境下的端到端延迟、抖动、丢包恢复、休眠与重连行为。
- 任何未明确写出“macOS + isochronous input/audio”的商业产品是否可用。
