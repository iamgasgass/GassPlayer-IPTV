import SwiftUI

struct ChannelGridView: View {
    let credentials: XtreamCredentials
    let kind: XtreamStreamKind

    @EnvironmentObject var contentManagement: ContentManagementService
    @EnvironmentObject var refreshCoordinator: CatalogRefreshCoordinator

    @State private var categories: [XtreamCategory] = []
    @State private var streams: [XtreamStream] = []
    @State private var seriesItems: [XtreamSeriesItem] = []

    @State private var selectedCategory: XtreamCategory?
    @State private var selectedStream: XtreamStream?
    @State private var selectedSeries: XtreamSeriesItem?

    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var epgByStream: [Int: EPGProgram] = [:]

    /// Risolve la race condition fra due categorie toccate rapidamente.
    @State private var contentTask: Task<Void, Never>?

    @State private var showEPGTimeline = false

    private var repository: CachedXtreamRepository {
        CachedXtreamRepository(credentials: credentials)
    }

    private var service: XtreamAPIService {
        XtreamAPIService(credentials: credentials)
    }

    private let columns = [
        GridItem(.adaptive(minimum: 110, maximum: 140), spacing: 14)
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                categoryChips

                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding()
                }

                if kind == .series {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(seriesItems) { series in
                            SeriesTile(series: series) {
                                selectedSeries = series
                            }
                        }
                    }
                    .padding()
                    .animation(
                        .spring(response: 0.4, dampingFraction: 0.8),
                        value: seriesItems.count
                    )
                } else {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(streams) { stream in
                            ChannelTile(
                                stream: stream,
                                kind: kind,
                                isFavorite: contentManagement.isFavorite(
                                    id: "\(credentials.host)-\(kind.rawValue)-\(stream.streamId)"
                                ),
                                currentProgram: kind == .live
                                    ? epgByStream[stream.streamId]
                                    : nil
                            ) {
                                selectedStream = stream
                            } onFavoriteToggle: {
                                contentManagement.toggleFavorite(
                                    id: "\(credentials.host)-\(kind.rawValue)-\(stream.streamId)",
                                    title: stream.name,
                                    kind: kind.rawValue
                                )
                            }
                        }
                    }
                    .padding()
                    .animation(
                        .spring(response: 0.4, dampingFraction: 0.8),
                        value: streams.count
                    )
                }
            }
            .overlay {
                if isLoading {
                    ProgressView()
                }
            }
            .navigationTitle(kind.displayName)
            .toolbar {
                if kind == .live {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button {
                            showEPGTimeline = true
                        } label: {
                            Label("Guida TV", systemImage: "calendar")
                        }
                    }
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    GlassSearchButton()
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    GlassSettingsButton()
                }
            }
            .task(id: kind) {
                await loadCategories()
            }
            .onChange(of: refreshCoordinator.latestRequest) { _, request in
                guard
                    let request,
                    request.host == credentials.host,
                    request.kind == kind
                else {
                    return
                }

                contentTask?.cancel()

                contentTask = Task {
                    await forceRefreshCurrentCategory()
                }
            }
            .fullScreenCover(item: $selectedStream) { stream in
                if let url = service.streamURL(for: stream, kind: kind) {
                    AdaptivePlayerView(url: url, title: stream.name)
                } else {
                    Text("URL dello stream non valido.")
                }
            }
            .navigationDestination(item: $selectedSeries) { series in
                SeriesEpisodesView(
                    credentials: credentials,
                    seriesId: series.seriesId,
                    seriesName: series.name
                )
            }
            .sheet(isPresented: $showEPGTimeline) {
                EPGTimelineView(
                    credentials: credentials,
                    streams: streams
                )
            }
        }
        .onDisappear {
            contentTask?.cancel()
        }
    }

    private var categoryChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(categories) { category in
                    let isSelected = selectedCategory?.id == category.id

                    Button {
                        withAnimation {
                            selectedCategory = category
                        }

                        contentTask?.cancel()

                        contentTask = Task {
                            await loadContent(for: category)
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(
                                systemName: Self.categoryIcon(
                                    for: category.categoryName
                                )
                            )
                            .font(.caption)

                            Text(category.categoryName)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                    }
                    .modifier(CategoryChipStyle(isSelected: isSelected))
                }
            }
            .padding(.horizontal)
        }
    }

    private static func categoryIcon(for name: String) -> String {
        let normalized = name.lowercased()

        if normalized.contains("sport") {
            return "sportscourt"
        }

        if normalized.contains("kids")
            || normalized.contains("cartoon")
            || normalized.contains("bambini")
        {
            return "gamecontroller"
        }

        if normalized.contains("news") || normalized.contains("notizie") {
            return "newspaper"
        }

        if normalized.contains("music") || normalized.contains("musica") {
            return "music.note"
        }

        if normalized.contains("cinema")
            || normalized.contains("film")
            || normalized.contains("movie")
        {
            return "film"
        }

        if normalized.contains("document") {
            return "video"
        }

        if normalized.contains("relig") {
            return "building.columns"
        }

        if normalized.contains("adult")
            || normalized.contains("+18")
            || normalized.contains("xxx")
        {
            return "eye.slash"
        }

        return "tv"
    }

    private func loadCategories() async {
        isLoading = true
        errorMessage = nil

        defer {
            isLoading = false
        }

        do {
            categories = try await repository.categories(kind: kind)

            if categories.isEmpty {
                errorMessage = "Nessuna categoria \(kind.displayName) trovata su questo server."
                return
            }

            if let first = categories.first {
                selectedCategory = first
                await loadContent(for: first)
            }
        } catch let error as XtreamError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = "Errore imprevisto: \(error.localizedDescription)"
        }
    }

    private func loadContent(for category: XtreamCategory) async {
        isLoading = true

        defer {
            if selectedCategory?.id == category.id {
                isLoading = false
            }
        }

        if kind == .series {
            do {
                let result = try await service.fetchSeriesList(
                    categoryId: category.categoryId
                )

                guard
                    !Task.isCancelled,
                    selectedCategory?.id == category.id
                else {
                    return
                }

                seriesItems = result
                errorMessage = nil
            } catch is CancellationError {
                return
            } catch let error as XtreamError {
                guard
                    !Task.isCancelled,
                    selectedCategory?.id == category.id
                else {
                    return
                }

                seriesItems = []
                errorMessage = error.errorDescription
            } catch {
                guard
                    !Task.isCancelled,
                    selectedCategory?.id == category.id
                else {
                    return
                }

                seriesItems = []
                errorMessage = "Errore imprevisto: \(error.localizedDescription)"
            }

            return
        }

        do {
            let result = try await repository.streams(
                kind: kind,
                categoryId: category.categoryId
            )

            guard
                !Task.isCancelled,
                selectedCategory?.id == category.id
            else {
                return
            }

            streams = result
            errorMessage = nil

            if kind == .live {
                await loadEPGForVisibleStreams()
            }
        } catch is CancellationError {
            return
        } catch let error as XtreamError {
            guard
                !Task.isCancelled,
                selectedCategory?.id == category.id
            else {
                return
            }

            streams = []
            errorMessage = error.errorDescription
        } catch {
            guard
                !Task.isCancelled,
                selectedCategory?.id == category.id
            else {
                return
            }

            streams = []
            errorMessage = "Errore imprevisto: \(error.localizedDescription)"
        }
    }

    private func forceRefreshCurrentCategory() async {
        guard let category = selectedCategory else {
            return
        }

        await CacheService.shared.invalidate(
            prefix: "\(credentials.host)-streams-\(kind.rawValue)-"
        )

        if kind == .live {
            await EPGService(credentials: credentials).invalidateCache()
            epgByStream = [:]
        }

        await loadContent(for: category)
    }

    /// Massimo quattro richieste EPG simultanee.
    private func loadEPGForVisibleStreams() async {
        let service = EPGService(credentials: credentials)
        let visibleStreams = Array(streams.prefix(24))

        guard !visibleStreams.isEmpty else {
            return
        }

        await withTaskGroup(of: (Int, EPGProgram?).self) { group in
            var nextIndex = 0
            let initialTaskCount = min(4, visibleStreams.count)

            for _ in 0..<initialTaskCount {
                let stream = visibleStreams[nextIndex]
                nextIndex += 1

                group.addTask {
                    let programs = try? await service.shortEPG(
                        streamId: stream.streamId,
                        limit: 2
                    )

                    let now = Date()

                    let current = programs?.first {
                        $0.start <= now && $0.end > now
                    }

                    return (
                        stream.streamId,
                        current ?? programs?.first
                    )
                }
            }

            for await (streamId, program) in group {
                guard !Task.isCancelled else {
                    group.cancelAll()
                    return
                }

                if let program {
                    epgByStream[streamId] = program
                }

                guard nextIndex < visibleStreams.count else {
                    continue
                }

                let stream = visibleStreams[nextIndex]
                nextIndex += 1

                group.addTask {
                    let programs = try? await service.shortEPG(
                        streamId: stream.streamId,
                        limit: 2
                    )

                    let now = Date()

                    let current = programs?.first {
                        $0.start <= now && $0.end > now
                    }

                    return (
                        stream.streamId,
                        current ?? programs?.first
                    )
                }
            }
        }
    }
}

