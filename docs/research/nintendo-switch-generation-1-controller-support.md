# Nintendo Switch 第一代手柄支持可行性

调查日期：2026-08-27

## 结论

可以支持。结合实际设备条件，本次实现目标调整为**初代原厂 Joy-Con 双支组合与任一单支横握/竖握均可使用**；Switch Pro Controller 仅保留为协议参照，不纳入本次交付范围。

| 设备形态 | Joy Harness 输入与验收基线 | 建议支持级别 |
| --- | --- | --- |
| 分开枚举的一对 Joy-Con（L+R） | Apple 两个单侧 profile 都是横握坐标；L 用 `(y, -x)`、R 用 `(-y, x)` 还原完整手柄布局，左摇杆负责 pointer/scroll、右摇杆负责 secondary/radial；肩键使用完整手柄语义 L/ZL/R/ZR | 完整双支模式 |
| 系统合成的一对 Joy-Con（L/R） | 完整 pair profile 的两侧摇杆均为 `(x, y)` identity；肩键使用完整手柄语义 L/ZL/R/ZR | 完整双支模式 |
| 单只 Joy-Con (L)，横握/竖握 | 横握轴为 `(x, y)` identity 并选择 SL/SR；竖握轴为 `(y, -x)` 并选择 L/ZL；两个上层肩键映射槽保持稳定 | 左单支模式 |
| 单只 Joy-Con (R)，横握/竖握 | 横握轴为 `(x, y)` identity 并选择 SL/SR；竖握轴为 `(-y, x)` 并选择 ZR/R；两个上层肩键映射槽保持稳定 | 右单支模式 |
| Nintendo Switch Pro Controller（HAC-013） | 公开源码可作为完整 Nintendo 布局和协议的交叉参照，但用户当前没有该设备，无法完成真机验收 | 本次不承诺支持 |

仓库最低系统是 macOS 13。Apple 的手柄设置文档把自定义手柄按钮功能的最低版本列为 **macOS Ventura 13**，而当前 SDK 的 `GCProductCategoryHID` 也从 macOS 13 起可用，因此暂不需要提高部署版本。不过，Apple 没有在公开 API 中提供 Nintendo 专用 profile；Switch 设备会经过通用 `GCExtendedGamepad` / HID 映射，不能照搬 PlayStation 专用类型的检测方式。特别是，单支 profile 的通用 `Left Shoulder` / `Right Shoulder` 只能表达两个位置，无法区分 SL、SR 与 L/ZL 或 R/ZR 四颗实体键。实现必须用原始 HID 位按所选握姿消歧肩键字段，但仍由 `GameController` 提供摇杆、面键、摇杆按下和 menu；不能把 Chrome 自带的 Joy-Con 聚合能力或两个通用 Shoulder 元素误认为 macOS 已提供完整物理身份。

本结论只覆盖初代 Switch 的原厂 Joy-Con（L/R）和 Switch Pro Controller，不覆盖 Joy-Con 2、Switch 2 Pro Controller 及第三方兼容手柄。本文公式中的 `(x, y)` 是 Apple 单侧横握 mini-controller profile 的 `Direction Pad` 输出，不是 Joy-Con 设备竖向原始轴。当前初代 Joy-Con (L) 的实机反馈已确认这一基准：竖握时物理上/右/下/左在 Apple profile 中依次报告为左/上/右/下，因此左单支横握应为 identity，左单支竖握应使用 `(y, -x)`；竖握肩位仍为 L/ZL，而不是 SL/SR。Joy-Con (R)、两侧横握和双支组合仍需按下文矩阵完成真机验收。

## 与当前实现的关系

改造前，Joy Harness 在 `ButtonBridge.attachPreferredController()` 中只接收 `GCController.controllers()` 里 `extendedGamepad != nil` 的设备，并从 `GCExtendedGamepad` 读取完整手柄输入；Nintendo 设备也只能落入 `generic`。当前实现已新增 Joy-Con 分类、`physicalInputProfile` 适配、左右聚合与三种独立映射模式，同时保留原有完整手柄事件链。

这些原有限制带来五个直接结果，也是当前实现需要处理的兼容点：

