import Cocoa

class RecordingWindow: NSPanel {
    private var waveformView: WaveformView?
    private var isClosed = false
    private let deviceName: String
    
    init(deviceName: String) {
        self.deviceName = deviceName
        let screenFrame = NSScreen.main?.frame ?? .zero
        let windowWidth: CGFloat = 264
        let windowHeight: CGFloat = 38
        let xPos = (screenFrame.width - windowWidth) / 2
        let yPos = screenFrame.height - windowHeight - 50
        
        let rect = NSRect(x: xPos, y: yPos, width: windowWidth, height: windowHeight)
        
        super.init(
            contentRect: rect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        
        setupWindow()
    }
    
    private func setupWindow() {
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
        
        let recordingIndicator = NSView(frame: NSRect(x: 10, y: frame.height - 16, width: 6, height: 6))
        recordingIndicator.wantsLayer = true
        recordingIndicator.layer?.cornerRadius = 3
        recordingIndicator.layer?.backgroundColor = NSColor.systemRed.cgColor
        recordingIndicator.autoresizingMask = [.maxXMargin, .minYMargin]
        contentView.addSubview(recordingIndicator)

        let recordingLabel = NSTextField(labelWithString: "REC")
        recordingLabel.textColor = NSColor.white.withAlphaComponent(0.96)
        recordingLabel.font = NSFont.monospacedSystemFont(ofSize: 8, weight: .semibold)
        recordingLabel.frame = NSRect(x: 21, y: frame.height - 19, width: 36, height: 10)
        recordingLabel.autoresizingMask = [.maxXMargin, .minYMargin]
        contentView.addSubview(recordingLabel)

        let microphoneIcon = NSImageView(frame: NSRect(x: frame.width - 112, y: frame.height - 19, width: 8, height: 10))
        microphoneIcon.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "Microphone")
        microphoneIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 8, weight: .medium)
        microphoneIcon.contentTintColor = NSColor.white.withAlphaComponent(0.58)
        microphoneIcon.imageScaling = .scaleProportionallyDown
        microphoneIcon.autoresizingMask = [.minXMargin, .minYMargin]
        contentView.addSubview(microphoneIcon)

        let deviceLabel = NSTextField(labelWithString: deviceName)
        deviceLabel.textColor = NSColor.white.withAlphaComponent(0.58)
        deviceLabel.font = NSFont.systemFont(ofSize: 8, weight: .medium)
        deviceLabel.alignment = .right
        deviceLabel.frame = NSRect(x: 62, y: frame.height - 19, width: frame.width - 76, height: 10)
        deviceLabel.lineBreakMode = .byTruncatingHead
        deviceLabel.autoresizingMask = [.width, .minYMargin, .minXMargin]
        contentView.addSubview(deviceLabel)
        
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
}

class WaveformView: NSView {
    private var waveformData: [Float] = []
    private var smoothedHeights: [CGFloat] = []
    private let barCount = 44
    
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
        let topInset: CGFloat = 15
        let bottomInset: CGFloat = 5
        let drawingHeight = max(1, height - topInset - bottomInset)
        let drawingY = bottomInset
        let barWidth = width / CGFloat(barCount)
        let barSpacing: CGFloat = 2.2
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
            
            let targetHeight = max(1.5, min(drawingHeight, 2 + amplitude * drawingHeight * 1.2))
            let alpha: CGFloat = targetHeight > smoothedHeights[i] ? 0.68 : 0.18
            smoothedHeights[i] = smoothedHeights[i] + (targetHeight - smoothedHeights[i]) * alpha
            
            let barHeight = smoothedHeights[i]
            let x = CGFloat(i) * barWidth
            let y = drawingY + (drawingHeight - barHeight) / 2
            let emphasis = min(1, barHeight / drawingHeight)
            let color = NSColor(white: 0.75 + emphasis * 0.25, alpha: 0.98)
            
            context.setFillColor(color.cgColor)
            
            let barRect = CGRect(
                x: x + barSpacing / 2,
                y: y,
                width: max(0.8, barWidth - barSpacing),
                height: barHeight
            )
            
            let path = NSBezierPath(roundedRect: barRect, xRadius: 0.7, yRadius: 0.7)
            path.fill()
        }
    }
}
