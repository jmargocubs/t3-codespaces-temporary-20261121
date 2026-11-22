import Foundation
import SwiftUI
import OSLog

enum LiveTVCategoryAppearance: String, CaseIterable, Codable { case list = "List", hybrid = "Hybrid", grid = "Grid" }
enum LiveTVCategoryGrouping: String, CaseIterable, Codable { case provider = "Provider Order", grouped = "Grouped" }

/// Preferences are local to Kyro; catalog entries and Guide data are never changed.
struct LiveTVCategoryPreferences: Codable, Equatable {
    var appearance: LiveTVCategoryAppearance = .hybrid
    var grouping: LiveTVCategoryGrouping = .provider
    var pinned: [String] = []
    var recent: [String] = []
    var hidden: Set<String> = []

    static let key = "kyro.liveTV.categoryPreferences.build78"
    private static let appearanceKey = "\(key).appearance"
    private static let groupingKey = "\(key).grouping"
    private static func providerKey(_ id: UUID) -> String { "\(key).provider.\(id.uuidString)" }
    static func load(providerID: UUID?, from defaults: UserDefaults = .standard) -> Self {
        var value = Self()
        // Migrate only presentation choices from the old unscoped record. Names cannot safely
        // be assigned to a provider when two providers have a category with the same name.
        let legacy = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(Self.self, from: $0) }
        value.appearance = defaults.string(forKey: appearanceKey).flatMap(LiveTVCategoryAppearance.init(rawValue:)) ?? legacy?.appearance ?? .hybrid
        value.grouping = defaults.string(forKey: groupingKey).flatMap(LiveTVCategoryGrouping.init(rawValue:)) ?? legacy?.grouping ?? .provider
        if let providerID, let data = defaults.data(forKey: providerKey(providerID)),
           let scoped = try? JSONDecoder().decode(Self.self, from: data) {
            value.pinned = scoped.pinned
            value.recent = scoped.recent
            value.hidden = scoped.hidden
        }
        return value
    }
    func save(providerID: UUID?, to defaults: UserDefaults = .standard) {
        defaults.set(appearance.rawValue, forKey: Self.appearanceKey)
        defaults.set(grouping.rawValue, forKey: Self.groupingKey)
        guard let providerID else { return }
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.providerKey(providerID))
    }
    mutating func togglePin(_ name: String) {
        if let index = pinned.firstIndex(of: name) { pinned.remove(at: index) } else { pinned.append(name) }
    }
    mutating func toggleHidden(_ name: String) {
        if hidden.contains(name) { hidden.remove(name) } else { hidden.insert(name) }
    }
    mutating func opened(_ name: String) {
        recent.removeAll { $0 == name }
        recent.insert(name, at: 0)
        recent = Array(recent.prefix(5))
    }
    mutating func movePin(from source: IndexSet, to destination: Int) {
        pinned.move(fromOffsets: source, toOffset: destination)
    }
    func availablePinned(in categories: [String]) -> [String] {
        let available = Set(categories).subtracting(hidden)
        return pinned.filter { available.contains($0) }
    }
    func availableRecent(in categories: [String]) -> [String] {
        let available = Set(categories).subtracting(hidden).subtracting(pinned)
        return recent.filter { available.contains($0) }
    }
}

enum LiveTVCategorySearch {
    static func tokens(_ value: String) -> [String] {
        let folded = value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        return folded.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }
    static func matches(_ name: String, query: [String]) -> Bool {
        guard !query.isEmpty else { return true }
        let words = tokens(name)
        return query.allSatisfy { token in words.contains { $0.hasPrefix(token) } }
    }
}

enum LiveTVCategoryGroup: String, CaseIterable {
    case sports = "Sports", local = "Local TV", entertainment = "Entertainment", movies = "Movies"
    case kids = "Kids & Family", news = "News", music = "Music", international = "International", other = "Other"
    static func classify(_ name: String) -> Self {
        let words = Set(LiveTVCategorySearch.tokens(name))
        let rules: [(Self, Set<String>)] = [
            (.sports, ["sports", "sport", "nfl", "nba", "mlb", "soccer", "football", "hockey"]),
            (.local, ["local"]), (.movies, ["movies", "movie", "cinema", "films"]),
            (.kids, ["kids", "children", "family", "cartoons"]),
            (.news, ["news"]), (.music, ["music", "radio"]),
            (.entertainment, ["entertainment"]), (.international, ["international"])
        ]
        let matches = rules.filter { !words.isDisjoint(with: $0.1) }
        return matches.count == 1 ? matches[0].0 : .other
    }
}

/// Per-category facts for the Categories page, built in one pass over the catalog already in
/// memory. Rows look values up here; nothing counts, sorts or scans inside a row body.
struct LiveTVCategoryDirectory: Equatable, Sendable {
    struct Entry: Equatable, Sendable {
        let channelCount: Int
        /// The first channel in provider order with a logo, used as the category's artwork.
        let artworkChannel: LiveTVChannel?
    }

    /// Provider order, unchanged.
    let categories: [String]
    let frequent: [String]
    let favoriteChannelCount: Int
    let totalChannelCount: Int
    private let entries: [String: Entry]

