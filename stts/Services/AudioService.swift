import Foundation
import AVFoundation

protocol AudioServiceDelegate: AnyObject {
    func audioService(_ service: AudioService, didUpdateWaveform data: [Float])
}

class AudioService: NSObject {
    weak var delegate: AudioServiceDelegate?
    
    private var audioEngine: AVAudioEngine?
    private var audioFile: AVAudioFile?
    private var audioPlayer: AVAudioPlayer?
    private var speechSynthesizer: AVSpeechSynthesizer?
    
    private var recordingTimer: Timer?
    private var waveformData: [Float] = []
    
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
        audioEngine = AVAudioEngine()
        guard let audioEngine = audioEngine else {
            completion(false)
            return
        }
        
        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        
        // Create temporary file for recording
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("recording_\(Date().timeIntervalSince1970).wav")
        
        do {
            audioFile = try AVAudioFile(forWriting: tempURL, settings: recordingFormat.settings)
        } catch {
            print("Failed to create audio file: \(error)")
            completion(false)
            return
        }
        
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
            guard let self = self, let audioFile = self.audioFile else { return }
            
            do {
                try audioFile.write(from: buffer)
                
                // Extract waveform data for visualization
                let channelData = buffer.floatChannelData?[0]
                let frameLength = Int(buffer.frameLength)
                
                var rms: Float = 0
                if let data = channelData {
                    for i in 0..<frameLength {
                        let sample = data[i]
                        rms += sample * sample
                    }
                    rms = sqrt(rms / Float(frameLength))
                }
                
                DispatchQueue.main.async {
                    self.waveformData.append(rms)
                    if self.waveformData.count > 100 {
                        self.waveformData.removeFirst()
                    }
                    self.delegate?.audioService(self, didUpdateWaveform: self.waveformData)
                }
            } catch {
                print("Failed to write audio buffer: \(error)")
            }
        }
        
        do {
            try audioEngine.start()
            completion(true)
        } catch {
            print("Failed to start audio engine: \(error)")
            completion(false)
        }
    }
    
    func stopRecording(completion: @escaping (URL?) -> Void) {
        guard let audioEngine = audioEngine else {
            completion(nil)
            return
        }
        
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        
        let fileURL = audioFile?.url
        audioFile = nil
        self.audioEngine = nil
        
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
