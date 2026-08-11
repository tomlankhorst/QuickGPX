import Cocoa

// Minimal host app. Its only job is to carry the Quick Look preview and
// thumbnail extensions; launching it once registers them with the system.

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 190),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: false)
        window.title = "QuickGPX"
        window.center()

        let label = NSTextField(wrappingLabelWithString: """
        The QuickGPX Quick Look extensions are installed.

        Select any .gpx file in Finder and press Space to see the track \
        on a map, or browse in Gallery view for map thumbnails.

        If previews don’t appear, enable “QuickGPX” under \
        System Settings → General → Login Items & Extensions → Quick Look.
        """)
        label.frame = NSRect(x: 24, y: 20, width: 412, height: 150)
        window.contentView?.addSubview(label)

        window.makeKeyAndOrderFront(nil)
        self.window = window
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)

let mainMenu = NSMenu()
let appMenuItem = NSMenuItem()
mainMenu.addItem(appMenuItem)
let appMenu = NSMenu()
appMenu.addItem(withTitle: "Quit QuickGPX", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
appMenuItem.submenu = appMenu
app.mainMenu = mainMenu

app.run()
