import AppKit
import Combine
import SwiftUI

/// 无焦点悬浮面板，透明区域点击穿透，分离后支持任意非控件区域拖动
final class FloatingNotchPanel: NSPanel {
    var allowsKeyFocus: Bool = false

    override var canBecomeKey: Bool { allowsKeyFocus }
    override var canBecomeMain: Bool { false }
}

/// 自定义 HostingView：在固定透明画布上只响应实际可见灵动岛区域的点击/悬停，其余区域完全穿透给下层应用
final class InteractiveNotchHostingView<Content: View>: NSHostingView<Content> {
    var activeRectProvider: (() -> NSRect)?
    var isDetachedProvider: (() -> Bool)?

    override func hitTest(_ point: NSPoint) -> NSView? {
        if let activeRect = activeRectProvider?() {
            guard activeRect.contains(point) else { return nil }
            // 在可见灵动岛区域内，即使点在按钮间隙也由面板吞掉事件，绝不穿透到后方窗口
            return super.hitTest(point) ?? self
        }
        return super.hitTest(point)
    }
}

final class NotchPanelController: ObservableObject {
    @Published var isExpanded: Bool = false {
        didSet {
            if isExpanded { isHoverPriming = false }
        }
    }
    @Published var isHoverPriming: Bool = false
    @Published var isPinned: Bool = false
    @Published var isLargeMode: Bool = false {
        didSet {
            if isDetached {
                updatePanelCanvasFrame()
            }
        }
    }
    @Published var isDetached: Bool = false {
        didSet {
            panel.isMovableByWindowBackground = isDetached
            if isDetached {
                isExpanded = true
                isPinned = true
            }
            updatePanelCanvasFrame()
        }
    }
    @Published var selectedTab: ExpandedTab = .lyrics {
        didSet {
            panel.allowsKeyFocus = (selectedTab == .settings)
            if selectedTab == .settings {
                panel.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            } else if selectedTab == .playlists && webAPI.isAuthenticated {
                Task { await webAPI.fetchMyPlaylists() }
            }
            if isDetached {
                updatePanelCanvasFrame()
            }
        }
    }

    let localController: SpotifyLocalController
    let lyricsClient: LRCLibClient
    let webAPI: SpotifyWebAPIClient
    let systemStatus: SystemStatusMonitor
    let settings: AppSettings

    /// 物理刘海尺寸：高度 +6pt（约 1.2–1.5mm）严丝合缝盖住物理刘海
    let notchWidth: CGFloat
    let notchHeight: CGFloat
    let hasPhysicalNotch: Bool

    /// 刘海模式下的固定透明画布尺寸（足够容纳放大态 760×280，确保全程 120Hz 丝滑形变）
    let notchCanvasWidth: CGFloat = 860
    let notchCanvasHeight: CGFloat = 340
    let topBleed: CGFloat = 2.0

    private let panel: FloatingNotchPanel
    private var statusItem: NSStatusItem?
    private var cancellables = Set<AnyCancellable>()
    private var hoverCollapseWorkItem: DispatchWorkItem?
    private var hoverExpandWorkItem: DispatchWorkItem?
    private var dragEventMonitor: Any?

    init() {
        self.localController = SpotifyLocalController()
        self.lyricsClient = LRCLibClient()
        self.webAPI = SpotifyWebAPIClient()
        self.systemStatus = SystemStatusMonitor()
        self.settings = AppSettings()

        let notchScreen = Self.preferredNotchScreen()
        let topInset = notchScreen?.safeAreaInsets.top ?? 0
        let leftW = notchScreen?.auxiliaryTopLeftArea?.width ?? 0
        let rightW = notchScreen?.auxiliaryTopRightArea?.width ?? 0
        if topInset > 0 && leftW > 0 && rightW > 0, let s = notchScreen {
            self.notchWidth = max(172, s.frame.width - leftW - rightW)
            self.notchHeight = topInset + 6.0
            self.hasPhysicalNotch = true
        } else {
            self.notchWidth = 180
            self.notchHeight = 38.0
            self.hasPhysicalNotch = false
        }

        self.panel = FloatingNotchPanel(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 250),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        configurePanel()
        configureStatusItem()
        installDetachedDragMonitor()
        bindControllers()
        updatePanelCanvasFrame()
        panel.orderFrontRegardless()
    }

