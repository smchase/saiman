import AppKit

extension NSImage {
    static func coolSIcon(size: CGFloat = 18) -> NSImage {
        // Load from bundle
        if let url = Bundle.main.url(forResource: "CoolS", withExtension: "svg"),
           let image = NSImage(contentsOf: url) {
            let resized = NSImage(size: NSSize(width: size, height: size))
            resized.lockFocus()
            image.draw(in: NSRect(x: 0, y: 0, width: size, height: size),
                      from: NSRect(origin: .zero, size: image.size),
                      operation: .sourceOver,
                      fraction: 1.0)
            resized.unlockFocus()
            resized.isTemplate = true
            return resized
        }

        // Fallback: draw a simple S shape
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()

        let path = NSBezierPath()
        let s = size / 14.0 // scale factor

        // Simplified Cool S outline
        path.move(to: NSPoint(x: 7 * s, y: 14 * s))      // top center
        path.line(to: NSPoint(x: 12 * s, y: 11.5 * s))  // top right
        path.line(to: NSPoint(x: 12 * s, y: 8 * s))     // right upper
        path.line(to: NSPoint(x: 7 * s, y: 8 * s))      // middle right to center
        path.line(to: NSPoint(x: 12 * s, y: 5 * s))     // center to lower right
        path.line(to: NSPoint(x: 12 * s, y: 2.5 * s))   // lower right
        path.line(to: NSPoint(x: 7 * s, y: 0 * s))      // bottom center
        path.line(to: NSPoint(x: 2 * s, y: 2.5 * s))    // bottom left
        path.line(to: NSPoint(x: 2 * s, y: 6 * s))      // left lower
        path.line(to: NSPoint(x: 7 * s, y: 6 * s))      // middle left to center
        path.line(to: NSPoint(x: 2 * s, y: 9 * s))      // center to upper left
        path.line(to: NSPoint(x: 2 * s, y: 11.5 * s))   // upper left
        path.close()

        NSColor.labelColor.setFill()
        path.fill()

        image.unlockFocus()
        image.isTemplate = true
        return image
    }
}