1. 一对被系统组合为完整 extended gamepad 的 Joy-Con，无需重写输入协议就能进入现有事件链路；若系统分别枚举 L/R，则需要新增逻辑聚合层。
2. 单只 Joy-Con 很可能因为不是完整 extended gamepad 而被过滤；即使系统构造了兼容 profile，另一半缺失控件的语义也不适合当前默认映射，必须新增左右单支 profile。
3. 通用面键属性是**位置语义**：Apple 的 `GCExtendedGamepad` 固定为上 Y、左 X、右 B、下 A。Nintendo 实物标签则为上 X、左 Y、右 A、下 B。因此必须在真机上记录 `buttonA/B/X/Y` 对应的物理键，并决定 UI 展示“逻辑位置”还是“Nintendo 标签”；否则用户看到的映射名称可能与按下的字母不一致。
4. Switch 的 ZL/ZR 是数字按键。即使它们被适配到 `leftTrigger` / `rightTrigger` 的浮点接口，也只应预期 0/1，不应承诺模拟量。
5. 单支 Joy-Con 有四颗可区分的实体肩键，但 `GameController` 可能只给出两个通用 Shoulder 元素。上层应始终保留 `leftShoulder` / `rightShoulder` 两个映射槽；底层 HID 在横握时为这两个槽选择 SL/SR，在左竖握时选择 L/ZL，在右竖握时选择 ZR/R。分开枚举的双支也由 HID 提供外侧 L/ZL/R/ZR，避免把通用 Shoulder 猜成错误实体键；系统已合成完整 extended profile 时则保留其完整肩键语义。`GameController` 同时继续拥有其余无歧义字段。切换握姿只更换肩位槽的物理来源和显示标签，不改变两个槽上保存的动作；同一逻辑字段始终只能有一个发布者。

Apple `GCExtendedGamepad` 文档说明 profile 会把硬件映射成与设备无关的逻辑控制器，并要求完整 profile 的控件全部有效；这正是组合 Joy-Con 可能复用现有代码、单 Joy-Con 必须采用独立策略的依据。

## 连接方式

### Switch Pro Controller

- Linux 主线 `hid-nintendo` 明确支持 Pro Controller 的 **USB 和 Bluetooth**。
- Chromium 的 Nintendo 控制器实现也将 Pro Controller 识别为既可 Bluetooth 又可 USB；macOS 的标准映射表包含 Nintendo VID/PID。
- 对 Joy Harness，优先建议先验收 Bluetooth，再验收 USB。Apple 的通用手柄文档说明蓝牙手柄可在系统蓝牙设置中配对，部分控制器也可通过支持数据的 USB 线自动连接，但没有对 Switch Pro 的 USB 路径作逐型号保证。

### Joy-Con（L/R）

- 单只 Joy-Con 本体通过 Bluetooth 连接；Chromium 源码明确写明 Joy-Con 只能经 Bluetooth 连接。
- 一对蓝牙 Joy-Con 是否作为一个控制器呈现，不是 Web Gamepad 标准本身规定的行为。Chromium 自己的 Nintendo fetcher 会把匹配的 L/R 自动组成 composite gamepad；macOS `GameController` 也存在 `Nintendo Switch JoyCon (L/R)` product category。Joy Harness 依赖的是后者，仍须在目标 macOS 13、当前 macOS 版本分别验证系统实际枚举数量和 profile。
- USB Charging Grip 的 PID 是 `0x200e`，Chromium 会把它或蓝牙复合 Joy-Con 映射成与 Pro Controller 相同的四轴布局。普通随主机附送的 Joy-Con Grip 不含 USB 数据能力，不能因为外形相同就承诺有线输入。

## VID/PID 与能力基线

Linux 主线 `hid-ids.h` 与 Chromium `gamepad_id_list.h` 对初代原厂设备给出一致标识：

| 设备 | VID | PID |
| --- | --- | --- |
| Nintendo | `0x057e` | - |
| Joy-Con (L) | `0x057e` | `0x2006` |
| Joy-Con (R) | `0x057e` | `0x2007` |
| Switch Pro Controller | `0x057e` | `0x2009` |
| Joy-Con Charging Grip / 复合 Joy-Con 的 Chromium 虚拟标识 | `0x057e` | `0x200e` |

这些 ID 适合实机诊断和识别原厂设备，但不应作为 Joy Harness 唯一接入条件：`GameController` 公共的 `GCController` 不直接承诺暴露 VID/PID，且授权第三方手柄会使用其他标识。

## 按键与轴映射

