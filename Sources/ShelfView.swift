import SwiftUI
import CoreData
import UniformTypeIdentifiers

extension UTType {
    /// A card dragged within ClipStack (declared in Info.plist), carrying its object ID.
    static let clipStackItem = UTType(exportedAs: "com.omid.clipstack.item")
}

enum CardDrag {
    /// Our own type for dropping on a category tab, plus the real content so the
    /// card can also be dropped into other apps.
    static func provider(for item: ClipItem) -> NSItemProvider {
        let provider = NSItemProvider()
        let uri = item.objectID.uriRepresentation().absoluteString
        provider.registerDataRepresentation(forTypeIdentifier: UTType.clipStackItem.identifier,
                                            visibility: .ownProcess) { completion in
            completion(Data(uri.utf8), nil)
            return nil
        }
        switch item.kind {
        case .text:
            provider.registerObject((item.text ?? "") as NSString, visibility: .all)
        case .url:
            if let url = URL(string: item.urlString ?? "") { provider.registerObject(url as NSURL, visibility: .all) }
        case .image:
            if let data = item.imageData {
                provider.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { completion in
                    completion(data, nil)
                    return nil
                }
            }
        case .file:
            if let path = item.filePaths.first {
                provider.registerObject(URL(fileURLWithPath: path) as NSURL, visibility: .all)
            }
        }
        return provider
    }

    /// Reads the object-ID URI back out of a dropped card.
    static func loadURI(from providers: [NSItemProvider], completion: @escaping @MainActor (String) -> Void) -> Bool {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.clipStackItem.identifier) })
        else { return false }
        _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.clipStackItem.identifier) { data, _ in
            guard let data, let uri = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(uri) } }
        }
        return true
    }
}

enum ShelfTab: Hashable {
    case all, pinned
    case kind(ClipKind)
    case category(NSManagedObjectID)
}

/// Shelf state shared by the views and the panel's keyboard handling.
/// (An ObservableObject because @State is a macro and CLT lacks its plugin.)
@MainActor
final class ShelfModel: ObservableObject {
    @Published var search = ""
    @Published var tab = ShelfTab.all { didSet { selectedIndex = 0 } }
    @Published var selectedIndex = 0
    @Published var copiedID: NSManagedObjectID?
    @Published var qrItem: ClipItem?
    /// Non-nil while the inline category name field is showing.
    @Published var categoryDraft: CategoryDraft?
    @Published var focusSearch = 0
    /// The bar shows a search icon until search is opened by clicking it or typing.
    @Published var searchActive = false

    /// Items currently on screen, in order, for arrow-key navigation.
    var visibleItems: [ClipItem] = []
    var onCopy: () -> Void = {}

    struct CategoryDraft: Equatable {
        var name = ""
        /// Category being renamed, or nil when creating one.
        var editing: ClipCategory?
        /// Item to add to the new category once it's created.
        var pendingItem: ClipItem?
        /// Picked in the name field; nil means the category's current (or next) color.
        var colorIndex: Int16?
    }

    var selectedItem: ClipItem? {
        visibleItems.indices.contains(selectedIndex) ? visibleItems[selectedIndex] : nil
    }

    func moveSelection(by delta: Int) {
        guard !visibleItems.isEmpty else { return }
        selectedIndex = min(max(selectedIndex + delta, 0), visibleItems.count - 1)
    }

    func closeSearch() {
        search = ""
        searchActive = false
        if case .kind = tab { tab = .all }
    }

    /// Starts a search from a key typed while the shelf has focus.
    func beginSearch(with characters: String) {
        searchActive = true
        search += characters
        focusSearch += 1
    }

    func reset() {
        search = ""
        searchActive = false
        selectedIndex = 0
        qrItem = nil
        categoryDraft = nil
        focusSearch += 1
    }

    func copy(_ item: ClipItem) {
        guard let context = item.managedObjectContext else { return }
        Paster.write(item)
        item.createdAt = Date()
        try? context.save()
        copiedID = item.objectID
        Task {
            try? await Task.sleep(for: .seconds(0.3))
            onCopy()
            try? await Task.sleep(for: .seconds(0.5))
            if copiedID == item.objectID { copiedID = nil }
        }
    }

