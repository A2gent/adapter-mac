import Foundation
import AVFoundation

protocol AudioServiceDelegate: AnyObject {
    func audioService(_ service: AudioService, didUpdateWaveform data: [Float])
}

class AudioService: NSObject {
    weak var delegate: AudioServiceDelegate?
    
    private var audioEngine: AVAudioEngine?
    private var inputNode: AVAudioInputNode?
    private var audioFile: AVAudioFile?
    private var audioPlayer: AVAudioPlayer?
    private var speechSynthesizer: AVSpeechSynthesizer?
    
    private var recordingTimer: Timer?
    private var waveformData: [Float] = []
    private var isRecording = false
    
    static func requestMicrophonePermission() {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            if granted {
                print("Microphone permission granted")
            } else {
                print("Microphone permission denied")
            }
        }
    }
    
    // MARK: - Recording
    
    func startRecording(completion: @escaping (Bool) -> Void) {
        guard !isRecording else {
            print("Already recording")
            completion(false)
            return
        }
        
        // Clean up any previous session
        stopRecording { _ in }
        waveformData.removeAll()
        
        // Create new audio engine
        let engine = AVAudioEngine()
        self.audioEngine = engine
        
        let input = engine.inputNode
        self.inputNode = input
        
        let bus = 0
        let inputFormat = input.outputFormat(forBus: bus)
        
        print("📱 Input format: sampleRate=\(inputFormat.sampleRate), channels=\(inputFormat.channelCount)")
        
        // Create temporary file for recording
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("recording_\(Date().timeIntervalSince1970).wav")
        
        // Use the input format directly to avoid conversion issues
        do {
            audioFile = try AVAudioFile(forWriting: tempURL, settings: inputFormat.settings)
        } catch {
            print("❌ Failed to create audio file: \(error)")
            completion(false)
            return
        }
        
        // Install tap to capture audio
        input.installTap(onBus: bus, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self = self, self.isRecording else { return }
            
            // Write to file
            do {
                try self.audioFile?.write(from: buffer)
            } catch {
                print("❌ Write error: \(error)")
                return
            }
            
            // Calculate RMS for waveform
            guard let channelData = buffer.floatChannelData?[0] else { return }
            let frameLength = Int(buffer.frameLength)
            
            var sum: Float = 0
            for i in 0..<frameLength {
                let sample = channelData[i]
                sum += sample * sample
            }
            let rms = sqrt(sum / Float(frameLength))
            
            // Update waveform on main thread
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.waveformData.append(rms)
                if self.waveformData.count > 100 {
                    self.waveformData.removeFirst()
                }
                self.delegate?.audioService(self, didUpdateWaveform: self.waveformData)
            }
        }
        
        // Start the engine
        do {
            try engine.start()
            isRecording = true
            print("✅ Recording started")
            completion(true)
        } catch {
            print("❌ Failed to start engine: \(error)")
            input.removeTap(onBus: bus)
            completion(false)
        }
    }
    
    func stopRecording(completion: @escaping (URL?) -> Void) {
        guard isRecording else {
            completion(nil)
            return
        }
        
        isRecording = false
        
        // Remove tap first
        inputNode?.removeTap(onBus: 0)
        
        // Stop engine
        audioEngine?.stop()
        
        // Get file URL before cleanup
        let fileURL = audioFile?.url
        
        // Cleanup
        audioFile = nil
        audioEngine = nil
        inputNode = nil
        
        print("🛑 Recording stopped: \(fileURL?.path ?? "no file")")
        
        completion(fileURL)
    }
    
    // MARK: - Text to Speech
    
    func playTextToSpeech(text: String, completion: @escaping (Bool) -> Void) {
        speechSynthesizer = AVSpeechSynthesizer()
        
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = 0.5
        
        speechSynthesizer?.speak(utterance)
        completion(true)
    }
}