### Pro Controller / 组合 Joy-Con

可按标准完整手柄建模：四个面键、L/R、数字 ZL/ZR、Minus/Plus、L3/R3、方向键、Home、Capture、左右摇杆四轴。Linux 主线映射逐项确认了这些物理键；Chromium 的标准映射把 Pro Controller 保留为四轴，并将 Capture 作为标准按钮之后的额外按钮。

当前 Joy Harness 可消费其中：四面键、L/R、ZL/ZR、Minus/Plus（视系统落到 Menu/Options 的实际结果）、L3/R3、方向键、Home、左右摇杆。Capture 没有对应的 `GCExtendedGamepad` 专用属性，Apple 是否把它放进通用 `physicalInputProfile` 不能从公开资料保证；当前代码也不会读取额外物理输入元素。

### 单只 Joy-Con

浏览器官方源码提供了一个有用但不能直接等同于原生 API 的参照：Chromium 的原始 Nintendo HID 后端先从设备竖向轴构造横握的 **2 axes** mini-controller；SDL 的 Apple `GameController` 映射则把 Joy-Con (L) 和 Joy-Con (R) 的 `Direction Pad` 都直接映射为同一套横握 left-x/left-y。SDL 在提交 `756978a` 中特意删除了两侧各自的额外旋转，改为 L/R 相同的 identity hat 映射，并说明两支都作为 individual mini controllers。结合左侧真机结果，可以确认 Joy Harness 从 Apple profile 读到的已经是横握逻辑坐标，不能再当作设备竖向原始轴旋转一次。

单支输入的规范化表如下；公式中的 `(x, y)` 专指 Apple 单侧横握 mini-controller profile 的 `Direction Pad.xAxis/yAxis` 输出，不是原始 HID 坐标：

| 设备与握姿 | pointer 输出 | 左肩位槽 | 右肩位槽 |
| --- | --- | --- | --- |
| Joy-Con (L) 横握 | `(x, y)` identity | SL | SR |
| Joy-Con (R) 横握 | `(x, y)` identity | SL | SR |
| Joy-Con (L) 竖握 | `(y, -x)` | L | ZL |
| Joy-Con (R) 竖握 | `(-y, x)` | ZR | R |

实现单只 Joy-Con 时，应新增明确的 `joyConLeft` / `joyConRight` family 与可切换横握/竖握映射，不应在现有 `generic` 默认值上打补丁。当前 Joy Harness 依赖左右摇杆分别承担鼠标、滚动/径向输入等动作，单摇杆无法无损覆盖完整工作流；单支模式需要明确的降级默认映射，并允许用户覆盖。握持方向同时决定摇杆坐标变换和 HID 选择的实体肩键对；两个上层肩位槽及其动作保持稳定，UI 标签随物理来源切换，其他输入继续来自 `GameController` 并按手柄印刷标签展示。未被当前握姿选中的另一对 HID 肩键不得别名到这两个槽，模糊的 `GameController` Shoulder 回调必须被抑制。HID 肩键流未就绪时暂不暴露肩位槽，但摇杆、面键和 menu 仍可使用。

### 双支 Joy-Con

双支模式忽略左右单支保存的握姿，但必须区分输入 profile。若 macOS 分别枚举 L/R，两个 endpoint 仍各自输出 Apple 横握 mini-controller 坐标，因此左侧先用 `(y, -x)`、右侧先用 `(-y, x)` 还原竖向完整手柄布局；左侧随后输出 pointer/scroll，右侧输出 secondary/radial。若 macOS 直接提供系统合成的完整 L/R profile，则其两侧摇杆已经是完整手柄坐标，均保持 `(x, y)` identity。两条路径最终必须输出相同逻辑布局，肩键都恢复完整手柄语义 L/ZL/R/ZR。

## 浏览器 Gamepad API

W3C Gamepad 规范只标准化 `buttons[]`、`axes[]`、`mapping` 与可选 haptic actuator 等低层接口；设备如何枚举、原始布局如何转为 `standard` mapping 由浏览器实现负责。

Chromium 当前 macOS 源码有 Nintendo 专用实现，而不是单纯依赖 Apple 的通用映射：

