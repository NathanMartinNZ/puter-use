import AppKit

/// Borrowing the clipboard to paste, and giving it back. The text put there is marked transient so
/// clipboard managers don't record it, and the user's own contents return shortly after the paste,
/// unless they copied something themselves in between.
@MainActor
enum Clipboard {
    private static var saved: [[NSPasteboard.PasteboardType: Data]]?  // the user's contents while borrowed
    private static var ours = -1  // changeCount right after we wrote
    private static var restore: Task<Void, Never>?

    static let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    /// Put `text` on the clipboard for a paste, keeping what was there.
    static func borrow(_ text: String) {
        let pb = NSPasteboard.general
        restore?.cancel()
        if saved == nil || pb.changeCount != ours { saved = snapshot(pb) }  // not our own text from a paste just now
        pb.clearContents()
        pb.setString(text, forType: .string)
        pb.setData(Data(), forType: transient)
        ours = pb.changeCount
    }

    /// Put the user's contents back once the app has had time to read ours (it does when it handles the
    /// paste), unless someone has copied something since.
    static func giveBack(after delay: Double = 0.6) {
        restore?.cancel()
        restore = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1e9))
            guard !Task.isCancelled else { return }
            putBack()
        }
    }

    /// The user's contents back now (unless they've copied since).
    static func putBack() {
        let pb = NSPasteboard.general
        if pb.changeCount == ours, let saved {
            pb.clearContents()
            let items = saved.map { types -> NSPasteboardItem in
                let item = NSPasteboardItem()
                for (type, data) in types { item.setData(data, forType: type) }
                return item
            }
            if !items.isEmpty { pb.writeObjects(items) }
        }
        saved = nil
        ours = -1
    }

    /// Before quitting: wait for a pending give-back (the app may still be reading the paste), then make
    /// sure the user's contents are back.
    static func finish() async {
        await restore?.value
        putBack()
    }

    /// What's on the clipboard, as text (for the agent to read what it copied).
    static func read(limit: Int = 4000) -> String {
        let pb = NSPasteboard.general
        if let s = pb.string(forType: .string) {
            return s.count > limit ? String(s.prefix(limit)) + "… (\(s.count) characters in all)" : s
        }
        let types = (pb.types ?? []).map(\.rawValue)
        if types.isEmpty { return "(the clipboard is empty)" }
        if types.contains(NSPasteboard.PasteboardType.fileURL.rawValue),
           let urls = pb.readObjects(forClasses: [NSURL.self]) as? [URL] {
            return "(files: " + urls.prefix(20).map(\.path).joined(separator: ", ") + ")"
        }
        if types.contains(where: { $0.contains("png") || $0.contains("tiff") || $0.contains("image") }) { return "(an image, no text)" }
        return "(no text: \(types.prefix(4).joined(separator: ", ")))"
    }

    /// Put `text` on the clipboard to stay (the user's contents are replaced, as when copying).
    static func set(_ text: String) {
        restore?.cancel()
        saved = nil
        ours = -1
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    static func snapshot(_ pb: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        (pb.pasteboardItems ?? []).map { item in
            var types: [NSPasteboard.PasteboardType: Data] = [:]
            for t in item.types { if let d = item.data(forType: t) { types[t] = d } }
            return types
        }
    }
}
