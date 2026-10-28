import SwiftUI
import CoreData
import UniformTypeIdentifiers

enum HistoryTab: Hashable {
    case all, pinned
    case kind(ClipKind)
    case category(NSManagedObjectID)
}

struct HistoryView: View {
    let store: ClipStore
    @ObservedObject var clipboard: ClipboardWatcher
    @Environment(\.managedObjectContext) private var context
    @Environment(\.scenePhase) private var scenePhase

    @State private var tab = HistoryTab.all
    @State private var search = ""
    @State private var toast: String?
    @State private var renaming: ClipItem?
    @State private var renameText = ""
    @State private var newCategoryFor: ClipItem?
    @State private var showingNewCategory = false
    @State private var newCategoryName = ""
    @State private var showingSettings = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                CategoryBar(tab: $tab, onNewCategory: { startNewCategory(for: nil) })
                if clipboard.hasNewContent {
                    newContentBanner
                }
                ItemGrid(search: search, tab: tab, actions: actions)
            }
            .navigationTitle("ClipStack")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $search, prompt: "Search")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showingSettings = true } label: { Image(systemName: "gearshape") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    typeMenu
                }
                ToolbarItem(placement: .topBarTrailing) {
                    PasteButton(supportedContentTypes: ClipImporter.types) { save($0) }
                        .labelStyle(.iconOnly)
                        .buttonBorderShape(.capsule)
                }
            }
        }
        .overlay(alignment: .bottom) { toastView }
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase == .active { clipboard.refresh() }
        }
        .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField(renaming.map(ClipCardView.defaultTitle) ?? "Name", text: $renameText)
            Button("Save") { commitRename() }
            Button("Cancel", role: .cancel) { renaming = nil }
        } message: {
            Text("Leave empty to use the default title.")
        }
        .alert("New Category", isPresented: $showingNewCategory) {
            TextField("Name", text: $newCategoryName)
            Button("Create") { createCategory() }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $showingSettings) {
            SettingsSheet(store: store, syncEnabled: store.isSyncEnabled)
        }
    }

    private var newContentBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.on.clipboard").font(.title3).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("New on your clipboard").font(.subheadline.weight(.semibold))
                Text("Tap Paste to save it.").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            PasteButton(supportedContentTypes: ClipImporter.types) { save($0) }
                .buttonBorderShape(.capsule)
        }
        .padding(12)
        .background(.tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private var typeMenu: some View {
        Menu {
            Picker("Type", selection: $tab) {
                Label("All", systemImage: "square.grid.2x2").tag(HistoryTab.all)
                Label("Text", systemImage: "text.alignleft").tag(HistoryTab.kind(.text))
                Label("Links", systemImage: "link").tag(HistoryTab.kind(.url))
                Label("Images", systemImage: "photo").tag(HistoryTab.kind(.image))
                Label("Files", systemImage: "doc").tag(HistoryTab.kind(.file))
            }
        } label: {
            Image(systemName: isKindTab ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
        }
    }

    private var isKindTab: Bool {
        if case .kind = tab { return true }
        return false
    }

    @ViewBuilder
    private var toastView: some View {
        if let toast {
            Label(toast, systemImage: "checkmark.circle.fill")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(.regularMaterial, in: Capsule())
                .shadow(radius: 8)
                .padding(.bottom, 24)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    // MARK: Actions

    private var actions: ItemActions {
        ItemActions(
            copy: { item in
                ClipboardWriter.write(item)
                clipboard.markSeen()
                item.createdAt = Date()
                try? context.save()
                show("Copied")
            },
            rename: { item in
                renameText = item.title ?? ""
                renaming = item
            },
            newCategory: { startNewCategory(for: $0) })
    }

    private func save(_ providers: [NSItemProvider]) {
        ClipImporter.load(providers) { clip in
            guard let clip else { return }
            store.insert(clip)
            clipboard.markSeen()
            show("Saved")
        }
    }

    private func commitRename() {
        guard let item = renaming else { return }
        let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        item.title = name.isEmpty ? nil : name
        try? context.save()
        renaming = nil
    }

    private func startNewCategory(for item: ClipItem?) {
        newCategoryFor = item
        newCategoryName = ""
        showingNewCategory = true
    }

    private func createCategory() {
        let name = newCategoryName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let category = ClipCategory(context: context)
        category.name = name
        let count = (try? context.count(for: ClipCategory.fetchRequest())) ?? 1
        category.colorIndex = Int16((count - 1) % ClipCategory.palette.count)
        newCategoryFor?.toggle(category)
        try? context.save()
        tab = .category(category.objectID)
    }

    private func show(_ message: String) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        withAnimation(.snappy) { toast = message }
        Task {
            try? await Task.sleep(for: .seconds(1.3))
            withAnimation(.easeOut) { if toast == message { toast = nil } }
        }
    }
}

struct ItemActions {
    var copy: (ClipItem) -> Void
    var rename: (ClipItem) -> Void
    var newCategory: (ClipItem) -> Void
}

// MARK: - Category bar

private struct CategoryBar: View {
    @Binding var tab: HistoryTab
    var onNewCategory: () -> Void
    @Environment(\.managedObjectContext) private var context
    @FetchRequest(sortDescriptors: [SortDescriptor(\ClipCategory.createdAt)])
    private var categories: FetchedResults<ClipCategory>
    @FetchRequest(sortDescriptors: [], predicate: NSPredicate(format: "isPinned == YES"))
    private var pinned: FetchedResults<ClipItem>
    @State private var renamingCategory: ClipCategory?
    @State private var categoryName = ""

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Chip(title: "Clipboard", systemImage: "clock.arrow.circlepath", selected: tab == .all) { tab = .all }
                if !pinned.isEmpty || tab == .pinned {
                    Chip(title: "Pinned", systemImage: "pin", selected: tab == .pinned) { tab = .pinned }
                }
                ForEach(categories) { category in
                    Chip(title: category.name, color: category.color,
                         selected: tab == .category(category.objectID)) {
                        tab = .category(category.objectID)
                    }
                    .contextMenu { menu(for: category) }
                }
                Button(action: onNewCategory) {
                    Image(systemName: "plus")
                        .font(.body.weight(.medium))
                        .frame(width: 36, height: 34)
                }
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .alert("Rename Category", isPresented: Binding(get: { renamingCategory != nil }, set: { if !$0 { renamingCategory = nil } })) {
            TextField("Name", text: $categoryName)
            Button("Save") {
                let name = categoryName.trimmingCharacters(in: .whitespaces)
                if let category = renamingCategory, !name.isEmpty {
                    category.name = name
                    try? context.save()
                }
                renamingCategory = nil
            }
            Button("Cancel", role: .cancel) { renamingCategory = nil }
        }
    }

    @ViewBuilder
    private func menu(for category: ClipCategory) -> some View {
        Button { categoryName = category.name; renamingCategory = category } label: {
            Label("Rename", systemImage: "pencil")
        }
        Picker(selection: Binding(get: { Int(category.colorIndex) }, set: {
            category.colorIndex = Int16($0)
            try? context.save()
        })) {
            ForEach(ClipCategory.palette.indices, id: \.self) { index in
                Label(ColorNames.all[index], systemImage: "circle.fill")
                    .tint(ClipCategory.palette[index])
                    .tag(index)
            }
        } label: {
            Label("Color", systemImage: "paintpalette")
        }
        .pickerStyle(.menu)
        Divider()
        Button(role: .destructive) {
            if tab == .category(category.objectID) { tab = .all }
            context.delete(category)
            try? context.save()
        } label: {
            Label("Delete Category", systemImage: "trash")
        }
    }
}

enum ColorNames {
    static let all = ["Red", "Orange", "Yellow", "Green", "Teal", "Blue", "Purple", "Pink"]
}

private struct Chip: View {
    let title: String
    var systemImage: String?
    var color: Color?
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if let color {
                    Circle().fill(color).frame(width: 12, height: 12)
                } else if let systemImage {
                    Image(systemName: systemImage).font(.subheadline)
                }
                Text(title).lineLimit(1)
            }
            .font(.subheadline.weight(selected ? .semibold : .regular))
            .foregroundStyle(.primary)
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(selected ? Color.primary.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 9))
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Grid

