import Foundation

struct TrackInfo: Equatable, Codable {
    let id: String
    let name: String
    let artist: String
    let album: String
    let duration: TimeInterval
    let artworkURL: String
    let isPlaying: Bool
    let position: TimeInterval
    let capturedAt: Date

    var spotifyTrackID: String? {
        let parts = id.split(separator: ":")
        if parts.count == 3, parts[1] == "track" {
            return String(parts[2])
        }
        return nil
    }

    var estimatedPosition: TimeInterval {
        guard isPlaying else { return position }
        let elapsed = Date().timeIntervalSince(capturedAt)
        return min(max(0, position + elapsed), max(duration, 0.1))
    }

    var cacheKey: String {
        if let tid = spotifyTrackID, !tid.isEmpty {
            return tid
        }
        return "\(artist.lowercased())|\(name.lowercased())|\(Int(duration))"
    }
}

struct LyricLine: Identifiable, Equatable, Codable {
    let id: Int
    let time: TimeInterval
    let text: String
}

struct CachedLyrics: Codable {
    let key: String
    let lines: [LyricLine]
    let plainLyrics: String?
    let instrumental: Bool
    let fetchedAt: Date
}

struct SpotifyPlaylist: Identifiable, Equatable, Codable {
    let id: String
    let name: String
    let trackCount: Int
    let ownerName: String
    let imageURL: String?
}

struct SpotifyCredentials: Codable, Equatable {
    var clientID: String
    var clientSecret: String
    var redirectURI: String

    static let defaultRedirectURI = "http://127.0.0.1:8888/callback"
}

struct SpotifyTokens: Codable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
}

enum ExpandedTab: String, CaseIterable {
    case lyrics = "歌词"
    case playlists = "歌单"
    case settings = "设置"
}

final class AppSettings: ObservableObject {
    @Published var showNotch: Bool {
        didSet { UserDefaults.standard.set(showNotch, forKey: "v2_showNotch") }
    }
    /// 收起态是否常驻下方歌词条（默认关闭，仅显示纯黑刘海本体）
    @Published var showCollapsedLyrics: Bool {
        didSet { UserDefaults.standard.set(showCollapsedLyrics, forKey: "v2_showCollapsedLyrics") }
    }
    /// 常驻歌词行数：1=单行，2=两行紧凑，3=三行紧凑
    @Published var collapsedLyricLines: Int {
        didSet { UserDefaults.standard.set(collapsedLyricLines, forKey: "v2_collapsedLyricLines") }
    }
    /// 鼠标悬停展开延迟（秒），防止误触
    @Published var hoverDelaySeconds: Double {
        didSet { UserDefaults.standard.set(hoverDelaySeconds, forKey: "v2_hoverDelaySeconds") }
    }
    @Published var lyricsFontSize: Double {
        didSet { UserDefaults.standard.set(lyricsFontSize, forKey: "v2_lyricsFontSize") }
    }
    @Published var lyricsBarWidth: Double {
        didSet { UserDefaults.standard.set(lyricsBarWidth, forKey: "v2_lyricsBarWidth") }
    }
    @Published var glassOpacity: Double {
        didSet { UserDefaults.standard.set(glassOpacity, forKey: "v2_glassOpacity") }
    }
    @Published var lyricOffset: Double {
        didSet { UserDefaults.standard.set(lyricOffset, forKey: "v2_lyricOffset") }
    }
    /// 展开态歌词模式：true=紧凑 3 行，false=完整滚动
    @Published var compactExpandedLyrics: Bool {
        didSet { UserDefaults.standard.set(compactExpandedLyrics, forKey: "v2_compactExpandedLyrics") }
    }

    init() {
        let d = UserDefaults.standard
        self.showNotch = d.object(forKey: "v2_showNotch") as? Bool ?? true
        self.showCollapsedLyrics = d.object(forKey: "v2_showCollapsedLyrics") as? Bool ?? false
        self.collapsedLyricLines = d.object(forKey: "v2_collapsedLyricLines") as? Int ?? 2
        self.hoverDelaySeconds = d.object(forKey: "v2_hoverDelaySeconds") as? Double ?? 1.2
        self.lyricsFontSize = d.object(forKey: "v2_lyricsFontSize") as? Double ?? 13.0
        self.lyricsBarWidth = d.object(forKey: "v2_lyricsBarWidth") as? Double ?? 640.0
        self.glassOpacity = d.object(forKey: "v2_glassOpacity") as? Double ?? 0.48
        self.lyricOffset = d.object(forKey: "v2_lyricOffset") as? Double ?? 0.0
        self.compactExpandedLyrics = d.object(forKey: "v2_compactExpandedLyrics") as? Bool ?? true
    }
}
