import Foundation
import Libmpv

final class MPVPlayerController {
    var onSnapshot: ((PlaybackSnapshot) -> Void)?
    var onLogMessage: ((String) -> Void)?
    var onTrackState: ((PlayerTrackState) -> Void)?
    
    fileprivate let queue = DispatchQueue(label: "StarmineApple.mpv", qos: .userInitiated)
    private var mpv: OpaquePointer?
    private var pollTimer: DispatchSourceTimer?
    private var hostID: Int64?
    private var pendingURL: URL?
    private var initialized = false
    private var lastTrackState = PlayerTrackState()
    private var needsTrackRefresh = true
    
    deinit {
        queue.sync {
            tearDownLocked()
        }
    }
    
    func attachHost(_ hostID: Int64) {
        queue.async {
            self.hostID = hostID
            if self.mpv == nil {
                self.bootstrapLocked(hostID: hostID)
            } else if let mpv = self.mpv {
                var mutableHostID = hostID
                mpv_set_property(mpv, "wid", MPV_FORMAT_INT64, &mutableHostID)
            }
            
            if let pendingURL = self.pendingURL {
                self.loadLocked(pendingURL)
                self.pendingURL = nil
            }
        }
    }
    
    func load(_ url: URL) {
        queue.async {
            guard self.initialized else {
                self.pendingURL = url
                return
            }
            self.loadLocked(url)
        }
    }
    
    func togglePause() {
        queue.async {
            let paused = self.flagPropertyLocked(name: "pause")
            self.setFlagPropertyLocked(name: "pause", value: !paused)
        }
    }

    func play() {
        queue.async {
            self.setFlagPropertyLocked(name: "pause", value: false)
        }
    }

    func pause() {
        queue.async {
            self.setFlagPropertyLocked(name: "pause", value: true)
        }
    }
    
    func seek(to seconds: Double) {
        queue.async {
            self.commandLocked("seek", arguments: [String(seconds), "absolute"])
        }
    }
    
    func seek(relative seconds: Double) {
        queue.async {
            self.commandLocked("seek", arguments: [String(seconds), "relative"])
        }
    }
    
    func selectAudioTrack(id: Int64) {
        queue.async {
            self.setIntPropertyLocked(name: "aid", value: id)
            self.needsTrackRefresh = true
        }
    }
    
    func selectSubtitleTrack(id: Int64?) {
        queue.async {
            self.setTrackSelectionLocked(name: "sid", value: id)
            self.needsTrackRefresh = true
        }
    }
    
