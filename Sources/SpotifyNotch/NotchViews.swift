import SwiftUI

struct NotchRootView: View {
    @ObservedObject var panelController: NotchPanelController
    @ObservedObject var local: SpotifyLocalController
    @ObservedObject var lyrics: LRCLibClient
    @ObservedObject var webAPI: SpotifyWebAPIClient
    @ObservedObject var systemStatus: SystemStatusMonitor
    @ObservedObject var settings: AppSettings

    var body: some View {
        VStack(spacing: 6) {
            MorphingIslandContainer(
                panelController: panelController,
                local: local,
                lyrics: lyrics,
                webAPI: webAPI,
                systemStatus: systemStatus,
                settings: settings
            )

            if !panelController.isExpanded && !panelController.isDetached && settings.showCollapsedLyrics {
                CollapsedGlassLyricsPill(local: local, lyrics: lyrics, settings: settings)
                    .frame(width: CGFloat(settings.lyricsBarWidth))
                    .transition(.opacity.combined(with: .move(edge: .top)))
                    .onTapGesture {
                        withAnimation(.spring(response: 0.40, dampingFraction: 0.80)) {
                            panelController.isExpanded = true
                            panelController.isPinned = true
                        }
                    }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .preferredColorScheme(.dark)
    }
}

/// 单一持久化连续形变容器（严禁用 if/else 替换外层视图身份，确保 120Hz 连续弹簧形变不闪现）
private struct MorphingIslandContainer: View {
    @ObservedObject var panelController: NotchPanelController
    @ObservedObject var local: SpotifyLocalController
    @ObservedObject var lyrics: LRCLibClient
    @ObservedObject var webAPI: SpotifyWebAPIClient
    @ObservedObject var systemStatus: SystemStatusMonitor
    @ObservedObject var settings: AppSettings

    var body: some View {
        let isExpanded = panelController.isExpanded
        let isDetached = panelController.isDetached
        let isLarge = panelController.isLargeMode
        let width = panelController.currentIslandWidth
        let height = panelController.currentIslandHeight
        let topR: CGFloat = 6
        let botR: CGFloat = isExpanded ? 24 : 12
        let headerH = panelController.notchHeight + panelController.topBleed
        let bodyH = max(0, height - headerH)

        // 单一稳定视图树：外层尺寸与形状连续插值动画
        ZStack(alignment: .top) {
            // 背景层：整块统一的苹果原生液态玻璃（零上下断层、零横向黑条）
            Group {
                if isDetached {
                    Color.black.opacity(0.002)
                        .nativeLiquidGlass(
                            in: RoundedRectangle(cornerRadius: 24, style: .continuous),
                            tintOpacity: max(0.06, settings.glassOpacity * 0.28)
                        )
                } else {
                    Color.black.opacity(0.002)
                        .nativeLiquidGlass(
                            in: UnevenRoundedRectangle(
                                topLeadingRadius: 0,
                                bottomLeadingRadius: botR,
                                bottomTrailingRadius: botR,
                                topTrailingRadius: 0,
                                style: .continuous
                            ),
                            tintOpacity: max(0.10, settings.glassOpacity * 0.34)
                        )
                }
            }
            .opacity(isExpanded || isDetached ? 1 : 0)

            // 物理刘海融合层：全部保持常驻挂载、纯透明度插值（严禁 if/else 销毁重建导致收起瞬间闪烁）
            if !isDetached {
                let notchRatio = min(0.42, (panelController.notchWidth + 12) / max(width, 1))
                let halfNotch = notchRatio / 2.0
                let fadeSpan: Double = 0.14

                // 展开态中央物理刘海水平柔化黑带
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: max(0.0, 0.5 - halfNotch - fadeSpan)),
                        .init(color: .black, location: max(0.0, 0.5 - halfNotch)),
                        .init(color: .black, location: min(1.0, 0.5 + halfNotch)),
                        .init(color: .clear, location: min(1.0, 0.5 + halfNotch + fadeSpan))
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: width, height: headerH)
                .mask(
                    LinearGradient(
                        stops: [
                            .init(color: .black, location: 0.0),
                            .init(color: .black, location: 0.78),
                            .init(color: .clear, location: 1.0)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .opacity(isExpanded ? 1 : 0)
                .allowsHitTesting(false)

                // 收起态纯黑刘海本体：随尺寸连续缩放与渐隐渐现，收起过程丝滑不闪
                Color.black
                    .frame(width: width, height: height)
                    .clipShape(NotchShape(topCornerRadius: topR, bottomCornerRadius: botR))
                    .opacity(isExpanded ? 0 : 1)
                    .allowsHitTesting(false)
            }

            // 内容层 1：收起态纯黑刘海（左极靠边专辑 + 右极靠边波形与系统状态）
            if !isDetached {
                collapsedHeader
                    .frame(width: width, height: headerH)
                    .opacity(isExpanded ? 0 : 1)
                    .scaleEffect(isExpanded ? 0.92 : 1.0, anchor: .top)
                    .allowsHitTesting(!isExpanded)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.spring(response: 0.40, dampingFraction: 0.80)) {
                            panelController.isExpanded = true
                            panelController.isPinned = true
                        }
                    }
            }

            // 内容层 2：展开态统一液态玻璃界面（整块覆盖可点，绝不穿透到后方窗口）
            VStack(spacing: 0) {
                if !isDetached {
                    expandedTopHeader
                        .frame(width: width, height: headerH)
                }
                expandedBody(isLarge: isLarge)
                    .frame(width: width, height: isDetached ? height : bodyH)
            }
            .frame(width: width, height: height, alignment: .top)
            .background(Color.black.opacity(0.002))
            .contentShape(Rectangle())
            .opacity(isExpanded || isDetached ? 1 : 0)
            .scaleEffect(isExpanded || isDetached ? 1.0 : 0.92, anchor: .top)
            .allowsHitTesting(isExpanded || isDetached)
        }
        .frame(width: width, height: height, alignment: .top)
        .animation(.spring(response: 0.40, dampingFraction: 0.80), value: isExpanded)
        .animation(.spring(response: 0.36, dampingFraction: 0.82), value: isLarge)
        .animation(.spring(response: 0.28, dampingFraction: 0.78), value: panelController.isHoverPriming)
        .animation(.spring(response: 0.34, dampingFraction: 0.82), value: panelController.selectedTab)
        .onHover { hovering in
            panelController.handleHoverChange(hovering)
        }
    }

    private var collapsedHeader: some View {
        let extraW: CGFloat = panelController.isHoverPriming ? 8 : 0
        return HStack(spacing: 0) {
            HStack(spacing: 0) {
                ArtworkThumb(urlString: local.track?.artworkURL, size: 22)
                    .padding(.leading, 11)
                    .padding(.top, 2)
                Spacer(minLength: 0)
            }
            .frame(width: panelController.leftEarWidth + extraW / 2)

            Spacer()
                .frame(width: panelController.notchWidth)

            HStack(spacing: 5) {
                Spacer(minLength: 0)
                SystemStatusDotsView(
                    isMicActive: systemStatus.isMicActive,
                    isCameraActive: systemStatus.isCameraActive,
                    isScreenRecording: systemStatus.isScreenRecording
                )
                AudioWaveView(isPlaying: local.track?.isPlaying ?? false, maxHeight: 15)
                    .padding(.trailing, 11)
                    .padding(.top, 2)
            }
            .frame(width: panelController.rightEarWidth + extraW / 2)
        }
    }

    private var expandedTopHeader: some View {
        ZStack {
            // 上边缘空白区支持：单击固定（Pin），双击取消固定（Unpin）
            Color.black.opacity(0.002)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    panelController.isPinned = false
                    webAPI.showToast("已取消固定")
                }
                .onTapGesture(count: 1) {
                    if !panelController.isPinned {
                        panelController.isPinned = true
                        webAPI.showToast("已固定")
                    }
                }

            HStack(spacing: 0) {
                HStack(spacing: 8) {
                    ForEach(ExpandedTab.allCases, id: \.self) { tab in
                        Button(action: { panelController.selectedTab = tab }) {
                            Text(tab.rawValue)
                                .font(.system(size: 11, weight: panelController.selectedTab == tab ? .semibold : .regular))
                                .foregroundColor(panelController.selectedTab == tab ? .white : .white.opacity(0.48))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(panelController.selectedTab == tab ? Color.white.opacity(0.16) : Color.clear)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }

                    SystemStatusDotsView(
                        isMicActive: systemStatus.isMicActive,
                        isCameraActive: systemStatus.isCameraActive,
                        isScreenRecording: systemStatus.isScreenRecording
                    )
                }
                .padding(.leading, 12)
                .padding(.top, 2)

                Spacer()

                HStack(spacing: 10) {
                    if let toast = webAPI.toastMessage {
                        Text(toast)
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundColor(.white.opacity(0.88))
                    }
                    topActionButtons
                }
                .padding(.trailing, 12)
                .padding(.top, 2)
            }
        }
    }

    private func expandedBody(isLarge: Bool) -> some View {
        HStack(alignment: .center, spacing: isLarge ? 20 : 16) {
            // 左栏：歌曲控件（放大模式下封面与排版同步舒展）
            VStack(alignment: .leading, spacing: isLarge ? 12 : 6) {
                if panelController.isDetached {
                    HStack(spacing: 8) {
                        ForEach(ExpandedTab.allCases, id: \.self) { tab in
                            Button(action: { panelController.selectedTab = tab }) {
                                Text(tab.rawValue)
                                    .font(.system(size: 10.5, weight: panelController.selectedTab == tab ? .semibold : .regular))
                                    .foregroundColor(panelController.selectedTab == tab ? .white : .white.opacity(0.55))
                            }
                            .buttonStyle(.plain)
                        }
                        Spacer()
                        topActionButtons
                    }
                }

                if isLarge {
                    Spacer(minLength: 0)
                }

                HStack(spacing: isLarge ? 14 : 10) {
                    ArtworkThumb(urlString: local.track?.artworkURL, size: isLarge ? 78 : 50)
                        .shadow(color: .black.opacity(0.32), radius: 6, y: 2)

                    VStack(alignment: .leading, spacing: isLarge ? 4 : 2) {
                        Text(local.track?.name ?? "未在播放")
                            .font(.system(size: isLarge ? 16 : 13.5, weight: .bold))
                            .foregroundColor(.white)
                            .lineLimit(isLarge ? 2 : 1)
                        Text(local.track?.artist ?? "打开 Spotify 开始播放")
                            .font(.system(size: isLarge ? 13 : 11.5))
                            .foregroundColor(.white.opacity(0.76))
                            .lineLimit(1)
                        if isLarge, let album = local.track?.album, !album.isEmpty {
                            Text(album)
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.48))
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }

                if let track = local.track, track.duration > 0 {
                    HStack(spacing: 5) {
                        Text(formatTime(local.currentPosition))
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundColor(.white.opacity(0.58))
                        Slider(
                            value: Binding(
                                get: { min(local.currentPosition, track.duration) },
                                set: { local.seek(to: $0) }
                            ),
                            in: 0...max(track.duration, 1)
                        )
                        .tint(.white)
                        .controlSize(.mini)
                        Text(formatTime(track.duration))
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundColor(.white.opacity(0.58))
                    }
                }

                HStack(spacing: isLarge ? 18 : 14) {
                    Button(action: {
                        if let track = local.track { webAPI.toggleLike(for: track) }
                    }) {
                        Image(systemName: webAPI.isCurrentTrackLiked ? "heart.fill" : "heart")
                            .font(.system(size: isLarge ? 15 : 13))
                            .foregroundColor(webAPI.isCurrentTrackLiked ? .green : .white.opacity(0.75))
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    Button(action: { local.previousTrack() }) {
                        Image(systemName: "backward.fill")
                            .font(.system(size: isLarge ? 15 : 13))
                            .foregroundColor(.white)
                    }
                    .buttonStyle(.plain)

                    Button(action: { local.playPause() }) {
                        Image(systemName: (local.track?.isPlaying ?? false) ? "pause.fill" : "play.fill")
                            .font(.system(size: isLarge ? 22 : 17))
                            .foregroundColor(.white)
                    }
                    .buttonStyle(.plain)

                    Button(action: { local.nextTrack() }) {
                        Image(systemName: "forward.fill")
                            .font(.system(size: isLarge ? 15 : 13))
                            .foregroundColor(.white)
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    AudioWaveView(isPlaying: local.track?.isPlaying ?? false, maxHeight: isLarge ? 16 : 13)
                }

                if isLarge {
                    Spacer(minLength: 0)
                }
            }
            .frame(width: isLarge ? 276 : 236)

            Rectangle()
                .fill(Color.white.opacity(0.14))
                .frame(width: 0.7)
                .padding(.vertical, 10)

            // 右栏：纯粹长歌词栏目（放大后可显示 6–7 行） / 歌单 / 设置
            Group {
                switch panelController.selectedTab {
                case .lyrics:
                    FluidLyricsView(local: local, lyrics: lyrics, settings: settings, isLarge: isLarge)
                case .playlists:
                    PlaylistsTabView(local: local, webAPI: webAPI, isLarge: isLarge)
                case .settings:
                    SettingsTabView(settings: settings, webAPI: webAPI)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, isLarge ? 14 : 10)
    }

    private var topActionButtons: some View {
        HStack(spacing: 10) {
            // 放大 / 恢复紧凑按钮
            Button(action: {
                withAnimation(.spring(response: 0.36, dampingFraction: 0.82)) {
                    panelController.isLargeMode.toggle()
                }
            }) {
                Image(systemName: panelController.isLargeMode ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundColor(panelController.isLargeMode ? .white : .white.opacity(0.65))
            }
            .buttonStyle(.plain)
            .help(panelController.isLargeMode ? "恢复紧凑尺寸" : "放大面板以显示更多歌词")

            if !panelController.isDetached {
                Button(action: { panelController.isPinned.toggle() }) {
                    Image(systemName: panelController.isPinned ? "pin.fill" : "pin")
                        .font(.system(size: 11))
                        .foregroundColor(panelController.isPinned ? .white : .white.opacity(0.55))
                }
                .buttonStyle(.plain)
                .help(panelController.isPinned ? "取消固定（也可双击顶栏）" : "固定展开（也可单击顶栏）")
            }

            Button(action: { panelController.isDetached.toggle() }) {
                Image(systemName: panelController.isDetached ? "rectangle.topthird.inset.filled" : "macwindow.on.rectangle")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.68))
            }
            .buttonStyle(.plain)
            .help(panelController.isDetached ? "吸附回刘海" : "分离为可拖动液态玻璃窗")

            Button(action: {
                withAnimation(.spring(response: 0.36, dampingFraction: 0.84)) {
                    panelController.isDetached = false
                    panelController.isPinned = false
                    panelController.isLargeMode = false
                    panelController.isExpanded = false
                }
            }) {
                Image(systemName: "chevron.up")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.68))
            }
            .buttonStyle(.plain)
            .help("收归刘海")
        }
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

private struct CollapsedGlassLyricsPill: View {
    @ObservedObject var local: SpotifyLocalController
    @ObservedObject var lyrics: LRCLibClient
    @ObservedObject var settings: AppSettings

    var body: some View {
        let activeIdx = lyrics.activeLineIndex(at: local.currentPosition, offset: settings.lyricOffset)
        let prevText = activeIdx.flatMap { $0 > 0 ? lyrics.lines[$0 - 1].text : nil }
        let currText = activeIdx.map { lyrics.lines[$0].text }
        let nextText = activeIdx.flatMap { ($0 + 1 < lyrics.lines.count) ? lyrics.lines[$0 + 1].text : nil }

        VStack(spacing: 2) {
            if let track = local.track {
                if settings.collapsedLyricLines == 3, let prevText {
                    Text(prevText)
                        .font(.system(size: max(10.5, settings.lyricsFontSize - 2)))
                        .foregroundColor(.white.opacity(0.45))
                        .multilineTextAlignment(.center)
                        .lineLimit(1)
                }
                Text(currText ?? (lyrics.statusText.isEmpty ? "\(track.name) · \(track.artist)" : "\(track.name) — \(lyrics.statusText)"))
                    .font(.system(size: settings.lyricsFontSize, weight: .semibold))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if settings.collapsedLyricLines >= 2 {
                    Text(nextText ?? "\(track.name) · \(track.artist)")
                        .font(.system(size: max(10.5, settings.lyricsFontSize - 1.8)))
                        .foregroundColor(.white.opacity(0.62))
                        .multilineTextAlignment(.center)
                        .lineLimit(1)
                }
            } else {
                Text("Spotify 未在播放")
                    .font(.system(size: settings.lyricsFontSize - 1, weight: .medium))
                    .foregroundColor(.white.opacity(0.65))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .nativeLiquidGlass(
            in: RoundedRectangle(cornerRadius: 16, style: .continuous),
            tintOpacity: 0.14
        )
    }
}

/// 纯粹歌词视图：连贯聚焦放大、非当前句虚化缩放 + 上下边缘柔化渐隐遮罩
private struct FluidLyricsView: View {
    @ObservedObject var local: SpotifyLocalController
    @ObservedObject var lyrics: LRCLibClient
    @ObservedObject var settings: AppSettings
    var isLarge: Bool = false

    var body: some View {
        let activeIdx = lyrics.activeLineIndex(at: local.currentPosition, offset: settings.lyricOffset)

        if lyrics.lines.isEmpty {
            VStack {
                Spacer()
                Text(lyrics.statusText.isEmpty ? "暂无同步歌词" : lyrics.statusText)
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.55))
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: isLarge ? 10 : 7) {
                        Color.clear.frame(height: isLarge ? 36 : 22)

                        ForEach(Array(lyrics.lines.enumerated()), id: \.element.id) { idx, line in
                            let distance = activeIdx.map { abs(idx - $0) } ?? 2
                            let isCurrent = (distance == 0)
                            let scale: CGFloat = isCurrent ? 1.06 : (distance == 1 ? 0.92 : 0.86)
                            let opacity: Double = isCurrent ? 1.0 : (distance == 1 ? 0.50 : (distance == 2 ? 0.30 : 0.18))
                            let blurRadius: CGFloat = isCurrent ? 0 : (distance == 1 ? 0.50 : (distance == 2 ? 1.15 : 1.8))

                            Text(line.text)
                                .font(.system(
                                    size: settings.lyricsFontSize + (isLarge ? 2.5 : 1.0),
                                    weight: isCurrent ? .bold : .medium
                                ))
                                .foregroundColor(.white.opacity(opacity))
                                .scaleEffect(scale, anchor: .leading)
                                .blur(radius: blurRadius)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                                .id(line.id)
                                .animation(.spring(response: 0.44, dampingFraction: 0.84), value: activeIdx)
                                .onTapGesture {
                                    local.seek(to: line.time)
                                }
                        }

                        Color.clear.frame(height: isLarge ? 42 : 26)
                    }
                    .padding(.trailing, 8)
                }
                .mask(
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0.0),
                            .init(color: .black.opacity(0.35), location: 0.10),
                            .init(color: .black, location: 0.24),
                            .init(color: .black, location: 0.72),
                            .init(color: .black.opacity(0.30), location: 0.88),
                            .init(color: .clear, location: 1.0)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .onChange(of: activeIdx) { _, newIdx in
                    guard let newIdx, newIdx < lyrics.lines.count else { return }
                    withAnimation(.spring(response: 0.48, dampingFraction: 0.86)) {
                        proxy.scrollTo(lyrics.lines[newIdx].id, anchor: .center)
                    }
                }
                .onAppear {
                    if let idx = activeIdx, idx < lyrics.lines.count {
                        proxy.scrollTo(lyrics.lines[idx].id, anchor: .center)
                    }
                }
            }
        }
    }
}

/// 歌单页：每项展示歌单封面 + 清晰歌单名与曲目数，舒展排布且触控板顺滑滚动
private struct PlaylistsTabView: View {
    @ObservedObject var local: SpotifyLocalController
    @ObservedObject var webAPI: SpotifyWebAPIClient
    var isLarge: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !webAPI.isAuthenticated {
                Spacer()
                VStack(spacing: 6) {
                    Text("尚未授权 Spotify（Client ID / Secret 已预填）")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundColor(.white.opacity(0.9))
                    Button("一键连接 Spotify 账号") {
                        webAPI.startOAuthFlow()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .controlSize(.small)
                }
                .frame(maxWidth: .infinity)
                Spacer()
            } else {
                HStack {
                    Text("我的歌单（\(webAPI.playlists.count)）")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundColor(.white.opacity(0.78))
                    Spacer()
                    Button("刷新") { Task { await webAPI.fetchMyPlaylists() } }
                        .font(.system(size: 10.5))
                        .foregroundColor(.white.opacity(0.75))
                        .buttonStyle(.plain)
                }

                ScrollView(.vertical, showsIndicators: true) {
                    VStack(spacing: isLarge ? 8 : 6) {
                        ForEach(webAPI.playlists) { pl in
                            HStack(spacing: isLarge ? 12 : 10) {
                                ArtworkThumb(urlString: pl.imageURL, size: isLarge ? 46 : 38)
                                    .shadow(color: .black.opacity(0.28), radius: 4, y: 1)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(pl.name)
                                        .font(.system(size: isLarge ? 13 : 12, weight: .semibold))
                                        .foregroundColor(.white)
                                        .lineLimit(1)
                                    Text(pl.ownerName.isEmpty ? "\(pl.trackCount) 首" : "\(pl.trackCount) 首 · \(pl.ownerName)")
                                        .font(.system(size: isLarge ? 10.5 : 10))
                                        .foregroundColor(.white.opacity(0.55))
                                        .lineLimit(1)
                                }

                                Spacer(minLength: 6)

                                Button(action: {
                                    local.playURI("spotify:playlist:\(pl.id)")
                                    webAPI.showToast("播放「\(pl.name)」")
                                }) {
                                    Image(systemName: "play.fill")
                                        .font(.system(size: isLarge ? 11 : 10))
                                        .foregroundColor(.white)
                                        .padding(isLarge ? 7 : 6)
                                        .background(Color.white.opacity(0.18))
                                        .clipShape(Circle())
                                }
                                .buttonStyle(.plain)
                                .help("播放此歌单")

                                Button(action: {
                                    if let track = local.track { webAPI.addTrack(track, to: pl) }
                                }) {
                                    Image(systemName: "plus")
                                        .font(.system(size: isLarge ? 11.5 : 10.5, weight: .bold))
                                        .foregroundColor(.white.opacity(0.9))
                                        .padding(isLarge ? 7 : 6)
                                        .background(Color.white.opacity(0.14))
                                        .clipShape(Circle())
                                }
                                .buttonStyle(.plain)
                                .help("将当前歌曲加入此歌单")
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, isLarge ? 8 : 6)
                            .background(Color.white.opacity(0.08))
                            .cornerRadius(12)
                        }
                    }
                    .padding(.trailing, 4)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

private struct SettingsTabView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var webAPI: SpotifyWebAPIClient

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("收起态在刘海下方常驻歌词条", isOn: $settings.showCollapsedLyrics)
                    .font(.system(size: 11))

                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(String(format: "悬停延迟：%.1f 秒", settings.hoverDelaySeconds))
                            .font(.system(size: 10)).foregroundColor(.white.opacity(0.75))
                        Slider(value: $settings.hoverDelaySeconds, in: 0.5...2.5, step: 0.1).controlSize(.mini)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text("宽幅：\(Int(settings.lyricsBarWidth)) px")
                            .font(.system(size: 10)).foregroundColor(.white.opacity(0.75))
                        Slider(value: $settings.lyricsBarWidth, in: 560...820, step: 20).controlSize(.mini)
                    }
                }

                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("字号：\(String(format: "%.1f", settings.lyricsFontSize))")
                            .font(.system(size: 10)).foregroundColor(.white.opacity(0.75))
                        Slider(value: $settings.lyricsFontSize, in: 11...18, step: 0.5).controlSize(.mini)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(String(format: "玻璃暗度：%.0f%%", settings.glassOpacity * 100))
                            .font(.system(size: 10)).foregroundColor(.white.opacity(0.75))
                        Slider(value: $settings.glassOpacity, in: 0.10...0.80, step: 0.05).controlSize(.mini)
                    }
                }

                HStack {
                    Button(webAPI.isAuthenticated ? "重新授权 Spotify" : "连接 Spotify") {
                        webAPI.startOAuthFlow()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .controlSize(.small)

                    if webAPI.isAuthenticated {
                        Button("断开") { webAPI.disconnect() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                    Spacer()
                }
            }
        }
    }
}

private struct ArtworkThumb: View {
    let urlString: String?
    let size: CGFloat

    var body: some View {
        Group {
            if let urlString, let url = URL(string: urlString), !urlString.isEmpty {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    placeholderView
                }
            } else {
                placeholderView
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size > 36 ? 8 : 5, style: .continuous))
    }

    private var placeholderView: some View {
        ZStack {
            Color.white.opacity(0.12)
            Image(systemName: "music.note")
                .font(.system(size: size * 0.45))
                .foregroundColor(.white.opacity(0.55))
        }
    }
}
