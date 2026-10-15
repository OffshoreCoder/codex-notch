import AppKit

/// A local visual preference. Unknown future values always recover to the original robot.
enum CharacterSkin: String, Codable, CaseIterable {
    case robot, cat, ghost, astronaut

    init(savedValue: String?) { self = savedValue.flatMap(Self.init(rawValue:)) ?? .robot }

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self.init(savedValue: value)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    var title: String {
        switch self {
        case .robot: return "Байт · робот"
        case .cat: return "Баг · кот"
        case .ghost: return "Бу · призрак"
        case .astronaut: return "Орбит · космонавт"
        }
    }

    var detail: String {
        switch self {
        case .robot: return "Мятный помощник с антенной"
        case .cat: return "Тёплый кот с острыми ушами"
        case .ghost: return "Сиреневый дух хорошего кода"
        case .astronaut: return "Маленький исследователь в шлеме"
        }
    }
}

/// All skins share one 56 × 58 logical canvas and the same state vocabulary.
/// Draws directly into our view; never reads pixels or loads external resources.
@MainActor
enum CharacterRenderer {
    static let canvasSize = NSSize(width: 56, height: 58)
    private static let mint = color(0.64, 0.96, 0.80)
    private static let dark = color(0.045, 0.075, 0.10)

    static func draw(skin: CharacterSkin, state: CompanionState, animationTime: TimeInterval,
                     reducedMotion: Bool, origin: NSPoint = .zero, accent: NSColor,
                     showAura: Bool = true, reactionProgress: CGFloat? = nil) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let t = reducedMotion || !animationTime.isFinite ? 0 : animationTime
        let busy = state == .working || state == .coding
        let motion = SkinMotion(time: t, busy: busy && !reducedMotion,
                                progress: reducedMotion ? nil : reactionProgress)
        let bob: CGFloat = busy && !reducedMotion
            ? CGFloat(sin(t * (skin == .ghost ? 2.8 : 3.4))) * (skin == .ghost ? 2.4 : 0.7) : 0
        let transform = NSAffineTransform()
        transform.translateX(by: origin.x + 28, yBy: origin.y + bob + 28 - motion.hop)
        transform.rotate(byDegrees: motion.tilt)
        transform.translateX(by: -28, yBy: -28)
        transform.concat()
        if showAura {
            accent.withAlphaComponent(0.08).setFill()
            NSBezierPath(ovalIn: NSRect(x: -8, y: -4, width: 73, height: 63)).fill()
        }
        switch skin {
        case .robot: drawRobot(state: state, time: t, reducedMotion: reducedMotion, accent: accent, motion: motion)
        case .cat: drawCat(state: state, time: t, reducedMotion: reducedMotion, accent: accent, motion: motion)
        case .ghost: drawGhost(state: state, time: t, reducedMotion: reducedMotion, accent: accent, motion: motion)
        case .astronaut: drawAstronaut(state: state, time: t, reducedMotion: reducedMotion, accent: accent, motion: motion)
        }
        if state == .coding { keyboard(time: t, color: skin == .robot ? mint : accent) }
        stateMark(state, accent: accent)
    }

    private struct SkinMotion {
        let wave: CGFloat
        let tap: CGFloat
        let reaction: CGFloat
        let hop: CGFloat
        let tilt: CGFloat

        init(time: TimeInterval, busy: Bool, progress: CGFloat?) {
            wave = busy ? CGFloat(sin(time * 4.2)) : 0
            tap = busy ? CGFloat(sin(time * 10)) : 0
            let p = progress.flatMap { $0.isFinite && $0 >= 0 && $0 < 1 ? $0 : nil }
            // Smoothly returns to the exact static pose at both ends.
            reaction = p.map { sin($0 * .pi) } ?? 0
            hop = reaction * 2.2
            tilt = p.map { sin($0 * .pi * 4) * sin($0 * .pi) * 2.4 } ?? 0
        }
    }

    private static func drawRobot(state: CompanionState, time: TimeInterval, reducedMotion: Bool, accent: NSColor,
                                  motion: SkinMotion) {
        let antenna = motion.wave * 3 + motion.reaction * 2
        stroke(points: [NSPoint(x: 28, y: 6), NSPoint(x: 28 + antenna, y: 0)], color: accent.withAlphaComponent(0.75), width: 2)
        fillOval(NSRect(x: 25.5 + antenna, y: -4, width: 5, height: 5), accent)
        round(NSRect(x: -3, y: 21, width: 7, height: 15), radius: 3, color: color(0.14, 0.21, 0.20))
        round(NSRect(x: 51, y: 21, width: 7, height: 15), radius: 3, color: color(0.14, 0.21, 0.20))
        round(NSRect(x: 0, y: 6, width: 56, height: 43), radius: 13, color: mint)
        round(NSRect(x: 6, y: 14, width: 44, height: 25), radius: 8, color: color(0.045, 0.105, 0.095))
        eyes(state: state, time: time, reducedMotion: reducedMotion, leftX: 15, rightX: 36, y: 22, color: mint)
        if state == .checking { fillOval(NSRect(x: 26.5, y: 32, width: 3, height: 3), accent) }
        round(NSRect(x: 11, y: 49, width: 11, height: 5), radius: 2, color: mint.withAlphaComponent(0.75))
        round(NSRect(x: 34, y: 49, width: 11, height: 5), radius: 2, color: mint.withAlphaComponent(0.75))
        if state == .working || state == .coding || motion.reaction > 0 {
            round(NSRect(x: 1, y: 40 + motion.tap * 2 - motion.reaction * 5, width: 12, height: 7), radius: 3, color: mint)
            round(NSRect(x: 43, y: 40 - motion.tap * 2 - motion.reaction * 5, width: 12, height: 7), radius: 3, color: mint)
        }
    }

    private static func drawCat(state: CompanionState, time: TimeInterval, reducedMotion: Bool, accent: NSColor,
                                motion: SkinMotion) {
        let fur = color(1, 0.79, 0.48)
        // A wide, readable ear silhouette survives the 24pt notch rendering.
        let ears = NSBezierPath()
        let earTwitch = motion.wave * 2.3 + motion.reaction * 1.7
        ears.move(to: NSPoint(x: 2, y: 23)); ears.line(to: NSPoint(x: 3 + earTwitch, y: 0))
        ears.line(to: NSPoint(x: 21, y: 13)); ears.line(to: NSPoint(x: 35, y: 13))
        ears.line(to: NSPoint(x: 53 - earTwitch, y: 0)); ears.line(to: NSPoint(x: 54, y: 23)); ears.close()
        fur.setFill(); ears.fill()
        triangle([NSPoint(x: 7, y: 6), NSPoint(x: 8, y: 18), NSPoint(x: 17, y: 14)], color: color(0.80, 0.42, 0.31))
        triangle([NSPoint(x: 49, y: 6), NSPoint(x: 48, y: 18), NSPoint(x: 39, y: 14)], color: color(0.80, 0.42, 0.31))
        round(NSRect(x: 0, y: 12, width: 56, height: 38), radius: 16, color: fur)
        let leftPaw = max(0, motion.tap) * 3 + motion.reaction * 4
        let rightPaw = max(0, -motion.tap) * 3 + motion.reaction * 4
        round(NSRect(x: 8, y: 43 - leftPaw, width: 14, height: 10), radius: 5, color: fur)
        round(NSRect(x: 34, y: 43 - rightPaw, width: 14, height: 10), radius: 5, color: fur)
        for x: CGFloat in [12, 16] {
            stroke(points: [NSPoint(x: x, y: 49 - leftPaw), NSPoint(x: x, y: 52 - leftPaw)], color: color(0.81, 0.50, 0.29), width: 1)
            stroke(points: [NSPoint(x: x + 26, y: 49 - rightPaw), NSPoint(x: x + 26, y: 52 - rightPaw)], color: color(0.81, 0.50, 0.29), width: 1)
        }
        eyes(state: state, time: time, reducedMotion: reducedMotion, leftX: 14, rightX: 37, y: 25, color: color(0.20, 0.13, 0.12))
        triangle([NSPoint(x: 25, y: 35), NSPoint(x: 31, y: 35), NSPoint(x: 28, y: 38)], color: color(0.64, 0.30, 0.27))
        stroke(points: [NSPoint(x: -3, y: 31), NSPoint(x: 7, y: 33)], color: fur, width: 2)
        stroke(points: [NSPoint(x: 49, y: 33), NSPoint(x: 59, y: 31)], color: fur, width: 2)
        stroke(points: [NSPoint(x: -2, y: 38), NSPoint(x: 7, y: 37)], color: fur, width: 2)
        stroke(points: [NSPoint(x: 49, y: 37), NSPoint(x: 58, y: 38)], color: fur, width: 2)
        if state == .working {
            stroke(points: [NSPoint(x: 25, y: 14), NSPoint(x: 28, y: 18), NSPoint(x: 31, y: 14)], color: color(0.82, 0.50, 0.28), width: 2)
        }
        if state == .checking { fillOval(NSRect(x: 25, y: 41, width: 6, height: 4), accent) }
    }

    private static func drawGhost(state: CompanionState, time: TimeInterval, reducedMotion: Bool, accent: NSColor,
                                  motion: SkinMotion) {
        let lavender = color(0.81, 0.74, 1)
        let body = NSBezierPath()
        body.move(to: NSPoint(x: 4, y: 51)); body.line(to: NSPoint(x: 4, y: 25))
        body.curve(to: NSPoint(x: 28, y: 2), controlPoint1: NSPoint(x: 4, y: 10), controlPoint2: NSPoint(x: 13, y: 2))
        body.curve(to: NSPoint(x: 52, y: 25), controlPoint1: NSPoint(x: 43, y: 2), controlPoint2: NSPoint(x: 52, y: 10))
        body.line(to: NSPoint(x: 52, y: 51)); body.line(to: NSPoint(x: 44, y: 45 + motion.wave))
        body.line(to: NSPoint(x: 36, y: 53 - motion.wave)); body.line(to: NSPoint(x: 28, y: 46 + motion.wave))
        body.line(to: NSPoint(x: 20, y: 53 - motion.wave)); body.line(to: NSPoint(x: 12, y: 45 + motion.wave)); body.close()
        lavender.setFill(); body.fill()
        // Soft shoulder lobes keep the silhouette distinct from a rounded robot head.
        fillOval(NSRect(x: -2, y: 27 + motion.wave * 3 - motion.reaction * 6, width: 13, height: 10), lavender)
        fillOval(NSRect(x: 45, y: 27 - motion.wave * 3 - motion.reaction * 6, width: 13, height: 10), lavender)
        eyes(state: state, time: time, reducedMotion: reducedMotion, leftX: 16, rightX: 35, y: 22, color: color(0.20, 0.15, 0.34))
        if state == .working || state == .checking {
            fillOval(NSRect(x: 25.5, y: 33, width: 5, height: 6), color(0.34, 0.25, 0.47))
        } else if state == .idle {
            round(NSRect(x: 24, y: 34, width: 8, height: 2), radius: 1, color: color(0.42, 0.31, 0.56))
        }
        fillOval(NSRect(x: 9, y: 31, width: 7, height: 3), color(0.90, 0.52, 0.73).withAlphaComponent(0.65))
        fillOval(NSRect(x: 40, y: 31, width: 7, height: 3), color(0.90, 0.52, 0.73).withAlphaComponent(0.65))
    }

    private static func drawAstronaut(state: CompanionState, time: TimeInterval, reducedMotion: Bool, accent: NSColor,
                                      motion: SkinMotion) {
        let suit = color(0.91, 0.95, 1)
        if state == .working || state == .coding || motion.reaction > 0 {
            let thrust: CGFloat = reducedMotion ? 2 : 2 + (motion.wave + 1) * 2 + motion.reaction * 2
            for x: CGFloat in [14, 36] {
                triangle([NSPoint(x: x, y: 49), NSPoint(x: x + 6, y: 49), NSPoint(x: x + 3, y: 53 + thrust)],
                         color: accent.withAlphaComponent(0.85))
            }
        }
        round(NSRect(x: 9, y: 30, width: 38, height: 23), radius: 9, color: suit)
        round(NSRect(x: 1, y: 16, width: 10, height: 20), radius: 4, color: color(0.48, 0.59, 0.72))
        round(NSRect(x: 45, y: 16, width: 10, height: 20), radius: 4, color: color(0.48, 0.59, 0.72))
        fillOval(NSRect(x: 2, y: 0, width: 52, height: 45), suit)
        round(NSRect(x: 8, y: 10, width: 40, height: 28), radius: 12, color: color(0.08, 0.18, 0.28))
        let reflection = NSBezierPath()
        let visorShift = motion.wave * 2
        reflection.move(to: NSPoint(x: 14 + visorShift, y: 20))
        reflection.curve(to: NSPoint(x: 24 + visorShift, y: 14), controlPoint1: NSPoint(x: 15 + visorShift, y: 16), controlPoint2: NSPoint(x: 19 + visorShift, y: 14))
        reflection.lineWidth = 2; reflection.lineCapStyle = .round
        NSColor.white.withAlphaComponent(0.23).setStroke(); reflection.stroke()
        eyes(state: state, time: time, reducedMotion: reducedMotion, leftX: 16, rightX: 35, y: 23, color: color(0.70, 0.89, 1))
        round(NSRect(x: 13, y: 48, width: 12, height: 6), radius: 2, color: suit)
        round(NSRect(x: 31, y: 48, width: 12, height: 6), radius: 2, color: suit)
        round(NSRect(x: 20, y: 41, width: 16, height: 8), radius: 2, color: color(0.28, 0.40, 0.55))
        fillOval(NSRect(x: 23, y: 43, width: 3, height: 3), accent)
        round(NSRect(x: 29, y: 44, width: 4, height: 1.5), radius: 0.5, color: suit)
    }

    private static func eyes(state: CompanionState, time: TimeInterval, reducedMotion: Bool,
                             leftX: CGFloat, rightX: CGFloat, y: CGFloat, color eyeColor: NSColor) {
        for x in [leftX, rightX] {
            switch state {
            case .finished:
                let smile = NSBezierPath(); smile.move(to: NSPoint(x: x - 1, y: y + 5))
                smile.curve(to: NSPoint(x: x + 7, y: y + 5), controlPoint1: NSPoint(x: x, y: y - 1), controlPoint2: NSPoint(x: x + 6, y: y - 1))
                smile.lineWidth = 2.5; smile.lineCapStyle = .round; eyeColor.setStroke(); smile.stroke()
            case .interrupted:
                round(NSRect(x: x - 1, y: y + 4, width: 8, height: 2.5), radius: 1, color: eyeColor)
            case .unknown:
                stroke(points: [NSPoint(x: x - 1, y: y + 5), NSPoint(x: x + 6, y: y + 3)], color: eyeColor, width: 2.5)
            case .needsAnswer:
                fillOval(NSRect(x: x - 1, y: y - 1, width: 7, height: 9), eyeColor)
                fillOval(NSRect(x: x + 1, y: y + 1, width: 2, height: 3), dark)
            case .needsReview:
                let lens = NSBezierPath(ovalIn: NSRect(x: x - 3, y: y - 2, width: 11, height: 12))
                lens.lineWidth = 1.7; eyeColor.setStroke(); lens.stroke()
                round(NSRect(x: x + 1, y: y + 1, width: 3, height: 6), radius: 1.5, color: eyeColor)
            default:
                let blink = !reducedMotion && time.truncatingRemainder(dividingBy: 6.7) > 6.48
                let glance: CGFloat = state == .working ? CGFloat(sin(time * 1.4)) * 2 : 0
                round(NSRect(x: x + glance, y: y, width: 5, height: blink ? 1.7 : (state == .checking ? 9 : 7)), radius: 2, color: eyeColor)
            }
        }
    }

    private static func keyboard(time: TimeInterval, color: NSColor) {
        round(NSRect(x: 1, y: 44, width: 54, height: 8), radius: 3, color: NSColor(calibratedWhite: 0.24, alpha: 1))
        let active = Int((time * 8).truncatingRemainder(dividingBy: 8))
        for index in 0..<8 {
            round(NSRect(x: 7 + CGFloat(index) * 5.6, y: 46, width: 3.5, height: 2), radius: 0.5,
                  color: color.withAlphaComponent(active == index ? 1 : 0.4))
        }
    }

    private static func stateMark(_ state: CompanionState, accent: NSColor) {
        if state == .finished {
            sparkle(center: NSPoint(x: 58, y: 8), size: 4, color: accent)
            sparkle(center: NSPoint(x: -4, y: 12), size: 2.5, color: accent.withAlphaComponent(0.7))
        } else if state == .needsAnswer {
            round(NSRect(x: 52, y: 1, width: 9, height: 14), radius: 4, color: accent)
            round(NSRect(x: 55.5, y: 4, width: 2, height: 5), radius: 1, color: dark)
            fillOval(NSRect(x: 55.5, y: 11, width: 2, height: 2), dark)
        } else if state == .needsReview {
            round(NSRect(x: 49, y: 0, width: 12, height: 15), radius: 3, color: accent)
            stroke(points: [NSPoint(x: 52, y: 5), NSPoint(x: 58, y: 5)], color: dark, width: 1.5)
            stroke(points: [NSPoint(x: 52, y: 9), NSPoint(x: 57, y: 9)], color: dark, width: 1.5)
        }
    }

    private static func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
    }
    private static func round(_ rect: NSRect, radius: CGFloat, color: NSColor) {
        color.setFill(); NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
    }
    private static func fillOval(_ rect: NSRect, _ color: NSColor) { color.setFill(); NSBezierPath(ovalIn: rect).fill() }
    private static func stroke(points: [NSPoint], color: NSColor, width: CGFloat) {
        guard let first = points.first else { return }
        let path = NSBezierPath(); path.move(to: first)
        for point in points.dropFirst() { path.line(to: point) }
        path.lineWidth = width; path.lineCapStyle = .round; path.lineJoinStyle = .round
        color.setStroke(); path.stroke()
    }
    private static func triangle(_ points: [NSPoint], color: NSColor) {
        guard let first = points.first else { return }
        let path = NSBezierPath(); path.move(to: first)
        for point in points.dropFirst() { path.line(to: point) }
        path.close(); color.setFill(); path.fill()
    }
    private static func sparkle(center: NSPoint, size: CGFloat, color: NSColor) {
        let path = NSBezierPath()
        for index in 0..<8 {
            let angle = CGFloat(index) * .pi / 4 - .pi / 2
            let radius = index % 2 == 0 ? size : size * 0.38
            let p = NSPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
            if index == 0 { path.move(to: p) } else { path.line(to: p) }
        }
        path.close(); color.setFill(); path.fill()
    }
}
