import AppKit
import SwiftUI

/// 首次启动隐私门禁：必须明确同意后才写盘并启动蓝牙轮询，拒绝则直接退出。
@MainActor
enum PrivacyGate {
    private static var modalWindow: NSWindow?

    static func ensureAccepted(settings: inout AppSettings) -> Bool {
        if settings.privacyAccepted { return true }

        var accepted = false
        let view = PrivacyConsentView(
            onAccept: {
                accepted = true
                NSApp.stopModal(withCode: .OK)
            },
            onDecline: {
                accepted = false
                NSApp.stopModal(withCode: .cancel)
            }
        )

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 480),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.backgroundColor = .clear
        win.isOpaque = false
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
        win.isMovableByWindowBackground = true
        win.level = .floating

        let hosting = NSHostingView(rootView: view)
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        win.contentView = GlassWindowHost.makeContainer(contentView: hosting, cornerRadius: 22)
        win.center()
        modalWindow = win

        NSApp.activate(ignoringOtherApps: true)
        let response = NSApp.runModal(for: win)
        win.orderOut(nil)
        modalWindow = nil

        if response == .OK && accepted {
            settings.privacyAccepted = true
            try? settings.save()
            return true
        }
        return false
    }
}

private struct PrivacyConsentView: View {
    let onAccept: () -> Void
    let onDecline: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(Theme.ok)
                VStack(alignment: .leading, spacing: 2) {
                    Text("隐私与本地使用说明")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text("第三方开源工具（MIT License），与小米或酷态科官方无关")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            Divider().opacity(0.25)

            ScrollView {
                VStack(alignment: .leading, spacing: 11) {
                    section("一、首次扫码配对时", "向小米云申请一张登录二维码，账号、密码与确认全程在手机米家 App 完成，本程序不接触密码，只获取这台充电器的 MAC 与 12 字节本地通信 token。")
                    section("二、数据保存在哪里", "配对凭据仅保存在本机 ~/Library/Application Support/CuktechMac10Ultra/config.json；单口电量采集统计仅留存在内存中，不落盘、不写日志。")
                    section("三、日常联网行为", "连接充电器后所有功率读取、开关和设置全走 CoreBluetooth 本地蓝牙直连，日常零网络请求；仅当你主动点击「检查更新」时才会访问 GitHub Releases。")
                    section("四、随时彻底清理", "删掉上述配置目录即可清除本机所有配置与日志；蓝牙充电器端不会记录客户端信息。")
                }
            }
            .frame(maxHeight: 290)

            HStack(spacing: 10) {
                Button(action: onDecline) {
                    Text("不同意，退出")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .liquidGlassCapsule(interactive: true)

                Spacer()

                Button(action: onAccept) {
                    Text("同意并继续")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(Theme.ok))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(22)
        .frame(width: 460, height: 480)
    }

    private func section(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.primary.opacity(0.05)))
    }
}
