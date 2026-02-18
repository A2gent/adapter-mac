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
        let inputFormat = inputNode.outputFormat(forBus: 0)
        
        // Use standard recording format (44.1kHz, mono, 16-bit PCM)
        guard let recordingFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 44100,
            channels: 1,
            interleaved: false
        ) else {
            print("Failed to create recording format")
            completion(false)
            return
        }
        
        // Create temporary file for recording
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("recording_\(Date().timeIntervalSince1970).wav")
        
        do {
            audioFile = try AVAudioFile(forWriting: tempURL, settings: recordingFormat.settings)
        } catch {
            print("Failed to create audio file: \(error)")
            completion(false)
            return
        }
        
        // Create converter from input format to recording format
        guard let converter = AVAudioConverter(from: inputFormat, to: recordingFormat) else {
            print("Failed to create audio converter")
            completion(false)
            return
        }
        
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self = self, let audioFile = self.audioFile else { return }
            
            // Convert buffer to recording format
            guard let convertedBuffer = AVAudioPCMBuffer(
                pcmFormat: recordingFormat,
                frameCapacity: AVAudioFrameCount(recordingFormat.sampleRate) * buffer.frameLength / AVAudioFrameCount(inputFormat.sampleRate)
            ) else {
                return
            }
            
            var error: NSError?
            let inputBlock: AVAudioConverterInputBlock = { inNumPackets, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }
            
            converter.convert(to: convertedBuffer, error: &error, withInputFrom: inputBlock)
            
            if let error = error {
                print("Conversion error: \(error)")
                return
            }
            
            do {
                try audioFile.write(from: convertedBuffer)
                
                // Extract waveform data for visualization from original buffer
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
