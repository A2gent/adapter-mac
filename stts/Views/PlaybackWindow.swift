import Cocoa

final class PlaybackWindow: NSPanel {
    var onStop: (() -> Void)?
    var onTogglePause: (() -> Void)?
    var onSeekBackward: (() -> Void)?
    var onSeekForward: (() -> Void)?
    var onSeekToTime: ((TimeInterval) -> Void)?

    private var isClosed = false
    private let titleLabel = NSTextField(labelWithString: "Preparing audio...")
    private let currentTimeLabel = NSTextField(labelWithString: "0:00")
    private let durationLabel = NSTextField(labelWithString: "0:00")
    private let progressSlider = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let pauseButton = NSButton(title: "Pause", target: nil, action: nil)

    init() {
        let screenFrame = NSScreen.main?.frame ?? .zero
        let windowWidth: CGFloat = 320
        let windowHeight: CGFloat = 108
        let xPos = (screenFrame.width - windowWidth) / 2
        let yPos = screenFrame.height - windowHeight - 50

        super.init(
            contentRect: NSRect(x: xPos, y: yPos, width: windowWidth, height: windowHeight),
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
        contentView.wantsLayer = true
        contentView.layer?.cornerRadius = 14
        contentView.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.92).cgColor
        contentView.layer?.borderWidth = 1
        contentView.layer?.borderColor = NSColor.white.withAlphaComponent(0.08).cgColor

        let titleIcon = NSTextField(labelWithString: "AUDIO")
        titleIcon.textColor = NSColor.white.withAlphaComponent(0.96)
        titleIcon.font = NSFont.monospacedSystemFont(ofSize: 8, weight: .semibold)
        titleIcon.frame = NSRect(x: 14, y: 84, width: 40, height: 10)
        contentView.addSubview(titleIcon)

        titleLabel.textColor = NSColor.white.withAlphaComponent(0.72)
        titleLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        titleLabel.frame = NSRect(x: 58, y: 80, width: 248, height: 16)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.autoresizingMask = [.width, .minYMargin]
        contentView.addSubview(titleLabel)

        currentTimeLabel.textColor = NSColor.white.withAlphaComponent(0.68)
        currentTimeLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        currentTimeLabel.frame = NSRect(x: 14, y: 58, width: 42, height: 12)
        contentView.addSubview(currentTimeLabel)

        durationLabel.textColor = NSColor.white.withAlphaComponent(0.68)
        durationLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        durationLabel.alignment = .right
        durationLabel.frame = NSRect(x: 264, y: 58, width: 42, height: 12)
        durationLabel.autoresizingMask = [.minXMargin]
        contentView.addSubview(durationLabel)

        progressSlider.frame = NSRect(x: 58, y: 54, width: 198, height: 18)
        progressSlider.target = self
        progressSlider.action = #selector(progressChanged)
        progressSlider.isContinuous = true
        progressSlider.controlSize = .small
        progressSlider.autoresizingMask = [.width]
        contentView.addSubview(progressSlider)

        let backButton = button(title: "« 15", action: #selector(seekBackwardPressed))
        backButton.frame = NSRect(x: 14, y: 16, width: 58, height: 28)
        contentView.addSubview(backButton)

        pauseButton.frame = NSRect(x: 80, y: 16, width: 70, height: 28)
        pauseButton.target = self
        pauseButton.action = #selector(togglePausePressed)
        contentView.addSubview(pauseButton)

        let forwardButton = button(title: "15 »", action: #selector(seekForwardPressed))
        forwardButton.frame = NSRect(x: 158, y: 16, width: 58, height: 28)
        contentView.addSubview(forwardButton)

        let stopButton = button(title: "Stop", action: #selector(stopPressed))
        stopButton.frame = NSRect(x: 224, y: 16, width: 82, height: 28)
        stopButton.autoresizingMask = [.minXMargin]
        contentView.addSubview(stopButton)
    }

    private func button(title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        return button
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func show() {
        isClosed = false
        orderFrontRegardless()
    }

    override func close() {
        guard !isClosed else { return }
        isClosed = true
        super.close()
    }

    func setPreparing() {
        titleLabel.stringValue = "Preparing audio..."
        currentTimeLabel.stringValue = "0:00"
        durationLabel.stringValue = "0:00"
        progressSlider.minValue = 0
        progressSlider.maxValue = 1
        progressSlider.doubleValue = 0
        pauseButton.title = "Pause"
    }

    func updatePlayback(currentTime: TimeInterval, duration: TimeInterval, isPlaying: Bool) {
        currentTimeLabel.stringValue = Self.formatTime(currentTime)
        durationLabel.stringValue = Self.formatTime(duration)
        progressSlider.maxValue = max(duration, 1)
        progressSlider.doubleValue = min(max(0, currentTime), max(duration, 1))
        pauseButton.title = isPlaying ? "Pause" : "Play"
        titleLabel.stringValue = isPlaying ? "Playing selected text" : "Playback paused"
    }

    private static func formatTime(_ value: TimeInterval) -> String {
        let totalSeconds = max(0, Int(value.rounded()))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return "\(minutes):" + String(format: "%02d", seconds)
    }

    @objc private func stopPressed() {
        onStop?()
    }

    @objc private func togglePausePressed() {
        onTogglePause?()
    }

    @objc private func seekBackwardPressed() {
        onSeekBackward?()
    }

    @objc private func seekForwardPressed() {
        onSeekForward?()
    }

    @objc private func progressChanged() {
        onSeekToTime?(progressSlider.doubleValue)
    }
}