    func commitCategoryDraft(in context: NSManagedObjectContext) {
        guard let draft = categoryDraft else { return }
        categoryDraft = nil
        let name = draft.name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        if let category = draft.editing {
            category.name = name
            if let color = draft.colorIndex { category.colorIndex = color }
        } else {
            let category = ClipCategory(context: context)
            category.name = name
            category.colorIndex = draft.colorIndex ?? Self.nextColor(in: context)
            draft.pendingItem?.toggle(category)
            tab = .category(category.objectID)
        }
        try? context.save()
    }

    /// New categories cycle through the palette.
    static func nextColor(in context: NSManagedObjectContext) -> Int16 {
        let count = (try? context.count(for: ClipCategory.fetchRequest())) ?? 0
        return Int16(count % ClipCategory.palette.count)
    }

    /// Adds a card dropped on a category tab. Returns false if the drop wasn't one of our cards.
    @discardableResult
    func addDroppedItem(_ uri: String, to category: ClipCategory) -> Bool {
        guard let context = category.managedObjectContext,
              let url = URL(string: uri),
              let id = context.persistentStoreCoordinator?.managedObjectID(forURIRepresentation: url),
              let item = try? context.existingObject(with: id) as? ClipItem
        else { return false }
        if !item.isIn(category) { item.toggle(category) }
        try? context.save()
        return true
    }
}

struct ShelfView: View {
    @ObservedObject var model: ShelfModel

    var body: some View {
        VStack(spacing: 0) {
            ShelfBar(model: model)
            ShelfCards(model: model, search: model.search, tab: model.tab)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            if let item = model.qrItem, let payload = QRCode.payload(for: item) {
                ZStack {
                    Color.black.opacity(0.35)
                        .onTapGesture { model.qrItem = nil }
                    QRShareView(payload: payload, isURL: item.kind == .url) { model.qrItem = nil }
                        .scaleEffect(0.85)
                }
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: model.qrItem)
    }
}

// MARK: - Top bar

/// One centered row: search icon, Clipboard, the user's categories, and +.
private struct ShelfBar: View {
    @ObservedObject var model: ShelfModel
    @Environment(\.managedObjectContext) private var context
    @FetchRequest(sortDescriptors: [SortDescriptor(\ClipCategory.createdAt)])
    private var categories: FetchedResults<ClipCategory>
    @FetchRequest(sortDescriptors: [], predicate: NSPredicate(format: "isPinned == YES"))
    private var pinned: FetchedResults<ClipItem>
    @FocusState private var searchFocused: Bool
    @FocusState private var draftFocused: Bool

