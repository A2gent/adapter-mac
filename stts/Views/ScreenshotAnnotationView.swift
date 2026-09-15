import AppKit
import SwiftUI

struct ScreenMark: Identifiable, Equatable {
    enum Kind: String, CaseIterable {
        case pen = "Pen"
        case arrow = "Arrow"
        case rectangle = "Rectangle"
    }
    let id = UUID()
    let kind: Kind
    var points: [CGPoint]

    // Coordinates are normalized to the screenshot, independent of window size and Retina scale.
    static func point(_ point: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(x: min(1, max(0, point.x / max(1, size.width))), y: min(1, max(0, point.y / max(1, size.height))))
    }

    func path(in size: CGSize) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first, let last = points.last else { return path }
        let start = CGPoint(x: first.x * size.width, y: first.y * size.height)
        let end = CGPoint(x: last.x * size.width, y: last.y * size.height)
        switch kind {
        case .pen:
            path.move(to: start)
            for point in points.dropFirst() {
                path.addLine(to: CGPoint(x: point.x * size.width, y: point.y * size.height))
            }
        case .rectangle:
            path.addRect(
                CGRect(
                    x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x),
                    height: abs(end.y - start.y)))
        case .arrow:
            path.move(to: start)
            path.addLine(to: end)
            let angle = atan2(end.y - start.y, end.x - start.x)
            let length = min(size.width, size.height) * 0.025
            for offset in [-CGFloat.pi / 6, CGFloat.pi / 6] {
                path.move(to: end)
                path.addLine(
                    to: CGPoint(x: end.x - length * cos(angle + offset), y: end.y - length * sin(angle + offset)))
            }
        }
        return path
    }
}

@MainActor
enum ScreenshotRenderer {
    static func png(image: NSImage, marks: [ScreenMark]) throws -> Data {
        guard let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
            let context = CGContext(
                data: nil, width: source.width, height: source.height, bitsPerComponent: 8,
                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else {
            throw SessionServiceError.message("Could not prepare the screenshot.")
        }
        let size = CGSize(width: source.width, height: source.height)
        context.draw(source, in: CGRect(origin: .zero, size: size))
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        context.setStrokeColor(NSColor.systemRed.cgColor)
        context.setLineWidth(max(2, size.width * 0.004))
        context.setLineCap(.round)
        context.setLineJoin(.round)
        for mark in marks {
            context.addPath(mark.path(in: size))
            context.strokePath()
        }
        guard let result = context.makeImage(),
            let data = NSBitmapImageRep(cgImage: result).representation(using: .png, properties: [:])
        else {
            throw SessionServiceError.message("Could not encode the screenshot.")
        }
        // Brute's image payload limit is 8 MiB per image (before base64).
        guard data.count <= 8 * 1024 * 1024 else {
            throw SessionServiceError.message("Screenshot is too large. Remove it or use a smaller display resolution.")
        }
        return data
    }
}

struct ScreenshotAnnotationView: View {
    let image: NSImage
    @Binding var marks: [ScreenMark]
    @State private var tool = ScreenMark.Kind.arrow
    @State private var current: ScreenMark?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("Draw", selection: $tool) {
                    ForEach(ScreenMark.Kind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).frame(width: 245)
                Spacer()
                Button("Undo") { if !marks.isEmpty { marks.removeLast() } }.disabled(marks.isEmpty)
                Button("Clear") { marks.removeAll() }.disabled(marks.isEmpty)
            }
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                .overlay {
                    GeometryReader { geometry in
                        Canvas { context, size in
                            for mark in marks + (current.map { [$0] } ?? []) {
                                context.stroke(
                                    Path(mark.path(in: size)), with: .color(.red),
                                    style: StrokeStyle(
                                        lineWidth: max(2, size.width * 0.004), lineCap: .round, lineJoin: .round))
                            }
                        }.contentShape(Rectangle())
                            .gesture(
                                DragGesture(minimumDistance: 1).onChanged { value in
                                    let point = ScreenMark.point(value.location, in: geometry.size)
                                    if current == nil {
                                        current = ScreenMark(
                                            kind: tool,
                                            points: [ScreenMark.point(value.startLocation, in: geometry.size)])
                                    }
                                    if tool == .pen {
                                        current?.points.append(point)
                                    } else if let start = current?.points.first {
                                        current?.points = [start, point]
                                    }
                                }.onEnded { _ in
                                    if let current, current.points.count > 1 { marks.append(current) }
                                    current = nil
                                })
                    }
                }.clipShape(RoundedRectangle(cornerRadius: 8))
            Text("Draw over the captured image. Marks are included in the image sent to the agent.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