- 识别 `0x057e:0x2006`、`:0x2007`、`:0x2009`、`:0x200e`。
- 单 Joy-Con 输出 2 axes；Pro 与组合 Joy-Con 输出 4 axes。
- 自动把匹配的蓝牙 Joy-Con L/R 合成一个 composite gamepad。
- 组合模式额外暴露 Capture 和四个 SL/SR 按钮。
- Nintendo fetcher 可向 Pro/Joy-Con 下发振动效果。

所以，“Chrome 网页能用”不能作为 Joy Harness 原生支持已完成的证明。Chrome 在 macOS 上会主动排除 Apple 已枚举的 Nintendo category，并改由自己的 HID Nintendo fetcher 处理，能力边界可能强于 `GameController` 公共 API。

## Android 原生映射参照

Android AOSP 主线包含 Switch Pro Controller `0x057e:0x2009` 的专用 key layout，文件注释明确对应 HAC-013 Bluetooth。它将 Nintendo 实体 B/A/Y/X 分别映射为 Android 的 `BUTTON_A/BUTTON_B/BUTTON_Y/BUTTON_X`，即优先保持标准位置语义；ZL/ZR 映射为数字按键，摇杆使用 X/Y 与 Z/RZ，同时还列出加速度计和陀螺仪轴。

AOSP 的官方 keyboard layouts 目录中没有 Joy-Con L/R 的 `0x2006` / `0x2007` 专用文件。因此只能把 AOSP 作为“Pro Controller 有系统级标准化映射”和“Nintendo 字母需要位置重排”的交叉证据，不能据此承诺 Android 对单只或成对 Joy-Con 的完整原生支持。Joy Harness 当前仅支持 macOS，这一节只用于校验映射语义，不代表新增 Android 平台范围。

## 震动、陀螺仪与其他特性

| 能力 | 硬件/协议证据 | Apple 公共 API / Joy Harness 判断 |
| --- | --- | --- |
| HD Rumble | Linux `hid-nintendo` 和 SDL 的 Switch HIDAPI 驱动都包含专用 rumble 输出、频率/幅度编码和发送限速 | Joy Harness 只能在 `controller.haptics != nil` 时走 Core Haptics。Apple 没有公开逐型号保证 Switch Pro/Joy-Con 会返回 haptics；必须实测。为此直接实现原始 HID 输出属于新的协议后端，不是小映射改动 |
| 加速度计 / 陀螺仪 | Linux 驱动对 Joy-Con、Charging Grip 和 Pro 判断为有 IMU，并读取工厂校准；SDL 定义加速度/陀螺比例并启用 IMU subcommand | Apple 的 `GCController.motion` 是可选属性，nil 表示系统未暴露。当前 Joy Harness 只探测并报告 motion 可用性，不消费传感器数据；必须实测每种设备/连接方式 |
| Home 灯 / 玩家灯 | Linux/SDL 协议包含设置 Home 灯和玩家灯 subcommand | Apple 通用 `light` API 不保证这些 Nintendo 灯可控，当前代码也不使用；不纳入首期 |
| Capture | Linux 映射与 Chromium composite mapping 都能识别 | `GCExtendedGamepad` 没有 Capture 专用属性；当前代码不读取额外 physical profile 元素，先视为不可映射，实测后再决定 |
| NFC / 右 Joy-Con IR 相机 | 不属于标准游戏手柄按键/轴；本次检索的 Apple `GameController` 公共 profile 没有相应 API | 不支持，不纳入 Joy Harness 手柄输入范围；若做原始 HID/MCU 协议属于独立研发项目 |

这里最重要的证据边界是：Linux/SDL 源码能证明硬件和协议具备能力，**不能证明 macOS 的公共 `GameController` 会把该能力交给第三方原生应用**。

## 建议实施范围

本次以 Joy-Con 为唯一硬件目标，并同时交付双支与单支模式：