    var body: some View {
        GeometryReader { geometry in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    search
                    Tab(title: "Clipboard", systemImage: "clock.arrow.circlepath", selected: model.tab == .all) {
                        model.tab = .all
                    }
                    if !pinned.isEmpty || model.tab == .pinned {
                        Tab(title: "Pinned", systemImage: "pin", selected: model.tab == .pinned) { model.tab = .pinned }
                    }
                    ForEach(categories) { category in
                        if model.categoryDraft?.editing == category {
                            draftField
                        } else {
                            Tab(title: category.name, color: category.color,
                                selected: model.tab == .category(category.objectID),
                                onDropItem: { model.addDroppedItem($0, to: category) }) {
                                model.tab = .category(category.objectID)
                            }
                            .contextMenu { categoryMenu(category) }
                        }
                    }
                    if let draft = model.categoryDraft, draft.editing == nil {
                        draftField
                    } else {
                        Button { model.categoryDraft = .init() } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 17, weight: .regular))
                                .frame(width: 36, height: 34)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("New category")
                    }
                }
                .padding(.horizontal, 16)
                .frame(minWidth: geometry.size.width)
            }
        }
        .frame(height: 50)
        .padding(.top, 8)
        .onChange(of: model.searchActive) { searchFocused = model.searchActive }
        .onChange(of: model.focusSearch) { if model.searchActive { searchFocused = true } }
    }

    @ViewBuilder
    private var search: some View {
        if model.searchActive {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search", text: $model.search)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .frame(width: 170)
                kindMenu
                Button { model.closeSearch() } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 15))
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(Color.primary.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            .padding(.trailing, 6)
        } else {
            Button { model.searchActive = true } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 17))
                    .frame(width: 40, height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Search (or just start typing)")
            .padding(.trailing, 6)
        }
    }

    private var kindMenu: some View {
        let kinds: [(ClipKind, String, String)] = [(.text, "Text", "text.alignleft"), (.url, "Links", "link"),
                                                    (.image, "Images", "photo"), (.file, "Files", "doc")]
        let current = kinds.first { model.tab == .kind($0.0) }
        return Menu {
            Button("All Types") { model.tab = .all }
            Divider()
            ForEach(kinds, id: \.0) { kind, title, icon in
                Button { model.tab = .kind(kind) } label: { Label(title, systemImage: icon) }
            }
        } label: {
            Image(systemName: current?.2 ?? "line.3.horizontal.decrease.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(current != nil ? Color.accentColor : .secondary)
        .help(current.map { "Showing \($0.1)" } ?? "Filter by type")
    }

    private var draftField: some View {
        HStack(spacing: 8) {
            Circle().fill(ClipCategory.palette[draftColorIndex]).frame(width: 14, height: 14)
            TextField("Category name", text: Binding(
                get: { model.categoryDraft?.name ?? "" },
                set: { model.categoryDraft?.name = $0 }))
                .textFieldStyle(.plain)
                .focused($draftFocused)
                .frame(width: 140)
                .onSubmit { model.commitCategoryDraft(in: context) }
                .onAppear { draftFocused = true }
            draftColorSwatches
        }
        .font(.system(size: 15))
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor, lineWidth: 1.5))
    }

    private var draftColorIndex: Int {
        Int(model.categoryDraft?.colorIndex
            ?? model.categoryDraft?.editing?.colorIndex
            ?? ShelfModel.nextColor(in: context)) % ClipCategory.palette.count
    }

    /// Swatches shown beside the name field. Plain SwiftUI buttons, since a menu or
    /// popover would take key status from the shelf and close it.
    private var draftColorSwatches: some View {
        HStack(spacing: 5) {
            ForEach(ClipCategory.palette.indices, id: \.self) { option in
                Button {
                    model.categoryDraft?.colorIndex = Int16(option)
                    draftFocused = true
                } label: {
                    Circle()
                        .fill(ClipCategory.palette[option])
                        .frame(width: 14, height: 14)
                        .padding(2)
                        .overlay(Circle().strokeBorder(Color.primary.opacity(option == draftColorIndex ? 0.9 : 0), lineWidth: 1.5))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(Self.colorNames[option])
            }
        }
        .padding(.leading, 2)
    }

    @ViewBuilder
    private func categoryMenu(_ category: ClipCategory) -> some View {
        Button("Rename…") { model.categoryDraft = .init(name: category.name, editing: category) }
        Menu("Color") {
            ForEach(ClipCategory.palette.indices, id: \.self) { index in
                Button { category.colorIndex = Int16(index); try? context.save() } label: {
                    Label(Self.colorNames[index], systemImage: category.colorIndex == index ? "checkmark.circle.fill" : "circle.fill")
                }
            }
        }
        Divider()
        Button("Delete Category", role: .destructive) {
            if model.tab == .category(category.objectID) { model.tab = .all }
            context.delete(category)
            try? context.save()
        }
    }

    private static let colorNames = ["Red", "Orange", "Yellow", "Green", "Teal", "Blue", "Purple", "Pink"]
}

/// A plain label with a colored dot or icon; the selected one sits in a rounded highlight.
private struct Tab: View {
    let title: String
    var systemImage: String?
    var color: Color?
    let selected: Bool
    /// Set on category tabs so cards can be dropped onto them.
    var onDropItem: ((String) -> Bool)?
    let action: () -> Void
    private let targeted = State(initialValue: false) // @State is a macro; CLT lacks its plugin

