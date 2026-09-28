import Cocoa
import FinderSync

@objc(pathcopFinderSync)
class FinderSync: FIFinderSync {

    // Safety rails so a giant folder can't freeze Finder.
    private let maxTreeEntries = 5000
    private let maxTreeDepth = 8

    // Caps so Copy Contents can't blow up the clipboard.
    private let maxContentFiles = 200
    private let maxContentBytes = 1_000_000

    private var prefs: (copyPath: Bool, copyTree: Bool, copyContents: Bool, copyFilename: Bool, filenameKeepExtension: Bool) {
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
            return (obj["copyPath"] ?? true, obj["copyTree"] ?? true,
                    obj["copyContents"] ?? true, obj["copyFilename"] ?? true,
                    obj["filenameKeepExtension"] ?? true)
        }
        return (true, true, true, true, true)
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
                let item = NSMenuItem(title: "Copy Path", action: #selector(copyPathClicked(_:)), keyEquivalent: "")
                item.image = menuIcon("doc.on.doc")
                menu.addItem(item)
            }
            if flags.copyTree {
                let item = NSMenuItem(title: "Copy Tree", action: #selector(copyTreeClicked(_:)), keyEquivalent: "")
                item.image = menuIcon("arrow.triangle.branch")
                menu.addItem(item)
            }
            if flags.copyContents {
                let item = NSMenuItem(title: "Copy Contents", action: #selector(copyContentsClicked(_:)), keyEquivalent: "")
                item.image = menuIcon("doc.plaintext")
                menu.addItem(item)
            }
            if flags.copyFilename {
                let item = NSMenuItem(title: "Copy Filename", action: #selector(copyFilenameClicked(_:)), keyEquivalent: "")
                item.image = menuIcon("textformat")
                menu.addItem(item)
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

    private func isDir(_ url: URL) -> Bool {
        var flag: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &flag)
        return flag.boolValue
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

    // MARK: - Copy Filename

    @IBAction func copyFilenameClicked(_ sender: AnyObject?) {
        let urls = targetURLs()
        guard !urls.isEmpty else { return }
        let keepExt = prefs.filenameKeepExtension
        let names = urls.map { displayName(for: $0, keepExtension: keepExt) }
        copyToClipboard(names.joined(separator: " "))
    }

    private func displayName(for url: URL, keepExtension: Bool) -> String {
        let full = url.lastPathComponent
        guard !keepExtension else { return full }
        guard !url.pathExtension.isEmpty else { return full }
        let stem = url.deletingPathExtension().lastPathComponent
        return stem.isEmpty ? full : stem
    }

    // MARK: - Copy Contents (adaptive: one file raw, many files as a content tree)

    @IBAction func copyContentsClicked(_ sender: AnyObject?) {
        let urls = targetURLs()
        guard !urls.isEmpty else { return }

        let files = collectTextFiles(from: urls)
        guard !files.isEmpty else {
            copyToClipboard("(no readable text files found)")
            return
        }

        // One file: its raw contents, nothing added.
        if files.count == 1 && urls.count == 1 && !isDir(urls[0]) {
            copyToClipboard(readText(at: files[0]) ?? "")
            return
        }

        // Folders or several files: contents laid out as a tree, spacing kept.
        copyToClipboard(contentsTree(for: files))
    }

    // Extension -> markdown fence language.
    private func fenceLanguage(for url: URL) -> String {
        if url.lastPathComponent == "Dockerfile" { return "dockerfile" }
        if url.lastPathComponent == "Makefile" { return "make" }
        switch url.pathExtension.lowercased() {
        case "swift": return "swift"
        case "m", "mm": return "objectivec"
        case "c", "h": return "c"
        case "cpp", "hpp", "cc", "cxx": return "cpp"
        case "cs": return "csharp"
        case "py": return "python"
        case "rb": return "ruby"
        case "js", "mjs", "cjs": return "javascript"
        case "ts": return "typescript"
        case "tsx", "jsx": return "tsx"
        case "vue", "svelte": return "html"
        case "java", "kt", "kts", "scala": return "java"
        case "go": return "go"
        case "rs": return "rust"
        case "php": return "php"
        case "lua", "pl", "pm", "r": return "lua"
        case "sh", "bash", "zsh", "fish": return "bash"
        case "ps1": return "powershell"
        case "bat", "cmd": return "bat"
        case "json", "jsonc": return "json"
        case "yml", "yaml": return "yaml"
        case "toml", "ini", "cfg", "conf", "env": return "toml"
        case "xml", "plist", "xib", "storyboard": return "xml"
        case "html", "htm": return "html"
        case "css", "scss", "less": return "css"
        case "sql": return "sql"
        case "graphql", "gql": return "graphql"
        case "md", "markdown": return "markdown"
        case "tex": return "latex"
        case "txt", "text", "log", "csv": return "text"
        default: return ""
        }
    }

    private func collectTextFiles(from urls: [URL]) -> [URL] {
        var out: [URL] = []
        var seen = Set<String>()
        func add(_ url: URL) {
            guard out.count < maxContentFiles else { return }
            let key = url.standardizedFileURL.path
            guard !seen.contains(key) else { return }
            seen.insert(key)
            var flag: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &flag),
                  !flag.boolValue,
                  isTextFile(url) else { return }
            out.append(url)
        }
        for url in urls {
            var flag: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &flag) else { continue }
            if flag.boolValue {
                let walker = FileManager.default.enumerator(
                    at: url, includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles])
                while let item = walker?.nextObject() as? URL {
                    if out.count >= maxContentFiles { break }
                    var d: ObjCBool = false
                    if FileManager.default.fileExists(atPath: item.path, isDirectory: &d),
                       !d.boolValue, isTextFile(item) {
                        add(item)
                    }
                }
            } else {
                add(url)
            }
            if out.count >= maxContentFiles { break }
        }
        return out.sorted { $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending }
    }

    private func isTextFile(_ url: URL) -> Bool {
        // Skip obvious binaries by extension first.
        let bin: Set<String> = ["png","jpg","jpeg","gif","webp","bmp","ico","icns",
            "pdf","zip","gz","bz2","xz","7z","tar","rar","dmg","pkg","app",
            "o","a","so","dylib","class","pyc","mp3","mp4","mov","m4a","wav",
            "sqlite","db","ttf","otf","woff","woff2"]
        if bin.contains(url.pathExtension.lowercased()) { return false }
        // Then sniff the first bytes for NUL.
        guard let fh = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? fh.close() }
        let sample = (try? fh.read(upToCount: 8192)) ?? Data()
        if sample.isEmpty { return true }
        return !sample.contains(0)
    }