    deinit {
        if let dragEventMonitor {
            NSEvent.removeMonitor(dragEventMonitor)
        }
    }

    private static func preferredNotchScreen() -> NSScreen? {
        if let builtInNotch = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) {
            return builtInNotch
        }
        return NSScreen.main ?? NSScreen.screens.first
    }

    var leftEarWidth: CGFloat { 42 }
    var rightEarWidth: CGFloat {
        let hasStatus = systemStatus.isMicActive || systemStatus.isCameraActive || systemStatus.isScreenRecording
        return hasStatus ? 62 : 42
    }
    var collapsedNotchWidth: CGFloat { notchWidth + leftEarWidth + rightEarWidth }

    var currentIslandWidth: CGFloat {
        if isDetached { return isLargeMode ? 720 : 580 }
        if isExpanded {
            return isLargeMode
                ? max(740, CGFloat(min(settings.lyricsBarWidth + 100, 820)))
                : max(600, CGFloat(min(settings.lyricsBarWidth, 720)))
        }
        return collapsedNotchWidth + (isHoverPriming ? 8 : 0)
    }

    var currentIslandHeight: CGFloat {
        if isDetached {
            if isLargeMode { return 244 }
            return (selectedTab == .lyrics) ? 132 : 198
        }
        if isExpanded {
            if isLargeMode {
                return notchHeight + 236 + topBleed
            }
            return (selectedTab == .lyrics) ? (notchHeight + 110 + topBleed) : (notchHeight + 174 + topBleed)
        }
        return notchHeight + topBleed + (isHoverPriming ? 3 : 0)
    }

    /// 计算当前可见灵动岛在窗口坐标系中的点击热区（AppKit 原点在左下角）
    private func currentInteractiveRect() -> NSRect {
        if isDetached {
            return NSRect(origin: .zero, size: panel.frame.size)
        }
        let canvasW = panel.frame.width
        let canvasH = panel.frame.height
        let w: CGFloat
        let h: CGFloat
        if isExpanded {
            w = currentIslandWidth
            h = currentIslandHeight
        } else if settings.showCollapsedLyrics {
            w = max(collapsedNotchWidth, CGFloat(settings.lyricsBarWidth))
            h = currentIslandHeight + 88
        } else {
            w = currentIslandWidth + 6
            h = currentIslandHeight + 4
        }
        return NSRect(x: (canvasW - w) / 2.0, y: canvasH - h, width: w, height: h)
    }

    private func configurePanel() {
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 3)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovable = true
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false

        let rootView = NotchRootView(
            panelController: self,
            local: localController,
            lyrics: lyricsClient,
            webAPI: webAPI,
            systemStatus: systemStatus,
            settings: settings
        )
        let hosting = InteractiveNotchHostingView(rootView: rootView)
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        hosting.activeRectProvider = { [weak self] in
            self?.currentInteractiveRect() ?? .zero
        }
        hosting.isDetachedProvider = { [weak self] in
            self?.isDetached ?? false
        }
        panel.contentView = hosting
    }

    /// 分离态全局拖动手势监听：点击卡片任意非按钮/非滑块区域并拖动即可直接拖拽整个悬浮窗
    private func installDetachedDragMonitor() {
        dragEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDragged) { [weak self] event in
            guard let self, self.isDetached, event.window === self.panel else {
                return event
            }
            // 若正在拖动进度条滑块则放行给 Slider，其余区域直接调用原生窗口拖动
            if let hitView = self.panel.contentView?.hitTest(event.locationInWindow) {
                var cursor: NSView? = hitView
                while let v = cursor {
                    if v is NSSlider || v is NSTextField || v is NSScroller {
                        return event
                    }
                    cursor = v.superview
                }
            }
            self.panel.performDrag(with: event)
            return nil
        }
    }

    func beginWindowDrag() {
        guard isDetached, let event = NSApp.currentEvent else { return }
        panel.performDrag(with: event)
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "music.note", accessibilityDescription: "SpotifyNotch")
            button.action = #selector(statusItemClicked(_:))
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        self.statusItem = item
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp {
            let menu = NSMenu()
            menu.addItem(NSMenuItem(title: settings.showNotch ? "隐藏音乐灵动岛" : "显示音乐灵动岛", action: #selector(toggleVisibility), keyEquivalent: ""))
            menu.addItem(NSMenuItem(title: settings.showCollapsedLyrics ? "关闭收起态常驻歌词" : "开启收起态常驻歌词", action: #selector(toggleCollapsedLyrics), keyEquivalent: ""))
            menu.addItem(NSMenuItem(title: isDetached ? "吸附回 MacBook 刘海" : "分离为可拖动玻璃窗", action: #selector(toggleDetached), keyEquivalent: ""))
            menu.addItem(NSMenuItem(title: "打开设置与 Spotify 登录", action: #selector(openSettingsPanel), keyEquivalent: ","))
            menu.addItem(.separator())
            menu.addItem(NSMenuItem(title: "退出 SpotifyNotch", action: #selector(quitApp), keyEquivalent: "q"))
            menu.items.forEach { $0.target = self }
            statusItem?.menu = menu
            statusItem?.button?.performClick(nil)
            statusItem?.menu = nil
        } else {
            if !settings.showNotch {
                settings.showNotch = true
                panel.orderFrontRegardless()
            }
            if isExpanded {
                isPinned = false
                isExpanded = false
            } else {
                isExpanded = true
                isPinned = true
            }
        }
    }

    @objc private func toggleVisibility() {
        settings.showNotch.toggle()
        if settings.showNotch {
            panel.orderFrontRegardless()
            updatePanelCanvasFrame()
        } else {
            isExpanded = false
            isPinned = false
            panel.orderOut(nil)
        }
    }

    @objc private func toggleCollapsedLyrics() {
        settings.showCollapsedLyrics.toggle()
    }

    @objc private func toggleDetached() {
        isDetached.toggle()
    }

    @objc private func openSettingsPanel() {
        settings.showNotch = true
        panel.orderFrontRegardless()
        isExpanded = true
        isPinned = true
        selectedTab = .settings
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    func handleHoverChange(_ hovering: Bool) {
        guard !isDetached else { return }
        hoverCollapseWorkItem?.cancel()
        hoverExpandWorkItem?.cancel()

        if hovering {
            if !isExpanded {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.78)) {
                    self.isHoverPriming = true
                }
                let delay = max(0.4, settings.hoverDelaySeconds)
                let work = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    if self.isHoverPriming && !self.isExpanded {
                        withAnimation(.spring(response: 0.38, dampingFraction: 0.80)) {
                            self.isHoverPriming = false
                            self.isExpanded = true
                        }
                    }
                }
                hoverExpandWorkItem = work
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
            }
        } else {
            if isHoverPriming {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                    self.isHoverPriming = false
                }
            }
            guard isExpanded && !isPinned else { return }
            let work = DispatchWorkItem { [weak self] in
                guard let self, !self.isPinned else { return }
                withAnimation(.spring(response: 0.36, dampingFraction: 0.84)) {
                    self.isExpanded = false
                }
            }
            hoverCollapseWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.30, execute: work)
        }
    }

    private func bindControllers() {
        localController.onTrackChanged = { [weak self] track in
            guard let self else { return }
            self.lyricsClient.fetchLyrics(for: track)
            self.webAPI.refreshLikeState(for: track)
        }

        settings.objectWillChange
            .debounce(for: .milliseconds(40), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                if self.settings.showNotch {
                    self.panel.orderFrontRegardless()
                } else {
                    self.panel.orderOut(nil)
                }
            }
            .store(in: &cancellables)
    }

    /// 刘海模式下画布固定不变，仅在切换分离/吸附模式时更新 NSWindow frame
    func updatePanelCanvasFrame() {
        guard let screen = Self.preferredNotchScreen() else { return }

        if isDetached {
            let width = currentIslandWidth
            let height = currentIslandHeight
            var origin = panel.frame.origin
            // 首次从刘海分离时放置在屏幕上中部，之后保持用户拖动位置
            if origin.y + panel.frame.height >= screen.frame.maxY - 6 || panel.frame.width > 700 {
                origin = NSPoint(x: round(screen.frame.midX - width / 2.0), y: round(screen.visibleFrame.maxY - height - 36))
            }
            panel.setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: true, animate: false)
        } else {
            let x = round(screen.frame.midX - notchCanvasWidth / 2.0)
            let y = screen.frame.maxY + topBleed - notchCanvasHeight
            panel.setFrame(NSRect(x: x, y: y, width: notchCanvasWidth, height: notchCanvasHeight), display: true, animate: false)
        }
    }
}