/// Separate view so the fetch request is rebuilt when search or tab change.
private struct ItemGrid: View {
    let actions: ItemActions
    @Environment(\.managedObjectContext) private var context
    @FetchRequest private var items: FetchedResults<ClipItem>
    @FetchRequest(sortDescriptors: [SortDescriptor(\ClipCategory.createdAt)])
    private var categories: FetchedResults<ClipCategory>
    private let isSearching: Bool

    private let columns = [GridItem(.adaptive(minimum: 160), spacing: 12)]

    init(search: String, tab: HistoryTab, actions: ItemActions) {
        self.actions = actions
        var predicates: [NSPredicate] = []
        switch tab {
        case .all: break
        case .pinned: predicates.append(NSPredicate(format: "isPinned == YES"))
        case .kind(let kind): predicates.append(NSPredicate(format: "kindRaw == %@", kind.rawValue))
        case .category(let id): predicates.append(NSPredicate(format: "ANY categories == %@", id))
        }
        let query = search.trimmingCharacters(in: .whitespaces)
        isSearching = !query.isEmpty
        if isSearching {
            predicates.append(NSPredicate(format: "title CONTAINS[cd] %@ OR text CONTAINS[cd] %@ OR urlString CONTAINS[cd] %@ OR filePathsRaw CONTAINS[cd] %@",
                                          query, query, query, query))
        }
        let request = ClipItem.fetchRequest()
        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
        request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: false)]
        request.fetchBatchSize = 30
        _items = FetchRequest(fetchRequest: request, animation: .snappy)
    }

    var body: some View {
        if items.isEmpty {
            ContentUnavailableView(isSearching ? "No matches" : "Nothing saved yet",
                                   systemImage: isSearching ? "magnifyingglass" : "doc.on.clipboard",
                                   description: Text(isSearching ? "Try a different search." : "Copy something, then tap Paste to save it here."))
                .frame(maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(items) { item in
                        ClipCardView(item: item)
                            .onTapGesture { actions.copy(item) }
                            .contextMenu { menu(for: item) } preview: { ClipCardView(item: item).frame(width: 280, height: 300) }
                    }
                }
                .padding(16)
            }
        }
    }

    @ViewBuilder
    private func menu(for item: ClipItem) -> some View {
        Button { actions.copy(item) } label: { Label("Copy", systemImage: "doc.on.doc") }
        ShareItemLink(item: item)
        Button { actions.rename(item) } label: { Label("Rename", systemImage: "pencil") }
        Button {
            item.isPinned.toggle()
            try? context.save()
        } label: {
            Label(item.isPinned ? "Unpin" : "Pin", systemImage: item.isPinned ? "pin.slash" : "pin")
        }
        Menu {
            ForEach(categories) { category in
                Button {
                    item.toggle(category)
                    try? context.save()
                } label: {
                    Label(category.name, systemImage: item.isIn(category) ? "checkmark.circle.fill" : "circle")
                }
            }
            if !categories.isEmpty { Divider() }
            Button { actions.newCategory(item) } label: { Label("New Category…", systemImage: "plus") }
        } label: {
            Label("Category", systemImage: "folder")
        }
        Divider()
        Button(role: .destructive) {
            context.delete(item)
            try? context.save()
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }
}

private struct ShareItemLink: View {
    let item: ClipItem

    var body: some View {
        switch item.kind {
        case .text:
            ShareLink(item: item.text ?? "") { Label("Share", systemImage: "square.and.arrow.up") }
        case .url:
            if let url = URL(string: item.urlString ?? "") {
                ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") }
            }
        case .image:
            if let data = item.imageData, let image = UIImage(data: data) {
                let shared = Image(uiImage: image)
                ShareLink(item: shared, preview: SharePreview(item.title ?? "Image", image: shared)) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
            }
        case .file:
            ShareLink(item: item.filePaths.joined(separator: "\n")) { Label("Share Path", systemImage: "square.and.arrow.up") }
        }
    }
}
