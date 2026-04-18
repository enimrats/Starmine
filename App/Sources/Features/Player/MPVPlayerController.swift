import CoreGraphics
import CoreImage
import Foundation
import Libmpv

private struct PendingExternalSubtitle {
    var url: URL
    var shouldSelect: Bool
}

enum PlayerScreenshotError: LocalizedError {
    case noActiveVideo
    case commandFailed(String)
    case invalidPayload(String)
    case imageCreationFailed

    var errorDescription: String? {
        switch self {
        case .noActiveVideo:
            return "当前没有可截图的视频。"
        case let .commandFailed(reason):
            return reason
        case let .invalidPayload(reason):
            return reason
        case .imageCreationFailed:
            return "截图图像生成失败。"
        }
    }
}

struct PlayerScreenshotCapture {
    let image: CGImage
}

final class MPVPlayerController: @unchecked Sendable {
    var onSnapshot: ((PlaybackSnapshot) -> Void)?
    var onLogMessage: ((String) -> Void)?
    var onTrackState: ((PlayerTrackState) -> Void)?

    fileprivate let queue = DispatchQueue(
        label: "StarmineApple.mpv",
        qos: .userInitiated
    )
    private var mpv: OpaquePointer?
    private var pollTimer: DispatchSourceTimer?
    private var hostID: Int64?
    private var pendingURL: URL?
    private var pendingExternalSubtitles: [PendingExternalSubtitle] = []
    private var initialized = false
    private var lastTrackState = PlayerTrackState()
    private var needsTrackRefresh = true
    private var desiredPlaybackRate = 1.0

    deinit {
        queue.sync {
            tearDownLocked()
        }
    }

    func attachHost(_ hostID: Int64) {
        queue.async {
            let previousHostID = self.hostID
            self.hostID = hostID
            if self.mpv == nil {
                self.bootstrapLocked(hostID: hostID)
            } else if previousHostID != hostID, let mpv = self.mpv {
                var mutableHostID = hostID
                mpv_set_property(mpv, "wid", MPV_FORMAT_INT64, &mutableHostID)
            }

            if let pendingURL = self.pendingURL {
                self.loadLocked(pendingURL)
                self.pendingURL = nil
            }
        }
    }

