import AppKit
import SwiftUI

struct LogView: View {
    let title: String
    let url: URL
    let live: Bool
    @Binding var follow: Bool
    var height: CGFloat = 360

    @State private var text = ""
    @State private var truncated = false

    private struct Key: Hashable { let path: String; let live: Bool }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Log · \(title)").font(.headline)
                Spacer()
                if live { ProgressView().controlSize(.small) }
                Toggle("Follow", isOn: $follow).toggleStyle(.checkbox)
                Button("Open", systemImage: "arrow.up.forward.app") { NSWorkspace.shared.open(url) }
                    .labelStyle(.iconOnly).buttonStyle(.borderless).help("Open the log file")
            }
            LogTextView(text: (truncated ? "… (earlier output trimmed)\n" : "") + (text.isEmpty ? "(no output yet)" : text), follow: follow)
                .frame(height: height)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .task(id: Key(path: url.path, live: live)) {
            while !Task.isCancelled {
                let u = url
                let r = await Task.detached(priority: .utility) { ManifestStore.readTail(u, maxBytes: 192 * 1024) }.value
                if r.text != text { text = r.text; truncated = r.truncated }
                if !live { break }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
}

/// NSTextView: fast for big logs, native find and selection.
struct LogTextView: NSViewRepresentable {
    let text: String
    let follow: Bool

    func makeNSView(context: Context) -> NSScrollView {
        let sv = NSTextView.scrollableTextView()
        let tv = sv.documentView as! NSTextView
        let bg = NSColor(srgbRed: 0.098, green: 0.098, blue: 0.094, alpha: 1)
        tv.isEditable = false
        tv.isRichText = false
        tv.usesFindBar = true
        tv.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        tv.textColor = NSColor(white: 0.9, alpha: 1)
        tv.backgroundColor = bg
        tv.textContainerInset = NSSize(width: 10, height: 10)
        tv.isAutomaticQuoteSubstitutionEnabled = false
        sv.backgroundColor = bg
        sv.drawsBackground = true
        sv.hasVerticalScroller = true
        sv.autohidesScrollers = true
        return sv
    }

    func updateNSView(_ sv: NSScrollView, context: Context) {
        let tv = sv.documentView as! NSTextView
        if tv.string != text {
            tv.string = text
            if follow { tv.scrollToEndOfDocument(nil) }
        }
    }
}
