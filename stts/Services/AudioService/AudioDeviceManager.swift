import AVFoundation
import Foundation

final class AudioInputDeviceManager {
    private let selectedMicrophoneIDKey = "selectedMicrophoneID"

    static func requestMicrophonePermission(completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async {
                    completion(granted)
                }
            }
        case .denied, .restricted:
            completion(false)
        @unknown default:
            completion(false)
        }
    }

    func availableInputDevices() -> [AudioInputDevice] {
        let defaultID = AVCaptureDevice.default(for: .audio)?.uniqueID

        return captureDevices()
            .map { device in
                AudioInputDevice(
                    id: device.uniqueID,
                    name: device.localizedName,
                    isDefault: device.uniqueID == defaultID
                )
            }
            .sorted { lhs, rhs in
                if lhs.isDefault != rhs.isDefault {
                    return lhs.isDefault
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
        if let selectedID = selectedInputDeviceID(),
           let selectedDevice = captureDevices().first(where: { $0.uniqueID == selectedID }) {
            return selectedDevice
        }

        return AVCaptureDevice.default(for: .audio) ?? captureDevices().first
    }

    private func captureDevices() -> [AVCaptureDevice] {
        let deviceTypes: [AVCaptureDevice.DeviceType]
        if #available(macOS 14.0, *) {
            deviceTypes = [.builtInMicrophone, .external]
        } else {
            deviceTypes = [.builtInMicrophone]
        }

        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: deviceTypes,
            mediaType: .audio,
            position: .unspecified
        )

        return discoverySession.devices
    }
}
