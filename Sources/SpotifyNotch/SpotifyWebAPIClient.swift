import AppKit
import Foundation
import Network

/// 管理 Spotify Web API OAuth 授权与曲库操作，并与本地 spotify-mcp-server 共享令牌文件
final class SpotifyWebAPIClient: ObservableObject {
    @Published var credentials: SpotifyCredentials
    @Published private(set) var isAuthenticated: Bool = false
    @Published private(set) var isCurrentTrackLiked: Bool = false
    @Published private(set) var playlists: [SpotifyPlaylist] = []
    @Published private(set) var authStatusMessage: String = ""
    @Published private(set) var toastMessage: String?

    private var tokens: SpotifyTokens?
    private let storageURL: URL
    private let sharedMCPConfigURL: URL?
    private var listener: NWListener?

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("SpotifyNotch", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.storageURL = dir.appendingPathComponent("spotify-auth.json")
        if let envPath = ProcessInfo.processInfo.environment["SPOTIFY_MCP_CONFIG_PATH"], !envPath.isEmpty {
            self.sharedMCPConfigURL = URL(fileURLWithPath: envPath)
        } else {
            self.sharedMCPConfigURL = nil
        }
        self.credentials = SpotifyCredentials(clientID: "", clientSecret: "", redirectURI: SpotifyCredentials.defaultRedirectURI)
        loadStoredState()
    }

    private struct StoredAuth: Codable {
        var credentials: SpotifyCredentials
        var tokens: SpotifyTokens?
    }

    private struct SharedMCPConfig: Codable {
        var clientId: String
        var clientSecret: String
        var redirectUri: String
        var accessToken: String?
        var refreshToken: String?
        var expiresAt: Double?
    }

    func saveCredentials() {
        persistState()
    }

    func disconnect() {
        tokens = nil
        isAuthenticated = false
        isCurrentTrackLiked = false
        playlists = []
        authStatusMessage = "已断开连接"
        persistState()
    }

    func startOAuthFlow() {
        let clientID = credentials.clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let clientSecret = credentials.clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clientID.isEmpty, !clientSecret.isEmpty else {
            authStatusMessage = "请先填写 Client ID 和 Client Secret"
            return
        }
        persistState()

        let redirectURI = credentials.redirectURI.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: redirectURI), let portVal = url.port, let nwPort = NWEndpoint.Port(rawValue: UInt16(portVal)) else {
            authStatusMessage = "Redirect URI 格式无效，需包含本地端口"
            return
        }

        startLoopbackListener(port: nwPort)

        // 与 spotify-mcp-server 完全一致的 15 项完整 scope，一次授权两边通用
        let scopes = [
            "user-read-private",
            "user-read-email",
            "user-read-playback-state",
            "user-modify-playback-state",
            "user-read-currently-playing",
            "user-read-playback-position",
            "playlist-read-private",
            "playlist-read-collaborative",
            "playlist-modify-private",
            "playlist-modify-public",
            "user-library-read",
            "user-library-modify",
            "user-read-recently-played",
            "user-top-read",
            "user-follow-read"
        ].joined(separator: " ")

