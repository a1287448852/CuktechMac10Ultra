# CuktechMac10Ultra

专为 **macOS** 打造的「酷态科 10 号 Ultra」菜单栏实时功率监控与控制工具。  
纯 Swift 原生编写（`AppKit` + `SwiftUI` + `CoreBluetooth`），无需 Electron、无需运行时，安装包约 **2 MB**，支持 **macOS 26+ 原生 Liquid Glass** 液态玻璃交互界面（macOS 14–15 自动平滑降级为系统毛玻璃）。

> 本项目基于 [Blank2007/cuktech-ultra-tray](https://github.com/Blank2007/cuktech-ultra-tray)（MIT License）衍生开发，面向 macOS 进行全事件驱动重构、性能优化与 Liquid Glass 原生视觉升级。

---

## 核心特性

- **原生 Liquid Glass 面板**：macOS 26+ 使用原生 `NSGlassEffectView` 与 SwiftUI `GlassEffectContainer` / `.glassEffect()`，支持交互高光、标题栏拖拽固定与点击外部自动收起。
- **状态栏实时总功率**：通过 `NSStatusItem` 直接在菜单栏显示四口总输出功率（按负载自动分色），支持固定宽度防图标抖动、自由切换仅图标模式，并在深色/浅色壁纸下自动保证清晰对比度。
- **零轮询事件驱动架构**：
  - `NotifyQueue` 与 `CBMibleLink` 全程使用 `CheckedContinuation` 事件唤醒，彻底消除空转定时器。
  - `TrayController` 通过 `AsyncStream` 响应式刷新，空闲时 CPU 占用趋近于 0。
  - **前后台自适应轮询**：面板收起时 `2.5s` 低频采集（跳过冗余模式查询）；点开面板支持自定义 `1 / 2 / 3 / 5 / 10s` 高频刷新，并修复延迟 `SET ACK` 串帧问题。
- **瞬时充电模式切换与四路开关**：
  - 修复四路端口索引映射，支持 C1 / C2 / C3 / USB-A 独立通断（读-改-写 + 回读校验）；针对硬件共用采样通道合并展示 `C3 / A` 实时功率与各口**实时协商协议**（如 `PD 65W` / `PPS`）。
  - 消除 `SET ACK` 后 1 秒冗余空等，支持控制指令优先插队与快速连击合并（Latest-Wins），配合 `.snappy` 乐观动画带来跟手切换体验。
- **单口 `Wh` 电量采集与硬件设置（v1.1.0）**：
  - **单口采集 (`Wh`)**：基于 1 秒精确节拍与同压段梯形 / 跨压段保守积分，实时展示充入电量，拔线或 30 秒空载自动结束并弹出 Liquid Glass 结果卡片（支持一键复制摘要，全程仅驻留内存不落盘）。
  - **硬件全参数设置**：Liquid Glass 设置窗口直接读写屏幕息屏时间、空闲息屏、方向锁、屏幕语言、USB-A 小电流模式、各口定时自动断电，以及 C1/C2/C3/A 各口独立快充协议开关（PD / PPS / UFCS / SCP 读-改-写掩码）。
  - **隐私承诺与手动检查更新**：首次启动展示本地协议与蓝牙隐私授权弹窗，内置手动触发的 GitHub Releases 版本检查（绝不在后台擅自联网）。
- **macOS 原生生态集成**：
  - 扫码配对向导（米家 App 扫码拿本机 token，日常读数纯本地蓝牙直连不联网）。
  - 支持 `SMAppService.mainApp` 原生「登录时自动启动」。
  - 监听 `NSWorkspace.didWakeNotification`，Mac 睡眠唤醒后自动触发快速重连。

---

## 安装与首次打开（DMG）

1. 前往本仓库 [Releases](https://github.com/a1287448852/CuktechMac10Ultra/releases) 页面下载 `CuktechMac10Ultra-<版本>-macOS.dmg`。
2. 双击打开 DMG，将 **`CuktechMac10Ultra.app`** 拖入 `Applications`（应用程序）文件夹。
3. **绕过未公证拦截（重要）**：由于本开源项目采用 ad-hoc 本地签名（暂无 Apple Developer \$99/年公证证书），首次双击可能会提示无法验证开发者，请任选以下一种方式放行：
   - **图形界面**：打开「系统设置 → 隐私与安全性」，滑到底部点击 **「仍要打开」**。
   - **终端命令**：
     ```bash
     xattr -dr com.apple.quarantine /Applications/CuktechMac10Ultra.app
     open /Applications/CuktechMac10Ultra.app
     ```
4. 首次运行会请求**蓝牙权限**，请点击「允许」；随后按向导用手机「米家」App 扫码选择你的酷态科 10 号 Ultra 即可完成配对。

> 如果你之前用过原版 `CuktechTray` 或 `CuktechMac`，首次启动会自动迁移原有配置，无需重新扫码。

---

## 隐私说明

- **扫码配对阶段**：向小米云申请登录二维码并在手机米家 App 确认，账号密码与验证码不经过本程序；配对后仅将充电器 `MAC` 与 `12 字节 token` 保存在本机 `~/Library/Application Support/CuktechMac10Ultra/config.json`。
- **日常运行阶段**：仅通过 CoreBluetooth 本地直连充电器，**完全不联网、不上传任何数据**。

---

## 本地编译与打包 DMG

需要 Xcode 或 Xcode Command Line Tools（macOS 14+ SDK，建议 macOS 26+ SDK 以启用 Liquid Glass）：

```bash
# 运行单元测试（协议加解密、黄金向量、MiBeacon 广播解析、并发互斥锁）
swift test

# 编译本机架构 .app 并生成 DMG 安装包（产物位于 dist/）
bash scripts/make-app.sh
bash scripts/make-dmg.sh

# 若需同时打包 Universal (arm64 + x86_64)
bash scripts/build-universal.sh
bash scripts/make-app.sh dist .build/release/CuktechMac10Ultra
bash scripts/make-dmg.sh
```

离线界面预览参数（不依赖真实充电器）：

```bash
./dist/CuktechMac10Ultra.app/Contents/MacOS/CuktechMac10Ultra --panel-demo
./dist/CuktechMac10Ultra.app/Contents/MacOS/CuktechMac10Ultra --wizard-demo=welcome
```

---

## 致谢 (Acknowledgments)

本项目以 **MIT License** 开源，协议与蓝牙实现深度受益于以下开源项目，特此致谢：

- **[Blank2007/cuktech-ultra-tray](https://github.com/Blank2007/cuktech-ultra-tray)**（MIT License）：提供完整的 MIoT BLE 加密认证、TLV 编解码、小米云扫码登录及 macOS 初版协议验证基础。
- **[kairui1108/cuktech-ble-ha](https://github.com/kairui1108/cuktech-ble-ha)** & **[kairui1108/cuktech-ble-esp32](https://github.com/kairui1108/cuktech-ble-esp32)**（MIT License）：最早反推出酷态科 10 号 Ultra 蓝牙协议的开源项目。
- **[apple/swift-crypto](https://github.com/apple/swift-crypto)**（Apache License 2.0）：提供跨平台密码学支持。

详情见 [LICENSE](LICENSE) 与 [NOTICE](NOTICE)。