    static let empty = LiveTVCategoryDirectory(categories: [], frequent: [], favoriteChannelCount: 0,
                                               totalChannelCount: 0, entries: [:])

    func entry(for category: String) -> Entry {
        entries[category] ?? Entry(channelCount: 0, artworkChannel: nil)
    }

    static func build(categories: [String], channels: [LiveTVChannel], favoriteIDs: Set<String>,
                      ranksFrequent: Bool = true) -> LiveTVCategoryDirectory {
        var counts: [String: Int] = [:]
        var artwork: [String: LiveTVChannel] = [:]
        var favorites = 0
        counts.reserveCapacity(categories.count)
        for channel in channels {
            counts[channel.category, default: 0] += 1
            if channel.logoURL != nil, artwork[channel.category] == nil { artwork[channel.category] = channel }
            if favoriteIDs.contains(channel.id) { favorites += 1 }
        }
        var entries: [String: Entry] = [:]
        entries.reserveCapacity(categories.count)
        for category in categories where entries[category] == nil {
            entries[category] = Entry(channelCount: counts[category, default: 0], artworkChannel: artwork[category])
        }
        let frequent = ranksFrequent
            ? LiveTVGuideCategoryPickerModel.frequentCategories(categories: categories, channels: channels,
                                                                favoriteIDs: favoriteIDs)
            : []
        return LiveTVCategoryDirectory(categories: categories, frequent: frequent, favoriteChannelCount: favorites,
                                       totalChannelCount: channels.count, entries: entries)
    }

    #if os(iOS)
    static func indexed(_ summaries: [LiveTVChannelCatalogStore.CategorySummary]) -> LiveTVCategoryDirectory {
        let categories = summaries.map(\.name)
        let entries = Dictionary(uniqueKeysWithValues: summaries.map {
            ($0.name, Entry(channelCount: $0.channelCount, artworkChannel: $0.artworkChannel))
        })
        let frequent = summaries.enumerated().sorted {
            let lhs = ($0.element.favoriteCount, $0.element.channelCount)
            let rhs = ($1.element.favoriteCount, $1.element.channelCount)
            return lhs == rhs ? $0.offset < $1.offset : lhs > rhs
        }.prefix(4).map(\.element.name)
        return LiveTVCategoryDirectory(categories: categories, frequent: frequent,
                                       favoriteChannelCount: summaries.reduce(0) { $0 + $1.favoriteCount },
                                       totalChannelCount: summaries.reduce(0) { $0 + $1.channelCount },
                                       entries: entries)
    }
    #endif
}

/// Keeps the shared category page source-compatible with tvOS while enabling the iOS-only
/// SQLite directory. The non-iOS targets continue through their established in-memory path.
@MainActor
func liveTVIndexedCategoryDirectory(service: LiveTVService) -> ((UUID) async -> LiveTVCategoryDirectory)? {
    #if os(iOS)
    return { providerID in await service.categoryDirectory(providerID: providerID) }
    #else
    return nil
    #endif
}

/// What the user picked on the Categories page.
enum LiveTVCategoryChoice: Equatable, Sendable {
    case all
    case favorites
    case category(String)

    /// The category filter this choice applies; favorites is not a category.
    var category: String? {
        if case .category(let name) = self { return name }
        return nil
    }
}

/// Navigation decisions for the Categories page, kept pure so they can be tested without a host.
enum LiveTVCategoryNavigation {
    /// How a caller shows the page. The watch screen's Guide is a tab under the player inside
    /// Watch's own cover; a push there would squeeze the page into that tab, so it gets a fixed
    /// full-height sheet with its own stack. Every other caller pushes.
    enum Presentation: Equatable { case push, fullHeightSheet }

    static func guidePresentation(isWatchGuide: Bool) -> Presentation {
        isWatchGuide ? .fullHeightSheet : .push
    }

    /// Home's choice becomes the browser's starting filters.
    static func homeFilters(for choice: LiveTVCategoryChoice) -> LiveTVBrowserFilters {
        switch choice {
        case .all: .channels
        case .favorites: .favorites
        case .category(let name): .category(name)
        }
    }

    /// The parent is selected at entry, not inferred from transient stack visibility.
    static func ownsPushedBrowser(fromCategories: Bool, isBrowserPushed: Bool,
                                  openedFromCategories: Bool) -> Bool {
        isBrowserPushed && openedFromCategories == fromCategories
    }

    static func shouldHandleBrowserPop(fromCategories: Bool, openedFromCategories: Bool,
                                       showingBrowser: Bool, stackShowsBrowser: Bool) -> Bool {
        openedFromCategories == fromCategories && showingBrowser && !stackShowsBrowser
    }

    static func shouldDismissCategories(showingCategories: Bool, browserPushedFromCategories: Bool) -> Bool {
        showingCategories && !browserPushedFromCategories
    }

    /// Where the browser replaces Home in place (Live TV itself pushed), Categories pops first.
    static func popsCategoriesOnChoice(isTabRoot: Bool) -> Bool {
        !LiveTVNavigationPolicy.pushesBrowser(isTabRoot: isTabRoot)
    }

