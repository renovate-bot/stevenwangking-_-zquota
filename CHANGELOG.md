# 更新日志

记录 ZQuota 每个版本的用户可见变更，格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)。

## [0.4.1] - 2026-10-11

### 修复

- 周窗口临近重置、剩余时间短于 5 小时窗口时，额度条不再把周窗口错标为「5 小时」行——窗口识别改按接口语义字段（`unit=3, number=5` 为 5 小时窗、`unit=6` 为周窗）判定，字段缺失时回退按重置时间排序。

### 变更

- 凭据读取改为双源：优先读取 `~/.zcode/v2/config.json` 中的 provider 明文 apiKey，不可用时回退原有 `credentials.json` 解密链路，降低对 ZCode 凭据加密格式变化的敏感度。

## [0.4.0] - 2026-10-10

### 新增

- 菜单栏与浮窗右键菜单的「设置」下方显示当前版本号（如 `ZQuota v0.4.0`），随时可确认正在运行的版本。

## [0.3.0] - 2026-10-10

### 新增

- 数据陈旧可见化：连续约 10 分钟（20 个刷新周期）未成功刷新即视为陈旧，Touch Bar 各展示加 ⚠ 前缀并保留上一组数据，恢复刷新后自动移除；掉登录、断网等场景下旧额度不再被误当作当前值。
- 发版自动化：推送 `v*` tag 后由 GitHub Actions 在云端构建 DMG、从本文件提取对应版本段落作为发布说明并自动创建 GitHub Release，本地不再手工打包。
- ZCode 项目 skill `/release`（`.zcode/skills/release`）：一句话完成版本号更新、CHANGELOG 归纳、打 tag 与发版验证。

## [0.2.0] - 2026-10-10

### 新增

- BetterTouchTool 版集成：`btt/render-bars.swift` 以与 APP 版一致的绘制参数渲染电量条 PNG，`btt/install.sh` 通过 BTT 的 AppleScript 接口幂等部署 ZCode 图标、主 widget（30 秒自刷新）与刷新按钮三个条目，点击 widget 或刷新按钮可即时重拉数据上屏；与 APP 版可共存、互不干扰。要求系统设置「触控栏显示」为 App 控制模式。
- DMG 打包脚本 `scripts/build-dmg.sh` 与 README 安装说明。

### 变更

- Touch Bar 仅在 ZCode 位于前台时呈现：监听前台应用切换，其他应用激活时自动隐藏，切回 ZCode 自动恢复；菜单栏开关更名为「在 ZCode 前台时显示」。
- Touch Bar 呈现不再激活 APP，避免抢走 ZCode 的键盘焦点（改为启动时激活一次）。

## [0.1.0] - 2026-10-09

### 新增

- Touch Bar 双行分段电量条常驻展示（5 小时额度 + 周额度 + 重置倒计时）。
- 菜单栏紧凑指示与桌面 HUD 浮窗，不依赖 Touch Bar 硬件。
- 每 30 秒自动刷新；自动读取 ZCode 本地凭据，无需配置 API Key。
- 支持 macOS 11+。
