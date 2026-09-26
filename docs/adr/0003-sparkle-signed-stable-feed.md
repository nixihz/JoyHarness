# Sparkle 只使用签名稳定版更新源

Joy Harness 的 GitHub Release 工作流既可发布 Developer ID 签名并公证的 DMG，也可发布 ad-hoc DMG；源码安装和调试构建则与正式应用共用固定安装路径。Sparkle 的更新源必须明确排除不符合正式分发条件的构建，并提供固定 HTTPS 地址。

**状态**：accepted（2026-09-25）

## 决策

- 只有 GitHub Release 的稳定版、Developer ID 签名、Apple 公证及 EdDSA 更新签名齐备时，才将它加入 Sparkle appcast。源码安装和调试构建不启动 Sparkle；ad-hoc DMG 与预发布版本也不启动 Sparkle，仍可通过 GitHub Release 手动下载。
- appcast 与合格稳定版一起作为 GitHub Release 资源发布，应用使用 `/releases/latest/download/appcast.xml`。appcast 中的安装包链接指向各版本固定的 Release 资源；发布后验证固定地址可访问。
- 只有合格稳定版设置 GitHub `latest`，ad-hoc 和预发布版本都显式设置 `--latest=false`。原流程对所有正式版本设置 `latest`，在接入 Sparkle 时必须同步改变。

## 影响

- Sparkle EdDSA 私钥只保存在发布环境；应用包嵌入公钥。缺少签名或公证条件时，不得把该版本加入更新源。
- 首个集成 Sparkle 的版本需要现有用户手动安装一次。
- 麦克风组件安装在应用包外，应用更新不能替代它的管理员授权安装流程；确需升级时由用户在设置中发起。