    /// A filter page's choice is the new selection. Leaving with Back, a swipe or Cancel never
    /// calls this, so the selection stays as it was.
    static func filterSelection(for choice: LiveTVCategoryChoice) -> String? { choice.category }

    /// A picker choice replaces the complete filter state. Category and Favorites are mutually
    /// exclusive; carrying the previous flag across a choice silently produced an empty/intersected
    /// result set and made section switches appear to retain the old collection.
    static func browserFilters(for choice: LiveTVCategoryChoice) -> LiveTVBrowserFilters {
        switch choice {
        case .all: .channels
        case .favorites: .favorites
        case .category(let name): .category(name)
        }
    }
}

/// Live TV Home's pushed routes, as typed entries on the shell's `NavigationPath`. Home is the
/// implicit root. The shell registers these values with `liveTVShellRoutes` (Build 82); this
/// ledger records which trailing entries of the shell path are Live TV's. Every mutation goes
/// through a named method, so each change has one owner and one trace line.
struct LiveTVHomeRoutes: Equatable {
    enum Destination: Hashable {
        case categories
        case channels(provider: UUID?, category: String?)
        var traceName: String {
            switch self {
            case .categories: "categories"
            // Salted per-process identity, not a provider ID or category name.
            case .channels: "channels#\(String(UInt(bitPattern: hashValue), radix: 16))"
            }
        }
    }
    /// An intent ledger for the typed suffix on the shell's real NavigationPath. It is never
    /// bound to a second stack or used by an isPresented destination.
    private(set) var path: [Destination] = []
    private(set) var baseDepth = 0
    /// The destination that pushed the channel browser, fixed when it opens.
    enum Owner: String, Equatable { case home, categories }

    var showsCategories: Bool { path.contains(.categories) }
    var browserOwner: Owner? {
        guard path.contains(where: { if case .channels = $0 { return true }; return false }) else { return nil }
        return showsCategories ? .categories : .home
    }

    var showsBrowser: Bool { browserOwner != nil }
    var browserOpenedFromCategories: Bool { browserOwner == .categories }

    // MARK: Intents (user actions)

    mutating func openCategories(source: String) {
        if !showsCategories { path.append(.categories) }
        LiveTVRouteTrace.log("push", route: "categories", owner: "home", detail: source)
    }

    /// Where the browser replaces Home in place, Categories pops before the browser shows.
    mutating func popCategoriesForChoice() {
        path.removeAll { $0 == .categories }
        LiveTVRouteTrace.log("pop", route: "categories", owner: "categories", detail: "choice replaces Home in place")
    }

    mutating func openBrowser(fromCategories: Bool, source: String, providerID: UUID? = nil, category: String? = nil) {
        let owner: Owner = fromCategories ? .categories : .home
        if browserOwner != nil, browserOwner != owner {
            LiveTVRouteTrace.log("replace", route: "channels", owner: owner.rawValue,
                                 detail: "previous owner \(browserOwner?.rawValue ?? "none")")
        }
        path = fromCategories ? [.categories, .channels(provider: providerID, category: category)]
                              : [.channels(provider: providerID, category: category)]
        LiveTVRouteTrace.log("push", route: "channels", owner: owner.rawValue, detail: source)
    }

    /// A programmatic or reported return from the browser. Categories, if shown, stays.
    mutating func closeBrowser(reason: String) {
        guard let owner = browserOwner else { return }
        if let index = path.firstIndex(where: { if case .channels = $0 { return true }; return false }) {
            path.removeSubrange(index...)
        }
        LiveTVRouteTrace.log("pop", route: "channels", owner: owner.rawValue, detail: reason)
    }


    /// The one write path: folds in a native pop not yet observed, applies the intent, then
    /// mutates the shell path in place. An intent is never dropped for a stale depth.
    mutating func perform(on root: inout NavigationPath, reason: String,
                          _ change: (inout LiveTVHomeRoutes) -> Void) {
        reconcile(rootDepth: root.count)
        let previous = path
        change(&self)
        apply(previous: previous, to: &root, reason: reason)
    }

    /// Mutate the existing shell NavigationPath in place. Never recreate a NavigationStack.
    mutating func apply(previous: [Destination], to root: inout NavigationPath, reason: String) {
        if previous.isEmpty { baseDepth = root.count }
        let common = zip(previous, path).prefix(while: { $0 == $1 }).count
        let remove = previous.count - common
        let depthBefore = root.count
        guard root.count == baseDepth + previous.count else {
            // Another feature's entries sit above Live TV's: never remove or reorder them.
            path = previous
            reconcile(rootDepth: root.count)
            LiveTVNavigationDiagnostics.shared.record("rejected intent over foreign entries: \(reason)", before: previous,
                                                      after: path, note: "depth=\(depthBefore) base=\(baseDepth)")
            return
        }
        if remove > 0 { root.removeLast(remove) }
        for route in path.dropFirst(common) { root.append(route) }
        LiveTVNavigationDiagnostics.shared.record("push/pop \(reason)", before: previous, after: path,
                                                  note: "shell depth \(depthBefore)->\(root.count) base=\(baseDepth)")
    }

