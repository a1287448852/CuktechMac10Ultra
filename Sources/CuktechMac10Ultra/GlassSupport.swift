import AppKit
import SwiftUI
import CuktechCore

/// 颜色映射：功率灯效采用高对比鲜明色阶，玻璃表面文本跟随系统自适应语义色。
enum Theme {
    static let ok = Color(red: 48 / 255, green: 209 / 255, blue: 88 / 255)
    static let bad = Color(red: 1.0, green: 69 / 255, blue: 58 / 255)
    static let warn = Color(red: 1.0, green: 159 / 255, blue: 10 / 255)
    static let accent = Color(red: 56 / 255, green: 189 / 255, blue: 248 / 255)

    static func color(_ c: RGB) -> Color {
        Color(red: c.r, green: c.g, blue: c.b)
    }

    static func menuBarNSColor(for rgb: RGB) -> NSColor {
        NSColor(srgbRed: rgb.r, green: rgb.g, blue: rgb.b, alpha: 1)
    }
}

/// 窗口级 Liquid Glass 宿主视图（macOS 26+ 使用原生 NSGlassEffectView，旧系统平滑降级为 NSVisualEffectView）。
enum GlassWindowHost {
    static func makeContainer(contentView: NSView, cornerRadius: CGFloat = 20) -> NSView {
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.cornerRadius = cornerRadius
            glass.contentView = contentView
            return glass
        } else {
            let blur = NSVisualEffectView()
            blur.material = .popover
            blur.blendingMode = .behindWindow
            blur.state = .active
            blur.wantsLayer = true
            blur.layer?.cornerRadius = cornerRadius
            blur.layer?.masksToBounds = true
            contentView.translatesAutoresizingMaskIntoConstraints = false
            blur.addSubview(contentView)
            NSLayoutConstraint.activate([
                contentView.leadingAnchor.constraint(equalTo: blur.leadingAnchor),
                contentView.trailingAnchor.constraint(equalTo: blur.trailingAnchor),
                contentView.topAnchor.constraint(equalTo: blur.topAnchor),
                contentView.bottomAnchor.constraint(equalTo: blur.bottomAnchor),
            ])
            return blur
        }
    }
}

/// SwiftUI Liquid Glass 表面修饰器：把原生玻璃质感与降级材质统一封装。
extension View {
    @ViewBuilder
    func liquidGlassSurface(cornerRadius: CGFloat = 14, tint: Color? = nil, interactive: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            if let tint {
                self.glassEffect(
                    .regular.tint(tint).interactive(interactive),
                    in: shape
                )
            } else {
                self.glassEffect(
                    .regular.interactive(interactive),
                    in: shape
                )
            }
        } else {
            let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            self
                .background(.ultraThinMaterial, in: shape)
                .overlay(shape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.75))
        }
    }

    @ViewBuilder
    func liquidGlassCapsule(tint: Color? = nil, interactive: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            if let tint {
                self.glassEffect(.regular.tint(tint).interactive(interactive), in: Capsule())
            } else {
                self.glassEffect(.regular.interactive(interactive), in: Capsule())
            }
        } else {
            self
                .background(.thinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.75))
        }
    }
}

/// 在 macOS 26+ 启用 GlassEffectContainer 进行玻璃通道合并优化，降低 GPU 合成开销。
struct AdaptiveGlassGroup<Content: View>: View {
    let spacing: CGFloat
    @ViewBuilder let content: () -> Content

    init(spacing: CGFloat = 8, @ViewBuilder content: @escaping () -> Content) {
        self.spacing = spacing
        self.content = content
    }

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) {
                content()
            }
        } else {
            content()
        }
    }
}
