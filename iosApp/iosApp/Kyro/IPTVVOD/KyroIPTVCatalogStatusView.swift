#if os(iOS)
import SwiftUI

/// Import state for one Xtream provider's Movies and Series, shared by Live TV settings and the
/// empty IPTV page so both say the same thing.
///
/// An import starts only from the button here. Turning VOD on, opening Movies or Series, or
/// pulling to refresh never downloads or replaces a catalog, and turning VOD off keeps the
/// imported catalogs on the device.
struct KyroIPTVCatalogStatusView: View {
    enum Emphasis { case page, settings }

    let provider: LiveTVProvider
    let emphasis: Emphasis

    private let service = XtreamVODService.shared
    @State private var catalogCounts: (movies: Int, series: Int)?

    private var progress: XtreamVODImportProgress? {
        guard let progress = service.progress, progress.providerID == provider.id else { return nil }
        return progress
    }

    private var isImporting: Bool { service.isRefreshing && progress != nil }
    private var otherProviderImporting: Bool { service.isRefreshing && progress == nil }

    var body: some View {
        VStack(alignment: emphasis == .page ? .center : .leading, spacing: 14) {
            if emphasis == .page {
                Image(systemName: "film.stack")
                    .font(.system(size: 44))
                    .foregroundColor(.siloOnSurface.opacity(0.3))
                Text(isImporting ? "Importing Movies & Series" : "Movies & Series from \(provider.name)")
                    .font(.siloSubheadline)
                    .foregroundColor(.siloOnSurface)
                    .multilineTextAlignment(.center)
            }
            Text(explanation)
                .font(emphasis == .page ? .siloBody : .footnote)
                .foregroundColor(.siloSecondaryText)
                .multilineTextAlignment(emphasis == .page ? .center : .leading)

            if let catalogCounts, emphasis == .settings, !isImporting {
                LabeledContent("Movies", value: catalogCounts.movies.formatted())
                LabeledContent("Series", value: catalogCounts.series.formatted())
                if let refreshed = service.refreshedAt(providerID: provider.id) {
                    LabeledContent("Last imported", value: refreshed.formatted(date: .abbreviated, time: .shortened))
                }
            }

            if let progress, isImporting || progress.stage == .failed || progress.stage == .ready {
                KyroIPTVImportProgressRows(progress: progress)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            actionButton
        }
        .frame(maxWidth: .infinity, alignment: emphasis == .page ? .center : .leading)
        .task(id: "\(service.catalogRevision):\(provider.id)") {
            let movies = await service.count(providerID: provider.id, kind: .movie)
            let series = await service.count(providerID: provider.id, kind: .series)
            catalogCounts = (movies, series)
        }
    }

    private var hasCatalog: Bool { (catalogCounts?.movies ?? 0) + (catalogCounts?.series ?? 0) > 0 }

    private var explanation: String {
        if isImporting {
            return "Kyro is downloading both catalogs from \(provider.name). You can keep using the app; titles appear when the import finishes."
        }
        if hasCatalog {
            return "Movies and Series from \(provider.name) appear in the Movies and Series tabs. Choose \(provider.name) in the library selector at the top of either tab."
        }
        return "Kyro imports both the Movies and the Series catalogs from \(provider.name) with the login you already saved for Live TV. Nothing needs to be entered again, and the catalogs stay on this iPhone until you remove them."
    }

    @ViewBuilder
    private var actionButton: some View {
        if isImporting {
            Button("Stop Import", role: .cancel) { service.cancel() }
                .modifier(KyroIPTVStatusButtonStyle(emphasis: emphasis, primary: false))
        } else if otherProviderImporting {
            Text("Another provider’s catalogs are importing.")
                .font(.footnote)
                .foregroundColor(.siloSecondaryText)
        } else {
            Button(hasCatalog ? "Update Movies & Series" : "Import Movies & Series") {
                Task { await service.refresh(providerID: provider.id) }
            }
            .modifier(KyroIPTVStatusButtonStyle(emphasis: emphasis, primary: !hasCatalog))
            .accessibilityIdentifier("kyroIPTVImportButton")
        }
    }
}

private struct KyroIPTVStatusButtonStyle: ViewModifier {
    let emphasis: KyroIPTVCatalogStatusView.Emphasis
    let primary: Bool

    func body(content: Content) -> some View {
        switch emphasis {
        case .page:
            if primary {
                content.siloPrimaryButton().frame(maxWidth: 280)
            } else {
                content.siloSecondaryButton().frame(maxWidth: 280)
            }
        case .settings:
            content
        }
    }
}

/// Stage and per-catalog progress for an import.
struct KyroIPTVImportProgressRows: View {
    let progress: XtreamVODImportProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(stageText)
                .font(.siloCaption.weight(.semibold))
                .foregroundColor(.siloOnSurface)
            row(title: "Movies", count: progress.movies, result: progress.movieResult)
            row(title: "Series", count: progress.series, result: progress.seriesResult)
            if progress.stage == .failed, let message = progress.message {
                Text(message)
                    .font(.siloCaption)
                    .foregroundColor(.siloErrorInk)
            }
        }
    }

    private var stageText: String {
        switch progress.stage {
        case .connecting: "Connecting to the provider…"
        case .downloading(let kind): "Downloading \(kind.title)…"
        case .importing(let kind): "Importing \(kind.title)…"
        case .ready: "Import finished"
        case .failed: "Import stopped"
        case .cancelled: "Import cancelled"
        }
    }

    private func row(title: String, count: XtreamVODImportCount, result: XtreamVODCatalogResult) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.siloCaption).foregroundColor(.siloOnSurface)
                Spacer()
                Text(detail(count: count, result: result))
                    .font(.siloCaption.monospacedDigit())
                    .foregroundColor(.siloSecondaryText)
            }
            if result == .loading || result == .waiting {
                if let fraction = count.fraction {
                    ProgressView(value: fraction).tint(.siloOnSurface)
                } else {
                    ProgressView(value: 0).tint(.siloOnSurface).opacity(0.4)
                }
            }
        }
    }

    private func detail(count: XtreamVODImportCount, result: XtreamVODCatalogResult) -> String {
        switch result {
        case .notSelected: "Off"
        case .waiting: "Waiting"
        case .loading:
            count.total > 0
                ? "\(min(count.processed + count.overLimit, count.total).formatted()) of \(count.total.formatted())"
                : "Starting"
        case .ready: "\(count.accepted.formatted()) titles"
        case .empty: "No titles"
        case .unsupported: "Not offered"
        case .authentication: "Login refused"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        }
    }
}
#endif