    private func bootstrapLocked(hostID: Int64) {
        guard let context = mpv_create() else {
            log("mpv_create failed")
            return
        }
        
        mpv = context
        var mutableHostID = hostID
        mpv_set_option(context, "wid", MPV_FORMAT_INT64, &mutableHostID)
        mpv_set_option_string(context, "config", "no")
        mpv_set_option_string(context, "terminal", "no")
        mpv_set_option_string(context, "idle", "yes")
        mpv_set_option_string(context, "force-window", "yes")
        mpv_set_option_string(context, "osc", "no")
        mpv_set_option_string(context, "input-default-bindings", "no")
        mpv_set_option_string(context, "keepaspect", "yes")
        mpv_set_option_string(context, "keepaspect-window", "yes")
        mpv_set_option_string(context, "video-unscaled", "no")
        mpv_set_option_string(context, "panscan", "0.0")
        mpv_set_option_string(context, "video-zoom", "0")
        mpv_set_option_string(context, "video-pan-x", "0")
        mpv_set_option_string(context, "video-pan-y", "0")
        mpv_set_option_string(context, "hwdec", "no")
        mpv_set_option_string(context, "vo", "gpu-next")
#if os(macOS)
        mpv_set_option_string(context, "gpu-api", "vulkan")
        mpv_set_option_string(context, "gpu-context", "moltenvk")
        mpv_set_option_string(context, "target-colorspace-hint", "yes")
#endif
        mpv_set_option_string(context, "keep-open", "yes")
#if os(macOS)
        mpv_set_option_string(context, "input-media-keys", "yes")
#endif
        
#if DEBUG
        mpv_request_log_messages(context, "info")
#else
        mpv_request_log_messages(context, "warn")
#endif
        
        let initializeStatus = mpv_initialize(context)
        if initializeStatus < 0 {
            log("mpv_initialize failed: \(String(cString: mpv_error_string(initializeStatus)))")
            return
        }
        
        initialized = true
        mpv_observe_property(context, 0, "time-pos", MPV_FORMAT_DOUBLE)
        mpv_observe_property(context, 0, "duration", MPV_FORMAT_DOUBLE)
        mpv_observe_property(context, 0, "pause", MPV_FORMAT_FLAG)
        mpv_set_wakeup_callback(context, mpvWakeupCallback, UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()))
        startPollingLocked()
    }
    
    private func startPollingLocked() {
        pollTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(33), leeway: .milliseconds(8))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.emitSnapshotLocked()
        }
        pollTimer = timer
        timer.resume()
    }
    
    private func emitSnapshotLocked() {
        guard mpv != nil else { return }
        let snapshot = PlaybackSnapshot(
            position: doublePropertyLocked(name: "time-pos"),
            duration: doublePropertyLocked(name: "duration"),
            paused: flagPropertyLocked(name: "pause"),
            loaded: stringPropertyLocked(name: "path") != nil,
            videoWidth: Int(intPropertyLocked(name: "video-out-params/dw") ?? intPropertyLocked(name: "width") ?? 0),
            videoHeight: Int(intPropertyLocked(name: "video-out-params/dh") ?? intPropertyLocked(name: "height") ?? 0)
        )
        DispatchQueue.main.async {
            self.onSnapshot?(snapshot)
        }
        
        if snapshot.loaded {
            emitTrackStateIfNeededLocked()
        } else if lastTrackState != PlayerTrackState() {
            lastTrackState = PlayerTrackState()
            DispatchQueue.main.async {
                self.onTrackState?(self.lastTrackState)
            }
        }
    }
    
    private func loadLocked(_ url: URL) {
        let arguments = [url.absoluteString, "replace"]
        commandLocked("loadfile", arguments: arguments)
    }
    
    private func commandLocked(_ command: String, arguments: [String]) {
        guard let mpv else { return }
        let ownedStrings = ([command] + arguments).map { strdup($0) }
        defer {
            for string in ownedStrings where string != nil {
                free(string)
            }
        }
        var cStrings = ownedStrings.map { pointer in
            pointer.map { UnsafePointer<CChar>($0) }
        }
        cStrings.append(nil)
        cStrings.withUnsafeMutableBufferPointer { buffer in
            _ = mpv_command(mpv, buffer.baseAddress)
        }
    }
    
    private func doublePropertyLocked(name: String) -> Double {
        guard let mpv else { return 0 }
        var value = 0.0
        let status = mpv_get_property(mpv, name, MPV_FORMAT_DOUBLE, &value)
        guard status >= 0 else { return 0 }
        return value.isFinite ? value : 0
    }
    
    private func flagPropertyLocked(name: String) -> Bool {
        guard let mpv else { return false }
        var value: Int64 = 0
        let status = mpv_get_property(mpv, name, MPV_FORMAT_FLAG, &value)
        guard status >= 0 else { return false }
        return value != 0
    }
    
    private func stringPropertyLocked(name: String) -> String? {
        guard let mpv else { return nil }
        guard let raw = mpv_get_property_string(mpv, name) else { return nil }
        defer { mpv_free(raw) }
        return String(cString: raw)
    }
    
    private func intPropertyLocked(name: String) -> Int64? {
        guard let mpv else { return nil }
        var value: Int64 = 0
        let status = mpv_get_property(mpv, name, MPV_FORMAT_INT64, &value)
        guard status >= 0 else { return nil }
        return value
    }
    
    private func setFlagPropertyLocked(name: String, value: Bool) {
        guard let mpv else { return }
        var mutable = value ? 1 : 0
        mpv_set_property(mpv, name, MPV_FORMAT_FLAG, &mutable)
    }
    
    private func setIntPropertyLocked(name: String, value: Int64) {
        guard let mpv else { return }
        var mutable = value
        mpv_set_property(mpv, name, MPV_FORMAT_INT64, &mutable)
    }
    
    private func setTrackSelectionLocked(name: String, value: Int64?) {
        guard let mpv else { return }
        guard let value else {
            mpv_set_property_string(mpv, name, "no")
            return
        }
        var mutable = value
        mpv_set_property(mpv, name, MPV_FORMAT_INT64, &mutable)
    }
    
    private func emitTrackStateIfNeededLocked() {
        let hasCachedTracks = !lastTrackState.audioTracks.isEmpty || !lastTrackState.subtitleTracks.isEmpty
        guard needsTrackRefresh || !hasCachedTracks, let _ = mpv else { return }
        let trackState = readTrackStateLocked()
        needsTrackRefresh = false
        guard trackState != lastTrackState else { return }
        lastTrackState = trackState
        DispatchQueue.main.async {
            self.onTrackState?(trackState)
        }
    }
    
    private func readTrackStateLocked() -> PlayerTrackState {
        let count = max(0, Int(intPropertyLocked(name: "track-list/count") ?? 0))
        var audioTracks: [MediaTrackOption] = []
        var subtitleTracks: [MediaTrackOption] = []
        
        for index in 0 ..< count {
            let base = "track-list/\(index)"
            guard
                let type = stringPropertyLocked(name: "\(base)/type"),
                let trackID = intPropertyLocked(name: "\(base)/id")
            else {
                continue
            }
            
            let title = stringPropertyLocked(name: "\(base)/title")?.trimmingCharacters(in: .whitespacesAndNewlines)
            let language = stringPropertyLocked(name: "\(base)/lang")?.trimmingCharacters(in: .whitespacesAndNewlines)
            let codec = stringPropertyLocked(name: "\(base)/codec")?.trimmingCharacters(in: .whitespacesAndNewlines)
            let isExternal = flagPropertyLocked(name: "\(base)/external")
            let isDefault = flagPropertyLocked(name: "\(base)/default")
            let isForced = flagPropertyLocked(name: "\(base)/forced")
            
            let labelPrefix = type == "audio" ? "音轨" : "字幕"
            let resolvedTitle = title.flatMap { $0.isEmpty ? nil : $0 } ?? {
                if let language, !language.isEmpty {
                    return "\(labelPrefix) \(trackID) · \(language.uppercased())"
                }
                return "\(labelPrefix) \(trackID)"
            }()
            
            let detail = [
                language?.uppercased(),
                codec,
                isExternal ? "外部" : nil,
                isDefault ? "默认" : nil,
                isForced ? "强制" : nil,
            ]
                .compactMap { value -> String? in
                    guard let value, !value.isEmpty else { return nil }
                    return value
                }
                .joined(separator: " · ")
            
            let track = MediaTrackOption(
                kind: type == "audio" ? .audio : .subtitle,
                mpvID: trackID,
                title: resolvedTitle,
                detail: detail,
                isExternal: isExternal
            )
            
            switch type {
            case "audio":
                audioTracks.append(track)
            case "sub":
                subtitleTracks.append(track)
            default:
                break
            }
        }
        
        return PlayerTrackState(
            audioTracks: audioTracks,
            subtitleTracks: subtitleTracks,
            selectedAudioID: intPropertyLocked(name: "aid"),
            selectedSubtitleID: intPropertyLocked(name: "sid")
        )
    }
    
    fileprivate func handleEventsLocked() {
        guard let mpv else { return }
        while let event = mpv_wait_event(mpv, 0) {
            if event.pointee.event_id == MPV_EVENT_NONE {
                break
            }
            
            switch event.pointee.event_id {
            case MPV_EVENT_LOG_MESSAGE:
                if
                    let logPointer = event.pointee.data?.assumingMemoryBound(to: mpv_event_log_message.self),
                    let prefix = logPointer.pointee.prefix,
                    let level = logPointer.pointee.level,
                    let text = logPointer.pointee.text
                {
                    log("[\(String(cString: prefix))] \(String(cString: level)): \(String(cString: text))")
                }
            case MPV_EVENT_START_FILE, MPV_EVENT_FILE_LOADED, MPV_EVENT_VIDEO_RECONFIG:
                needsTrackRefresh = true
            case MPV_EVENT_SHUTDOWN:
                tearDownLocked()
                return
            default:
                break
            }
        }
    }
    
    private func tearDownLocked() {
        pollTimer?.cancel()
        pollTimer = nil
        if let mpv {
            mpv_terminate_destroy(mpv)
        }
        mpv = nil
        initialized = false
        lastTrackState = PlayerTrackState()
        needsTrackRefresh = true
    }
    
    private func log(_ message: String) {
        DispatchQueue.main.async {
            self.onLogMessage?(message)
        }
    }
}

private func mpvWakeupCallback(_ context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    let controller = Unmanaged<MPVPlayerController>.fromOpaque(context).takeUnretainedValue()
    controller.queue.async {
        controller.handleEventsLocked()
    }
}