        var comps = URLComponents(string: "https://accounts.spotify.com/authorize")!
        comps.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "scope", value: scopes),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "show_dialog", value: "true")
        ]
        if let authURL = comps.url {
            authStatusMessage = "请在浏览器中完成 Spotify 授权..."
            NSWorkspace.shared.open(authURL)
        }
    }

    private func startLoopbackListener(port: NWEndpoint.Port) {
        listener?.cancel()
        do {
            let newListener = try NWListener(using: .tcp, on: port)
            newListener.newConnectionHandler = { [weak self] conn in
                self?.handleLoopbackConnection(conn)
            }
            newListener.start(queue: .global(qos: .userInitiated))
            self.listener = newListener
        } catch {
            DispatchQueue.main.async {
                self.authStatusMessage = "本地回调端口启动失败：\(error.localizedDescription)"
            }
        }
    }

    private func handleLoopbackConnection(_ conn: NWConnection) {
        conn.start(queue: .global(qos: .userInitiated))
        conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            guard let self, let data, let requestStr = String(data: data, encoding: .utf8) else {
                conn.cancel()
                return
            }
            let firstLine = requestStr.components(separatedBy: "\r\n").first ?? ""
            let parts = firstLine.split(separator: " ")
            var code: String?
            if parts.count >= 2, let comps = URLComponents(string: "http://127.0.0.1" + String(parts[1])) {
                code = comps.queryItems?.first(where: { $0.name == "code" })?.value
            }

            let html = code != nil
                ? "<html><body style='font-family:-apple-system;padding:32px;background:#111;color:#eee;'><h2>Spotify 授权成功</h2><p>SpotifyNotch 与本机 Spotify MCP 已同步激活，可以关闭此页面。</p></body></html>"
                : "<html><body style='font-family:-apple-system;padding:32px;background:#111;color:#eee;'><h2>授权未完成</h2><p>未收到授权码，请重试。</p></body></html>"
            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nConnection: close\r\n\r\n" + html
            conn.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
                conn.cancel()
            })

            if let code {
                self.listener?.cancel()
                self.listener = nil
                Task {
                    await self.exchangeCodeForTokens(code: code)
                }
            }
        }
    }

    private struct TokenResponse: Decodable {
        let access_token: String
        let refresh_token: String?
        let expires_in: Int
    }

    private func exchangeCodeForTokens(code: String) async {
        var req = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let basic = Data("\(credentials.clientID):\(credentials.clientSecret)".utf8).base64EncodedString()
        req.setValue("Basic \(basic)", forHTTPHeaderField: "Authorization")

        var body = URLComponents()
        body.queryItems = [
            URLQueryItem(name: "grant_type", value: "authorization_code"),
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "redirect_uri", value: credentials.redirectURI)
        ]
        req.httpBody = body.percentEncodedQuery?.data(using: .utf8)

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                await MainActor.run { self.authStatusMessage = "换取令牌失败，请检查 Client ID / Secret 与 Redirect URI" }
                return
            }
            let decoded = try JSONDecoder().decode(TokenResponse.self, from: data)
            let newTokens = SpotifyTokens(
                accessToken: decoded.access_token,
                refreshToken: decoded.refresh_token ?? "",
                expiresAt: Date().addingTimeInterval(TimeInterval(decoded.expires_in - 60))
            )
            await MainActor.run {
                self.tokens = newTokens
                self.isAuthenticated = true
                self.authStatusMessage = "已连接 Spotify（已同步至本机 MCP）"
                self.persistState()
                self.showToast("Spotify 授权成功")
            }
            await fetchMyPlaylists()
        } catch {
            await MainActor.run { self.authStatusMessage = "授权请求出错：\(error.localizedDescription)" }
        }
    }

    private func validAccessToken() async -> String? {
        guard let tokens else { return nil }
        if Date() < tokens.expiresAt {
            return tokens.accessToken
        }
        guard !tokens.refreshToken.isEmpty else { return nil }
        var req = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let basic = Data("\(credentials.clientID):\(credentials.clientSecret)".utf8).base64EncodedString()
        req.setValue("Basic \(basic)", forHTTPHeaderField: "Authorization")

        var body = URLComponents()
        body.queryItems = [
            URLQueryItem(name: "grant_type", value: "refresh_token"),
            URLQueryItem(name: "refresh_token", value: tokens.refreshToken)
        ]
        req.httpBody = body.percentEncodedQuery?.data(using: .utf8)

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            let decoded = try JSONDecoder().decode(TokenResponse.self, from: data)
            let updated = SpotifyTokens(
                accessToken: decoded.access_token,
                refreshToken: decoded.refresh_token ?? tokens.refreshToken,
                expiresAt: Date().addingTimeInterval(TimeInterval(decoded.expires_in - 60))
            )
            await MainActor.run {
                self.tokens = updated
                self.persistState()
            }
            return updated.accessToken
        } catch {
            return nil
        }
    }

    func refreshLikeState(for track: TrackInfo) {
        guard isAuthenticated, let trackID = track.spotifyTrackID else {
            DispatchQueue.main.async { self.isCurrentTrackLiked = false }
            return
        }
        Task {
            guard let token = await validAccessToken(),
                  let url = URL(string: "https://api.spotify.com/v1/me/tracks/contains?ids=\(trackID)") else { return }
            var req = URLRequest(url: url)
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            do {
                let (data, resp) = try await URLSession.shared.data(for: req)
                guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else { return }
                let arr = try JSONDecoder().decode([Bool].self, from: data)
                await MainActor.run {
                    self.isCurrentTrackLiked = arr.first ?? false
                }
            } catch {}
        }
    }

    func toggleLike(for track: TrackInfo) {
        guard isAuthenticated else {
            showToast("请先点击「设置 → 连接 Spotify」")
            return
        }
        guard let trackID = track.spotifyTrackID else { return }
        let targetLike = !isCurrentTrackLiked
        Task {
            guard let token = await validAccessToken(),
                  let url = URL(string: "https://api.spotify.com/v1/me/tracks?ids=\(trackID)") else { return }
            var req = URLRequest(url: url)
            req.httpMethod = targetLike ? "PUT" : "DELETE"
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            do {
                let (_, resp) = try await URLSession.shared.data(for: req)
                if let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) {
                    await MainActor.run {
                        self.isCurrentTrackLiked = targetLike
                        self.showToast(targetLike ? "已加入喜欢" : "已取消喜欢")
                    }
                }
            } catch {}
        }
    }

    func fetchMyPlaylists() async {
        guard let token = await validAccessToken(),
              let playlistsURL = URL(string: "https://api.spotify.com/v1/me/playlists?limit=50") else { return }
        var req = URLRequest(url: playlistsURL)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        struct PlaylistsResp: Decodable {
            struct Item: Decodable {
                struct Owner: Decodable { let display_name: String? }
                struct TrackRef: Decodable { let total: Int? }
                struct ImageObj: Decodable { let url: String }
                let id: String
                let name: String
                let owner: Owner?
                let images: [ImageObj]?
                // Spotify 2026 Web API 将 tracks 字段迁为 items
                let items: TrackRef?
                let tracks: TrackRef?
            }
            let items: [Item]
        }

        struct RecentlyPlayedResp: Decodable {
            struct PlayItem: Decodable {
                struct Context: Decodable { let uri: String? }
                let context: Context?
            }
            let items: [PlayItem]
        }

        let playlistsReq = req
        do {
            // 并行拉取用户歌单与最近播放记录，按最近播放顺序排布歌单
            async let playlistsResult = URLSession.shared.data(for: playlistsReq)

            var recentOrder: [String: Int] = [:]
            if let recentURL = URL(string: "https://api.spotify.com/v1/me/player/recently-played?limit=50") {
                var recentReq = URLRequest(url: recentURL)
                recentReq.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                if let (recentData, recentResp) = try? await URLSession.shared.data(for: recentReq),
                   let rHttp = recentResp as? HTTPURLResponse, rHttp.statusCode == 200,
                   let recentDecoded = try? JSONDecoder().decode(RecentlyPlayedResp.self, from: recentData) {
                    var rank = 0
                    for entry in recentDecoded.items {
                        guard let uri = entry.context?.uri, uri.hasPrefix("spotify:playlist:") else { continue }
                        let pid = String(uri.dropFirst("spotify:playlist:".count))
                        if recentOrder[pid] == nil {
                            recentOrder[pid] = rank
                            rank += 1
                        }
                    }
                }
            }

            let (data, resp) = try await playlistsResult
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else { return }
            let decoded = try JSONDecoder().decode(PlaylistsResp.self, from: data)
            let mapped = decoded.items.enumerated().map { idx, item in
                (
                    originalIndex: idx,
                    playlist: SpotifyPlaylist(
                        id: item.id,
                        name: item.name,
                        trackCount: item.items?.total ?? item.tracks?.total ?? 0,
                        ownerName: item.owner?.display_name ?? "",
                        imageURL: item.images?.first?.url
                    )
                )
            }
            let sorted = mapped.sorted { a, b in
                let ra = recentOrder[a.playlist.id] ?? Int.max
                let rb = recentOrder[b.playlist.id] ?? Int.max
                if ra != rb { return ra < rb }
                return a.originalIndex < b.originalIndex
            }.map(\.playlist)

            await MainActor.run {
                self.playlists = sorted
            }
        } catch {}
    }

    func addTrack(_ track: TrackInfo, to playlist: SpotifyPlaylist) {
        guard isAuthenticated else {
            showToast("请先连接 Spotify")
            return
        }
        let uri = track.id.hasPrefix("spotify:track:") ? track.id : "spotify:track:\(track.spotifyTrackID ?? "")"
        Task {
            guard let token = await validAccessToken(),
                  let url = URL(string: "https://api.spotify.com/v1/playlists/\(playlist.id)/items") else { return }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONEncoder().encode(["uris": [uri]])
            do {
                let (_, resp) = try await URLSession.shared.data(for: req)
                if let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) {
                    await MainActor.run {
                        self.showToast("已加入「\(playlist.name)」")
                    }
                    await fetchMyPlaylists()
                } else {
                    await MainActor.run {
                        self.showToast("加入歌单失败，请确认歌单可编辑")
                    }
                }
            } catch {}
        }
    }

    func showToast(_ msg: String) {
        DispatchQueue.main.async {
            self.toastMessage = msg
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
                if self.toastMessage == msg {
                    self.toastMessage = nil
                }
            }
        }
    }

    private func loadStoredState() {
        if let sharedURL = sharedMCPConfigURL,
           let data = try? Data(contentsOf: sharedURL),
           let shared = try? JSONDecoder().decode(SharedMCPConfig.self, from: data) {
            self.credentials = SpotifyCredentials(
                clientID: shared.clientId,
                clientSecret: shared.clientSecret,
                redirectURI: shared.redirectUri
            )
            if let at = shared.accessToken, let rt = shared.refreshToken, !at.isEmpty, !rt.isEmpty {
                let expDate = Date(timeIntervalSince1970: (shared.expiresAt ?? 0) / 1000.0)
                self.tokens = SpotifyTokens(accessToken: at, refreshToken: rt, expiresAt: expDate)
                self.isAuthenticated = true
                self.authStatusMessage = "已连接 Spotify"
                Task { await fetchMyPlaylists() }
                return
            }
        }

        guard let data = try? Data(contentsOf: storageURL),
              let stored = try? JSONDecoder().decode(StoredAuth.self, from: data) else { return }
        self.credentials = stored.credentials
        self.tokens = stored.tokens
        self.isAuthenticated = stored.tokens != nil
        if self.isAuthenticated {
            self.authStatusMessage = "已连接 Spotify"
            Task { await fetchMyPlaylists() }
        }
    }

    private func persistState() {
        let stored = StoredAuth(credentials: credentials, tokens: tokens)
        if let data = try? JSONEncoder().encode(stored) {
            try? data.write(to: storageURL, options: .atomic)
        }
        if let sharedURL = sharedMCPConfigURL,
           FileManager.default.fileExists(atPath: sharedURL.deletingLastPathComponent().path) {
            let shared = SharedMCPConfig(
                clientId: credentials.clientID,
                clientSecret: credentials.clientSecret,
                redirectUri: credentials.redirectURI,
                accessToken: tokens?.accessToken,
                refreshToken: tokens?.refreshToken,
                expiresAt: tokens.map { $0.expiresAt.timeIntervalSince1970 * 1000.0 }
            )
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? enc.encode(shared) {
                try? data.write(to: sharedURL, options: .atomic)
            }
        }
    }
}
