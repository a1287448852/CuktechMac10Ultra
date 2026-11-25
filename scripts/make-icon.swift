import AppKit
import Foundation

// 生成 macOS 应用图标（AppIcon.iconset），make-app.sh 会调它再 iconutil 成 .icns。
//
// 为什么不把 .icns 直接提交进仓库：二进制进 git 既没法 review，diff 也全是噪音；
// 而且图标一旦要微调，改一行颜色比重新导出一套 PNG 干净得多。这里用同一个
// 绘制函数按需要生成全部尺寸，保证各尺寸形状一致（不是从 1024 缩下来的糊图）。
//
// 用法：
//   swiftc -O scripts/make-icon.swift -o .build/make-icon
//   .build/make-icon <输出目录>

let outDir = CommandLine.arguments.count > 1
    ? URL(fileURLWithPath: CommandLine.arguments[1])
    : URL(fileURLWithPath: "AppIcon.iconset")

try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

struct Spec {
    let points: Int
    let scale: Int
    var name: String {
        scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
    }
    var pixels: Int { points * scale }
}

/// iconset 要求的十个尺寸（16/32/128/256/512 各 @1x @2x）。
let specs: [Spec] = [
    Spec(points: 16, scale: 1), Spec(points: 16, scale: 2),
    Spec(points: 32, scale: 1), Spec(points: 32, scale: 2),
    Spec(points: 128, scale: 1), Spec(points: 128, scale: 2),
    Spec(points: 256, scale: 1), Spec(points: 256, scale: 2),
    Spec(points: 512, scale: 1), Spec(points: 512, scale: 2),
]

/// 画一枚图标：深蓝到电青的渐变底 + 白色闪电。
/// 小尺寸下细节会被抹掉，所以只保留「底 + 一道闪电」两个元素。
func draw(pixels: Int) -> Data? {
    let size = CGFloat(pixels)
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                     pixelsWide: pixels, pixelsHigh: pixels,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                     isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0),
          let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    ctx.imageInterpolation = .high

    // 按 macOS 惯例留边，四角圆角（半径接近系统 squircle 的观感）
    let inset = size * 0.055
    let rect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let radius = rect.width * 0.225
    let plate = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

    // 底：上亮下深的垂直渐变。
    //
    // 这里刻意不用 NSGradient / CGGradient：两者都会加抖动（dither）来消除色带，
    // 在 1024px 上表现为满屏细噪点——实测单张 PNG 从几十 KB 涨到 900 KB，
    // .icns 跟着变成 1.2 MB。逐行填纯色能得到同样的肉眼效果，压缩率却是数量级的好。
    NSGraphicsContext.saveGraphicsState()
    plate.setClip()
    let top = NSColor(srgbRed: 0.16, green: 0.60, blue: 1.00, alpha: 1)
    let bottom = NSColor(srgbRed: 0.04, green: 0.13, blue: 0.36, alpha: 1)
    for y in 0..<pixels {
        let t = CGFloat(y) / CGFloat(max(pixels - 1, 1))
        let c = NSColor(srgbRed: bottom.redComponent + (top.redComponent - bottom.redComponent) * t,
                        green: bottom.greenComponent + (top.greenComponent - bottom.greenComponent) * t,
                        blue: bottom.blueComponent + (top.blueComponent - bottom.blueComponent) * t,
                        alpha: 1)
        c.setFill()
        NSRect(x: rect.minX, y: CGFloat(y), width: rect.width, height: 1).fill()
    }
    NSGraphicsContext.restoreGraphicsState()

    // 白色闪电：sf symbol 按像素尺寸取，保证小图也锐利
    let config = NSImage.SymbolConfiguration(pointSize: size * 0.60, weight: .bold)
        .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
    if let bolt = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {
        let s = bolt.size
        let target = NSRect(x: (size - s.width) / 2,
                            y: (size - s.height) / 2,
                            width: s.width, height: s.height)
        // 不画阴影：模糊会让 PNG 变成几 MB 的噪声，压不下去，也让 16px 尺寸发脏。
        bolt.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1)
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

var failed = 0
for spec in specs {
    if let data = draw(pixels: spec.pixels) {
        try? data.write(to: outDir.appendingPathComponent(spec.name))
    } else {
        FileHandle.standardError.write(Data("✗ 生成 \(spec.name) 失败\n".utf8))
        failed += 1
    }
}
exit(failed == 0 ? 0 : 1)
