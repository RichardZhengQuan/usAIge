import AppKit

guard CommandLine.arguments.count == 3 else {
    fputs("usage: prepare-dmg-assets <Applications alias> <background PNG>\n", stderr)
    exit(64)
}

let applicationsAlias = CommandLine.arguments[1]
let backgroundURL = URL(fileURLWithPath: CommandLine.arguments[2])
let applicationsIcon = NSWorkspace.shared.icon(forFile: "/Applications")

guard NSWorkspace.shared.setIcon(applicationsIcon, forFile: applicationsAlias, options: []) else {
    fputs("could not apply the Applications folder icon\n", stderr)
    exit(1)
}

let canvasSize = NSSize(width: 660, height: 400)
let background = NSImage(size: canvasSize)
background.lockFocus()

NSColor(calibratedRed: 0.945, green: 0.955, blue: 0.925, alpha: 1).setFill()
NSRect(origin: .zero, size: canvasSize).fill()

let instruction = "DRAG TO INSTALL" as NSString
let paragraph = NSMutableParagraphStyle()
paragraph.alignment = .center
instruction.draw(
    in: NSRect(x: 245, y: 244, width: 170, height: 18),
    withAttributes: [
        .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold),
        .foregroundColor: NSColor.black.withAlphaComponent(0.48),
        .paragraphStyle: paragraph,
        .kern: 1.4,
    ]
)

let arrow = NSBezierPath()
arrow.lineWidth = 9
arrow.lineCapStyle = .round
arrow.lineJoinStyle = .round
arrow.move(to: NSPoint(x: 275, y: 204))
arrow.line(to: NSPoint(x: 385, y: 204))
arrow.move(to: NSPoint(x: 355, y: 174))
arrow.line(to: NSPoint(x: 385, y: 204))
arrow.line(to: NSPoint(x: 355, y: 234))
NSColor(calibratedRed: 0.38, green: 0.62, blue: 0.03, alpha: 0.95).setStroke()
arrow.stroke()

background.unlockFocus()

guard
    let tiff = background.tiffRepresentation,
    let bitmap = NSBitmapImageRep(data: tiff),
    let png = bitmap.representation(using: .png, properties: [:])
else {
    fputs("could not render the DMG background\n", stderr)
    exit(1)
}

try FileManager.default.createDirectory(
    at: backgroundURL.deletingLastPathComponent(),
    withIntermediateDirectories: true
)
try png.write(to: backgroundURL, options: .atomic)