    private func readText(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        if let s = String(data: data, encoding: .utf8) { return s }
        if let s = String(data: data, encoding: .utf16) { return s }
        return String(data: data, encoding: .macOSRoman)
    }

    private func contentsTree(for files: [URL]) -> String {
        let base = commonBase(of: files)
        var parts: [String] = []
        var total = 0
        for (i, file) in files.enumerated() {
            let rel = relativePath(of: file, to: base)
            let lang = fenceLanguage(for: file)
            let body = readText(at: file) ?? "(unreadable)"
            // Keep original spacing, cap runaway files.
            let clipped = clip(body, limit: 50_000)
            parts.append("## \(rel)\n```\(lang)\n\(clipped)\n```")
            total += clipped.utf8.count
            if total >= maxContentBytes || i + 1 >= maxContentFiles {
                parts.append("\n… (truncated, too much content)")
                break
            }
        }
        parts.append("")
        parts.append("\(files.count) file\(files.count == 1 ? "" : "s")")
        return parts.joined(separator: "\n\n")
    }

    private func commonBase(of files: [URL]) -> URL {
        guard let first = files.first else { return URL(fileURLWithPath: "/") }
        var base = first.deletingLastPathComponent()
        for f in files.dropFirst() {
            while !f.path.hasPrefix(base.path + "/") && base.path != "/" {
                base = base.deletingLastPathComponent()
            }
        }
        return base
    }

    private func relativePath(of file: URL, to base: URL) -> String {
        let p = file.path
        let b = base.path
        if p.hasPrefix(b + "/") { return String(p.dropFirst(b.count + 1)) }
        return file.lastPathComponent
    }

    private func clip(_ s: String, limit: Int) -> String {
        guard s.count > limit else { return s }
        return String(s.prefix(limit)) + "\n… (file truncated)"
    }

    // MARK: - Copy Tree (ls -R, but neat)

    @IBAction func copyTreeClicked(_ sender: AnyObject?) {
        let urls = targetURLs()
        guard !urls.isEmpty else { return }

        var sections: [String] = []
        for url in urls {
            var isDirFlag: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirFlag)
            if exists && isDirFlag.boolValue {
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

    private func treeChildren(of url: URL) -> [URL] {
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

        func walk(_ url: URL, prefix: String, depth: Int) {
            if truncated { return }
            if depth > maxTreeDepth {
                lines.append(prefix + "└── … (deeper levels skipped)")
                truncated = true
                return
            }
            let kids = treeChildren(of: url)
            for (i, child) in kids.enumerated() {
                if count >= maxTreeEntries {
                    lines.append(prefix + "└── … (truncated, too many entries)")
                    truncated = true
                    return
                }
                count += 1
                let last = i == kids.count - 1
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
            lines.append("(empty)")
        } else {
            lines.append("")
            let note = truncated ? " (truncated)" : ""
            lines.append("\(count) item\(count == 1 ? "" : "s")\(note)")
        }
        return lines.joined(separator: "\n")
    }
}
