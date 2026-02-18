import Cocoa

class RecordingWindow: NSWindow {
    private var waveformView: WaveformView?
    private var isClosed = false
    
    init() {
        // Create small floating window at top of screen
        let screenFrame = NSScreen.main?.frame ?? .zero
        let windowWidth: CGFloat = 400
        let windowHeight: CGFloat = 80
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
        self.isOpaque = false
        self.backgroundColor = NSColor.black.withAlphaComponent(0.85)
        self.level = .floating
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        self.hasShadow = true
        self.isMovableByWindowBackground = true
        self.ignoresMouseEvents = false
        
        // Add waveform view
        let waveformView = WaveformView(frame: self.contentView!.bounds)
        waveformView.autoresizingMask = [.width, .height]
        self.contentView?.addSubview(waveformView)
        self.waveformView = waveformView
        
        // Add recording indicator
        let recordingLabel = NSTextField(labelWithString: "● Recording")
        recordingLabel.textColor = .red
        recordingLabel.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        recordingLabel.frame = NSRect(x: 10, y: self.frame.height - 30, width: 120, height: 20)
        recordingLabel.autoresizingMask = [.maxXMargin, .minYMargin]
        self.contentView?.addSubview(recordingLabel)
        
        // Add rounded corners
        self.contentView?.wantsLayer = true
        self.contentView?.layer?.cornerRadius = 10
    }
    
    override var canBecomeKey: Bool {
        return false
    }
    
    override var canBecomeMain: Bool {
        return false
    }
    
    func show() {
        isClosed = false
        self.orderFrontRegardless()
    }
    
    override func close() {
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
    private let barCount = 50
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        self.wantsLayer = true
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
        let barWidth = width / CGFloat(barCount)
        let barSpacing: CGFloat = 2
        
        // Draw bars
        for i in 0..<barCount {
            // Map bar index to waveform data (with safety checks)
            let amplitude: CGFloat
            if waveformData.isEmpty {
                amplitude = 0
            } else {
                let dataIndex = Int(Float(i) / Float(barCount) * Float(waveformData.count))
                let safeIndex = min(max(0, dataIndex), waveformData.count - 1)
                amplitude = CGFloat(waveformData[safeIndex])
            }
            
            // Calculate target height
            let targetHeight = max(4, amplitude * height * 2)
            
            // Smooth the height with alpha blending
            let alpha: CGFloat = targetHeight > smoothedHeights[i] ? 0.42 : 0.24
            smoothedHeights[i] = smoothedHeights[i] + (targetHeight - smoothedHeights[i]) * alpha
            
            let barHeight = smoothedHeights[i]
            let x = CGFloat(i) * barWidth
            let y = (height - barHeight) / 2
            
            // Create gradient color (red to purple based on height)
            let hue = 0.0 + (barHeight / height) * 0.8 // 0.0 = red, 0.8 = purple
            let color = NSColor(hue: hue, saturation: 0.8, brightness: 0.9, alpha: 1.0)
            
            context.setFillColor(color.cgColor)
            
            let barRect = CGRect(
                x: x + barSpacing / 2,
                y: y,
                width: barWidth - barSpacing,
                height: barHeight
            )
            
            // Draw rounded bar
            let path = NSBezierPath(roundedRect: barRect, xRadius: 2, yRadius: 2)
            path.fill()
        }
    }
}