1. 增加 `joyConPair`、`joyConLeft`、`joyConRight` 设备形态，展示 Nintendo 实体标签与对应布局。
2. 建立 Joy-Con 逻辑输入层：上层继续消费统一按钮、摇杆和按压事件，底层可按字段合并 `GameController` 与 HID。单支由 `GameController` 提供摇杆、面键、摇杆按下和 menu，由原始 HID 区分四颗实体肩键；分开枚举的双支同样用 HID 的外侧位确定 L/ZL/R/ZR。每个规范化字段只有一个所有者，模糊的 GC shoulder 字段被替换或抑制，HID 未就绪或同侧存在无法关联的多个 HID endpoint 时，对应肩键暂不暴露。
3. 双支模式将左右 Joy-Con 聚合为一个逻辑控制器；分开枚举时分别对 L/R 应用 `(y, -x)` / `(-y, x)`，系统合成完整 pair 时保持 identity。任一侧断开时释放所有活跃输入并切换为仍在线的单支模式，避免鼠标键或 PTT 卡住。
4. 单支模式严格使用上述变换表：两侧横握都是 identity，左竖握为 `(y, -x)`，右竖握为 `(-y, x)`；两个逻辑肩位槽在横握选择 SL/SR，左竖握选择 L/ZL，右竖握选择 ZR/R，并提供不依赖第二摇杆或另一侧按键的默认工作流。
5. 映射设置按设备形态分别持久化，左右单支也分别保存握持方向；切换方向时先释放活动输入再重新采样。UI 只展示当前形态实际可用的输入。
6. HD Rumble、电量与 IMU 采用能力探测：系统公开能力可用时接入，不作为基础输入验收的阻塞项；Capture、灯、NFC、IR 延后。
7. 本次不承诺 Switch Pro Controller，也不因其缺少实机而阻塞 Joy-Con 发布。

## 必须实机验证的矩阵

在最低 macOS 13 与当前支持的最新 macOS 上分别记录以下值；Apple 没有逐型号公开这些返回结果，不能以源码推测替代：

| 场景 | 必查项 |
| --- | --- |
| Joy-Con L 单只横握 / Bluetooth | Apple profile `(x, y)` identity、SL/SR、四个实体方向键、Minus/Capture、非选中 L/ZL 不产生重复动作、motion、haptics |
| Joy-Con R 单只横握 / Bluetooth | Apple profile `(x, y)` identity、SL/SR、A/B/X/Y、Plus/Home、非选中 R/ZR 不产生重复动作、motion、haptics |
| Joy-Con L 单只竖握 / Bluetooth | Apple profile 经 `(y, -x)` 后物理上/右/下/左对应逻辑上/右/下/左、L/ZL、四个实体方向键、非选中 SL/SR 不产生重复动作；左侧轴已获实机真值 |
| Joy-Con R 单只竖握 / Bluetooth | Apple profile 经 `(-y, x)` 后物理上/右/下/左对应逻辑上/右/下/左、ZR/R、A/B/X/Y、非选中 SL/SR 不产生重复动作 |
| Joy-Con L+R 分开枚举 / Bluetooth | L `(y, -x)`、R `(-y, x)`、L/ZL/R/ZR、左右连接顺序、组合/拆分通知、两侧震动与 motion 暴露方式 |
| Joy-Con L/R 系统合成 / Bluetooth | 完整 pair profile 两侧 `(x, y)` identity、L/ZL/R/ZR、不重复消费同时可见的单侧 representation、两侧震动与 motion 暴露方式 |
| L/R 动态组合与拆分 | 单支进入双支、双支退回单支、左右任意顺序连接、活动按键/摇杆在断连时归零、当前映射自动切换 |
| 应用重启与系统唤醒 | 已配对设备重连、不会重复注册事件、左右身份稳定、不会错误选择其他已连接手柄 |
| Charging Grip / USB（如纳入） | 是否为数据版 Charging Grip、PID `0x200e`、一侧拔出时行为、是否仍为完整 extended gamepad |

建议写一个只读诊断小工具或在现有诊断日志临时打印所有公开属性完成验收；在拿到这些记录前，文档措辞应是“实验性兼容”，不能写成完整支持。

## 一手来源

