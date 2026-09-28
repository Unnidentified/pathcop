import Cocoa
import FinderSync

@objc(pathcopFinderSync)
class FinderSync: FIFinderSync {

    // Safety rails for Copy Tree so a giant folder can't freeze Finder.
    private let maxTreeEntries = 5000
    private let maxTreeDepth = 8

    private var prefs: (copyPath: Bool, copyTree: Bool) {
        let fm = FileManager.default
        var url = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/pathcop/prefs.json")
        if !fm.fileExists(atPath: url.path) {
            // Fall back to old CopyPath prefs during rename transition.
            let old = fm.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/CopyPath/prefs.json")
            if fm.fileExists(atPath: old.path) { url = old }
        }
        if let data = try? Data(contentsOf: url),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Bool] {
            return (obj["copyPath"] ?? true, obj["copyTree"] ?? true)
        }
        return (true, true)
    }

    private func menuIcon(_ name: String) -> NSImage? {
        // Template icons tint to the menu highlight, which washes
        // them out. Plain white stays readable in both modes.
        guard let icon = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return nil }
        icon.isTemplate = false
        if let tinted = icon.copy() as? NSImage {
            tinted.lockFocus()
            NSColor.white.set()
            NSRect(origin: .zero, size: tinted.size).fill(using: .sourceAtop)
            tinted.unlockFocus()
            return tinted
        }
        return icon
    }

    override init() {
        super.init()
        // Watch everywhere: Desktop, any folder, any Finder window.
        FIFinderSyncController.default().directoryURLs = [URL(fileURLWithPath: "/")]
    }

    override func menu(for menuKind: FIMenuKind) -> NSMenu {
        let menu = NSMenu(title: "")
        switch menuKind {
        case .contextualMenuForItems,
             .contextualMenuForContainer,
             .contextualMenuForSidebar:
            let flags = prefs
            if flags.copyPath {
                let pathItem = NSMenuItem(title: "Copy Path", action: #selector(copyPathClicked(_:)), keyEquivalent: "")
                pathItem.image = menuIcon("doc.on.doc")
                menu.addItem(pathItem)
            }
            if flags.copyTree {
                let treeItem = NSMenuItem(title: "Copy Tree", action: #selector(copyTreeClicked(_:)), keyEquivalent: "")
                treeItem.image = menuIcon("arrow.triangle.branch")
                menu.addItem(treeItem)
            }
        default:
            break
        }
        return menu
    }

    // MARK: - Targets

    private func targetURLs() -> [URL] {
        let controller = FIFinderSyncController.default()
        // 1. Right-click on file(s): selected items win.
        // 2. Right-click on empty folder background / Desktop: targetedURL is the folder itself.
        if let selected = controller.selectedItemURLs(), !selected.isEmpty {
            return selected
        }
        if let target = controller.targetedURL() {
            return [target]
        }
        return []
    }

    private func copyToClipboard(_ string: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(string, forType: .string)
    }

    // MARK: - Copy Path

    @IBAction func copyPathClicked(_ sender: AnyObject?) {
        let urls = targetURLs()
        guard !urls.isEmpty else { return }

        // The fucking path. Space separated for multi-select.
        // Paths with spaces get quoted so they still paste cleanly into a terminal.
        let paths = urls.map { quoteIfNeeded($0.path) }.joined(separator: " ")
        copyToClipboard(paths)
    }

    private func quoteIfNeeded(_ path: String) -> String {
        if path.contains(" ") || path.contains("\"") || path.contains("'") {
            let escaped = path.replacingOccurrences(of: "\"", with: "\\\"")
            return "\"\(escaped)\""
        }
        return path
    }

    // MARK: - Copy Tree (ls -R, but neat)

    @IBAction func copyTreeClicked(_ sender: AnyObject?) {
        let urls = targetURLs()
        guard !urls.isEmpty else { return }

        var sections: [String] = []
        for url in urls {
            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            if exists && isDir.boolValue {
                sections.append(tree(for: url))
            } else {
                sections.append(url.lastPathComponent + fileDateSuffix(url))
            }
        }
        copyToClipboard(sections.joined(separator: "\n\n"))
    }

    private func fileDateSuffix(_ url: URL) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "d MMM yyyy HH:mm"
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return "" }
        var bits: [String] = []
        if let m = attrs[.modificationDate] as? Date { bits.append("mod " + fmt.string(from: m)) }
        if let c = attrs[.creationDate] as? Date { bits.append("created " + fmt.string(from: c)) }
        return bits.isEmpty ? "" : "  (" + bits.joined(separator: ", ") + ")"
    }

    private func tree(for root: URL) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "d MMM yyyy HH:mm"

        func dates(of url: URL) -> String {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return "" }
            var bits: [String] = []
            if let m = attrs[.modificationDate] as? Date { bits.append("mod " + fmt.string(from: m)) }
            if let c = attrs[.creationDate] as? Date { bits.append("created " + fmt.string(from: c)) }
            return bits.isEmpty ? "" : "  (" + bits.joined(separator: ", ") + ")"
        }

        var lines: [String] = [root.path + dates(of: root)]
        var count = 0
        var truncated = false

        func isDir(_ url: URL) -> Bool {
            var flag: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &flag)
            return flag.boolValue
        }

        func children(of url: URL) -> [URL] {
            let got = (try? FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles])) ?? []
            // Directories first, then files, alphabetical.
            return got.sorted {
                let d0 = isDir($0), d1 = isDir($1)
                if d0 != d1 { return d0 && !d1 }
                return $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending
            }
        }

        func walk(_ url: URL, prefix: String, depth: Int) {
            if truncated { return }
            if depth > maxTreeDepth {
                lines.append(prefix + "└── … (deeper levels skipped)")
                truncated = true
                return
            }
            for (i, child) in children(of: url).enumerated() {
                if count >= maxTreeEntries {
                    lines.append(prefix + "└── … (truncated, too many entries)")
                    truncated = true
                    return
                }
                count += 1
                let last = i == children(of: url).count - 1
                let branch = last ? "└── " : "├── "
                let name = child.lastPathComponent + (isDir(child) ? "/" : "") + dates(of: child)
                lines.append(prefix + branch + name)
                if isDir(child) {
                    walk(child, prefix: prefix + (last ? "    " : "│   "), depth: depth + 1)
                }
            }
        }

        walk(root, prefix: "", depth: 1)

        if count == 0 {
            lines.append("(empty)");
        } else {
            lines.append("");
            let note = truncated ? " (truncated)" : ""
            lines.append("\(count) item\(count == 1 ? "" : "s")\(note)");
        }
        return lines.joined(separator: "\n")
    }
}
