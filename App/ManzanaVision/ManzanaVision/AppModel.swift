// SPDX-License-Identifier: GPL-2.0-only
@preconcurrency import AVFoundation
import Foundation
import ManzanaPlayback
import ManzanaTuner
import ManzanaTV
import Observation

/// App state: the session (live tuner, or recordings standing in for it),
/// the channel list, and what the views show.
@MainActor
@Observable
final class AppModel {
    let layer = AVSampleBufferDisplayLayer()
    let engine: PlaybackEngine
    let session: TVSession
    /// Playing recordings instead of the tuner (MANZANA_RECORDINGS or -recordings DIR)
    let recordingsDirectory: URL?

    private(set) var channels: [Channel] = []
    private(set) var current: Channel?
    private(set) var status: LiveStatus = .stopped
    private(set) var signal: Signal?
    private(set) var tmcc: TMCC?
    private(set) var stats = PlaybackStats()

    var showHUD: Bool {
        didSet { UserDefaults.standard.set(showHUD, forKey: "showHUD") }
    }
    /// Digits typed for a channel number ("9.1"), shown until committed
    private(set) var entry = ""
    /// The channel banner shown briefly after a zap
    private(set) var banner: Channel?
    var scan: ScanModel?

    var deinterlace: DeinterlaceMode {
        didSet {
            engine.deinterlace = deinterlace
            UserDefaults.standard.set(deinterlace.rawValue, forKey: "deinterlace")
        }
    }
    var showOneSeg: Bool {
        didSet { UserDefaults.standard.set(showOneSeg, forKey: "showOneSeg") }
    }

    private var tasks: [Task<Void, Never>] = []
    private var entryTask: Task<Void, Never>?
    private var bannerTask: Task<Void, Never>?
    private var activity: NSObjectProtocol?