    /// Native Back/swipe modifies the root path. Observe it; do not pop again in response.
    /// Returns true when the observed change closed the channel browser.
    @discardableResult
    mutating func reconcile(rootDepth: Int) -> Bool {
        let hadBrowser = showsBrowser
        let before = path
        path = Array(path.prefix(max(0, rootDepth - baseDepth)))
        if before != path {
            LiveTVNavigationDiagnostics.shared.record("shell path write: native Back/swipe/pop-to-root", before: before,
                                                      after: path, note: "shell depth=\(rootDepth) base=\(baseDepth)")
        }
        return hadBrowser && !showsBrowser
    }
}

/// Temporary, bounded on-device evidence. Off on every launch; no names, UUIDs, URLs or credentials.
@Observable
final class LiveTVNavigationDiagnostics {
    static let shared = LiveTVNavigationDiagnostics()
    static var isAvailable: Bool {
        #if DEBUG
        true
        #else
        Bundle.main.object(forInfoDictionaryKey: "SiloBuildChannel") as? String == "sideload"
        #endif
    }
    var enabled = false
    private(set) var lines: [String] = []
    private var sequence = 0
    func record(_ reason: String, before: [LiveTVHomeRoutes.Destination], after: [LiveTVHomeRoutes.Destination],
                note: String = "") {
        append("owner=LiveTV/shell \(reason) [\(before.map(\.traceName).joined(separator: ","))] -> [\(after.map(\.traceName).joined(separator: ","))]\(note.isEmpty ? "" : " " + note)")
    }
    /// A line without a route change: a destination resolving, or a shell path attaching.
    func note(_ text: String) { append(text) }
    private func append(_ line: String) {
        guard enabled, Self.isAvailable else { return }
        sequence += 1
        lines.append("\(sequence) \(line)")
        if lines.count > 150 { lines.removeFirst(lines.count - 150) }
    }
    var export: String { (["Kyro Categories navigation trace (names and provider identities omitted)"] + lines).joined(separator: "\n") }
}

struct LiveTVNavigationDiagnosticsView: View {
    @Bindable private var trace = LiveTVNavigationDiagnostics.shared
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Toggle("Record Categories navigation", isOn: $trace.enabled)
                Text("Off by default. Keeps the latest 150 events in memory. Enable, reproduce Back, then return here to share the trace. No provider or category names are recorded. A \"push/pop\" line without a following \"destination resolved\" line means the screen did not resolve.")
                    .font(.footnote)
                ShareLink("Share navigation trace", item: trace.export)
                #if os(iOS)
                Button("Copy navigation trace") { UIPasteboard.general.string = trace.export }
                #endif
                Text(trace.export).font(.caption.monospaced()).textSelection(.enabled)
            }
            .navigationTitle("Navigation Diagnostics")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

/// DEBUG-only navigation trace for Live TV Home routes. Lines name the route, the owner that
/// changed it and the trigger; never URLs, credentials or provider details. Filter Console by
/// subsystem `com.cubbiestream.kyro`, category `LiveTVNavigation`.
enum LiveTVRouteTrace {
    #if DEBUG
    private static let logger = Logger(subsystem: "com.cubbiestream.kyro", category: "LiveTVNavigation")
    #endif

    @inline(__always)
    static func log(_ event: String, route: String, owner: String, detail: String = "") {
        #if DEBUG
        logger.notice("[route] \(event, privacy: .public) \(route, privacy: .public) owner=\(owner, privacy: .public) \(detail, privacy: .public)")
        #endif
    }
}

/// How the page behaves for its caller. Home browses (rows push channels, so they show a chevron);
/// the channel browser and Guide filter (rows apply a selection, so the current one is checked).
enum LiveTVCategoryPageMode: Equatable {
    case browse
    case filter(selected: String?)

    var selected: String? {
        if case .filter(let selected) = self { return selected }
        return nil
    }
}

/// A letter tile for categories without artwork. The color comes from a stable hash of the name
/// so it is the same on every launch (`hashValue` is seeded per process).
enum LiveTVCategoryFallbackIcon {
    static func letter(for category: String) -> String {
        // Provider names often read "USA | Sports"; the part after the last separator is the name.
        let tail = category.split(separator: "|").last.map(String.init) ?? category
        let source = tail.first(where: { $0.isLetter || $0.isNumber }) != nil ? tail : category
        guard let first = source.first(where: { $0.isLetter || $0.isNumber }) else { return "#" }
        return String(first).uppercased()
    }

    static func hue(for category: String) -> Double {
        var hash: UInt32 = 5381
        for scalar in category.unicodeScalars { hash = (hash &* 33) &+ scalar.value }
        return Double(hash % 360) / 360
    }
}

