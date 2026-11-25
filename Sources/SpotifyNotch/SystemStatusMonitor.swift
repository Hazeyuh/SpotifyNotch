import AppKit
import CoreAudio
import CoreMediaIO
import Foundation

/// 监测 macOS 实时录音（麦克风）、摄像头与屏幕录制状态，无需额外系统隐私弹窗
final class SystemStatusMonitor: ObservableObject {
    @Published private(set) var isMicActive: Bool = false
    @Published private(set) var isCameraActive: Bool = false
    @Published private(set) var isScreenRecording: Bool = false

    private var timer: Timer?
    private let queue = DispatchQueue(label: "spotifynotch.sysstatus", qos: .utility)

    init() {
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.poll()
        }
        if let timer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    deinit {
        timer?.invalidate()
    }

    private func poll() {
        queue.async { [weak self] in
            guard let self else { return }
            let mic = Self.checkAnyInputAudioDeviceRunning()
            let cam = Self.checkAnyCameraRunning()
            let rec = Self.checkScreenRecordingActive()
            DispatchQueue.main.async {
                if self.isMicActive != mic { self.isMicActive = mic }
                if self.isCameraActive != cam { self.isCameraActive = cam }
                if self.isScreenRecording != rec { self.isScreenRecording = rec }
            }
        }
    }

    private static func checkAnyInputAudioDeviceRunning() -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize) == noErr,
              dataSize > 0 else {
            return false
        }
        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var devices = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &devices) == noErr else {
            return false
        }

        for dev in devices {
            // 仅检查具备输入声道的录音设备
            var streamAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreamConfiguration,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )
            var streamSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(dev, &streamAddr, 0, nil, &streamSize) == noErr,
                  streamSize > 0 else {
                continue
            }
            let bufPtr = UnsafeMutableRawPointer.allocate(byteCount: Int(streamSize), alignment: MemoryLayout<AudioBufferList>.alignment)
            defer { bufPtr.deallocate() }
            guard AudioObjectGetPropertyData(dev, &streamAddr, 0, nil, &streamSize, bufPtr) == noErr else {
                continue
            }
            let abl = UnsafeMutableAudioBufferListPointer(bufPtr.assumingMemoryBound(to: AudioBufferList.self))
            let inputChannels = abl.reduce(0) { $0 + Int($1.mNumberChannels) }
            guard inputChannels > 0 else { continue }

            var runAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var isRunning: UInt32 = 0
            var runSize = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(dev, &runAddr, 0, nil, &runSize, &isRunning) == noErr, isRunning != 0 {
                return true
            }
        }
        return false
    }

    private static func checkAnyCameraRunning() -> Bool {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        var dataSize: UInt32 = 0
        var usedSize: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, &dataSize) == noErr,
              dataSize > 0 else {
            return false
        }
        let count = Int(dataSize) / MemoryLayout<CMIODeviceID>.size
        var devices = [CMIODeviceID](repeating: 0, count: count)
        guard CMIOObjectGetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, dataSize, &usedSize, &devices) == noErr else {
            return false
        }

        for dev in devices {
            var runAddr = CMIOObjectPropertyAddress(
                mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
                mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
            )
            var isRunning: UInt32 = 0
            var runUsed: UInt32 = 0
            let runSize = UInt32(MemoryLayout<UInt32>.size)
            if CMIOObjectGetPropertyData(dev, &runAddr, 0, nil, runSize, &runUsed, &isRunning) == noErr, isRunning != 0 {
                return true
            }
        }
        return false
    }

    private static func checkScreenRecordingActive() -> Bool {
        // 检测系统原生录屏进程或常见录屏软件（如 screencaptureui / OBS）
        let runningApps = NSWorkspace.shared.runningApplications
        for app in runningApps {
            if let bid = app.bundleIdentifier {
                if bid == "com.apple.screencaptureui" {
                    return true
                }
            }
        }
        return false
    }
}
