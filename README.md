# AgentDeck

把 Xbox（或任意 macOS Game Controller）手柄接入 Codex Desktop 的原生 Codex Micro
bridge：六个任务槽、按住说话、任务切换、审批，以及摇杆和扳机操作。

现在也提供原生 macOS 可视化控制台，实时展示六个槽位、当前任务状态、手柄映射和
控制器 / RP2040 / 系统权限诊断，并可直接批准、拒绝、中断或打开任务。

RP2040 在 USB 侧模拟 Codex Micro，AgentDeck 在 Mac 上把 Xbox 手柄事件通过串口转发给
RP2040。Xbox 手柄和 RP2040 都连接 Mac，二者不直接接线。AgentDeck 不启动 app-server、
不模拟键盘；只有左摇杆控制鼠标需要 macOS 辅助功能权限。

## 状态映射

| Codex 事件 | 手柄感觉 |
|---|---|
| `UserPromptSubmit` / tool 循环 | `busy` — 低频轻震 |
| `PermissionRequest` | `waiting` — 急促脉冲（最有用） |
| `Stop` / `agent-turn-complete` | `done` — 两下短震后回 idle |
| 手动 / 失败 | `error` — 三下重震 |
| `SessionStart` / `SessionEnd` | `idle` |

## Codex Micro 映射

| 键 | 功能 |
|---|---|
| A | 鼠标左键按下 / 松开，可点击或拖动 |
| B | 鼠标右键按下 / 松开，可点击或拖动 |
| X | Backspace，按住可连续删除 |
| Y | Esc |
| LT + A / B | Codex Micro `ACT07` / `ACT08`，批准 / 拒绝 |
| LT + X / Y | Codex Micro `ACT06` / `ACT09`，快速操作 / 拆分任务 |
| LB / RB | 上一个 / 下一个任务槽 |
| LT + 上 / 下 / 左 / 右 | 选择任务槽 1 / 2 / 3 / 4 |
| LT + LB / RB | 选择任务槽 5 / 6 |
| Menu 按住 / 松开 | Codex Micro `ACT10` 按下 / 松开，原生按住说话 |
| RT | Codex Micro `ACT12`，默认聚焦 Codex |
| 十字键 / 右摇杆 | Codex Micro 径向输入 `v.oai.rad` |
| 左摇杆 | 移动 macOS 鼠标指针（120Hz 平滑、死区和渐进加速） |
| 左摇杆按下（L3） | 按住启用 `1.8x` 鼠标加速，松开恢复精细速度 |
| 右摇杆按下（R3） | 鼠标中键按下 / 松开 |

LT 组合键和 LB/RB 直接使用 Codex Desktop 管理的六个 Micro 任务槽。A/B/X/Y 默认执行
鼠标和系统按键操作，按住 LT 时切换为原来的 Codex Micro 操作。AgentDeck 只记录当前
槽号，用 1–6 下短震确认切换，不另行维护一份任务列表。

## 快速开始

```bash
# 编译 + LaunchAgent + 写入 ~/.codex/hooks.json
# hook 脚本会安装到稳定的 ~/.agent-deck/bin，并保留现有 notify 链
task install
# 或: bash scripts/install.sh
```

### 1. 构建并刷入 RP2040

```bash
task firmware
```

按住 RP2040 的 `BOOTSEL`，把它插入 Mac；看到 Finder 中出现 `RPI-RP2` 后执行：

```bash
task flash
```

刷完会自动重启。固件提供两个 USB 接口：

- Codex Desktop 看到的 `Codex Micro` Vendor HID
- AgentDeck 使用的 `AgentDeck Bridge` 串口

默认按 Raspberry Pi Pico 兼容板构建。若你的 RP2040 Plus 要求其他 Pico SDK 板型，使用：

```bash
PICO_BOARD=<board-name> task firmware
```

### 2. 安装并连接

然后：

1. 通过 USB 线或蓝牙连接 Xbox 手柄
2. 保持刷好固件的 RP2040 连接 Mac
3. 完全退出并重新打开 Codex Desktop，让它重新扫描 Codex Micro
4. 首次启动时，在 macOS 提示中允许 AgentDeck 使用辅助功能
5. 查看 `~/.agent-deck/status.json`，确认 `rp2040` 和 `accessibility` 为 `true`
6. 试震：

```bash
~/.agent-deck/bin/agent-deck-send waiting
task demo
```

前台调试（不走 LaunchAgent）：

```bash
./script/build_and_run.sh
# 另开终端
python3 bin/agent-deck-send busy
```

Codex 桌面端会读取 `.codex/environments/environment.toml`，也可直接使用项目的 **Run** 操作构建并打开控制台。

## 架构

```
Codex Desktop 原生 Codex Micro bridge
        ▲
        │ Vendor HID（Codex Micro JSON-RPC）
RP2040 Codex Micro 固件
        ▲
        │ USB CDC 串口
AgentDeck daemon ◀── GameController ── Xbox 手柄
        ▲
        │ Unix socket（任务状态）
Codex hooks / notify_fanout.py

AgentDeck daemon ── Core Haptics ──▶ Xbox 手柄震动
```

## 文件

- `Sources/AgentDeck/` — 手柄、震动、串口和状态 daemon
- `firmware/rp2040/` — RP2040 Codex Micro 固件
- `bin/agent-deck-send` — CLI
- `codex-hooks/` — Codex 桥
- `scripts/install.sh` — 安装

## 注意

- 改 hooks 后 Codex 要求重新 trust（`/hooks`）
- `PermissionRequest` hook 只发送等待震动；批准和拒绝由 Codex Desktop 原生处理
- 按住说话由 Codex Desktop 原生处理，AgentDeck 不申请麦克风权限
- A/B 鼠标键和 X/Y 系统按键通过 macOS 辅助功能发送给当前前台应用
- Codex hooks 默认启用；若你显式配置过 `[features] hooks = false`，需要改回 `true`
- 没手柄时 daemon 仍跑，状态写到 `status.json`，震动会在日志里标明 skipped
- `install.sh` 会改 `~/.codex/config.toml` 的 `notify`；原配置备份为 `config.toml.bak-agentdeck`
- Xbox 灯光没有 macOS 公共 API，本项目用震动表达状态；手柄在任务中途连接时会恢复当前状态
- 当前测试的 Xbox Series 手柄在 macOS 26.5.2 下仅蓝牙模式能正常震动；USB 有线模式虽会被 `XboxUSBDevice` 识别，但系统原生 Identify 也无震动
- AgentDeck 只有在串口返回 `READY agentdeck-rp2040` 后才标记 RP2040 已连接，不会误连其他 USB 串口设备
- Codex Desktop 需要 Input Monitoring 权限以接收 Codex Micro 按键