    init() {
        let defaults = UserDefaults.standard
        let mode = DeinterlaceMode(rawValue: defaults.string(forKey: "deinterlace") ?? "") ?? .auto
        deinterlace = mode
        showOneSeg = defaults.object(forKey: "showOneSeg") as? Bool ?? false
        showHUD = defaults.bool(forKey: "showHUD")
        engine = PlaybackEngine(videoRenderer: layer.sampleBufferRenderer, deinterlace: mode)
        layer.videoGravity = .resizeAspect

        let path = defaults.string(forKey: "recordings") ?? ProcessInfo.processInfo.environment["MANZANA_RECORDINGS"]
        recordingsDirectory = path.map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let dir = recordingsDirectory {
            session = RecordingSession(engine: engine, directory: dir)
        } else {
            session = LiveSession(engine: engine)
        }

        let session = self.session
        tasks = [
            Task { [weak self] in
                for await s in session.statusUpdates { self?.statusChanged(s) }
            },
            Task { [weak self] in
                for await s in session.signalUpdates { self?.signal = s }
            },
            Task { [weak self] in
                for await t in session.tmccUpdates { self?.tmcc = t }
            },
            Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(500))
                    guard let self else { return }
                    stats = engine.currentStats()
                }
            },
        ]
        reloadChannels()
        let last = defaults.string(forKey: lastChannelKey)
        if let channel = visibleChannels.first(where: { $0.id == last }) ?? visibleChannels.first {
            play(channel)
        }
    }

    /// Recordings mode (UI tests, development) keeps its own "last channel"
    private var lastChannelKey: String { recordingsDirectory == nil ? "lastChannel" : "lastRecordedChannel" }

    var visibleChannels: [Channel] {
        channels.filter { showOneSeg || !$0.isOneSeg }
    }

    /// Channels grouped by virtual major, for the sidebar
    var groups: [(major: Int, title: String, channels: [Channel])] {
        Dictionary(grouping: visibleChannels, by: \.major).keys.sorted().map { major in
            let list = visibleChannels.filter { $0.major == major }.sorted { $0.minor < $1.minor }
            return (major, list.first?.name ?? "\(major)", list)
        }
    }

    func reloadChannels() {
        do {
            channels = try session.loadChannels().sorted { ($0.major, $0.minor) < ($1.major, $1.minor) }
        } catch {
            NSLog("ManzanaVision: can't load channels: \(error)")
            channels = []
        }
    }

    // MARK: - playback

    func play(_ channel: Channel) {
        guard channel != current || status == .stopped else { return }
        current = channel
        tmcc = nil
        signal = nil
        UserDefaults.standard.set(channel.id, forKey: lastChannelKey)
        session.play(channel)
        showBanner(channel)
    }

    func step(_ delta: Int) {
        let list = visibleChannels
        guard !list.isEmpty else { return }
        let i = current.flatMap { c in list.firstIndex(of: c) } ?? 0
        play(list[(i + delta + list.count) % list.count])
    }

    private func statusChanged(_ s: LiveStatus) {
        status = s
        let playing: Bool
        if case .playing = s { playing = true } else { playing = false }
        if playing && activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: [.idleDisplaySleepDisabled, .userInitiated],
                                                             reason: "Playing live TV")
        } else if !playing, case .signalLost = s {
            // keep the display awake through short dropouts
        } else if !playing, let a = activity {
            ProcessInfo.processInfo.endActivity(a)
            activity = nil
        }
    }

    private func showBanner(_ channel: Channel) {
        banner = channel
        bannerTask?.cancel()
        bannerTask = Task {
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled { banner = nil }
        }
    }

    // MARK: - numeric entry ("9", "9.1", "13.31")

    func type(_ character: Character) {
        guard character.isNumber || (character == "." && !entry.contains(".") && !entry.isEmpty),
              entry.count < 6 else { return }
        entry.append(character)
        entryTask?.cancel()
        entryTask = Task {
            try? await Task.sleep(for: .seconds(1.5))
            if !Task.isCancelled { commitEntry() }
        }
    }

    func commitEntry() {
        entryTask?.cancel()
        defer { entry = "" }
        guard !entry.isEmpty else { return }
        let parts = entry.split(separator: ".").compactMap { Int($0) }
        let match: Channel? = parts.count == 2
            ? channels.first { $0.major == parts[0] && $0.minor == parts[1] }
            : visibleChannels.first { $0.major == parts.first }
        if let match { play(match) }
    }

    func cancelEntry() {
        entryTask?.cancel()
        entry = ""
    }

    // MARK: - scanning

    func startScan(from: Int, to: Int) {
        let model = ScanModel(from: from, to: to)
        scan = model
        let wasPlaying = current
        current = nil
        model.task = Task { [weak self] in
            guard let self else { return }
            do {
                for try await p in session.scan(from...to, psiTimeout: .seconds(5)) {
                    model.apply(p)
                }
            } catch {
                model.failure = errorMessage(error)
            }
            model.running = false
            reloadChannels()
            if let c = wasPlaying.flatMap({ c in channels.first { $0.id == c.id } }) ?? visibleChannels.first {
                play(c)
            }
        }
    }
}

/// One scan's progress, for the scan sheet
@MainActor
@Observable
final class ScanModel {
    struct Row: Identifiable {
        var rf: Int
        var mux: Mux?
        var id: Int { rf }
    }

    let from: Int, to: Int
    var rows: [Row] = []
    var current: Int?
    var running = true
    var failure: String?
    var changed: Int?
    var task: Task<Void, Never>?

    init(from: Int, to: Int) {
        self.from = from
        self.to = to
    }

    var progress: Double {
        guard let current else { return 0 }
        return Double(current - from) / Double(max(1, to - from + 1))
    }

    var found: [Row] { rows.filter { $0.mux?.signal.hasLock == true } }

    func apply(_ p: ScanProgress) {
        switch p {
        case .tuning(let rf):
            current = rf
        case .result(let mux):
            rows.append(Row(rf: mux.rf, mux: mux))
        case .finished(let n):
            changed = n
            current = to + 1
        }
    }

    func cancel() {
        task?.cancel()
        running = false
    }
}

/// A scan or tuner failure, in the user's language
func errorMessage(_ error: any Error) -> String {
    guard let error = error as? TunerError else { return error.localizedDescription }
    return switch error {
    case .noDevice, .gone: String(localized: "The tuner isn't plugged in.")
    case .busy: String(localized: "Another program is using the tuner.")
    case .firmware(let why): firmwareMessage(why)
    case .noLock: String(localized: "No signal.")
    case .cancelled: String(localized: "Cancelled.")
    case .io, .noFrontend, .invalid, .notOpen: String(localized: "The tuner stopped responding. Unplug it and plug it back in.")
    }
}
