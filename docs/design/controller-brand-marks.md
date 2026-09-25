# Dashboard 控制器品牌标识核验

核验日期：2026-09-24

本文只回答 Dashboard 中各类控制器正面是否应出现品牌标识，以及可用资源的准确性和使用风险。产品外观以厂商官方产品页、官方支持图解和 Apple 提供的 SF Symbols 为依据。

原生手柄模式的应用列表不使用仓库内置品牌图。`AppIconView` 先按 Bundle ID 定位本机已安装的 `.app`，再通过 `NSWorkspace.icon(forFile:)` 读取应用自身图标；因此 JoyDSH 与 Antigravity 应继续使用各自安装包提供的图标，未安装时也不会显示替代 Logo。

## 结论

| 设备 | 真实硬件正面标识 | Dashboard 建议 |
| --- | --- | --- |
| Xbox Wireless Controller | 上部中央的 Xbox/Guide 键带圆形 Xbox 标志 | 使用未修改的 SF Symbol `xbox.logo` |
| PS5 DualSense / DualShock 4 | 两个摇杆之间的 PS 键带 PlayStation `PS` 标志 | 使用未修改的 SF Symbol `playstation.logo` |
| Nintendo Joy-Con L/R | 正面没有 Nintendo 字标或 Nintendo Switch 标志 | 不添加厂商品牌 Logo |
| 小米蓝牙遥控器 2 Pro | 正面下部是小写 `xiaomi` 字标；上方 `N` 是 NFC 标志 | 使用小米官方信任中心 SVG 中未经重绘的 `xiaomi` 字标路径 |

## Xbox

微软的 [Xbox Wireless Controller 官方产品页](https://www.xbox.com/en-US/accessories/controllers/xbox-wireless-controller) 及其 [官方正面产品图](https://assets.xboxservices.com/assets/d3/b8/d3b82872-cea1-4f26-81c8-c8da49a27362.jpg?n=Xbox-Wireless-Controller_Image-Hero-1084_White_1920x831_01.jpg) 显示：控制器正面上部中央的 Guide 键带 Xbox 圆形标志。仓库现有图片同一位置是空白圆键，因此应补上该标志。

macOS 可使用 `xbox.logo`。本机系统的 SF Symbols 元数据将其标记为 2022 年加入，覆盖项目最低支持的 macOS 13；运行时 `NSImage(systemSymbolName:)` 也可成功解析。Apple 将该符号标记为不可修改，且只能用于指代 Microsoft Xbox。参考：[SF Symbols](https://developer.apple.com/sf-symbols/) 和 [`NSImage(systemSymbolName:accessibilityDescription:)`](https://developer.apple.com/documentation/appkit/nsimage/init(systemsymbolname:accessibilitydescription:))。

许可风险：Apple 提供系统符号不等于允许导出、描摹或重打包品牌资产。微软的 [Trademark and Brand Guidelines](https://www.microsoft.com/en-us/legal/intellectualproperty/trademarks) 对 Logo 使用要求很严。应在 Apple 平台界面中直接调用、保持原形，并仅用于识别 Xbox 控制器；不要把符号导出成仓库图片。

## PlayStation

Sony 的 [DualSense 官方产品页](https://www.playstation.com/en-us/accessories/dualsense-wireless-controller/) 及其 [官方正面产品图](https://gmedia.playstation.com/is/image/SIEPDC/dualsense-controller-image-block-01-ps5-26jun20?$1600px$) 显示：PlayStation `PS` 标志本身构成 PS 键，位于两个摇杆之间、静音键上方。相同品牌标志也用于 [DualShock 4 官方产品](https://www.playstation.com/en-us/accessories/dualshock-4-wireless-controller/) 的 PS 键。

macOS 可使用 `playstation.logo`。本机 SF Symbols 元数据同样标记为 2022 年加入；Apple 限制该符号不可修改，且只能用于指代 Sony PlayStation。参考：[SF Symbols](https://developer.apple.com/sf-symbols/) 和 [Apple SF Symbols 设计指南](https://developer.apple.com/design/human-interface-guidelines/sf-symbols)。

许可风险：Sony 的 [Copyright and Trademark Notice](https://www.playstation.com/en-us/legal/copyright-and-trademark-notice/) 明确将 PlayStation 相关标志列为其商标。Dashboard 的设备识别语境符合 Apple 对系统符号的用途限制，但仍不应导出、改形或作为应用自身品牌使用。

## Nintendo Joy-Con

Nintendo 的 [Joy-Con Controller Diagram](https://en-americas-support.nintendo.com/app/answers/detail/a_id/22634/~/joy-con-controller-diagram) 展示了 Joy-Con 正面、侧面与背面。L/R 正面只有摇杆、方向或 ABXY 键、Minus/Plus、Capture/Home 等控制件，没有 Nintendo 字标或 Nintendo Switch 双胶囊标志。因此，为仓库中的两只裸 Joy-Con 正面叠加 Nintendo/Switch Logo 反而会造成硬件外观错误。

本机系统符号库没有 Nintendo 或 Joy-Con 品牌符号，`nintendo.switch.logo` 运行时也无法解析。此处应保留“无品牌标识”的真实状态；产品名称由界面文字表达即可。

许可风险：官方产品图和支持图解可作为外观事实依据，但不等于授予素材再分发许可。不要从官方页面截取 Logo 或自行绘制近似商标放进资源包。

## 小米蓝牙遥控器 2 Pro

小米的 [官方产品页](https://www.mi.com/xiaomi-bluetooth-remote-2-pro) 和页面引用的 [官方主视觉](https://cdn.cnbj1.fds.api.mi-img.com/product-images/xiaomi-bluetooth-remote-2-prob7e569/section-01.jpg) 显示：遥控器正面下部为小写 `xiaomi` 字标；其上方的 `N` 是 NFC 标志，不是小米品牌 Logo。没有可用的 Xiaomi/Mi 品牌 SF Symbol。

仓库的 `controller-dashboard-xiaomi-remote.png` 不能视为官方 Logo 资产。现有来源记录表明它由用户提供的 Gemini 生成图处理而来，因此图片中原有的 `xiaomi` 字样不会直接展示。Dashboard 先用同一张遥控器图片中相邻的金属纹理覆盖旧字样，再叠加由小米官方信任中心 CDN 提供的 [组合标志 SVG](https://cdna.sec.miui.com/mi-trust-center/group-mi-logo-mobile.svg) 中 `viewBox="20 4.667 40 6.667"` 对应的 `xiaomi` 字标路径（核验时原文件 SHA-256：`42ddf8a8231442f2072c443bddbdc176a1604be668b450941ebfa362c312e951`）。仓库资源 `xiaomi-wordmark.svg` 只裁切视口和取出该原始路径，不重绘字形。

官方产品图与 Trust Center 资源可用于核验外观和几何，但不自动扩大商标使用授权。该字标只在识别小米遥控器的语境中展示，不作为 Joy Harness 自身品牌，也不改变路径比例。

## 实施边界

- Xbox 与 PlayStation：直接使用 `Image(systemName:)` 或 `NSImage(systemSymbolName:)`，不导出、不修改符号路径。
- Joy-Con：不添加品牌 Logo，这是对真实正面外观的还原。
- 小米：设备外观仍使用现有示意图，但遮盖其中生成的字样，并叠加官方 SVG 中原始 `xiaomi` 字标路径。
- 以上结论只用于产品实现风险判断，不构成法律意见。