/// Build 82.1: which remembered Categories row should drive `scrollPosition` on appear.
///
/// The search field sits above the `scrollTargetLayout`, so scrolling any row ID — including
/// `.allCategories` — to `anchor: .top` pushes search off-screen and collapses the large title.
/// A fresh entry and a remembered "All Channels" row therefore keep `position == nil` (content
/// offset 0). Only a mid-list `.category` restore scrolls.
enum LiveTVCategoryScrollRestore {
    static func positionForAppear(_ initial: LiveTVGuideCategoryPickerID?) -> LiveTVGuideCategoryPickerID? {
        switch initial {
        case nil, .allCategories: return nil
        case .category: return initial
        }
    }

    /// Whether a remembered ID is a true mid-list restore (not the visual top).
    static func isMidListRestore(_ initial: LiveTVGuideCategoryPickerID?) -> Bool {
        positionForAppear(initial) != nil
    }
}

/// Live TV's full-page category browser. Home, the channel browser and the Guide each pass their
/// own selection and remembered position, so sharing the page never couples their filters.
/// The page owns its scroll position and search while open; callers only hear the final choice
/// and, on leaving, the last visible row. Scrolling never writes the caller's state.
struct LiveTVCategoryBrowserPage: View {
    let providerID: UUID?
    let title: String
    let allTitle: String
    let mode: LiveTVCategoryPageMode
    let categories: [String]
    let channels: [LiveTVChannel]
    let favoriteIDs: Set<String>
    let catalogRevision: Int
    /// iOS production catalogs provide one indexed summary per category. Other platforms and
    /// legacy snapshots keep the established in-memory builder.
    var indexedDirectory: ((UUID) async -> LiveTVCategoryDirectory)? = nil
    /// Home offers a Favorites row; filters keep their own favorites toggle.
    var showsFavorites = false
    let initialPosition: LiveTVGuideCategoryPickerID?
    let select: (LiveTVCategoryChoice) -> Void
    /// Reports the last visible row when the page leaves, for the caller's remembered position.
    var rememberPosition: (LiveTVGuideCategoryPickerID?) -> Void = { _ in }
    /// Shown as a Cancel button when the page has its own stack (the watch screen's Guide).
    var cancel: (() -> Void)?

    @State private var query = ""
    @State private var directory = LiveTVCategoryDirectory.empty
    @State private var projection = LiveTVGuideCategoryPickerModel.Projection(frequent: [], remaining: [])
    @State private var position: LiveTVGuideCategoryPickerID?
    @State private var hasPrepared = false
    @State private var preferences = LiveTVCategoryPreferences()
    @State private var showingManage = false
    @State private var showingDiagnostics = false
    @State private var directoryGeneration = 0
    @FocusState private var isSearchFocused: Bool
    @ScaledMetric(relativeTo: .body) private var tileMinHeight: CGFloat = 180

