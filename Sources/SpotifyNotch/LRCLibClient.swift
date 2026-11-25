import Foundation

/// 对接免费开源的 LRCLIB 同步歌词库，并提供本地磁盘缓存
final class LRCLibClient: ObservableObject {
    @Published private(set) var lines: [LyricLine] = []
    @Published private(set) var statusText: String = ""
    @Published private(set) var isLoading: Bool = false

    private var cache: [String: CachedLyrics] = [:]
    private let cacheURL: URL
    private var currentTask: Task<Void, Never>?

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("SpotifyNotch", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.cacheURL = dir.appendingPathComponent("lyrics-cache.json")
        loadCache()
    }

    func fetchLyrics(for track: TrackInfo) {
        currentTask?.cancel()
        let key = track.cacheKey

        if let cached = cache[key] {
            DispatchQueue.main.async {
                self.lines = cached.lines
                self.isLoading = false
                self.statusText = cached.instrumental ? "纯音乐" : (cached.lines.isEmpty ? "暂无同步歌词" : "")
            }
            return
        }

        DispatchQueue.main.async {
            self.lines = []
            self.isLoading = true
            self.statusText = "正在获取歌词..."
        }

        currentTask = Task {
            let result = await queryLRCLib(track: track)
            if Task.isCancelled { return }
            await MainActor.run {
                self.isLoading = false
                if let result {
                    self.cache[key] = result
                    self.saveCache()
                    self.lines = result.lines
                    if result.instrumental {
                        self.statusText = "纯音乐"
                    } else if result.lines.isEmpty {
                        self.statusText = "暂无同步歌词"
                    } else {
                        self.statusText = ""
                    }
                } else {
                    self.lines = []
                    self.statusText = "未找到歌词"
                }
            }
        }
    }

    func activeLineIndex(at position: TimeInterval, offset: TimeInterval = 0) -> Int? {
        guard !lines.isEmpty else { return nil }
        let adjusted = position + offset
        var active: Int?
        for (idx, line) in lines.enumerated() {
            if line.time <= adjusted {
                active = idx
            } else {
                break
            }
        }
        return active
    }

    private func queryLRCLib(track: TrackInfo) async -> CachedLyrics? {
        // 1. 精确查询 /api/get
        var comps = URLComponents(string: "https://lrclib.net/api/get")!
        comps.queryItems = [
            URLQueryItem(name: "track_name", value: track.name),
            URLQueryItem(name: "artist_name", value: track.artist),
            URLQueryItem(name: "album_name", value: track.album),
            URLQueryItem(name: "duration", value: String(Int(round(track.duration))))
        ]
        if let url = comps.url, let hit = await requestSingle(url: url, cacheKey: track.cacheKey) {
            return hit
        }

        // 2. 回退模糊搜索 /api/search
        var searchComps = URLComponents(string: "https://lrclib.net/api/search")!
        searchComps.queryItems = [
            URLQueryItem(name: "track_name", value: track.name),
            URLQueryItem(name: "artist_name", value: track.artist)
        ]
        guard let searchURL = searchComps.url else { return nil }
        return await requestSearch(url: searchURL, track: track)
    }

    private struct LRCLibRecord: Decodable {
        let instrumental: Bool?
        let syncedLyrics: String?
        let plainLyrics: String?
        let duration: Double?
    }

    private func makeRequest(url: URL) -> URLRequest {
        var req = URLRequest(url: url, timeoutInterval: 8)
        req.setValue("SpotifyNotch/0.1 (macOS SwiftUI Personal Player)", forHTTPHeaderField: "User-Agent")
        return req
    }

    private func requestSingle(url: URL, cacheKey: String) async -> CachedLyrics? {
        do {
            let (data, resp) = try await URLSession.shared.data(for: makeRequest(url: url))
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            let record = try JSONDecoder().decode(LRCLibRecord.self, from: data)
            return buildCachedLyrics(from: record, key: cacheKey)
        } catch {
            return nil
        }
    }

    private func requestSearch(url: URL, track: TrackInfo) async -> CachedLyrics? {
        do {
            let (data, resp) = try await URLSession.shared.data(for: makeRequest(url: url))
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            let records = try JSONDecoder().decode([LRCLibRecord].self, from: data)
            // 优先挑选带同步歌词且时长最接近的条目
            let synced = records.filter { ($0.syncedLyrics ?? "").isEmpty == false }
            let best = (synced.isEmpty ? records : synced).min { a, b in
                abs((a.duration ?? track.duration) - track.duration) < abs((b.duration ?? track.duration) - track.duration)
            }
            guard let best else { return nil }
            return buildCachedLyrics(from: best, key: track.cacheKey)
        } catch {
            return nil
        }
    }

    private func buildCachedLyrics(from record: LRCLibRecord, key: String) -> CachedLyrics {
        let parsed = parseLRC(record.syncedLyrics ?? "")
        return CachedLyrics(
            key: key,
            lines: parsed,
            plainLyrics: record.plainLyrics,
            instrumental: record.instrumental ?? false,
            fetchedAt: Date()
        )
    }

    private func parseLRC(_ raw: String) -> [LyricLine] {
        let pattern = #"\[(\d{1,2}):(\d{2})(?:\.(\d{1,3}))?\](.*)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        var result: [LyricLine] = []
        var nextID = 0

        for line in raw.components(separatedBy: .newlines) {
            let nsLine = line as NSString
            let range = NSRange(location: 0, length: nsLine.length)
            guard let match = regex.firstMatch(in: line, range: range) else { continue }

            let minStr = nsLine.substring(with: match.range(at: 1))
            let secStr = nsLine.substring(with: match.range(at: 2))
            let fracStr = match.range(at: 3).location != NSNotFound ? nsLine.substring(with: match.range(at: 3)) : "0"
            let text = nsLine.substring(with: match.range(at: 4)).trimmingCharacters(in: .whitespaces)
            if text.isEmpty { continue }

            let minutes = Double(minStr) ?? 0
            let seconds = Double(secStr) ?? 0
            let fracDivisor = pow(10.0, Double(fracStr.count))
            let fraction = (Double(fracStr) ?? 0) / fracDivisor
            let timestamp = minutes * 60.0 + seconds + fraction

            result.append(LyricLine(id: nextID, time: timestamp, text: text))
            nextID += 1
        }
        return result.sorted { $0.time < $1.time }
    }

    private func loadCache() {
        guard let data = try? Data(contentsOf: cacheURL),
              let decoded = try? JSONDecoder().decode([String: CachedLyrics].self, from: data) else {
            return
        }
        cache = decoded
    }

    private func saveCache() {
        if let data = try? JSONEncoder().encode(cache) {
            try? data.write(to: cacheURL, options: .atomic)
        }
    }
}
