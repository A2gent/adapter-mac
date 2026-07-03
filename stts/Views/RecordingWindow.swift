import Cocoa

class RecordingWindow: NSPanel {
    private var waveformView: WaveformView?
    private var isClosed = false
    private let titleText: String

    private let deviceLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let hintLabel = NSTextField(labelWithString: "")

    init(deviceName: String, titleText: String, hintText: String) {
        self.titleText = titleText
        let screenFrame = NSScreen.main?.frame ?? .zero
        let windowWidth: CGFloat = 280
        let windowHeight: CGFloat = 76
        let xPos = (screenFrame.width - windowWidth) / 2
        let yPos = screenFrame.height - windowHeight - 50

        let rect = NSRect(x: xPos, y: yPos, width: windowWidth, height: windowHeight)

        super.init(
            contentRect: rect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        setupWindow(deviceName: deviceName, hintText: hintText)
    }

    private func setupWindow(deviceName: String, hintText: String) {
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        hasShadow = true
        isMovableByWindowBackground = true
        ignoresMouseEvents = false

        guard let contentView = contentView else { return }

        let waveformView = WaveformView(frame: contentView.bounds)
        waveformView.autoresizingMask = [.width, .height]
        contentView.addSubview(waveformView)
        self.waveformView = waveformView

        let recordingIndicator = NSView(frame: NSRect(x: 10, y: frame.height - 19, width: 6, height: 6))
        recordingIndicator.wantsLayer = true
        recordingIndicator.layer?.cornerRadius = 3
        recordingIndicator.layer?.backgroundColor = NSColor.systemRed.cgColor
        recordingIndicator.autoresizingMask = [.maxXMargin, .minYMargin]
        contentView.addSubview(recordingIndicator)

        let recordingLabel = NSTextField(labelWithString: titleText)
        recordingLabel.textColor = NSColor.white.withAlphaComponent(0.96)
        recordingLabel.font = NSFont.monospacedSystemFont(ofSize: 8, weight: .semibold)
        recordingLabel.frame = NSRect(x: 21, y: frame.height - 22, width: 36, height: 10)
        recordingLabel.autoresizingMask = [.maxXMargin, .minYMargin]
        contentView.addSubview(recordingLabel)

        deviceLabel.textColor = NSColor.white.withAlphaComponent(0.58)
        deviceLabel.font = NSFont.systemFont(ofSize: 8, weight: .medium)
        deviceLabel.alignment = .right
        deviceLabel.frame = NSRect(x: 60, y: frame.height - 22, width: frame.width - 70, height: 10)
        deviceLabel.lineBreakMode = .byTruncatingMiddle
        deviceLabel.autoresizingMask = [.width, .minYMargin, .minXMargin]
        deviceLabel.stringValue = deviceName
        contentView.addSubview(deviceLabel)

        statusLabel.textColor = NSColor.white.withAlphaComponent(0.9)
        statusLabel.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        statusLabel.alignment = .left
        statusLabel.frame = NSRect(x: 10, y: frame.height - 40, width: frame.width - 20, height: 12)
        statusLabel.autoresizingMask = [.width, .minYMargin]
        statusLabel.stringValue = "Connecting microphone..."
        contentView.addSubview(statusLabel)

        hintLabel.textColor = NSColor.white.withAlphaComponent(0.5)
        hintLabel.font = NSFont.systemFont(ofSize: 8, weight: .regular)
        hintLabel.alignment = .left
        hintLabel.frame = NSRect(x: 10, y: 6, width: frame.width - 20, height: 24)
        hintLabel.lineBreakMode = .byTruncatingTail
        hintLabel.maximumNumberOfLines = 2
        hintLabel.autoresizingMask = [.width, .maxYMargin]
        hintLabel.stringValue = hintText
        contentView.addSubview(hintLabel)

        contentView.wantsLayer = true
        contentView.layer?.cornerRadius = 12
        contentView.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.92).cgColor
        contentView.layer?.borderWidth = 1
        contentView.layer?.borderColor = NSColor.white.withAlphaComponent(0.08).cgColor
    }

    override var canBecomeKey: Bool {
        return false
    }

    override var canBecomeMain: Bool {
        return false
    }

    func show() {
        isClosed = false
        orderFrontRegardless()
    }

    override func close() {
        guard !isClosed else { return }
        isClosed = true
        super.close()
    }

    func updateWaveform(data: [Float]) {
        guard !isClosed else { return }
        waveformView?.updateData(data)
    }

    func updateRecordingState(_ state: AudioRecordingState) {
        guard !isClosed else { return }

        switch state {
        case .idle:
            statusLabel.stringValue = state.statusText
        case .preparing(let deviceName, let hint), .recording(let deviceName, let hint):
            deviceLabel.stringValue = deviceName
            statusLabel.stringValue = state.statusText
            if let hint, !hint.isEmpty {
                hintLabel.stringValue = hint
            }
        case .finishing:
            statusLabel.stringValue = state.statusText
        case .failed(let issue):
            statusLabel.stringValue = "Microphone issue"
            hintLabel.stringValue = issue.userMessage
        }
    }
}

class WaveformView: NSView {
    private var waveformData: [Float] = []
    private var smoothedHeights: [CGFloat] = []
    private let barCount = 52

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        smoothedHeights = Array(repeating: 0, count: barCount)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func updateData(_ data: [Float]) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.waveformData = data
            self.needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard let context = NSGraphicsContext.current?.cgContext else { return }

        let width = bounds.width
        let height = bounds.height
        let topInset: CGFloat = 28
        let bottomInset: CGFloat = 22
        let drawingHeight = max(1, height - topInset - bottomInset)
        let drawingY = bottomInset
        let barWidth = width / CGFloat(barCount)
        let barSpacing: CGFloat = 2.4
        let baselineY = drawingY + drawingHeight / 2

        context.setFillColor(NSColor.white.withAlphaComponent(0.1).cgColor)
        let baselineRect = CGRect(x: 10, y: baselineY - 0.5, width: width - 20, height: 1)
        context.fill(baselineRect)

        for i in 0..<barCount {
            let amplitude: CGFloat
            if waveformData.isEmpty {
                amplitude = 0
            } else {
                let dataIndex = Int(Float(i) / Float(barCount) * Float(waveformData.count))
                let safeIndex = min(max(0, dataIndex), waveformData.count - 1)
                amplitude = CGFloat(waveformData[safeIndex])
            }

            let targetHeight = max(1.5, min(drawingHeight * 0.92, amplitude * drawingHeight * 0.9))
            let currentHeight = smoothedHeights[i]
            let smoothedHeight = currentHeight * 0.72 + targetHeight * 0.28
            smoothedHeights[i] = smoothedHeight

            let x = CGFloat(i) * barWidth + 10
            let barRect = CGRect(
                x: x,
                y: baselineY - smoothedHeight / 2,
                width: max(1.4, barWidth - barSpacing),
                height: smoothedHeight
            )

            let radius = min(barRect.width / 2, 1.5)
            let path = CGPath(roundedRect: barRect, cornerWidth: radius, cornerHeight: radius, transform: nil)
            context.addPath(path)
            context.setFillColor(NSColor.white.withAlphaComponent(0.9).cgColor)
            context.fillPath()
        }
    }
}
