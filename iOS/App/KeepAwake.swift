import AVFoundation
import CoreLocation
import Foundation

/// How Hongyan keeps itself running in the background during a backup.
enum KeepAwakeMode: String, CaseIterable, Identifiable {
    case off, audio, location
    var id: Self { self }
}

/// Keeps the app from being suspended while it uploads by itself.
///
/// - `.audio`: plays silence in a loop, mixed with other audio. The Now
///   Playing controls don't change and the user hears nothing.
/// - `.location`: coarse location updates. iOS shows the blue location
///   indicator while it runs.
///
/// Both need the matching UIBackgroundModes entry (audio, location). They
/// must start while the app is in the foreground; iOS does not allow either
/// to start from the background.
@MainActor
final class KeepAwake: NSObject {
    private(set) var mode: KeepAwakeMode = .off
    private(set) var isActive = false {
        didSet { if oldValue != isActive { onChange?(isActive) } }
    }
    private(set) var problem: String?
    var onChange: ((Bool) -> Void)?

    private var player: AVAudioPlayer?
    private var interruptionObserver: NSObjectProtocol?
    private var location: CLLocationManager?

    func start(_ mode: KeepAwakeMode) {
        stop()
        self.mode = mode
        problem = nil
        switch mode {
        case .off: break
        case .audio: startAudio()
        case .location: startLocation()
        }
    }

    func stop() {
        player?.stop()
        player = nil
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
            self.interruptionObserver = nil
        }
        if mode == .audio {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        location?.stopUpdatingLocation()
        location?.delegate = nil
        location = nil
        mode = .off
        isActive = false
    }

    // MARK: Silent audio

    private func startAudio() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            let player = try AVAudioPlayer(data: Self.silentWAV(seconds: 2))
            player.numberOfLoops = -1
            player.prepareToPlay()
            guard player.play() else { throw CocoaError(.featureUnsupported) }
            self.player = player
            interruptionObserver = NotificationCenter.default.addObserver(
                forName: AVAudioSession.interruptionNotification, object: session, queue: .main
            ) { [weak self] note in
                let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                Task { @MainActor in self?.handleInterruption(raw.flatMap(AVAudioSession.InterruptionType.init)) }
            }
            isActive = true
        } catch {
            problem = String(localized: "Could not start silent audio: \(error.localizedDescription)")
            isActive = false
        }
    }

    /// A phone call or another app can take the audio session. Resume after it.
    private func handleInterruption(_ type: AVAudioSession.InterruptionType?) {
        switch type {
        case .began:
            isActive = false
        case .ended:
            try? AVAudioSession.sharedInstance().setActive(true)
            isActive = player?.play() ?? false
        default:
            break
        }
    }

    /// 8 kHz, 16-bit mono PCM of zeros.
    static func silentWAV(seconds: Int) -> Data {
        let sampleRate: UInt32 = 8_000
        let dataSize = UInt32(seconds) * sampleRate * 2
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36) + dataSize)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(sampleRate); append(sampleRate * 2); append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(dataSize)
        data.append(Data(count: Int(dataSize)))
        return data
    }

    // MARK: Location

    private func startLocation() {
        let manager = CLLocationManager()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        manager.distanceFilter = CLLocationDistanceMax
        manager.pausesLocationUpdatesAutomatically = false
        location = manager
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        } else {
            beginLocationUpdates()
        }
    }

    private func beginLocationUpdates() {
        guard let manager = location else { return }
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            manager.allowsBackgroundLocationUpdates = true
            manager.showsBackgroundLocationIndicator = true
            manager.startUpdatingLocation()
            isActive = true
        case .notDetermined:
            break
        default:
            problem = String(localized: "Hongyan needs location access to stay awake. Change it in Settings › Privacy › Location Services.")
            isActive = false
        }
    }
}

extension KeepAwake: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in self.beginLocationUpdates() }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        // The updates only keep the app running; the positions are not used or stored.
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}