    private var isSearching: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                searchField
                LazyVStack(alignment: .leading, spacing: 0) {
                    rows
                }
                .scrollTargetLayout()
            }
            .padding(.bottom, 24)
        }
        .scrollPosition(id: $position, anchor: .top)
        .scrollDismissesKeyboard(.immediately)
        .liveTVPageBackground()
        .tint(LiveTVAccent.primaryText)
        .navigationTitle(title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.large)
        #endif
        .toolbar {
            if let cancel {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: cancel) }
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Picker("View", selection: $preferences.appearance) {
                        ForEach(LiveTVCategoryAppearance.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    Picker("Organization", selection: $preferences.grouping) {
                        ForEach(LiveTVCategoryGrouping.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    Button("Manage Categories") { showingManage = true }
                    if LiveTVNavigationDiagnostics.isAvailable {
                        Button("Navigation Diagnostics") { showingDiagnostics = true }
                    }
                } label: { Label("View", systemImage: "square.grid.2x2") }
            }
        }
        .sheet(isPresented: $showingManage) {
            NavigationStack { LiveTVManageCategoriesView(categories: Self.unique(directory.categories), preferences: $preferences) }
        }
        .sheet(isPresented: $showingDiagnostics) { LiveTVNavigationDiagnosticsView() }
        .accessibilityIdentifier("liveTVCategoriesPage")
        .onAppear {
            prepareIfNeeded()
            let saved = LiveTVCategoryPreferences.load(providerID: providerID)
            if saved != preferences { preferences = saved }
        }
        .onDisappear { rememberPosition(position) }
        .onChange(of: query) { refreshProjection() }
        .onChange(of: catalogRevision) { rebuildDirectory(keepingPosition: true) }
        .onChange(of: categories) { rebuildDirectory(keepingPosition: true) }
        .onChange(of: favoriteIDs) { rebuildDirectory(keepingPosition: true) }
        .onChange(of: preferences) { preferences.save(providerID: providerID); refreshProjection() }
        .onChange(of: providerID) { preferences = LiveTVCategoryPreferences.load(providerID: providerID); rebuildDirectory(keepingPosition: true) }
        #if os(iOS)
        // A settings restore or Undo can change the layout and grouping while this page is alive.
        // Reload only those two, so this page never saves its older copy back over them.
        .onReceive(NotificationCenter.default.publisher(for: .kyroSettingsDidRestore)) { _ in
            let saved = LiveTVCategoryPreferences.load(providerID: providerID)
            if saved.appearance != preferences.appearance { preferences.appearance = saved.appearance }
            if saved.grouping != preferences.grouping { preferences.grouping = saved.grouping }
        }
        #endif
    }

    // MARK: Data

    private func prepareIfNeeded() {
        guard !hasPrepared else { return }
        hasPrepared = true
        preferences = LiveTVCategoryPreferences.load(providerID: providerID)
        // nil / .allCategories → natural top (search + large title). Mid-list category → restore.
        position = LiveTVCategoryScrollRestore.positionForAppear(initialPosition)
        rebuildDirectory(keepingPosition: false)
    }

    private func rebuildDirectory(keepingPosition: Bool) {
        #if os(iOS)
        if let providerID, let indexedDirectory {
            directoryGeneration += 1
            let generation = directoryGeneration
            Task { @MainActor in
                let interval = KyroPerformanceDiagnostics.begin("Category data", .categoryDirectory)
                let loaded = await indexedDirectory(providerID)
                KyroPerformanceDiagnostics.end(interval)
                guard generation == directoryGeneration, self.providerID == providerID else { return }
                directory = loaded
                finishDirectoryRebuild(keepingPosition: keepingPosition)
            }
            return
        }
        #endif
        let interval = KyroPerformanceDiagnostics.begin("Category data", .categoryDirectory)
        directory = LiveTVCategoryDirectory.build(categories: categories, channels: channels, favoriteIDs: favoriteIDs)
        KyroPerformanceDiagnostics.end(interval)
        finishDirectoryRebuild(keepingPosition: keepingPosition)
    }

    private func finishDirectoryRebuild(keepingPosition: Bool) {
        refreshProjection()
        if keepingPosition, case .category(let name)? = position, !categories.contains(name) {
            position = .allCategories
        }
    }

    private func refreshProjection() {
        let visible = Self.unique(directory.categories).filter { !preferences.hidden.contains($0) }
        let searchTokens = LiveTVCategorySearch.tokens(query)
        let matching = visible.filter { LiveTVCategorySearch.matches($0, query: searchTokens) }
        let pinned = preferences.availablePinned(in: matching)
        let recent = isSearching ? [] : preferences.availableRecent(in: matching)
        let excluded = Set(pinned + recent)
        let next = LiveTVGuideCategoryPickerModel.Projection(frequent: pinned + recent,
                                                              remaining: matching.filter { !excluded.contains($0) })
        if next != projection { projection = next }
    }

    private static func unique(_ names: [String]) -> [String] {
        var seen: Set<String> = []
        return names.filter { seen.insert($0).inserted }
    }

    // MARK: Content

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Color.siloSecondaryText)
                .accessibilityHidden(true)
            TextField("Search categories", text: $query)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused($isSearchFocused)
                .foregroundStyle(Color.siloOnSurface)
                .accessibilityIdentifier("liveTVCategoriesSearch")
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Color.siloSecondaryText)
                        // Build 75: a finger-sized target without growing the field.
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.trailing, -8)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 40)
        .background(Color.siloSurfaceElevated, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var rows: some View {
        if !isSearching {
            row(id: .allCategories, title: allTitle, count: directory.totalChannelCount, symbol: "square.grid.2x2",
                isSelected: mode == .filter(selected: nil)) { select(.all) }
            if showsFavorites && directory.favoriteChannelCount > 0 {
                sectionHeader("Favorites")
                favoritesRow
            }
        }
        let pinned = preferences.availablePinned(in: projection.frequent)
        let recent = projection.frequent.filter { !pinned.contains($0) }
        if !pinned.isEmpty {
            sectionHeader("Pinned")
            categoryCollection(pinned, tiles: preferences.appearance != .list,
                               compactTiles: preferences.appearance == .hybrid)
        }
        if !recent.isEmpty {
            sectionHeader("Recently Visited")
            categoryCollection(recent, tiles: preferences.appearance == .grid)
        }
        if preferences.grouping == .grouped && !isSearching {
            ForEach(LiveTVCategoryGroup.allCases, id: \.self) { group in
                let names = projection.remaining.filter { LiveTVCategoryGroup.classify($0) == group }
                if !names.isEmpty { sectionHeader(group.rawValue); categoryCollection(names, tiles: preferences.appearance == .grid) }
            }
        } else if !projection.remaining.isEmpty {
            sectionHeader(isSearching ? "Results" : "Categories")
            categoryCollection(projection.remaining, tiles: preferences.appearance == .grid)
        }
        if isSearching && projection.remaining.isEmpty && projection.frequent.isEmpty {
            ContentUnavailableView.search(text: query)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
        }
    }

    @ViewBuilder private func categoryCollection(_ names: [String], tiles: Bool, compactTiles: Bool = false) -> some View {
        if tiles {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160, maximum: 220), spacing: 12)], spacing: 12) {
                ForEach(names, id: \.self) { name in
                    if compactTiles { compactCategoryTile(name) } else { categoryTile(name) }
                }
            }
            .padding(.horizontal, 16)
        } else {
            ForEach(names, id: \.self, content: categoryRow)
        }
    }

    private func compactCategoryTile(_ name: String) -> some View {
        let entry = directory.entry(for: name)
        return Button { choose(name) } label: {
            VStack(alignment: .leading, spacing: 8) {
                LiveTVCategoryRowLabel(title: name, count: entry.channelCount,
                                       icon: entry.artworkChannel.map { .artwork($0) } ?? .letter(name),
                                       accessory: mode.selected == name ? .checkmark : .none)
                    .equatable()
                Label("Pinned", systemImage: "pin.fill").font(.caption2)
            }
            .frame(maxWidth: .infinity, minHeight: 88, alignment: .leading)
            .background(Color.siloSurfaceElevated, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(mode.selected == name ? LiveTVAccent.primaryText : .clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
        .contextMenu { pinAction(name) }
        .id(LiveTVGuideCategoryPickerID.category(name))
        .accessibilityAddTraits(mode.selected == name ? .isSelected : [])
    }

    private func categoryTile(_ name: String) -> some View {
        let entry = directory.entry(for: name)
        return Button { choose(name) } label: {
            VStack(spacing: 10) {
                LiveTVCategoryTileArtwork(name: name, channel: entry.artworkChannel)
                Text(verbatim: name)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.siloOnSurface)
                    .lineLimit(3)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                Text(entry.channelCount == 1 ? "1 channel" : "\(entry.channelCount) channels")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(Color.siloSecondaryText)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: tileMinHeight, alignment: .top)
            .background(Color.siloSurfaceElevated, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(mode.selected == name ? LiveTVAccent.primaryText : .clear, lineWidth: 2))
            .overlay(alignment: .topTrailing) {
                if preferences.pinned.contains(name) {
                    Image(systemName: "pin.fill")
                        .font(.caption)
                        .foregroundStyle(LiveTVAccent.primaryText)
                        .padding(10)
                        .accessibilityHidden(true)
                }
            }
        }
        .buttonStyle(.plain)
        .contextMenu { pinAction(name) }
        .id(LiveTVGuideCategoryPickerID.category(name))
        .accessibilityAddTraits(mode.selected == name ? .isSelected : [])
        .accessibilityLabel(Text(verbatim: name))
        .accessibilityValue("\(entry.channelCount) channels\(preferences.pinned.contains(name) ? ", pinned" : "")\(mode.selected == name ? ", selected" : "")")
    }

    private func choose(_ name: String) {
        // Persist before navigating, but do not move the tapped row into Recently Visited while
        // SwiftUI is resolving its nested destination. Reload the projection when this page returns.
        var saved = preferences
        saved.opened(name)
        saved.save(providerID: providerID)
        select(.category(name))
    }

    private func pinAction(_ name: String) -> some View {
        Button(preferences.pinned.contains(name) ? "Unpin Category" : "Pin Category",
               systemImage: preferences.pinned.contains(name) ? "pin.slash" : "pin") {
            preferences.togglePin(name)
        }
    }

    /// Favorites is not a scroll target; it sits beside All so remembered positions stay categories.
    private var favoritesRow: some View {
        Button { select(.favorites) } label: {
            LiveTVCategoryRowLabel(title: "Favorite Channels", count: directory.favoriteChannelCount,
                                   icon: .symbol("star.fill"), accessory: accessory(isSelected: false))
                .equatable()
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("liveTVCategoriesFavorites")
    }

    private func categoryRow(_ category: String) -> some View {
        let entry = directory.entry(for: category)
        return row(id: .category(category), title: category, count: entry.channelCount,
                   artwork: entry.artworkChannel, isSelected: mode.selected == category) {
            choose(category)
        }
        .contextMenu { pinAction(category) }
    }

    private func row(id: LiveTVGuideCategoryPickerID, title: String, count: Int, symbol: String? = nil,
                     artwork: LiveTVChannel? = nil, isSelected: Bool,
                     action: @escaping () -> Void) -> some View {
        let icon: LiveTVCategoryRowLabel.Icon = symbol.map { .symbol($0) }
            ?? artwork.map { .artwork($0) }
            ?? .letter(title)
        return Button(action: action) {
            LiveTVCategoryRowLabel(title: title, count: count, icon: icon,
                                   accessory: accessory(isSelected: isSelected))
                .equatable()
        }
        .buttonStyle(.plain)
        .id(id)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func accessory(isSelected: Bool) -> LiveTVCategoryRowLabel.Accessory {
        switch mode {
        case .browse: .chevron
        case .filter: isSelected ? .checkmark : .none
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.title3.weight(.bold))
            .foregroundStyle(Color.siloOnSurface)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 18)
            .padding(.bottom, 6)
            .accessibilityAddTraits(.isHeader)
    }
}

private struct LiveTVCategoryTileArtwork: View {
    let name: String
    let channel: LiveTVChannel?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        Group {
            if let channel {
                LiveTVChannelLogo(channel: channel, size: CGSize(width: 52, height: 44))
            } else {
                Text(LiveTVCategoryFallbackIcon.letter(for: name))
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(hue: LiveTVCategoryFallbackIcon.hue(for: name), saturation: 0.45, brightness: 0.55))
            }
        }
        .frame(width: 60, height: 60)
        .background(Color.siloBackground, in: shape)
        .clipShape(shape)
        .accessibilityHidden(true)
    }
}

