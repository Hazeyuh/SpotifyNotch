import Foundation

/// 通过 DistributedNotificationCenter 与 AppleScript 零轮询同步本地 Spotify.app 状态
final class SpotifyLocalController: ObservableObject {
    @Published private(set) var track: TrackInfo?
    @Published private(set) var currentPosition: TimeInterval = 0
    @Published private(set) var isSpotifyRunning: Bool = false

    private var tickTimer: Timer?
    private var syncTimer: Timer?
    private var notificationObserver: NSObjectProtocol?
    private let scriptQueue = DispatchQueue(label: "spotifynotch.applescript", qos: .userInitiated)

    var onTrackChanged: ((TrackInfo) -> Void)?

    init() {
        startObserving()
        refreshState()
    }

    deinit {
        if let observer = notificationObserver {
            DistributedNotificationCenter.default().removeObserver(observer)
        }
        tickTimer?.invalidate()
        syncTimer?.invalidate()
    }

    private func startObserving() {
        notificationObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.spotify.client.PlaybackStateChanged"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshState()
        }

        // 高频本地进度推算（不调用外部进程），驱动毫秒级歌词高亮
        tickTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            guard let self, let track = self.track else { return }
            if track.isPlaying {
                self.currentPosition = track.estimatedPosition
            }
        }
        if let tickTimer {
            RunLoop.main.add(tickTimer, forMode: .common)
        }

        // 低频校准（每 4 秒同步一次，防止用户手动拖动进度条后漂移）
        syncTimer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: true) { [weak self] _ in
            self?.refreshState()
        }
        if let syncTimer {
            RunLoop.main.add(syncTimer, forMode: .common)
        }
    }

    func refreshState() {
        scriptQueue.async { [weak self] in
            guard let self else { return }
            let script = """
            if application "Spotify" is running then
                tell application "Spotify"
                    set pState to player state as string
                    set tId to id of current track
                    set tName to name of current track
                    set tArtist to artist of current track
                    set tAlbum to album of current track
                    set tDur to duration of current track
                    set tArt to artwork url of current track
                    set tPos to player position
                    return pState & "|||" & tId & "|||" & tName & "|||" & tArtist & "|||" & tAlbum & "|||" & (tDur as string) & "|||" & tArt & "|||" & (tPos as string)
                end tell
            else
                return "NOT_RUNNING"
            end if
            """
            guard let output = self.runAppleScript(script) else {
                DispatchQueue.main.async {
                    self.isSpotifyRunning = false
                }
                return
            }

            if output == "NOT_RUNNING" {
                DispatchQueue.main.async {
                    self.isSpotifyRunning = false
                    self.track = nil
                    self.currentPosition = 0
                }
                return
            }

            let parts = output.components(separatedBy: "|||")
            guard parts.count == 8 else { return }

            let isPlaying = (parts[0] == "playing")
            let id = parts[1]
            let name = parts[2]
            let artist = parts[3]
            let album = parts[4]
            // Spotify AppleScript 返回的 duration 单位为毫秒
            let rawDur = Double(parts[5].replacingOccurrences(of: ",", with: ".")) ?? 0
            let duration = rawDur > 10000 ? rawDur / 1000.0 : rawDur
            let artworkURL = parts[6]
            let pos = Double(parts[7].replacingOccurrences(of: ",", with: ".")) ?? 0

            let newTrack = TrackInfo(
                id: id,
                name: name,
                artist: artist,
                album: album,
                duration: duration,
                artworkURL: artworkURL,
                isPlaying: isPlaying,
                position: pos,
                capturedAt: Date()
            )

            DispatchQueue.main.async {
                let previousID = self.track?.id
                self.isSpotifyRunning = true
                self.track = newTrack
                self.currentPosition = pos
                if previousID != newTrack.id {
                    self.onTrackChanged?(newTrack)
                }
            }
        }
    }

    func playPause() {
        runCommandAndRefresh("tell application \"Spotify\" to playpause")
    }

    func nextTrack() {
        runCommandAndRefresh("tell application \"Spotify\" to next track")
    }

    func previousTrack() {
        runCommandAndRefresh("tell application \"Spotify\" to previous track")
    }

    func seek(to seconds: TimeInterval) {
        let clamped = max(0, seconds)
        DispatchQueue.main.async {
            self.currentPosition = clamped
        }
        runCommandAndRefresh("tell application \"Spotify\" to set player position to \(clamped)")
    }

    func playURI(_ uri: String) {
        let escaped = uri.replacingOccurrences(of: "\"", with: "\\\"")
        runCommandAndRefresh("tell application \"Spotify\" to play track \"\(escaped)\"")
    }

    private func runCommandAndRefresh(_ source: String) {
        scriptQueue.async { [weak self] in
            _ = self?.runAppleScript(source)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                self?.refreshState()
            }
        }
    }

    private func runAppleScript(_ source: String) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", source]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
            guard proc.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }
}
