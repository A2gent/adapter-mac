import AppKit

@MainActor
enum BrandResources {
    static var bundle: Bundle {
        #if SWIFT_PACKAGE
            return .module
        #else
            return .main
        #endif
    }

    static func url(_ name: String, extension ext: String) -> URL? {
        bundle.url(forResource: name, withExtension: ext, subdirectory: "Brand")
    }

    static var logo: NSImage? {
        url("a2gent", extension: "jpg").flatMap(NSImage.init(contentsOf:))
    }

    static func statusImage(active: Bool) -> NSImage? {
        guard let image = url("status-icon", extension: "png").flatMap(NSImage.init(contentsOf:)) else {
            return nil
        }
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        if !active { return image }
        // A template badge remains legible in both light and dark menu bars.
        let badged = NSImage(size: NSSize(width: 22, height: 18), flipped: false) { _ in
            image.draw(in: NSRect(x: 0, y: 0, width: 18, height: 18))
            NSColor.black.setFill()
            NSBezierPath(ovalIn: NSRect(x: 18, y: 1, width: 4, height: 4)).fill()
            return true
        }
        badged.isTemplate = true
        return badged
    }
}