private struct LiveTVManageCategoriesView: View {
    let categories: [String]
    @Binding var preferences: LiveTVCategoryPreferences
    @Environment(\.dismiss) private var dismiss
    private var availablePins: [String] { preferences.pinned.filter { categories.contains($0) } }

    var body: some View {
        List {
            if !availablePins.isEmpty {
                Section("Pinned — drag to reorder") {
                    ForEach(availablePins, id: \.self) { name in
                        Text(verbatim: name)
                            .contextMenu { Button("Unpin Category", systemImage: "pin.slash") { preferences.togglePin(name) } }
                    }
                    .onMove { source, destination in
                        var reordered = availablePins
                        reordered.move(fromOffsets: source, toOffset: destination)
                        preferences.pinned = reordered + preferences.pinned.filter { !categories.contains($0) }
                    }
                }
            }
            Section("Categories") {
                ForEach(categories, id: \.self) { name in
                    HStack(spacing: 12) {
                        Text(verbatim: name).lineLimit(2)
                        Spacer()
                        Button(preferences.pinned.contains(name) ? "Unpin" : "Pin",
                               systemImage: preferences.pinned.contains(name) ? "pin.fill" : "pin") {
                            preferences.togglePin(name)
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                        .accessibilityLabel(preferences.pinned.contains(name) ? "Unpin \(name)" : "Pin \(name)")
                        Button(preferences.hidden.contains(name) ? "Show" : "Hide",
                               systemImage: preferences.hidden.contains(name) ? "eye.slash" : "eye") {
                            preferences.toggleHidden(name)
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                        .accessibilityLabel(preferences.hidden.contains(name) ? "Show \(name)" : "Hide \(name)")
                    }
                    .accessibilityElement(children: .contain)
                }
            }
            if !preferences.hidden.isEmpty {
                Section("Hidden Categories") {
                    ForEach(categories.filter { preferences.hidden.contains($0) }, id: \.self) { name in
                        Button("Show \(name)") { preferences.hidden.remove(name) }
                    }
                    Button("Restore All Hidden Categories") { preferences.hidden.removeAll() }
                }
            }
            Section {
                Button("Reset Appearance and Organization") {
                    preferences.appearance = .hybrid
                    preferences.grouping = .provider
                }
            }
        }
        .navigationTitle("Manage Categories")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            ToolbarItem(placement: .primaryAction) { EditButton() }
        }
    }
}

/// One category row: icon, full name, right-aligned channel count, then a chevron or checkmark.
/// Equatable, so scrolling and searching re-render only rows whose values changed.
struct LiveTVCategoryRowLabel: View, Equatable {
    enum Icon: Equatable {
        case symbol(String)
        case artwork(LiveTVChannel)
        case letter(String)
    }

