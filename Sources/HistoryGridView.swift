import SwiftUI
import CoreData

enum KindFilter: String, CaseIterable, Identifiable {
    case all = "All", text = "Text", links = "Links", images = "Images", files = "Files"
    var id: Self { self }

    var kind: ClipKind? {
        switch self {
        case .all: nil
        case .text: .text
        case .links: .url
        case .images: .image
        case .files: .file
        }
    }
}

struct HistoryGridView: View {
    @AppStorage(Prefs.capturePaused) private var paused = false
    /// Called after an item is copied, e.g. so the floating panel can dismiss itself.
    var onCopy: () -> Void = {}
    @Environment(\.managedObjectContext) private var context
    // @State is a macro and CLT lacks its plugin, so State is used directly.
    private let search = State(initialValue: "")
    private let filter = State(initialValue: KindFilter.all)

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            FilteredGrid(search: search.wrappedValue, filter: filter.wrappedValue, onCopy: onCopy)
            Divider()
            footer
        }
        .frame(width: 520, height: 560)
    }

    private var header: some View {
        VStack(spacing: 8) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search history", text: search.projectedValue)
                    .textFieldStyle(.plain)
                if !search.wrappedValue.isEmpty {
                    Button { search.wrappedValue = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(8)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))

            Picker("Filter", selection: filter.projectedValue) {
                ForEach(KindFilter.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        .padding(12)
    }

    private var footer: some View {
        HStack {
            Button("Clear Unpinned", role: .destructive) { clearUnpinned() }
            Toggle("Pause", isOn: $paused)
                .toggleStyle(.checkbox)
                .help("Stop saving new copies until unchecked")
            Spacer()
            SettingsLink { Text("Settings…") }
                .simultaneousGesture(TapGesture().onEnded { NSApp.activate() })
            Button("Quit") { NSApp.terminate(nil) }
        }
        .controlSize(.small)
        .padding(10)
    }

    private func clearUnpinned() {
        let request = ClipItem.fetchRequest()
        request.predicate = NSPredicate(format: "isPinned == NO")
        for item in (try? context.fetch(request)) ?? [] { context.delete(item) }
        try? context.save()
    }
}

/// Separate view so the fetch request is rebuilt when search or filter change.
private struct FilteredGrid: View {
    @Environment(\.managedObjectContext) private var context
    @FetchRequest private var items: FetchedResults<ClipItem>
    private let copiedID = State<NSManagedObjectID?>(initialValue: nil)
    private let qrItem = State<ClipItem?>(initialValue: nil)
    private let onCopy: () -> Void

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 10)]

    init(search: String, filter: KindFilter, onCopy: @escaping () -> Void) {
        self.onCopy = onCopy
        var predicates: [NSPredicate] = []
        if let kind = filter.kind {
            predicates.append(NSPredicate(format: "kindRaw == %@", kind.rawValue))
        }
        let query = search.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty {
            predicates.append(NSPredicate(format: "text CONTAINS[cd] %@ OR urlString CONTAINS[cd] %@ OR filePathsRaw CONTAINS[cd] %@",
                                          query, query, query))
        }
        let request = ClipItem.fetchRequest()
        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
        request.sortDescriptors = [NSSortDescriptor(key: "isPinned", ascending: false),
                                   NSSortDescriptor(key: "createdAt", ascending: false)]
        request.fetchBatchSize = 40
        _items = FetchRequest(fetchRequest: request, animation: .default)
    }

    var body: some View {
        if items.isEmpty {
            ContentUnavailableView("Nothing here yet", systemImage: "doc.on.clipboard",
                                   description: Text("Copy something and it will show up here."))
                .frame(maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(items) { item in
                        let payload = QRCode.payload(for: item)
                        ClipCardView(item: item, justCopied: copiedID.wrappedValue == item.objectID,
                                     onShowQR: payload.map { _ in { qrItem.wrappedValue = item } })
                            .onTapGesture { copy(item) }
                            .contextMenu {
                                Button("Copy") { copy(item) }
                                if payload != nil {
                                    Button("Show QR Code") { qrItem.wrappedValue = item }
                                }
                                Button(item.isPinned ? "Unpin" : "Pin") { togglePin(item) }
                                Divider()
                                Button("Delete", role: .destructive) { delete(item) }
                            }
                    }
                }
                .padding(12)
            }
            // An in-view overlay rather than a popover: a popover window would take key
            // status from the floating panel, which closes it.
            .overlay {
                if let item = qrItem.wrappedValue, let payload = QRCode.payload(for: item) {
                    ZStack {
                        Color.black.opacity(0.35)
                            .onTapGesture { qrItem.wrappedValue = nil }
                        QRShareView(payload: payload, isURL: item.kind == .url) { qrItem.wrappedValue = nil }
                    }
                    .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.15), value: qrItem.wrappedValue)
        }
    }

    private func copy(_ item: ClipItem) {
        Paster.write(item)
        item.createdAt = Date()
        try? context.save()
        copiedID.wrappedValue = item.objectID
        Task {
            try? await Task.sleep(for: .seconds(0.35))
            onCopy()
            try? await Task.sleep(for: .seconds(0.85))
            if copiedID.wrappedValue == item.objectID { copiedID.wrappedValue = nil }
        }
    }

    private func togglePin(_ item: ClipItem) {
        item.isPinned.toggle()
        try? context.save()
    }

    private func delete(_ item: ClipItem) {
        context.delete(item)
        try? context.save()
    }
}
