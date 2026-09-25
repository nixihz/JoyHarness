# 更新日志 (Changelog)

本项目的重大变更均记录于此。

格式基于 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
且本项目遵循[语义化版本 (Semantic Versioning)](https://semver.org/lang/zh-CN/)。

[English](CHANGELOG.md)

## [Unreleased]

### 新增
- 新增按下 PS/Home 即时呼出的 Harness 切换浮层，支持 Codex、Claude、Cursor 和 Antigravity 的独立映射、应用关联及唯一前台应用匹配。浮层宽度随已启用的 Harness 数量扩展，macOS 26 上使用 Liquid Glass 玻璃背景。卡片显示关联应用的真实图标；再次按 PS/Home 或 B、点击任意位置、切换应用或桌面空间都会关闭浮层且不切换 Harness。末尾的“主窗口”卡片可直接用手柄显示 Joy Harness 主窗口，关闭后也能重新打开。
- 原生模式应用列表新增 Antigravity，默认关闭以保留其 Harness 映射；旧开发版的默认开启状态会迁移为关闭。默认应用仅在已安装时列出。
- 新增 Claude Harness 默认映射：L1/R1 切换到上一个/下一个 Claude 会话（`⌘⇧[` / `⌘⇧]`），RT 打开 Claude 搜索（`⌘⇧K`）。已保存的 Claude 配置中这些键若仍为“不执行操作”，会一次性补上新默认值。
- Dashboard 手柄图示显示 Xbox、PlayStation 品牌标识和小米字标。
- 连接多个设备时，Dashboard 顶部显示设备切换器，并自动切换到最近按下按键的设备；同名设备会自动编号。切换器只影响展示，与设置中的“设置设备”选择器相互独立。

### 变更
- 游戏手柄的 PS/Home 在映射模式下改为呼出 Harness 切换浮层；原生手柄模式下按 PS/Home 返回映射模式，与小米遥控器主页键一致。
- 安装和本地测试构建改为写入 `/Applications/Joy Harness.app`，并移除旧的 `~/.agent-deck/Joy Harness.app` 副本。
- 右摇杆在所有 Harness 中直接滚动，无需按住 LT；速度和方向与 LT + 左摇杆相同，并可与左摇杆移动鼠标同时进行。LT + 左摇杆滚动继续保留，供单只 Joy-Con 使用；LT + 右摇杆四个方向仍触发各自的映射。Codex 径向输入改为只由十字键左/下/右发送。

### 修复
- 当前映射配置页选中小米遥控器时仍保持 DualSense R2 自适应阻力，避免重复挂载手柄，并支持 Joy Harness 在后台时通过蓝牙恢复扳机效果。
- 小米遥控器语音服务就绪时预热虚拟麦克风，并在连续语音会话间复用 CoreAudio 输出引擎，避免反复重建设备链路造成大概率无声。
- Harness 切换浮层显示期间释放已激活的映射输出，并阻止非 Codex Harness 发送 Codex Micro 按下或径向输入。
- 通过 USB 和蓝牙 HID 输入报告识别 DualSense PS 键。
- 每次按下 PS 都能呼出 Harness 切换浮层：DualSense 持续发送的输入报告不再推迟 HID 松开判定；同一次按压经 GameController 与 HID 两路到达时只计一次，即使其中一路延迟或丢失松开事件；GameController 尚未列出手柄时也能响应。
- 呼出 Harness 切换浮层的手柄断开时自动关闭浮层，并在状态文件中记录新选中的 Harness。
- 展示其他设备期间，已连接的 Joy-Con 保持自己的握持方向、摇杆和电量读数。
- 主窗口关闭后点击 Dock 图标可重新打开；此前点击没有反应。

## [0.7.0] - 2026-09-21

### 新增
- 标准游戏手柄与小米遥控器可同时保持连接，提供在线设备选择器和彼此独立的映射配置。
- 新增按需展开的连接详情侧栏、固定 Dashboard 工作区，以及跟随系统、日间和夜间三种外观设置。

### 修复
- 修复小米遥控器在映射模式下同时输出自定义按键与原始反引号或 F5 的问题；正确匹配蓝牙设备并在原生模式或退出时恢复原始按键。
- 遥控器 HID 事件服务延迟出现时持续重试原生按键屏蔽，成功或离开映射模式后停止重试。
- 小米遥控器独立保存映射、应用目标与录制快捷键，保留升级前的遥控器配置，避免断连重连丢失设置或覆盖其他手柄配置。
- 语音键松开后继续接收 BLE 句尾音频，播放完成再释放录音快捷键；断连、停用或切换原生模式时立即取消音频。
- Dashboard 的重新扫描可在首次打开失败后重试小米 HID 设备发现。

## [0.6.1] - 2026-09-20

### 修复
- 修复下载版启动崩溃：显式读取 Contents/Resources 内的资源包，不再依赖 SwiftPM 的应用根目录或构建机路径。
- 创建 DMG 前执行搬离构建目录的应用，校验版本及控制器图片，防止资源加载问题漏过发布检查。

## [0.6.0] - 2026-09-19

### 新增
- 支持小米蓝牙遥控器 2 Pro（RC003-MS），提供通过内置虚拟麦克风组件实现的语音输入和音量控制。
- 六个任务槽均可配置全局快捷键。

### 变更
- 重做控制器 Dashboard，采用固定 744 × 600 布局，展示设备图、实时输入反馈、逐项按键映射和可展开的连接详情。
- 震动测试改为有限反馈，不再改变任务状态。

### 修复
- 麦克风驱动直接随应用签名打包，通过管理员授权启用，移除独立安装器及其证书依赖。
- 修复错位排列显示器之间的指针移动。
- 合并重复的 Joy-Con HID 快照。
- 修复类型化控制器动作的处理。
- 修复 macOS 应用打包时的资源放置。

## [0.5.1] - 2026-09-01

### 修复
- 当与显示刷新同步的指针时钟停跳时，自动恢复手柄指针移动。
- 在获取单实例锁之前创建本地运行目录，修复首次启动失败。

### 优化与重构
- 缩短手柄指针响应时间，并合并重复的 Joy-Con 输入刷新。

## [0.5.0] - 2026-08-30

### 新增
- 新增本地 Codex app-server 进程恢复机制，包括有界重试，以及对异常响应和超时的可预测处理。
- 为本地 socket、串口与 RP2040 固件传输链路新增有界原子缓冲。
- 新增 CI 与发布共用校验、本地协议文档、映射迁移覆盖，并扩充回归测试。

### 变更
- 手柄指针更新改用与显示刷新同步的时钟，可适应显示器变化，不再受主线程阻塞影响，并通过有界追赶保留延迟移动。
- 强化运行时生命周期清理、状态时效、手柄映射持久化、本地协议和固件传输可靠性。

### 修复
- 快捷键松开时会清除修饰键标记，避免 Command 等状态泄漏到后续由手柄生成的鼠标点击。

## [0.4.0] - 2026-08-28

### 新增
- 完整支持 Nintendo Switch 第一代 Joy-Con 手柄：
  - 单只 Joy-Con（L/R）横握与竖握方向切换及独立持久化。
  - 双持成对组合（Joy-Con Pair）逻辑控制器。
  - IOHID 物理侧键消歧（SL/SR vs L/ZL vs R/ZR），无缝衔接 GameController 字段。
  - 6 轴 IMU 运动传感器（加速度计 G 与陀螺仪 DPS）数据解析与上报。
  - 仪表盘 Joy-Con 专属线稿图元与按键高亮布局。
- 原生手柄模式（Native Mode / Passthrough）：
  - 当游戏或模拟器（如 JoyDSH 等白名单前台应用）激活时自动暂停键鼠映射。
  - 支持通过 PS / Home 键快速切换模式并伴随专属触觉振动反馈。
  - 设置界面新增“原生模式”配置 Tab，支持管理白名单应用。
- 指针灵敏度调节：
  - 设置中新增普通（Normal）、快速（Fast 加速）和慢速（Slow 微调/触控板）三级独立滑块配置与持久化存储。
- 多手柄并发触觉振动反馈支持。
- 仪表盘实时按键物理按下高亮反馈。
- 新增硬件摇杆指向验证脚本 `scripts/verify_joycon_pointer.sh`。

## [0.3.0] - 2026-08-26

### 新增
- 可录制键盘快捷键，支持组合修饰键（Command、Control、Option、Shift、Fn）与自定义备注。
- 手柄鼠标按键支持系统原生双击与三击行为。

### 变更
- DualSense / DualShock 触控板按键默认改为鼠标左键（按住说话仍可作为自定义映射配置）。

## [0.2.5] - 2026-08-25

### 修复
- 修复手柄指针越过屏幕边缘后坐标继续漂移，导致光标拉回缓慢的问题。

## [0.2.4] - 2026-08-24

### 新增
- 按住 `L3` 临时指针加速（`1.8x`）。
- DualSense / DualShock 触控板滑动慢速精细瞄准。
- GitHub Release 自动化工作流接入 Developer ID 签名与 Apple 公证。

### 变更
- Dashboard 与设置窗口采用更紧凑的 macOS 原生标题栏。
- 移除旧 LaunchAgent 机制，登录自启改由应用设置统一管理。

## [0.2.3] - 2026-08-24

### 新增
- `LT + 右摇杆` 方向支持自定义映射（左右默认为浏览器前进/后退 `Command-[` / `Command-]`）。
- 新增打开应用程序动作与应用选择器。
- 设置中新增自然 vs 传统滚动方向设置。

## [0.2.2] - 2026-08-24

### 新增
- 新增“通用”设置面板与登录自启开关。
- 优化 Dashboard 与菜单栏的设置入口。

## [0.2.1] - 2026-08-24

### 修复
- 修复 Release 构建中预加载 SwiftPM resource bundle 导致的启动崩溃问题。

## [0.2.0] - 2026-08-23

### 新增
- 新增 `LT + RT` 回车、`LT + L3/R3` 复制/粘贴、飞书截图快捷键（`Command-Shift-A`）。
- 仪表盘重构为三列紧凑布局与健康状态指示。
- 版本元数据统一由 `VERSION` 资源管理。
- 新增 Xbox 脉冲扳机与 DualSense R2 阻力墙自适应力反馈。
- 界面支持简体中文与英文双语切换。

## [0.1.0] - 2026-08-23

### 新增
- Joy Harness 首个公开版本。
- 六个 Codex Micro 任务槽切换、直接跳转、审批（`ACT07`）与拒绝（`ACT08`）。
- RP2040 USB CDC 串口与 Vendor HID 桥接。
- 手柄控制鼠标移动、摇杆滚动、鼠标点击、Backspace 与 Escape。
- 原生按住说话功能（Menu/Options 键 `ACT10`）。
- 本地诊断 Dashboard（电量、震动、RP2040 与权限监控）。
- DMG 打包工作流。

[0.7.0]: https://github.com/nixihz/JoyHarness/compare/v0.6.1...v0.7.0
[0.6.1]: https://github.com/nixihz/JoyHarness/compare/v0.6.0...v0.6.1
[0.6.0]: https://github.com/nixihz/JoyHarness/compare/v0.5.1...v0.6.0
[0.5.1]: https://github.com/nixihz/JoyHarness/compare/v0.5.0...v0.5.1
[0.5.0]: https://github.com/nixihz/JoyHarness/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/nixihz/JoyHarness/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/nixihz/JoyHarness/compare/v0.2.5...v0.3.0
[0.2.5]: https://github.com/nixihz/JoyHarness/compare/v0.2.4...v0.2.5
[0.2.4]: https://github.com/nixihz/JoyHarness/compare/v0.2.3...v0.2.4
[0.2.3]: https://github.com/nixihz/JoyHarness/compare/v0.2.2...v0.2.3
[0.2.2]: https://github.com/nixihz/JoyHarness/compare/v0.2.1...v0.2.2
[0.2.1]: https://github.com/nixihz/JoyHarness/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/nixihz/JoyHarness/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/nixihz/JoyHarness/releases/tag/v0.1.0
