import ImageIO
import SwiftUI

struct StatusPill: View {
    let status: Status
    var compact = false

    var body: some View {
        Text(status.rawValue)
            .font(compact ? .caption2 : .caption)
            .fontWeight(.medium)
            .padding(.horizontal, compact ? 6 : 8)
            .padding(.vertical, compact ? 1.5 : 3)
            .background(status.color.opacity(0.15), in: Capsule())
            .foregroundStyle(status.color)
    }
}

/// Four dots, one per run stage, like the web UI's status dots.
struct StageDots: View {
    let run: Run

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Run.stages, id: \.self) { k in
                Circle().fill(run.stage(k).status.color).frame(width: 6, height: 6)
            }
        }
    }
}

struct Card<Content: View>: View {
    let title: String
    var trailing: AnyView? = nil
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !title.isEmpty { Text(title).font(.headline) }
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).strokeBorder(.separator))
    }
}

struct MetricTile: View {
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(Theme.display(24))
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct WarningBanner: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.accent)
            Text(text).textSelection(.enabled)
        }
        .padding(.vertical, 9).padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        .overlay(alignment: .leading) { Rectangle().fill(Theme.accent).frame(width: 3).clipShape(RoundedRectangle(cornerRadius: 2)) }
    }
}

/// CGImage isn't marked Sendable; the loader only ever hands the image to the view that asked for it.
private struct LoadedImage: @unchecked Sendable {
    let image: CGImage
}

/// Downsampled image from a file on disk, reloaded when the file's modification date changes.
struct FileImage: View {
    let url: URL?
    var maxPixel: Int = 1800

    @State private var image: CGImage?

    private struct Key: Hashable { let path: String?; let mtime: Date? }
    private var key: Key {
        Key(path: url?.path, mtime: url.flatMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate })
    }

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fit)
            } else {
                Rectangle().fill(.quaternary)
            }
        }
        .task(id: key) {
            guard let url else { image = nil; return }
            let max = maxPixel
            let loaded = await Task.detached(priority: .utility) { () -> LoadedImage? in
                guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
                let opts: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: max,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true,
                ]
                return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary).map { LoadedImage(image: $0) }
            }.value
            image = loaded?.image
        }
    }
}

struct HealthBar: View {
    let health: Health

    var body: some View {
        HStack(spacing: 12) {
            tool("colmap", health.colmap)
            tool("openmvs", health.openmvs)
            tool("blender", health.blender)
        }
        .font(.caption)
        .padding(.horizontal, 12).padding(.vertical, 6)
        .glassEffect()
    }

    private func tool(_ name: String, _ ok: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle").foregroundStyle(ok ? Theme.ok : Theme.bad)
            Text(name).foregroundStyle(.secondary)
        }
        .help(ok ? "\(name) found" : "\(name) not found: see README setup")
    }
}