    enum Accessory: Equatable { case chevron, checkmark, none }

    let title: String
    let count: Int
    let icon: Icon
    let accessory: Accessory

    private static let iconSize = CGSize(width: 40, height: 40)

    var body: some View {
        HStack(spacing: 12) {
            iconView
            Text(verbatim: title)
                .font(.body)
                .foregroundStyle(Color.siloOnSurface)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(count, format: .number)
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(Color.siloSecondaryText)
                .layoutPriority(1)
            accessoryView
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 56)
        // Build 75: a hairline from the title's leading edge, as in the reference list, so long
        // runs of similar provider names read as separate rows. Icons stay unbroken.
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 0.5)
                .padding(.leading, 16 + Self.iconSize.width + 12)
                .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: title))
        .accessibilityValue(count == 1 ? "1 channel" : "\(count) channels")
    }

    @ViewBuilder
    private var iconView: some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        switch icon {
        case .symbol(let name):
            Image(systemName: name)
                .font(.body.weight(.semibold))
                .foregroundStyle(LiveTVAccent.primaryText)
                .frame(width: Self.iconSize.width, height: Self.iconSize.height)
                .background(Color.siloSurfaceElevated, in: shape)
        case .artwork(let channel):
            LiveTVChannelLogo(channel: channel, size: CGSize(width: 36, height: 30))
                .frame(width: Self.iconSize.width, height: Self.iconSize.height)
                .background(Color.siloSurfaceElevated, in: shape)
                .clipShape(shape)
        case .letter(let name):
            Text(LiveTVCategoryFallbackIcon.letter(for: name))
                .font(.headline)
                .foregroundStyle(.white)
                .frame(width: Self.iconSize.width, height: Self.iconSize.height)
                .background(Color(hue: LiveTVCategoryFallbackIcon.hue(for: name), saturation: 0.45, brightness: 0.55),
                            in: shape)
        }
    }

    @ViewBuilder
    private var accessoryView: some View {
        switch accessory {
        case .chevron:
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.siloSecondaryText.opacity(0.7))
        case .checkmark:
            Image(systemName: "checkmark")
                .font(.body.weight(.semibold))
                .foregroundStyle(LiveTVAccent.primaryText)
                .frame(width: 18)
        case .none:
            Color.clear.frame(width: 18, height: 1)
        }
    }
}
