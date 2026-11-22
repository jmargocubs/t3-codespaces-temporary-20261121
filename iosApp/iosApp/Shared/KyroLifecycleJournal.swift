import Foundation
#if os(iOS)
import AVFoundation
import UIKit
#endif

/// Build 65: a small on-device journal of playback lifecycle and sports-provider events, kept so a
/// device test can be explained after the fact (Build 64's Picture in Picture report had a screen
/// recording but no device log: collecting one needs root on the Mac).
///
/// Privacy: callers pass fixed event labels and short state words (enum names, counts, provider
/// names). Never stream or channel names, URLs, server names, account or profile data. `record`
/// also strips anything after 160 characters and every line break.
///
/// Storage: `Library/Application Support/Diagnostics/kyro-lifecycle.log`, one line per event,
/// rotated to `kyro-lifecycle.1.log` at 192 KB, so at most ~384 KB. Copy it from Live TV Settings ›
/// Diagnostics, or read it over USB from the app's data container (`devicectl device copy from
/// --domain-type appDataContainer --domain-identifier com.cubbiestream.kyro`).
enum KyroLifecycleJournal {
    static let maximumBytes = 192 * 1024

    private static let queue = DispatchQueue(label: "com.cubbiestream.kyro.lifecycle-journal", qos: .utility)
    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Overridable for tests; nil disables writing. Off under XCTest unless a test sets it.
    nonisolated(unsafe) static var directory: URL? = {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
              !ProcessInfo.processInfo.processName.hasPrefix("xctest") else { return nil }
        return FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Diagnostics", isDirectory: true)
    }()

    static var currentURL: URL? { directory?.appendingPathComponent("kyro-lifecycle.log") }
    static var previousURL: URL? { directory?.appendingPathComponent("kyro-lifecycle.1.log") }

    /// One line: `2026-11-13T00:34:55.482Z pip did_stop restored`.
    static func line(_ category: String, _ event: String, _ state: String, at date: Date = Date()) -> String {
        let parts = [formatter.string(from: date), clean(category), clean(event), clean(state)].filter { !$0.isEmpty }
        return parts.joined(separator: " ")
    }

    static func clean(_ value: String) -> String {
        let flat = value.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
        return String(flat.prefix(160))
    }

    static func record(_ category: String, _ event: String, _ state: String = "") {
        let text = line(category, event, state) + "\n"
        queue.async { append(text) }
    }

    /// Waits for queued lines; tests and Copy use it.
    static func flush() {
        queue.sync {}
    }

    static func contents() -> String {
        flush()
        return queue.sync {
            [previousURL, currentURL].compactMap { url -> String? in
                guard let url else { return nil }
                return try? String(contentsOf: url, encoding: .utf8)
            }.joined()
        }
    }

    static func clear() {
        queue.sync {
            for url in [previousURL, currentURL].compactMap({ $0 }) {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    private static func append(_ text: String) {
        guard let directory, let current = currentURL, let previous = previousURL else { return }
        let manager = FileManager.default
        if !manager.fileExists(atPath: directory.path) {
            try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let size = (try? manager.attributesOfItem(atPath: current.path)[.size] as? Int) ?? 0
        if size > maximumBytes {
            try? manager.removeItem(at: previous)
            try? manager.moveItem(at: current, to: previous)
        }
        guard let data = text.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: current) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: current, options: .atomic)
        }
    }

    #if os(iOS)
    nonisolated(unsafe) private static var observers: [NSObjectProtocol] = []

    /// App and audio-session edges, recorded from the moment the app starts. Idempotent.
    @MainActor
    static func startObservingSystemEvents() {
        guard observers.isEmpty else { return }
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        record("app", "launch", "build=\(build) state=\(applicationStateName())")
        let center = NotificationCenter.default
        let app: [(Notification.Name, String)] = [
            (UIApplication.willResignActiveNotification, "will_resign_active"),
            (UIApplication.didEnterBackgroundNotification, "did_enter_background"),
            (UIApplication.willEnterForegroundNotification, "will_enter_foreground"),
            (UIApplication.didBecomeActiveNotification, "did_become_active"),
            (UIApplication.didReceiveMemoryWarningNotification, "memory_warning"),
            (UIApplication.willTerminateNotification, "will_terminate"),
        ]
        for (name, label) in app {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                record("app", label)
            })
        }
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let type = raw.flatMap(AVAudioSession.InterruptionType.init(rawValue:))
            let options = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt).map(AVAudioSession.InterruptionOptions.init(rawValue:))
            let label = type == .began ? "began" : (type == .ended ? "ended" : "unknown")
            record("audio", "interruption", "\(label) should_resume=\(options?.contains(.shouldResume) == true)")
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { note in
            let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt) ?? 0
            record("audio", "route_change", "reason=\(reason) category=\(AVAudioSession.sharedInstance().category.rawValue.replacingOccurrences(of: "AVAudioSessionCategory", with: ""))")
        })
        for (name, label) in [(AVAudioSession.mediaServicesWereResetNotification, "media_services_reset"),
                              (AVAudioSession.mediaServicesWereLostNotification, "media_services_lost")] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in record("audio", label) })
        }
    }

    @MainActor
    static func applicationStateName() -> String {
        switch UIApplication.shared.applicationState {
        case .active: "active"
        case .inactive: "inactive"
        case .background: "background"
        @unknown default: "unknown"
        }
    }
    #endif
}
