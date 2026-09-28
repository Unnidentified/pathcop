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
    var copyContents: Bool = true
    var copyFilename: Bool = true
    var filenameKeepExtension: Bool = true
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
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 360),
                         styleMask: [.titled, .closable, .miniaturizable],
                         backing: .buffered, defer: false)
        w.title = "pathcop"
        w.delegate = self
        w.isReleasedWhenClosed = false
        w.center()

        let prefs = loadPrefs()

        let title = NSTextField(labelWithString: "Finder menu items")
        title.font = .boldSystemFont(ofSize: 13)
        title.frame = NSRect(x: 20, y: 310, width: 280, height: 20)
        w.contentView?.addSubview(title)

        let cp = NSButton(checkboxWithTitle: "Copy Path", target: self, action: #selector(toggled(_:)))
        cp.frame = NSRect(x: 20, y: 280, width: 280, height: 20)
        cp.state = prefs.copyPath ? .on : .off
        cp.identifier = NSUserInterfaceItemIdentifier("copyPath")
        w.contentView?.addSubview(cp)

        let ct = NSButton(checkboxWithTitle: "Copy Tree", target: self, action: #selector(toggled(_:)))
        ct.frame = NSRect(x: 20, y: 258, width: 280, height: 20)
        ct.state = prefs.copyTree ? .on : .off
        ct.identifier = NSUserInterfaceItemIdentifier("copyTree")
        w.contentView?.addSubview(ct)

        let cc = NSButton(checkboxWithTitle: "Copy Contents", target: self, action: #selector(toggled(_:)))
        cc.frame = NSRect(x: 20, y: 236, width: 280, height: 20)
        cc.state = prefs.copyContents ? .on : .off
        cc.identifier = NSUserInterfaceItemIdentifier("copyContents")
        w.contentView?.addSubview(cc)

        let cf = NSButton(checkboxWithTitle: "Copy Filename", target: self, action: #selector(toggled(_:)))
        cf.frame = NSRect(x: 20, y: 214, width: 280, height: 20)
        cf.state = prefs.copyFilename ? .on : .off
        cf.identifier = NSUserInterfaceItemIdentifier("copyFilename")
        w.contentView?.addSubview(cf)

        let login = NSButton(checkboxWithTitle: "Start on login", target: self, action: #selector(toggledLogin(_:)))
        login.frame = NSRect(x: 20, y: 170, width: 280, height: 20)
        login.state = isLoginItem() ? .on : .off
        w.contentView?.addSubview(login)

        let ext = NSButton(checkboxWithTitle: "Filenames keep extension", target: self, action: #selector(toggled(_:)))
        ext.frame = NSRect(x: 40, y: 148, width: 260, height: 20)
        ext.state = prefs.filenameKeepExtension ? .on : .off
        ext.identifier = NSUserInterfaceItemIdentifier("filenameKeepExtension")
        w.contentView?.addSubview(ext)

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
        if #unavailable(macOS 13.0) {
            return legacyLoginItemEnabled()
        }
        return SMAppService.mainApp.status == .enabled
    }

    func setLoginItem(_ enabled: Bool) {
        if #unavailable(macOS 13.0) {
            setLegacyLoginItem(enabled)
            return
        }
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

    // macOS 11/12 fallback: LSSharedFileList login items.
    private func loginItemsList() -> LSSharedFileList? {
        LSSharedFileListCreate(nil, kLSSharedFileListSessionLoginItems.takeRetainedValue(), nil)?.takeRetainedValue()
    }

    private func legacyLoginItemEnabled() -> Bool {
        guard let list = loginItemsList() else { return false }
        let items = LSSharedFileListCopySnapshot(list, nil)?.takeRetainedValue() as? [LSSharedFileListItem] ?? []
        let appURL = Bundle.main.bundleURL as URL
        for item in items {
            var resolved: Unmanaged<CFURL>?
            if LSSharedFileListItemResolve(item, 0, &resolved, nil) == noErr,
               let url = resolved?.takeRetainedValue() as URL?,
               url == appURL {
                return true
            }
        }
        return false
    }

    private func setLegacyLoginItem(_ enabled: Bool) {
        guard let list = loginItemsList() else { NSSound.beep(); return }
        let appURL = Bundle.main.bundleURL as CFURL
        if enabled {
            LSSharedFileListInsertItemURL(list, kLSSharedFileListItemBeforeFirst.takeRetainedValue(), nil, nil, appURL, nil, nil)
        } else {
            let items = LSSharedFileListCopySnapshot(list, nil)?.takeRetainedValue() as? [LSSharedFileListItem] ?? []
            let target = Bundle.main.bundleURL
            for item in items {
                var resolved: Unmanaged<CFURL>?
                if LSSharedFileListItemResolve(item, 0, &resolved, nil) == noErr,
                   let url = resolved?.takeRetainedValue() as URL?,
                   url == target {
                    LSSharedFileListItemRemove(list, item)
                }
            }
        }
    }

    @objc func toggledLogin(_ sender: NSButton) {
        setLoginItem(sender.state == .on)
        // Reflect reality in case registration failed.
        sender.state = isLoginItem() ? .on : .off
    }

    @objc func toggled(_ sender: NSButton) {
        var prefs = loadPrefs()
        switch sender.identifier?.rawValue {
        case "copyPath": prefs.copyPath = sender.state == .on
        case "copyTree": prefs.copyTree = sender.state == .on
        case "copyContents": prefs.copyContents = sender.state == .on
        case "copyFilename": prefs.copyFilename = sender.state == .on
        case "filenameKeepExtension": prefs.filenameKeepExtension = sender.state == .on
        default: break
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
