# Sparkle 应用更新框架调研

调研日期：2026-09-25

## 定位

[Sparkle](https://github.com/sparkle-project/Sparkle) 是 macOS 应用的更新框架。本记录保存 Joy Harness 的接入决策和实施状态。代码已接入 Sparkle；更新 feed 将随首个合格的稳定版 Release 发布，目前尚无已发布的端到端更新验证。

## 官方能力与接入前提

- Sparkle 2 提供 Swift Package Manager 集成。SwiftUI 应用可持有 `SPUStandardUpdaterController`，并调用 `updater.checkForUpdates()` 实现手动检查更新。[安装文档](https://sparkle-project.org/documentation/)
- 更新需要 appcast feed（`SUFeedURL`）和新版本安装包。官方 `generate_appcast` 工具可以生成 appcast 和更新签名；发布的 DMG 可以作为更新包。[发布文档](https://sparkle-project.org/documentation/publishing/)
- 官方推荐 EdDSA 更新签名：在应用中配置 `SUPublicEDKey`，私钥留在发布环境。还应保证新版本的 `CFBundleVersion` 递增。Developer ID 签名、公证和 HTTPS 属于正式分发需要核对的安全链路。[安装文档](https://sparkle-project.org/documentation/) · [安全文档](https://sparkle-project.org/documentation/#security)
- 自动检查、后台下载与自动安装是不同的选择。`SUEnableAutomaticChecks` 控制自动检查的初始设置；`SUAutomaticallyUpdate` 控制自动下载及可行时的自动安装；`SUAllowsAutomaticUpdates` 可以禁止自动安装选项；`SUScheduledCheckInterval` 控制检查间隔。需要给用户修改这些偏好时，应按 Sparkle 的设置 API 接入。[定制文档](https://sparkle-project.org/documentation/customization/) · [偏好设置文档](https://sparkle-project.org/documentation/preferences-ui/)
- 自动安装并非无条件保证；需要用户授权等情况会改变安装行为。沙盒应用还需要 Sparkle 文档规定的服务和 entitlement 配置。[定制文档](https://sparkle-project.org/documentation/customization/) · [沙盒文档](https://sparkle-project.org/documentation/sandboxing/)

## 接入前基线

- macOS 13+、SwiftPM 构建；接入前 `Package.swift` 没有 Sparkle 依赖，应用设置的“通用”页也没有更新设置。
- GitHub Actions 从 `main` 构建并发布版本化 DMG 与 SHA-256 文件。发布模式可能是 Developer ID 签名并公证，也可能是 ad-hoc 签名且未公证；接入前没有 appcast 生成、签名和托管流程。
- `scripts/package_dmg.sh`、`scripts/install.sh` 和 `scripts/build_and_run.sh` 各自组装 `.app` 和 `Info.plist`，因此三个路径都需要核对框架嵌入、配置和嵌套代码签名。
- 源码安装和调试使用固定的 `/Applications/Joy Harness.app` 路径，并依赖稳定的 Developer ID 身份维持本机权限。若允许应用内更新覆盖本地构建，会干扰开发验证。

## 已决定

- 先记录框架并逐项讨论开关与发布边界；讨论完成后接入 Sparkle。
- 仅合格的 GitHub Release 稳定版启用 Sparkle 更新；源码安装版和调试构建关闭。后二者也使用 `/Applications/Joy Harness.app`，避免更新覆盖正在验证的本地版本。
- 为 GitHub Release 安装版提供手动“检查更新”；即使关闭自动检查，用户也能主动查询新版本。
- 手动“检查更新”放在 Joy Harness 应用菜单；自动更新偏好放在设置的“通用”页。
- 自动检查使用 Sparkle 的原生初始流程：第二次启动时询问用户是否开启，之后可在“通用”设置中修改。
- 开启自动检查后，沿用 Sparkle 默认的约 24 小时间隔；不提供单独的周期设置。
- 关闭自动下载和自动安装。自动检查只发现并提示新版本；下载和安装须由用户主动确认。
- 使用 Sparkle 原生更新窗口提示新版本，用户可选择立即更新或稍后；Joy Harness 不自行强制退出或重启。
- 只有 Developer ID 签名、Apple 公证及 EdDSA 更新签名齐备的发布包才进入 Sparkle 更新 feed。
- appcast 作为合格稳定版的 GitHub Release 资源发布，应用使用固定 HTTPS 地址 `/releases/latest/download/appcast.xml`；其中安装包链接指向各版本的固定 Release 资源。只有合格稳定版可设置为 `latest`，ad-hoc 与预发布版本必须显式设置 `--latest=false`。[GitHub Release 下载链接](https://docs.github.com/en/repositories/releasing-projects-on-github/linking-to-releases)
- 缺少签名或公证条件时，保留现有 ad-hoc DMG 手动下载方式；该构建关闭 Sparkle，且不进入更新 feed。
- 首版只提供稳定版更新通道；GitHub 预发布版本仍可手动下载，但不进入稳定版 feed，也不另设预发布 feed。
- Sparkle 更新应用时不自动重装已安装到系统目录的麦克风组件。只有组件确需升级时，才在设置中提示用户点击安装并完成管理员验证；不得静默重载音频服务。

## 实施与验证

- 2026-09-25 核对 GitHub Actions：Developer ID 与 Apple 公证所需的五个 secret 名称已存在；`SPARKLE_EDDSA_PRIVATE_KEY` 已配置为 Actions secret。私钥不提交到仓库，应用仅嵌入 `config/sparkle-public-key.txt` 中的公钥。
- GitHub Pages 对此仓库的默认地址会跳转到账号自定义域名，并将 `appcast.xml` 改写为页面路径，因此不作为 feed。正式发布时需验证 GitHub Release 的固定 `latest/download/appcast.xml` 可访问。
- 三条 `.app` 组装路径已嵌入 Sparkle 框架并签署嵌套代码；只有合格 Release 的 `Info.plist` 启用 updater。ad-hoc 和 Developer ID 本地 DMG 已通过签名与资源校验；隔离目录生成的 appcast 已通过结构校验。
- 当前已发布版本没有 Sparkle，用户需手动安装首个集成版本，此后才能使用应用内更新。
- 麦克风组件内容变更时须递增其 `CFBundleVersion`，以便应用识别已安装副本需要升级。
- 尚未发布集成 Sparkle 的公证稳定版，因此未验证真实 Release feed 下载与应用内安装全过程。

长期的更新源与签名边界记录在 [ADR 0003](../adr/0003-sparkle-signed-stable-feed.md)。
