# Joy Harness Protocol

本文定义 Joy Harness 本机控制面和 RP2040 Codex Micro Bridge 的现行契约。除非另有说明，字符串使用 UTF-8，换行符为 `\n`。

## 兼容性名称与路径

| 项目 | 当前值 | 兼容行为 |
| --- | --- | --- |
| 状态目录 | `~/.agent-deck` | 保留既有目录名 |
| Unix socket | `~/.agent-deck/pad.sock` | `AGENT_DECK_SOCK` 可覆盖路径 |
| 状态快照 | `~/.agent-deck/status.json` | 保留既有文件名 |
| RP2040 端口 | 自动发现 `/dev/cu.usbmodem*` 和 `/dev/cu.usbserial*` | `AGENT_DECK_RP2040_PORT` 可指定端口 |
| 固件 READY 名称 | `agentdeck-rp2040` | 主机也接受 `codexpad-rp2040` |

## Unix Socket

socket 使用本地 `AF_UNIX` 流式连接，监听文件权限为 `0600`。一个连接只发送一个请求行；服务端等待最多 1 秒，最大请求长度为 64,000 字节（不含换行符）。请求必须以换行符结束。

### 请求

JSON 对象至少包含 `state` 或 `action` 之一：

```json
{"state":"waiting","note":"PermissionRequest","thread_id":"thread-123"}
```

| 字段 | 说明 |
| --- | --- |
| `state` | 可选。`idle`、`busy`、`waiting`、`done`、`error`，忽略首尾空白且不区分大小写。 |
| `action` | 可选。`ping`、`status`、`slots-refresh`、`slot-next`、`slot-previous`、`slot-open`；校验时不区分大小写。 |
| `note` | 可选状态说明。 |
| `thread_id` | 可选来源任务标识。 |

为兼容旧调用方，单独发送一个状态词（如 `waiting`）也有效。`bin/joy-harness-send` 将 `ping` 和 `status` 位置参数转换为 `action`。

### 响应与失败

有效请求响应：

```json
{"ok":true}
```

成功仅表示请求已通过语法和取值检查，并已被接纳到应用的本地命令处理流程；它不表示状态文件已经写入、外接设备已执行，或目标任务已经改变。客户端同时接受历史成功响应 `ok`。

失败响应为 `{"ok":false,"error":"<code>"}`，其中 `<code>` 是以下之一：`empty_request`、`incomplete_request`、`invalid_action`、`invalid_command`、`invalid_json`、`invalid_state`、`invalid_utf8`、`read_failed`、`request_too_large`、`timeout`。

## 状态快照

`status.json` 是原子替换写入的 JSON 对象。通用顶层字段包括 `state`、`selected_slot`、`slots`、`controller`、`controller_connected`、`controller_family`、`controller_touchpad`、`controller_battery_level`、`controller_battery_state`、`haptics`、`accessibility`、`input_monitoring`、`microphone`、`voice_input`、`voice_input_default`、`voice_input_transport`、`default_voice_input`、`rp2040`、`mode`、`operation_mode`、`frontmost_app_name`、`frontmost_app_bundle_id`、`note` 和 `ts`。

`slots` 恒为六项；每项包含从 1 开始的 `slot`、`selected`、`thread_id`、`title` 和 `state`。`controller_battery_level` 与 `controller_battery_state` 仅在手柄提供电池信息时出现。`mode` 当前为 `physical-codex-micro`；`operation_mode` 为 `mapping` 或 `native`；`ts` 为 ISO 8601 时间戳。读取方按时间戳将快照分类为 fresh、stale 或 unavailable，读取或解码失败不得继续把旧快照呈现为 fresh。

连接 Joy-Con 时还可出现 `joycon_mode`、`joycon_orientation`、`joycon_primary_stick`、`joycon_secondary_stick`、`joycon_left_connected`、`joycon_right_connected`、`joycon_left_battery_level`、`joycon_right_battery_level`、`joycon_left_battery_state`、`joycon_right_battery_state`、`joycon_left_haptics`、`joycon_right_haptics`、`joycon_left_motion`、`joycon_right_motion`、`joycon_left_profile_elements`、`joycon_right_profile_elements`、`joycon_left_imu`、`joycon_right_imu` 和 `joycon_inactive_endpoints`。单只 Joy-Con 的 `joycon_orientation` 为 `horizontal` 或 `vertical`；成对模式省略该字段。摇杆对象包含 `x`、`y`，IMU 对象包含加速度、旋转速率和校准来源。

## RP2040 CDC

主机以 115200 baud、原始串行模式向 RP2040 CDC 端口发送一行命令。固件每行最多累积 127 个字符；超过限制的未完成行被丢弃，不返回错误。

| 命令 | 格式 | 结果 |
| --- | --- | --- |
| 探测 | `P` | 回复 `READY agentdeck-rp2040 0.1.0`。 |
| 按键 | `H <key> <action> <agent>` | 转换为 `v.oai.hid` 通知；`agent < 0` 时省略 `ag`。 |
| 径向输入 | `J <angle> <distance>` | 转换为 `v.oai.rad` 通知；两个数均夹紧到 0 至 1000，再缩放为 0.000 至 1.000。 |

主机仅发送非空、ASCII 字母数字或下划线组成的 `<key>`。例如 `ACT07`、`ACT08`、`ACT06`、`ACT09`、`ACT10`、`ACT12` 用于 Codex Micro 操作，`AG00` 至 `AG05` 用于六个槽位。主机发送成功表示消息进入已连接串口的 64,000 字节有界输出缓冲；没有 CDC ACK，因此不代表 RP2040 或 Codex Micro 已执行。

## Codex Micro Vendor HID

RP2040 暴露 Vendor Defined Usage Page `0xFF00`、Usage `1` 的 HID 接口，报告 ID 为 `6`。输入和输出报告的负载均为 63 字节。

每个传输包格式如下：

| 字节 | 含义 |
| --- | --- |
| 0 | 通道，RPC 固定为 `2`。 |
| 1 | 有效负载长度。 |
| 2-62 | UTF-8 JSON 负载，单包最多 61 字节。 |

固件把 JSON 文本按 61 字节分包，通过 32 项环形队列发送；环形队列保留一项作判满，因此容量为 31 包。单条消息若需要的包数超过剩余容量即被拒绝，已入队消息不会被部分入队。单个方向的重组缓冲区上限为 4,096 字节；超出上限时重组内容被丢弃。

支持的来自主机的 RPC 为 `device.status`、`sys.version`、`v.oai.rgbcfg`、`v.oai.thstatus` 和 `lights.preview`。未知方法返回 JSON-RPC 错误 `{"code":-32601,"message":"Method not implemented"}`。HID 发送层的成功表示 TinyUSB 已接收该报告并将其从队列移除，不构成 Codex Micro 级别的 ACK。
