import AppKit

@main
struct CharacterSkinTests {
    private static var checks = 0
    private static let states: [CompanionState] = [.idle, .working, .coding, .checking, .finished, .interrupted, .unknown, .needsAnswer, .needsReview]

    @MainActor
    static func main() throws {
        _ = NSApplication.shared
        try expect(CharacterSkin.allCases.count == 4, "Four complete skins are available")
        try expect(Set(CharacterSkin.allCases.map(\.title)).count == 4, "Skin titles distinguish choices")
        try expect(CharacterSkin(savedValue: nil) == .robot, "Missing preference uses familiar robot")
        try expect(CharacterSkin(savedValue: "future-skin") == .robot, "Unknown preference recovers safely")
        try expect(try JSONDecoder().decode(CharacterSkin.self, from: Data("\"future-skin\"".utf8)) == .robot,
                   "A future serialized skin does not corrupt the local library")
        var silhouettes: [Data] = []
        for skin in CharacterSkin.allCases {
            try expect(try JSONDecoder().decode(CharacterSkin.self, from: JSONEncoder().encode(skin)) == skin, "Skin preference round trips")
            let idle = render(skin: skin, state: .idle, time: 0, reducedMotion: true)
            silhouettes.append(idle.data)
            try expect(idle.occupied > 500, "Skin remains visible without aura")
            try expect(!idle.touchesEdge, "Full skin and state marks fit safely within the character region")
            for state in states {
                let first = render(skin: skin, state: state, time: 0.3, reducedMotion: true)
                let later = render(skin: skin, state: state, time: 6.6, reducedMotion: true)
                try expect(first.data == later.data, "Reduced motion is static for every skin and state")
                try expect(first.occupied > 450 && !first.touchesEdge, "Every state renders completely")
                let tiny = render(skin: skin, state: state, time: 0, reducedMotion: true, tiny: true)
                try expect(tiny.occupied > 85, "Every state remains visible at the 32pt notch size")
                if [.coding, .finished, .interrupted, .unknown, .needsAnswer, .needsReview].contains(state) {
                    try expect(first.data != idle.data, "Actionable states remain distinct without animation")
                }
            }
            let animatedA = render(skin: skin, state: .working, time: 0.3, reducedMotion: false)
            let animatedB = render(skin: skin, state: .working, time: 1.4, reducedMotion: false)
            try expect(animatedA.data != animatedB.data, "Working motion is available when permitted")
            let invalidTime = render(skin: skin, state: .working, time: .infinity, reducedMotion: false)
            try expect(invalidTime.occupied > 450, "Invalid clock value cannot break a character")
        }
        for left in silhouettes.indices {
            for right in silhouettes.indices where right > left {
                try expect(silhouettes[left] != silhouettes[right], "Skins have distinct silhouettes and colors")
            }
        }
        if let flag = CommandLine.arguments.firstIndex(of: "--preview"), CommandLine.arguments.count > flag + 1 {
            try writePreview(to: URL(fileURLWithPath: CommandLine.arguments[flag + 1]))
        }
        print("PASS: Character skins (\(checks) checks)")
    }

    @MainActor
    private static func render(skin: CharacterSkin, state: CompanionState, time: TimeInterval,
                               reducedMotion: Bool, tiny: Bool = false) -> (data: Data, occupied: Int, touchesEdge: Bool) {
        let edge = tiny ? 32 : 72
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: edge, pixelsHigh: edge,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        let context = NSGraphicsContext(bitmapImageRep: bitmap)!
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context.cgContext, flipped: true)
        let transform = NSAffineTransform()
        transform.translateX(by: tiny ? 4.3 : 8, yBy: tiny ? 28 : 64)
        transform.scaleX(by: tiny ? 0.42 : 1, yBy: tiny ? -0.42 : -1)
        transform.concat()
        CharacterRenderer.draw(skin: skin, state: state, animationTime: time,
            reducedMotion: reducedMotion, accent: NSColor(srgbRed: 0.64, green: 0.96, blue: 0.80, alpha: 1), showAura: false)
        NSGraphicsContext.restoreGraphicsState()
        var occupied = 0
        var touchesEdge = false
        for y in 0..<edge {
            for x in 0..<edge where bitmap.colorAt(x: x, y: y)!.alphaComponent > 0.2 {
                occupied += 1
                if x == 0 || y == 0 || x == edge - 1 || y == edge - 1 { touchesEdge = true }
            }
        }
        return (bitmap.representation(using: .png, properties: [:])!, occupied, touchesEdge)
    }

    @MainActor
    private static func writePreview(to url: URL) throws {
        let width = 1028, height = 578
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        let context = NSGraphicsContext(bitmapImageRep: bitmap)!
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context.cgContext, flipped: true)
        let flip = NSAffineTransform(); flip.translateX(by: 0, yBy: CGFloat(height)); flip.scaleX(by: 1, yBy: -1); flip.concat()
        NSColor(srgbRed: 0.035, green: 0.045, blue: 0.06, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        let names = ["Готов", "Думает", "Код", "Проверка", "Завершён", "Остановлен", "Нет событий", "Нужен ответ", "Результат"]
        for (index, name) in names.enumerated() {
            (name as NSString).draw(at: NSPoint(x: 176 + index * 94, y: 22), withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.white.withAlphaComponent(0.6)])
        }
        for (row, skin) in CharacterSkin.allCases.enumerated() {
            (skin.title as NSString).draw(at: NSPoint(x: 20, y: 88 + row * 128), withAttributes: [.font: NSFont.systemFont(ofSize: 14, weight: .semibold), .foregroundColor: NSColor.white])
            for (column, state) in states.enumerated() {
                let x = CGFloat(182 + column * 94), y = CGFloat(58 + row * 128)
                let accent = state == .needsAnswer || state == .needsReview || state == .checking
                    ? NSColor(srgbRed: 1, green: 0.75, blue: 0.38, alpha: 1)
                    : NSColor(srgbRed: 0.64, green: 0.96, blue: 0.80, alpha: 1)
                CharacterRenderer.draw(skin: skin, state: state, animationTime: 0,
                    reducedMotion: true, origin: NSPoint(x: x, y: y), accent: accent, showAura: false)
                let tiny = render(skin: skin, state: state, time: 0, reducedMotion: true, tiny: true)
                NSColor.black.setFill(); NSRect(x: x + 12, y: y + 67, width: 32, height: 32).fill()
                NSImage(data: tiny.data)?.draw(in: NSRect(x: x + 12, y: y + 67, width: 32, height: 32),
                    from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        try bitmap.representation(using: .png, properties: [:])!.write(to: url, options: .atomic)
    }

    private static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        checks += 1
        if try !condition() { throw Failure(message: message) }
    }
    private struct Failure: Error { let message: String }
}