private struct CategoryChipStyle: ViewModifier {
    let isSelected: Bool

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            if isSelected {
                content
                    .buttonStyle(.glassProminent)
                    .buttonBorderShape(.capsule)
                    .tint(Color.accentColor)
            } else {
                content
                    .buttonStyle(.glass)
                    .buttonBorderShape(.capsule)
            }
        } else {
            content
                .buttonStyle(.plain)
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay {
                    if isSelected {
                        Capsule()
                            .fill(Color.accentColor.opacity(0.85))
                    }
                }
        }
    }
}

private struct ChannelTile: View {
    let stream: XtreamStream
    let kind: XtreamStreamKind
    let isFavorite: Bool
    let currentProgram: EPGProgram?
    let onTap: () -> Void
    let onFavoriteToggle: () -> Void

    private var epgProgress: Double {
        guard let currentProgram else {
            return 0
        }

        let total = currentProgram.end.timeIntervalSince(currentProgram.start)

        guard total > 0 else {
            return 0
        }

        return min(
            max(
                Date().timeIntervalSince(currentProgram.start) / total,
                0
            ),
            1
        )
    }

    var body: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .topTrailing) {
                if kind == .movie {
                    TMDBEnrichedPoster(
                        title: stream.name,
                        isSeries: false,
                        fallbackIconURL: stream.streamIcon,
                        width: 100,
                        height: 150
                    )
                } else {
                    AsyncImage(url: URL(string: stream.streamIcon ?? "")) { phase in
                        switch phase {
                        case .success(let image):
                            image
                                .resizable()
                                .scaledToFit()

                        default:
                            RoundedRectangle(cornerRadius: 12)
                                .fill(.ultraThinMaterial)
                                .overlay {
                                    Image(systemName: "tv")
                                        .foregroundStyle(.secondary)
                                }
                        }
                    }
                    .frame(width: 100, height: 100)
                    .clipShape(
                        RoundedRectangle(cornerRadius: 12)
                    )
                }

                Button(action: onFavoriteToggle) {
                    Image(systemName: isFavorite ? "star.fill" : "star")
                        .font(.caption)
                        .padding(6)
                        .foregroundStyle(.yellow)
                }
                .background(.ultraThinMaterial, in: Circle())
                .padding(4)
            }

            Text(stream.name)
                .font(.caption)
                .lineLimit(2)
                .multilineTextAlignment(.center)

            if let currentProgram {
                VStack(alignment: .leading, spacing: 3) {
                    Text(currentProgram.title)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    ProgressView(value: epgProgress)
                        .tint(.accentColor)
                }
                .padding(5)
                .background(
                    .ultraThinMaterial,
                    in: RoundedRectangle(cornerRadius: 6)
                )
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            onTap()
        }
    }
}

private struct SeriesTile: View {
    let series: XtreamSeriesItem
    let onTap: () -> Void

    var body: some View {
        VStack(spacing: 4) {
            TMDBEnrichedPoster(
                title: series.name,
                isSeries: true,
                fallbackIconURL: series.cover,
                width: 100,
                height: 140
            )

            Text(series.name)
                .font(.caption)
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            onTap()
        }
    }
}