    func load(_ url: URL, externalSubtitles: [URL] = []) {
        queue.async {
            self.pendingExternalSubtitles = externalSubtitles.map {
                PendingExternalSubtitle(url: $0, shouldSelect: false)
            }
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

    func setPlaybackRate(_ rate: Double) {
        queue.async {
            let clampedRate = PlaybackPreferences.clampedPlaybackRate(rate)
            self.desiredPlaybackRate = clampedRate
            guard self.initialized else { return }
            self.setDoublePropertyLocked(name: "speed", value: clampedRate)
        }
    }

    func stop() {
        queue.async {
            self.pendingURL = nil
            self.pendingExternalSubtitles.removeAll()
            guard self.initialized else { return }
            self.commandLocked("stop", arguments: [])
            self.needsTrackRefresh = true
        }
    }

    func seek(to seconds: Double) {
        queue.async {
            self.commandLocked(
                "seek",
                arguments: [String(seconds), "absolute"]
            )
        }
    }

    func seek(relative seconds: Double) {
        queue.async {
            self.commandLocked(
                "seek",
                arguments: [String(seconds), "relative"]
            )
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

    func addExternalSubtitle(_ url: URL, shouldSelect: Bool = true) {
        queue.async {
            let subtitle = PendingExternalSubtitle(
                url: url,
                shouldSelect: shouldSelect
            )
            if self.stringPropertyLocked(name: "path") != nil {
                self.addExternalSubtitleLocked(subtitle)
                self.needsTrackRefresh = true
            } else {
                self.pendingExternalSubtitles.append(subtitle)
            }
        }
    }

    func captureScreenshot() async throws -> PlayerScreenshotCapture {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    let capture = try self.captureScreenshotLocked()
                    continuation.resume(returning: capture)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
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
        mpv_set_option_string(context, "profile", "high-quality")
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
        mpv_set_option_string(context, "hwdec", "videotoolbox")
        mpv_set_option_string(context, "hwdec-software-fallback", "60")
        mpv_set_option_string(context, "audio-pitch-correction", "yes")
        mpv_set_option_string(context, "video-sync", "display-resample")
        mpv_set_option_string(context, "interpolation", "yes")
        mpv_set_option_string(context, "tscale", "oversample")
        mpv_set_option_string(context, "screenshot-high-bit-depth", "yes")
        mpv_set_option_string(context, "screenshot-tag-colorspace", "yes")
        mpv_set_option_string(context, "vo", "gpu-next")
        mpv_set_option_string(context, "scale", "ewa_lanczossharp")
        mpv_set_option_string(context, "cscale", "ewa_lanczossharp")
        mpv_set_option_string(context, "dscale", "spline36")
        #if os(macOS)
            mpv_set_option_string(context, "gpu-api", "vulkan")
            mpv_set_option_string(context, "gpu-context", "moltenvk")
        #endif
        mpv_set_option_string(context, "target-colorspace-hint", "yes")
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
            log(
                "mpv_initialize failed: \(String(cString: mpv_error_string(initializeStatus)))"
            )
            return
        }

        initialized = true
        setDoublePropertyLocked(name: "speed", value: desiredPlaybackRate)
        mpv_observe_property(context, 0, "time-pos", MPV_FORMAT_DOUBLE)
        mpv_observe_property(context, 0, "duration", MPV_FORMAT_DOUBLE)
        mpv_observe_property(context, 0, "pause", MPV_FORMAT_FLAG)
        mpv_set_wakeup_callback(
            context,
            mpvWakeupCallback,
            UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        )
        startPollingLocked()
    }

    private func startPollingLocked() {
        pollTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now(),
            repeating: .milliseconds(33),
            leeway: .milliseconds(8)
        )
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
            playbackRate: doublePropertyLocked(name: "speed"),
            videoWidth: Int(
                intPropertyLocked(name: "video-out-params/dw")
                    ?? intPropertyLocked(name: "width") ?? 0
            ),
            videoHeight: Int(
                intPropertyLocked(name: "video-out-params/dh")
                    ?? intPropertyLocked(name: "height") ?? 0
            )
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

    private func applyPendingExternalSubtitlesLocked() {
        guard !pendingExternalSubtitles.isEmpty else { return }
        for subtitle in pendingExternalSubtitles {
            addExternalSubtitleLocked(subtitle)
        }
        pendingExternalSubtitles.removeAll()
    }

    private func addExternalSubtitleLocked(_ subtitle: PendingExternalSubtitle)
    {
        let subtitleTarget =
            subtitle.url.isFileURL
            ? subtitle.url.path : subtitle.url.absoluteString
        commandLocked(
            "sub-add",
            arguments: [
                subtitleTarget,
                subtitle.shouldSelect ? "select" : "auto",
            ]
        )
    }

    private func captureScreenshotLocked() throws -> PlayerScreenshotCapture {
        guard stringPropertyLocked(name: "path") != nil else {
            throw PlayerScreenshotError.noActiveVideo
        }

        let colorSpace = resolvedScreenshotColorSpaceLocked()
        var lastError: Error?

        for requestedFormat in ScreenshotPixelFormat.captureOrder {
            do {
                var result = try commandResultLocked(
                    "screenshot-raw",
                    arguments: ["subtitles", requestedFormat.mpvArgument]
                )
                defer { mpv_free_node_contents(&result) }
                return try makeScreenshotCaptureLocked(
                    from: result,
                    colorSpace: colorSpace
                )
            } catch {
                lastError = error
            }
        }

        throw lastError
            ?? PlayerScreenshotError.invalidPayload("mpv 未返回可用的原始截图数据。")
    }

    private func commandLocked(_ command: String, arguments: [String]) {
        _ = commandStatusLocked(command, arguments: arguments)
    }

    @discardableResult
    private func commandStatusLocked(_ command: String, arguments: [String])
        -> Int32
    {
        guard let mpv else { return Int32(MPV_ERROR_UNINITIALIZED.rawValue) }
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
        return cStrings.withUnsafeMutableBufferPointer { buffer in
            mpv_command(mpv, buffer.baseAddress)
        }
    }

    private func commandResultLocked(_ command: String, arguments: [String])
        throws
        -> mpv_node
    {
        guard let mpv else {
            throw PlayerScreenshotError.commandFailed("播放器尚未初始化。")
        }

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

        var result = mpv_node()
        let status = cStrings.withUnsafeMutableBufferPointer { buffer in
            mpv_command_ret(mpv, buffer.baseAddress, &result)
        }
        guard status >= 0 else {
            let message = String(cString: mpv_error_string(status))
            throw PlayerScreenshotError.commandFailed("截图失败：\(message)")
        }
        return result
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

    private func setDoublePropertyLocked(name: String, value: Double) {
        guard let mpv else { return }
        var mutable = value
        mpv_set_property(mpv, name, MPV_FORMAT_DOUBLE, &mutable)
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
        let hasCachedTracks =
            !lastTrackState.audioTracks.isEmpty
            || !lastTrackState.subtitleTracks.isEmpty
        guard needsTrackRefresh || !hasCachedTracks, mpv != nil else { return }
        let trackState = readTrackStateLocked()
        needsTrackRefresh = false
        guard trackState != lastTrackState else { return }
        lastTrackState = trackState
        DispatchQueue.main.async {
            self.onTrackState?(trackState)
        }
    }

    private func readTrackStateLocked() -> PlayerTrackState {
        let count = max(
            0,
            Int(intPropertyLocked(name: "track-list/count") ?? 0)
        )
        var audioTracks: [MediaTrackOption] = []
        var subtitleTracks: [MediaTrackOption] = []

        for index in 0..<count {
            let base = "track-list/\(index)"
            guard
                let type = stringPropertyLocked(name: "\(base)/type"),
                let trackID = intPropertyLocked(name: "\(base)/id")
            else {
                continue
            }

            let title = stringPropertyLocked(name: "\(base)/title")?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let language = stringPropertyLocked(name: "\(base)/lang")?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let codec = stringPropertyLocked(name: "\(base)/codec")?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let isExternal = flagPropertyLocked(name: "\(base)/external")
            let isDefault = flagPropertyLocked(name: "\(base)/default")
            let isForced = flagPropertyLocked(name: "\(base)/forced")

            let labelPrefix = type == "audio" ? "音轨" : "字幕"
            let resolvedTitle =
                title.flatMap { $0.isEmpty ? nil : $0 }
                ?? {
                    if let language, !language.isEmpty {
                        return
                            "\(labelPrefix) \(trackID) · \(language.uppercased())"
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
                if let logPointer = event.pointee.data?.assumingMemoryBound(
                    to: mpv_event_log_message.self
                ),
                    let prefix = logPointer.pointee.prefix,
                    let level = logPointer.pointee.level,
                    let text = logPointer.pointee.text
                {
                    log(
                        "[\(String(cString: prefix))] \(String(cString: level)): \(String(cString: text))"
                    )
                }
            case MPV_EVENT_START_FILE, MPV_EVENT_VIDEO_RECONFIG:
                needsTrackRefresh = true
            case MPV_EVENT_FILE_LOADED:
                needsTrackRefresh = true
                applyPendingExternalSubtitlesLocked()
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
        pendingExternalSubtitles.removeAll()
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

    private func makeScreenshotCaptureLocked(
        from node: mpv_node,
        colorSpace: CGColorSpace
    ) throws -> PlayerScreenshotCapture {
        let payload = try screenshotPayload(from: node)
        guard
            let provider = CGDataProvider(data: payload.data as CFData),
            let image = CGImage(
                width: payload.width,
                height: payload.height,
                bitsPerComponent: payload.pixelFormat.bitsPerComponent,
                bitsPerPixel: payload.pixelFormat.bitsPerPixel,
                bytesPerRow: payload.bytesPerRow,
                space: colorSpace,
                bitmapInfo: payload.pixelFormat.bitmapInfo,
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
            )
        else {
            throw PlayerScreenshotError.imageCreationFailed
        }
        return PlayerScreenshotCapture(image: image)
    }

    private func screenshotPayload(from node: mpv_node) throws
        -> ScreenshotPayload
    {
        guard node.format == MPV_FORMAT_NODE_MAP, let list = node.u.list else {
            throw PlayerScreenshotError.invalidPayload(
                "mpv 原始截图返回格式异常。"
            )
        }

        let availableKeys = screenshotPayloadKeys(list: list)
        guard
            let width = intValue(in: list, forKey: "w"),
            let height = intValue(in: list, forKey: "h"),
            let bytesPerRow = intValue(in: list, forKey: "stride"),
            let formatName = stringValue(in: list, forKey: "format"),
            let byteArray = dataValue(in: list, forKey: "data"),
            let pixelFormat = ScreenshotPixelFormat(mpvFormat: formatName)
        else {
            throw PlayerScreenshotError.invalidPayload(
                "mpv 原始截图数据不完整：\(availableKeys.joined(separator: ", "))"
            )
        }

        guard width > 0, height > 0, bytesPerRow > 0 else {
            throw PlayerScreenshotError.invalidPayload("mpv 原始截图尺寸无效。")
        }

        let minimumBytes = bytesPerRow * height
        guard byteArray.count >= minimumBytes else {
            throw PlayerScreenshotError.invalidPayload("mpv 原始截图数据长度不足。")
        }

        return ScreenshotPayload(
            width: width,
            height: height,
            bytesPerRow: bytesPerRow,
            pixelFormat: pixelFormat,
            data: Data(byteArray.prefix(minimumBytes))
        )
    }

    private func screenshotPayloadKeys(
        list: UnsafeMutablePointer<mpv_node_list>
    )
        -> [String]
    {
        guard let keys = list.pointee.keys else { return [] }
        return (0..<Int(list.pointee.num)).compactMap { index in
            guard let key = keys[index] else { return nil }
            return String(cString: key)
        }
    }

    private func nodeValue(
        in list: UnsafeMutablePointer<mpv_node_list>,
        forKey key: String
    ) -> mpv_node? {
        guard let keys = list.pointee.keys, let values = list.pointee.values
        else {
            return nil
        }
        for index in 0..<Int(list.pointee.num) {
            guard let rawKey = keys[index] else { continue }
            if String(cString: rawKey) == key {
                return values[index]
            }
        }
        return nil
    }

    private func intValue(
        in list: UnsafeMutablePointer<mpv_node_list>,
        forKey key: String
    ) -> Int? {
        guard let value = nodeValue(in: list, forKey: key) else { return nil }
        switch value.format {
        case MPV_FORMAT_INT64:
            return Int(value.u.int64)
        case MPV_FORMAT_DOUBLE:
            return Int(value.u.double_)
        default:
            return nil
        }
    }

    private func stringValue(
        in list: UnsafeMutablePointer<mpv_node_list>,
        forKey key: String
    ) -> String? {
        guard
            let value = nodeValue(in: list, forKey: key),
            value.format == MPV_FORMAT_STRING,
            let raw = value.u.string
        else {
            return nil
        }
        return String(cString: raw)
    }

    private func dataValue(
        in list: UnsafeMutablePointer<mpv_node_list>,
        forKey key: String
    ) -> Data? {
        guard
            let value = nodeValue(in: list, forKey: key),
            value.format == MPV_FORMAT_BYTE_ARRAY,
            let byteArray = value.u.ba,
            byteArray.pointee.size > 0,
            let raw = byteArray.pointee.data
        else {
            return nil
        }
        return Data(bytes: raw, count: byteArray.pointee.size)
    }

    private func resolvedScreenshotColorSpaceLocked() -> CGColorSpace {
        let primaries =
            stringPropertyLocked(name: "video-out-params/primaries")
            ?? stringPropertyLocked(name: "video-params/primaries")
            ?? stringPropertyLocked(name: "target-prim")
        let transfer =
            stringPropertyLocked(name: "video-out-params/gamma")
            ?? stringPropertyLocked(name: "video-params/gamma")
            ?? stringPropertyLocked(name: "target-trc")

        return Self.screenshotColorSpace(
            primaries: primaries,
            transfer: transfer
        )
            ?? CGColorSpace(name: CGColorSpace.displayP3)
            ?? CGColorSpaceCreateDeviceRGB()
    }

    static func screenshotColorSpace(
        primaries: String?,
        transfer: String?
    ) -> CGColorSpace? {
        let normalizedPrimaries = primaries?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let normalizedTransfer = transfer?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        if let normalizedTransfer {
            if normalizedTransfer.contains("pq") {
                if normalizedPrimaries?.contains("p3") == true {
                    return CGColorSpace(name: CGColorSpace.displayP3_PQ)
                }
                return CGColorSpace(name: CGColorSpace.itur_2100_PQ)
            }
            if normalizedTransfer.contains("hlg") {
                if normalizedPrimaries?.contains("p3") == true {
                    return CGColorSpace(name: CGColorSpace.displayP3_HLG)
                }
                return CGColorSpace(name: CGColorSpace.itur_2100_HLG)
            }
            if normalizedTransfer == "linear" {
                if normalizedPrimaries?.contains("2020") == true {
                    return
                        CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)
                }
                if normalizedPrimaries?.contains("p3") == true {
                    return
                        CGColorSpace(
                            name: CGColorSpace.extendedLinearDisplayP3
                        )
                }
                return CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
            }
        }

        if normalizedPrimaries?.contains("2020") == true {
            return CGColorSpace(name: CGColorSpace.itur_2020)
                ?? CGColorSpace(name: CGColorSpace.extendedITUR_2020)
        }
        if normalizedPrimaries?.contains("p3") == true {
            return CGColorSpace(name: CGColorSpace.displayP3)
        }
        if normalizedPrimaries?.contains("xyz") == true {
            return CGColorSpace(name: CGColorSpace.genericXYZ)
        }
        return CGColorSpace(name: CGColorSpace.itur_709)
            ?? CGColorSpace(name: CGColorSpace.sRGB)
    }
}

private struct ScreenshotPayload {
    let width: Int
    let height: Int
    let bytesPerRow: Int
    let pixelFormat: ScreenshotPixelFormat
    let data: Data
}

private enum ScreenshotPixelFormat: String {
    case rgba64
    case bgra
    case rgba

    static let captureOrder: [ScreenshotPixelFormat] = [.rgba64, .bgra, .rgba]

    init?(mpvFormat: String) {
        self.init(rawValue: mpvFormat.lowercased())
    }

    var mpvArgument: String {
        rawValue
    }

    var bitsPerComponent: Int {
        switch self {
        case .rgba64:
            return 16
        case .bgra, .rgba:
            return 8
        }
    }

    var bitsPerPixel: Int {
        switch self {
        case .rgba64:
            return 64
        case .bgra, .rgba:
            return 32
        }
    }

    var bitmapInfo: CGBitmapInfo {
        switch self {
        case .rgba64:
            return [
                .byteOrder16Little,
                CGBitmapInfo(
                    rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
                ),
            ]
        case .bgra:
            return [
                .byteOrder32Little,
                CGBitmapInfo(
                    rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                ),
            ]
        case .rgba:
            return [
                .byteOrder32Big,
                CGBitmapInfo(
                    rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
                ),
            ]
        }
    }
}

private func mpvWakeupCallback(_ context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    let controller = Unmanaged<MPVPlayerController>.fromOpaque(context)
        .takeUnretainedValue()
    controller.queue.async {
        controller.handleEventsLocked()
    }
}
