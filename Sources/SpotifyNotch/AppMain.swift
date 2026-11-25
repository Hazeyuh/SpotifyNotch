import AppKit

@main
final class SpotifyNotchApp: NSObject, NSApplicationDelegate {
    private var panelController: NotchPanelController?

    static func main() {
        let app = NSApplication.shared
        let delegate = SpotifyNotchApp()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        panelController = NotchPanelController()
    }
}
