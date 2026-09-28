import Cocoa
import ServiceManagement

// Shared with the FinderSync extension through a plain JSON file.
// (No App Group cert on ad-hoc builds, so a world-readable prefs file it is.
// The extension reads this fresh on every right-click, no IPC needed.)
let prefsDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/pathcop", isDirectory: true)
let prefsURL = prefsDir.appendingPathComponent("prefs.json")

struct Prefs: Codable {
    var copyPath: Bool = true
    var copyTree: Bool = true
}

func loadPrefs() -> Prefs {
    // Migrate from old CopyPath location once.
    let oldURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/CopyPath/prefs.json")
    if !FileManager.default.fileExists(atPath: prefsURL.path),
       FileManager.default.fileExists(atPath: oldURL.path) {
        try? FileManager.default.createDirectory(at: prefsDir, withIntermediateDirectories: true)
        try? FileManager.default.copyItem(at: oldURL, to: prefsURL)
    }
    if let data = try? Data(contentsOf: prefsURL),
       let p = try? JSONDecoder().decode(Prefs.self, from: data) {
        return p
    }
    return Prefs()
}

func savePrefs(_ p: Prefs) {
    try? FileManager.default.createDirectory(at: prefsDir, withIntermediateDirectories: true)
    if let data = try? JSONEncoder().encode(p) {
        try? data.write(to: prefsURL, options: .atomic)
    }
}

class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: NSWindow?
    var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)

        if !FileManager.default.fileExists(atPath: prefsURL.path) {
            savePrefs(Prefs())
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pluginkit")
        task.arguments = ["-e", "use", "-i", "com.gefaass.pathcop.ext"]
        try? task.run()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let btn = statusItem?.button {
            btn.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "pathcop")
        }
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Settings…", action: #selector(showWindow), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit pathcop", action: #selector(quitApp), keyEquivalent: ""))
        statusItem?.menu = menu

        buildWindow()
    }

    func buildWindow() {
        if window != nil {
            window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 275),
                         styleMask: [.titled, .closable, .miniaturizable],
                         backing: .buffered, defer: false)
        w.title = "pathcop"
        w.delegate = self
        w.isReleasedWhenClosed = false
        w.center()

        let prefs = loadPrefs()

        let title = NSTextField(labelWithString: "Finder menu items")
        title.font = .boldSystemFont(ofSize: 13)
        title.frame = NSRect(x: 20, y: 225, width: 280, height: 20)
        w.contentView?.addSubview(title)

        let cp = NSButton(checkboxWithTitle: "Copy Path", target: self, action: #selector(toggled(_:)))
        cp.frame = NSRect(x: 20, y: 195, width: 280, height: 20)
        cp.state = prefs.copyPath ? .on : .off
        cp.identifier = NSUserInterfaceItemIdentifier("copyPath")
        w.contentView?.addSubview(cp)

        let ct = NSButton(checkboxWithTitle: "Copy Tree", target: self, action: #selector(toggled(_:)))
        ct.frame = NSRect(x: 20, y: 170, width: 280, height: 20)
        ct.state = prefs.copyTree ? .on : .off
        ct.identifier = NSUserInterfaceItemIdentifier("copyTree")
        w.contentView?.addSubview(ct)

        let login = NSButton(checkboxWithTitle: "Start on login", target: self, action: #selector(toggledLogin(_:)))
        login.frame = NSRect(x: 20, y: 145, width: 280, height: 20)
        login.state = isLoginItem() ? .on : .off
        w.contentView?.addSubview(login)

        let hint = NSTextField(wrappingLabelWithString: "Right-click anywhere in Finder. Enable pathcop first under System Settings > General > Login Items & Extensions > Finder Extensions.")
        hint.frame = NSRect(x: 20, y: 55, width: 280, height: 80)
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        w.contentView?.addSubview(hint)

        let quit = NSButton(title: "Quit pathcop", target: self, action: #selector(quitApp))
        quit.frame = NSRect(x: 20, y: 15, width: 120, height: 28)
        quit.bezelStyle = .rounded
        w.contentView?.addSubview(quit)

        self.window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func isLoginItem() -> Bool {
        SMAppService.mainApp.status == .enabled
    }

    func setLoginItem(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSSound.beep()
        }
    }

    @objc func toggledLogin(_ sender: NSButton) {
        setLoginItem(sender.state == .on)
        // Reflect reality in case registration failed.
        sender.state = isLoginItem() ? .on : .off
    }

    @objc func toggled(_ sender: NSButton) {
        var prefs = loadPrefs()
        if sender.identifier?.rawValue == "copyPath" {
            prefs.copyPath = sender.state == .on
        } else {
            prefs.copyTree = sender.state == .on
        }
        savePrefs(prefs)
    }

    @objc func showWindow() {
        NSApp.setActivationPolicy(.regular)
        buildWindow()
    }

    @objc func quitApp() {
        NSApp.terminate(nil)
    }

    // Close button: window goes away, Dock icon goes away, app keeps running.
    // Reopen from the menu bar icon.
    func windowWillClose(_ notification: Notification) {
        window?.orderOut(nil)
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }
}

// Traditional bootstrap (no @main): without a Main nib, @main never
// wires the delegate, so didFinishLaunching would silently never fire.
let delegate = AppDelegate()
let app = NSApplication.shared
app.delegate = delegate
app.run()
