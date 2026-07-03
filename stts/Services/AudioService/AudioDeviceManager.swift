import AVFoundation
import Foundation

final class AudioInputDeviceManager {
    private let selectedMicrophoneIDKey = "selectedMicrophoneID"

    static func requestMicrophonePermission(completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            DispatchQueue.main.async {
                completion(true)
            }
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async {
                    completion(granted)
                }
            }
        case .denied, .restricted:
            DispatchQueue.main.async {
                completion(false)
            }
        @unknown default:
            DispatchQueue.main.async {
                completion(false)
            }
        }
    }

    func availableInputDevices() -> [AudioInputDevice] {
        let defaultID = AVCaptureDevice.default(for: .audio)?.uniqueID

        return captureDevices()
            .map { device in
                AudioInputDevice(
                    id: device.uniqueID,
                    name: device.localizedName,
                    isDefault: device.uniqueID == defaultID,
                    connectionKind: Self.connectionKind(for: device)
                )
            }
            .sorted { lhs, rhs in
                if lhs.isDefault != rhs.isDefault {
                    return lhs.isDefault
                }

                let lhsPriority = priority(for: lhs.connectionKind)
                let rhsPriority = priority(for: rhs.connectionKind)
                if lhsPriority != rhsPriority {
                    return lhsPriority < rhsPriority
                }

                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    func selectedInputDeviceID() -> String? {
        let storedID = UserDefaults.standard.string(forKey: selectedMicrophoneIDKey)
        guard let storedID else { return nil }

        let exists = availableInputDevices().contains { $0.id == storedID }
        return exists ? storedID : nil
    }

    func selectedInputDevice() -> AudioInputDevice? {
        guard let selectedID = selectedInputDeviceID() else { return nil }
        return availableInputDevices().first { $0.id == selectedID }
    }

    func activeInputDevice() -> AudioInputDevice? {
        if let selected = selectedInputDevice() {
            return selected
        }

        guard let defaultDevice = availableInputDevices().first(where: \.isDefault) else {
            return availableInputDevices().first
        }

        return defaultDevice
    }

    func activeInputDeviceName() -> String {
        activeInputDevice()?.name ?? "No microphone"
    }

    func activeInputDeviceConnectionHint() -> String? {
        activeInputDevice()?.connectionHint
    }

    func systemDefaultInputDeviceName() -> String {
        if let systemDefault = availableInputDevices().first(where: \.isDefault) {
            return systemDefault.name
        }

        return activeInputDeviceName()
    }

    func selectInputDevice(id: String?) {
        if let id, availableInputDevices().contains(where: { $0.id == id }) {
            UserDefaults.standard.set(id, forKey: selectedMicrophoneIDKey)
        } else {
            UserDefaults.standard.removeObject(forKey: selectedMicrophoneIDKey)
        }
    }

    func resolvedCaptureDevice() -> AVCaptureDevice? {
        let devices = captureDevices()

        if let selectedID = selectedInputDeviceID(),
           let selectedDevice = devices.first(where: { $0.uniqueID == selectedID }) {
            return selectedDevice
        }

        if let defaultDevice = AVCaptureDevice.default(for: .audio) {
            return defaultDevice
        }

        return devices.sorted { lhs, rhs in
            priority(for: Self.connectionKind(for: lhs)) < priority(for: Self.connectionKind(for: rhs))
        }.first
    }

    private func captureDevices() -> [AVCaptureDevice] {
        let deviceTypes: [AVCaptureDevice.DeviceType]
        if #available(macOS 14.0, *) {
            deviceTypes = [.microphone, .external]
        } else {
            deviceTypes = [.builtInMicrophone]
        }

        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: deviceTypes,
            mediaType: .audio,
            position: .unspecified
        )

        return deduplicated(devices: discoverySession.devices)
    }

    private func deduplicated(devices: [AVCaptureDevice]) -> [AVCaptureDevice] {
        var seenIDs = Set<String>()
        return devices.filter { device in
            seenIDs.insert(device.uniqueID).inserted
        }
    }

    private static func connectionKind(for device: AVCaptureDevice) -> AudioInputConnectionKind {
        if device.deviceType == .microphone {
            return .builtIn
        }

        if #unavailable(macOS 14.0) {
            if device.deviceType == .builtInMicrophone {
                return .builtIn
            }
        }

        return AudioInputDeviceDescriptor.classify(name: device.localizedName)
    }

    private func priority(for connectionKind: AudioInputConnectionKind) -> Int {
        switch connectionKind {
        case .builtIn:
            return 0
        case .external:
            return 1
        case .bluetooth:
            return 2
        case .continuity:
            return 3
        case .unknown:
            return 4
        }
    }
}