- Apple Support，连接无线手柄与最低系统版本（macOS Ventura 13）：<https://support.apple.com/en-us/111099>
- Apple Developer，`GCExtendedGamepad`（设备无关逻辑 profile、完整控件、Menu/Options/Home）：<https://developer.apple.com/documentation/gamecontroller/gcextendedgamepad>
- Apple Developer，`GCControllerDirectionPad`（right/left 分别对应正/负 x，up/down 分别对应正/负 y）：<https://developer.apple.com/documentation/gamecontroller/gccontrollerdirectionpad>
- Apple Developer，`GCController`（可选 `motion`、`haptics`、`battery`、`physicalInputProfile`）：<https://developer.apple.com/documentation/gamecontroller/gccontroller>
- Apple Developer，`GCMotion`（可用性判断、传感器激活、加速度与 rotation rate）：<https://developer.apple.com/documentation/gamecontroller/gcmotion>
- Apple Developer，`GCDeviceHaptics`（通过 Core Haptics 创建 engine）：<https://developer.apple.com/documentation/gamecontroller/gcdevicehaptics>
- W3C，Gamepad 规范：<https://www.w3.org/TR/gamepad/>
- Android AOSP，Switch Pro Controller（HAC-013 Bluetooth）key layout：<https://android.googlesource.com/platform/frameworks/base/+/refs/heads/main/data/keyboards/Vendor_057e_Product_2009.kl>
- Android AOSP，官方 keyboard layouts 目录：<https://android.googlesource.com/platform/frameworks/base/+/refs/heads/main/data/keyboards/>
- Chromium，macOS `GameController` fetcher（识别并排除 `Switch Pro Controller` 与 `Nintendo Switch JoyCon (L/R)`，交由 Nintendo fetcher）：<https://chromium.googlesource.com/chromium/src/+/main/device/gamepad/game_controller_data_fetcher_mac.mm>
- Chromium，Nintendo fetcher（单只、匹配 L/R 自动组合、振动）：<https://chromium.googlesource.com/chromium/src/+/main/device/gamepad/nintendo_data_fetcher.h>
- Chromium，Nintendo 控制器协议与连接实现：<https://chromium.googlesource.com/chromium/src/+/main/device/gamepad/nintendo_controller.cc>
- Chromium，macOS 标准映射（Nintendo VID/PID、单只/Pro/复合选择）：<https://chromium.googlesource.com/chromium/src/+/main/device/gamepad/gamepad_standard_mappings_mac.mm>
- Chromium，共用 Switch 映射（单只 2 axes、复合额外按钮）：<https://chromium.googlesource.com/chromium/src/+/main/device/gamepad/gamepad_standard_mappings.cc>
- Chromium，Gamepad ID 列表：<https://chromium.googlesource.com/chromium/src/+/main/device/gamepad/gamepad_id_list.h>
- Linux 主线，`hid-nintendo`（USB/Bluetooth、按键、校准、rumble、IMU、灯）：<https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/drivers/hid/hid-nintendo.c>
- Linux 主线，Nintendo VID/PID：<https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/drivers/hid/hid-ids.h>
- SDL，Nintendo Switch HIDAPI 驱动（rumble、IMU、USB/Bluetooth 协议）：<https://github.com/libsdl-org/SDL/blob/main/src/joystick/hidapi/SDL_hidapi_switch.c>
- SDL，官方映射数据库（macOS/Android/Linux 的 Pro、单只与组合 Joy-Con 映射）：<https://github.com/libsdl-org/SDL/blob/main/src/joystick/SDL_gamepad_db.h>
- SDL，修正 Apple 单支 Joy-Con L/R 为相同横握 identity 映射的提交：<https://github.com/libsdl-org/SDL/commit/756978a236b0650f354f0cedb15de605ea4cc066>

## 最终判断

**值得支持，交付目标明确为初代 Joy-Con 双支组合、单支横握和单支竖握三类场景。** 现有架构可复用鼠标、Codex 动作、映射与状态输出，但输入层需要从“选择一个完整 `GCExtendedGamepad`”演进为“识别物理 Joy-Con、按字段聚合并输出统一逻辑输入”。单支上层固定为两个肩位映射槽：`GameController` 保留无歧义的摇杆、面键和 menu 字段，原始 HID 按握姿提供 SL/SR、L/ZL 或 ZR/R；分开枚举的双支由 HID 提供外侧 L/ZL/R/ZR，完整合成 profile 则直接保留其肩键身份。坐标基准必须固定为 Apple 单侧横握 mini-controller profile 输出：L/R 单支横握均为 identity，左单支竖握与分开枚举双支左侧使用 `(y, -x)`，右单支竖握与分开枚举双支右侧使用 `(-y, x)`；只有系统合成完整 pair 的两侧轴原样输入。真正的不确定性集中在不同 macOS 版本的枚举和字段级 backend 共存行为，必须通过单支四种握姿、分开枚举双支和系统合成双支的实机矩阵验收。HD Rumble、IMU、Capture、灯、NFC 和 IR 不应阻塞基础输入交付。