    var body: some View {
        let highlight = targeted.wrappedValue ? (color ?? .accentColor).opacity(0.35)
            : selected ? Color.primary.opacity(0.14) : .clear
        Button(action: action) {
            HStack(spacing: 8) {
                if let color {
                    Circle().fill(color).frame(width: 14, height: 14)
                } else if let systemImage {
                    Image(systemName: systemImage).font(.system(size: 15))
                }
                Text(title).lineLimit(1)
            }
            .font(.system(size: 15))
            .foregroundStyle(Color.primary.opacity(selected ? 1 : 0.85))
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(highlight, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .scaleEffect(targeted.wrappedValue ? 1.08 : 1)
        .animation(.snappy(duration: 0.15), value: targeted.wrappedValue)
        .onDrop(of: onDropItem == nil ? [] : [.clipStackItem], isTargeted: targeted.projectedValue) { providers in
            guard let onDropItem else { return false }
            return CardDrag.loadURI(from: providers) { _ = onDropItem($0) }
        }
    }
}

// MARK: - Cards

/// Separate view so the fetch request is rebuilt when search or tab change.
private struct ShelfCards: View {
    @ObservedObject var model: ShelfModel
    @Environment(\.managedObjectContext) private var context
    @FetchRequest private var items: FetchedResults<ClipItem>
    @FetchRequest(sortDescriptors: [SortDescriptor(\ClipCategory.createdAt)])
    private var categories: FetchedResults<ClipCategory>

    init(model: ShelfModel, search: String, tab: ShelfTab) {
        self.model = model
        var predicates: [NSPredicate] = []
        switch tab {
        case .all: break
        case .pinned: predicates.append(NSPredicate(format: "isPinned == YES"))
        case .kind(let kind): predicates.append(NSPredicate(format: "kindRaw == %@", kind.rawValue))
        case .category(let id): predicates.append(NSPredicate(format: "ANY categories == %@", id))
        }
        let query = search.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty {
            predicates.append(NSPredicate(format: "text CONTAINS[cd] %@ OR urlString CONTAINS[cd] %@ OR filePathsRaw CONTAINS[cd] %@",
                                          query, query, query))
        }
        let request = ClipItem.fetchRequest()
        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
        // The main history is newest first, like a timeline; pins live in their own tab.
        request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: false)]
        request.fetchBatchSize = 30
        _items = FetchRequest(fetchRequest: request, animation: .snappy)
    }

    var body: some View {
        Group {
            if items.isEmpty {
                ContentUnavailableView(emptyTitle, systemImage: "rectangle.stack",
                                       description: Text(emptyMessage))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 14) {
                            ForEach(Array(items.enumerated()), id: \.element.objectID) { index, item in
                                card(item, index: index)
                                    .id(item.objectID)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                    }
                    .onChange(of: model.selectedIndex) {
                        guard let item = model.selectedItem else { return }
                        withAnimation(.snappy) { proxy.scrollTo(item.objectID, anchor: .center) }
                    }
                }
            }
        }
        .onAppear { model.visibleItems = Array(items) }
        .onChange(of: items.map(\.objectID)) {
            model.visibleItems = Array(items)
            model.selectedIndex = min(model.selectedIndex, max(items.count - 1, 0))
        }
    }

    private func card(_ item: ClipItem, index: Int) -> some View {
        let payload = QRCode.payload(for: item)
        return ClipCardView(item: item,
                            selected: model.selectedIndex == index,
                            justCopied: model.copiedID == item.objectID,
                            onShowQR: payload.map { _ in { model.qrItem = item } })
            .onDrag { CardDrag.provider(for: item) }
            .onTapGesture {
                model.selectedIndex = index
                model.copy(item)
            }
            .contextMenu {
                Button("Copy") { model.copy(item) }
                if payload != nil {
                    Button("Show QR Code") { model.qrItem = item }
                }
                Button(item.isPinned ? "Unpin" : "Pin") {
                    item.isPinned.toggle()
                    try? context.save()
                }
                Menu("Category") {
                    ForEach(categories) { category in
                        Button {
                            item.toggle(category)
                            try? context.save()
                        } label: {
                            Label(category.name, systemImage: item.isIn(category) ? "checkmark.circle.fill" : "circle")
                        }
                    }
                    if !categories.isEmpty { Divider() }
                    Button("New Category…") { model.categoryDraft = .init(pendingItem: item) }
                }
                Divider()
                Button("Delete", role: .destructive) {
                    context.delete(item)
                    try? context.save()
                }
            }
    }

    private var emptyTitle: String {
        switch model.tab {
        case .all: model.search.isEmpty ? "Nothing copied yet" : "No matches"
        case .pinned: "No pinned items"
        case .kind: "Nothing of this type"
        case .category: "This category is empty"
        }
    }

    private var emptyMessage: String {
        if !model.search.isEmpty { return "Try a different search." }
        return switch model.tab {
        case .category: "Right-click any card and choose Category to add it here."
        case .pinned: "Right-click a card and choose Pin."
        default: "Copy something and it will show up here."
        }
    }
}
