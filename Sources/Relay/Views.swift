import AppKit
import SwiftUI
import RelayCore

/// Only http(s) links are opened from Relay.
func webURL(_ raw: String) -> URL? {
    guard let url = URL(string: raw), url.scheme == "http" || url.scheme == "https" else { return nil }
    return url
}

/// Untrusted multi-line prose, hidden characters revealed.
func prose(_ s: String) -> String { Sanitize.reveal(s, as: .prose).text }

/// Untrusted single-line prose; LF and TAB are revealed too.
func line(_ s: String) -> String { Sanitize.revealLine(s) }

/// "label · host" for a link, so the destination is always visible. Foundation
/// stores an internationalized host as punycode ("xn--…"), which gets a warning.
func linkTitle(_ label: String, _ url: URL) -> String {
    let host = url.host(percentEncoded: false) ?? ""
    let nonASCII = !host.allSatisfy(\.isASCII)
        || host.lowercased().split(separator: ".").contains { $0.hasPrefix("xn--") }
    return line(label) + " · " + line(host) + (nonASCII ? " ⚠︎ non-ASCII host" : "")
}

/// A Link that shows its host and its full URL on hover.
struct WebLink: View {
    let label: String
    let url: URL

    var body: some View {
        Link(destination: url) {
            Text(verbatim: linkTitle(label, url))
        }
        .help(line(url.absoluteString))
    }
}

struct RootView: View {
    @ObservedObject private var store: Store
    @ObservedObject private var model: AppModel
    private let onSettings: () -> Void

    init(store: Store, model: AppModel, onSettings: @escaping () -> Void) {
        _store = ObservedObject(wrappedValue: store)
        _model = ObservedObject(wrappedValue: model)
        self.onSettings = onSettings
    }

    var body: some View {
        Group {
            if let id = store.selectedID {
                if store.notFoundID == id {
                    NotFoundView(store: store)
                } else {
                    // A fresh view per ask, so ticks and the reply draft never carry over.
                    DetailView(store: store, id: id).id(id)
                }
            } else {
                SidebarView(store: store, model: model, onSettings: onSettings)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onChange(of: store.items) { _, items in
            pruneTicks(items)
        }
    }

    /// Ticks are pruned only after a successful list of the same source: the
    /// Store is reachable and the list is non-empty. A swap empties `items`
    /// before the new source lists, so it never prunes. The open ask is kept.
    private func pruneTicks(_ items: [WireItem]) {
        guard store.reachable, !items.isEmpty else { return }
        // Pending closes are still listed by the source: keep their ticks for Undo.
        var keep = store.listedIDs
        if let selected = store.selectedID { keep.insert(selected) }
        Ticks.prune(.standard, sourceKey: store.sourceKey, keep: keep)
    }
}

struct NotFoundView: View {
    @ObservedObject var store: Store

    var body: some View {
        VStack(spacing: 10) {
            Spacer()
            Text("Ask not found").font(.headline)
            Text("It may have been removed.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Back to the queue") { store.select(nil) }
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(14)
    }
}
