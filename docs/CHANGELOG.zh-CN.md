# 更新日志 (Changelog)

本项目的重大变更均记录于此。

格式基于 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
且本项目遵循[语义化版本 (Semantic Versioning)](https://semver.org/lang/zh-CN/)。

[English](CHANGELOG.md)

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
