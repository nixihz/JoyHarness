# RC003-MS 内置麦克风

Joy Harness 直接接收遥控器的 BLE 语音，解码后交给应用自带的虚拟麦克风组件。
不需要 BlackHole 或独立语音桥应用，不使用电脑麦克风来替代遥控器。

## 使用

1. 配对 RC003-MS，启动固定路径的 Joy Harness，并允许其访问蓝牙。
2. 在“设置 → 通用 → 遥控器麦克风”启用 Joy Harness 麦克风组件。组件随 App 打包，
   安装到 `/Library/Audio/Plug-Ins/HAL/JoyHarnessMicrophone.driver`，首次需要管理员验证。
   安装程序重载音频服务，新设备出现前声音可能短暂中断。
3. 点击“使用遥控器作为系统麦克风”。语音应用使用系统默认输入，或直接选择
   “Joy Harness 遥控器麦克风”。这会改变默认输入，可在系统声音设置中切回。
4. 按住遥控器语音键说话。按键动作沿用自定义映射；原生模式暂停语音桥接。

### Spokenly

Spokenly 的录音快捷键可设为“右侧 Command / 按住或切换”，Joy Harness 的语音键
映射为“右侧 Command”。Spokenly 的麦克风选择“使用系统默认”。Joy Harness 发送
标准修饰键状态事件，并在映射模式下屏蔽此遥控器原生 F5，避免重复按键干扰录音；
原生模式或退出时恢复 F5。松开语音键后，等待末尾音频排空再释放录音快捷键。

## 链路与边界

`RC003 麦克风 → ATVV BLE → 16 kHz 单声道 PCM → 轻量语音增强 → CoreAudio 重采样 → Joy Harness HAL 组件 → 语音应用`

- Bluetooth Device Information 的 Model Number 必须确认是 `RC003` / `RC003-MS`。
- ATVV 服务 `AB5E0001-5A21-4F05-BC7D-AF01F617B664`；尾号 `0002` 为主机命令，
  `0003` 为音频通知，`0004` 为控制通知。
- 实机能力应答：`0b 01 00 02 03 00 78 00 00`，v1.0、16 kHz IMA/DVI ADPCM、120 字节帧。
- 实机按住语音键可直接上报 `04 03 02 <session>`，无需先出现 `08 START_SEARCH`。
  松开上报 `00 02`。按会话重置解码状态；同步包刷新 predictor/index 并丢弃不完整帧。
- 音频以高半字节优先解码；只保存在进程和音频缓冲中，不保存、上传或转写语音。
- BLE/ADPCM 解码完成后、回调给识别链路前，PCM 经过保守的 80 Hz 高通、低电平噪声衰减、+6 dB 增益和软限幅；增强器跨 BLE 分包保留状态，避免产生边界杂音，且不会把峰值推过 0 dBFS。HAL 只转发实时 PCM，不对生成文件做后处理。
- HAL 组件提供固定 48 kHz、双声道 Float32 输入与输出，设备 UID 为
  `tech.keli.joyharness.microphone.device`。应用按 UID 定向输出，不向扬声器播放。
- 每帧时间戳防止循环缓冲区中的旧语音被重放；未写入的时段读出静音。
- 输出缓冲有上限，语音键释放等待末尾音频输出。断开、停用或新会话清理旧数据。
- 设备出现在列表、蓝牙握手成功、解码有数据分别只是局部证据。完整验收仍需确认
  语音应用收到遥控器讲话并保留句首、句尾。

## 验证

`task test` 包含 Swift 语音协议测试以及带 AddressSanitizer / UndefinedBehaviorSanitizer
的 HAL 组件测试。覆盖实际能力响应、ADPCM 独立参考向量、分包、同步、会话隔离、
PCM 环回、静音、循环缓冲过期、重启清空和格式约束。

2026-09-19 已在当前 RC003 实机收到、解码多次语音会话；自带 HAL 组件已被 CoreAudio
加载，系统默认输入已切换为“Joy Harness 遥控器麦克风”，应用音频输出队列正常排空。
用户已确认系统麦克风测试正常；Spokenly 的按住录音与实际识别效果、句首和句尾
完整性仍待实机验收。当前构建的驱动已签名，
本机构建的组件安装包未公证；公开发布时须单独完成安装包签名、公证和目标机器验收。

## 协议资料

- [RC003 实机音频契约](https://github.com/mintisan/omavoice/blob/ba731306b6922ada2f75ac8e6361a492581f7c71/docs/RC003-HARDWARE.zh-CN.md)
- [ATVV 特征与音频格式说明](https://github.com/HD838A/remote-mic-app/blob/d0396756944d2ddcb889a54da736ca7140c7cabf/TECHNICAL.en.md)
- [Core Bluetooth](https://developer.apple.com/documentation/corebluetooth)
- [AudioServerPlugInDriverInterface](https://developer.apple.com/documentation/coreaudio/audioserverplugindriverinterface)
