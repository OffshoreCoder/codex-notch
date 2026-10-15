import AppKit

// Native vector artwork: no downloaded assets or design-time dependencies.
func color(_ rgb: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255,
            green: CGFloat((rgb >> 8) & 255) / 255,
            blue: CGFloat(rgb & 255) / 255, alpha: 1)
}

func png(size: Int) -> Data {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: bitmap)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.cgContext.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    context.imageInterpolation = .high
    context.shouldAntialias = true

    let tile = NSBezierPath(roundedRect: NSRect(x: 40, y: 40, width: 944, height: 944), xRadius: 216, yRadius: 216)
    color(0x111722).setFill(); tile.fill()
    color(0x344459).setStroke(); tile.lineWidth = 8; tile.stroke()
    let inset = NSBezierPath(roundedRect: NSRect(x: 87, y: 87, width: 850, height: 850), xRadius: 174, yRadius: 174)
    color(0x171F2D).setFill(); inset.fill()

    // The black notch and tiny camera echo where the companion lives.
    let notch = NSBezierPath(roundedRect: NSRect(x: 327, y: 808, width: 370, height: 176), xRadius: 54, yRadius: 54)
    color(0x070A10).setFill(); notch.fill()
    color(0x24364C).setFill()
    NSBezierPath(ovalIn: NSRect(x: 496, y: 852, width: 32, height: 32)).fill()

    color(0x7FAEFF).setFill()
    NSBezierPath(roundedRect: NSRect(x: 490, y: 703, width: 44, height: 85), xRadius: 18, yRadius: 18).fill()
    NSBezierPath(ovalIn: NSRect(x: 474, y: 757, width: 76, height: 76)).fill()
    NSBezierPath(roundedRect: NSRect(x: 172, y: 410, width: 88, height: 190), xRadius: 35, yRadius: 35).fill()
    NSBezierPath(roundedRect: NSRect(x: 764, y: 410, width: 88, height: 190), xRadius: 35, yRadius: 35).fill()
    let head = NSBezierPath(roundedRect: NSRect(x: 232, y: 315, width: 560, height: 414), xRadius: 114, yRadius: 114)
    color(0xB9D4FF).setFill(); head.fill()
    color(0x7FAEFF).setStroke(); head.lineWidth = 12; head.stroke()
    let visor = NSBezierPath(roundedRect: NSRect(x: 288, y: 420, width: 448, height: 221), xRadius: 64, yRadius: 64)
    color(0x142238).setFill(); visor.fill()

    for left in [true, false] {
        let eye = NSBezierPath()
        let x: CGFloat = left ? 410 : 614
        let d: CGFloat = left ? -44 : 44
        eye.move(to: NSPoint(x: x, y: 568))
        eye.line(to: NSPoint(x: x + d, y: 530))
        eye.line(to: NSPoint(x: x, y: 492))
        color(0x91BBFF).setStroke(); eye.lineWidth = 25; eye.lineCapStyle = .round; eye.lineJoinStyle = .round; eye.stroke()
    }
    color(0x142238).setFill()
    NSBezierPath(roundedRect: NSRect(x: 460, y: 356, width: 104, height: 18), xRadius: 9, yRadius: 9).fill()
    color(0x81CFB0).setFill()
    NSBezierPath(roundedRect: NSRect(x: 390, y: 194, width: 244, height: 22), xRadius: 11, yRadius: 11).fill()

    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])!
}

func bigEndian(_ value: UInt32) -> Data {
    var number = value.bigEndian
    return withUnsafeBytes(of: &number) { Data($0) }
}

guard CommandLine.arguments.count == 2 || CommandLine.arguments.count == 3 else { exit(2) }
var elements = Data()
for (size, type) in [(16, "icp4"), (32, "icp5"), (64, "icp6"), (128, "ic07"),
                     (256, "ic08"), (512, "ic09"), (1024, "ic10")] {
    let data = png(size: size)
    elements.append(Data(type.utf8)); elements.append(bigEndian(UInt32(data.count + 8))); elements.append(data)
}
var icon = Data("icns".utf8)
icon.append(bigEndian(UInt32(elements.count + 8))); icon.append(elements)
try icon.write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .atomic)
if CommandLine.arguments.count == 3 {
    try png(size: 512).write(to: URL(fileURLWithPath: CommandLine.arguments[2]), options: .atomic)
}
