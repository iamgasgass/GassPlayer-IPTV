import SwiftUI

struct ChannelGridView: View {
    let streamKind: XtreamStreamKind
    @ObservedObject var catalog: XtreamCatalogStore
    let credentials: XtreamCredentials?

    @State private var selectedCategoryID: String?
    @State private var searchText = ""
    @State private var refreshing = false

    private let columns = [
        GridItem(
            .adaptive(minimum: 150, maximum: 220),
            spacing: 12
        )
    ]

    private var categories: [XtreamCategory] {
        catalog.categories(for: streamKind)
    }

    private var visibleStreams: [XtreamStream] {
        let normalizedQuery = searchText
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return catalog.streams(for: streamKind).filter { stream in
            let categoryMatches =
                selectedCategoryID == nil ||
                stream.categoryId == selectedCategoryID

            let queryMatches =
                normalizedQuery.isEmpty ||
                stream.name.localizedCaseInsensitiveContains(normalizedQuery)

            return categoryMatches && queryMatches
        }
    }

    var body: some View {
        ZStack {
            ScrollView {
                LazyVStack(
                    alignment: .leading,
                    spacing: 16
                ) {
                    if !categories.isEmpty {
                        categorySelector
                    }

                    if !visibleStreams.isEmpty {
                        LazyVGrid(
                            columns: columns,
                            spacing: 12
                        ) {
                            ForEach(visibleStreams) { stream in
                                StreamTile(
                                    stream: stream,
                                    streamKind: streamKind
                                )
                            }
                        }
                        .padding(.horizontal)
                    }
                }
                .padding(.vertical)
            }

            CatalogLoadOverlay(
                state: catalog.state,
                isEmpty: visibleStreams.isEmpty
            )
        }
        .navigationTitle(streamKind.title)
        .searchable(
            text: $searchText,
            prompt: "Cerca \(streamKind.title.lowercased())"
        )
        .refreshable {
            await refreshCatalog()
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task {
                        await refreshCatalog()
                    }
                } label: {
                    Label(
                        "Aggiorna",
                        systemImage: "arrow.clockwise"
                    )
                }
                .disabled(refreshing || credentials == nil)
            }
        }
        .onChange(of: categories.map(\.categoryId)) { _, availableIDs in
            guard let selectedCategoryID else {
                return
            }

            if !availableIDs.contains(selectedCategoryID) {
                self.selectedCategoryID = nil
            }
        }
    }

    private var categorySelector: some View {
        ScrollView(
            .horizontal,
            showsIndicators: false
        ) {
            HStack(spacing: 8) {
                CategoryFilterButton(
                    title: "Tutti",
                    isSelected: selectedCategoryID == nil
                ) {
                    selectedCategoryID = nil
                }

                ForEach(categories) { category in
                    CategoryFilterButton(
                        title: category.categoryName,
                        isSelected: selectedCategoryID == category.categoryId
                    ) {
                        selectedCategoryID = category.categoryId
                    }
                }
            }
            .padding(.horizontal)
        }
    }

    private func refreshCatalog() async {
        guard let credentials, !refreshing else {
            return
        }

        refreshing = true

        await catalog.refresh(
            credentials: credentials,
            kind: streamKind
        )

        refreshing = false
    }
}

private struct CategoryFilterButton: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .lineLimit(1)
        }
        .buttonStyle(.bordered)
        .tint(isSelected ? .accentColor : .secondary)
        .controlSize(.small)
        .accessibilityAddTraits(
            isSelected ? .isSelected : []
        )
    }
}

private struct StreamTile: View {
    let stream: XtreamStream
    let streamKind: XtreamStreamKind

    var body: some View {
        VStack(
            alignment: .leading,
            spacing: 8
        ) {
            artwork

            Text(stream.name)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(
                    maxWidth: .infinity,
                    alignment: .leading
                )
        }
        .padding(10)
        .background(
            .thinMaterial,
            in: RoundedRectangle(
                cornerRadius: 14,
                style: .continuous
            )
        )
        .contentShape(
            RoundedRectangle(
                cornerRadius: 14,
                style: .continuous
            )
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(stream.name), \(streamKind.title)"
        )
    }

    @ViewBuilder
    private var artwork: some View {
        AsyncImage(url: artworkURL) { phase in
            switch phase {
            case .success(let image):
                image
                    .resizable()
                    .scaledToFill()

            case .empty:
                placeholder
                    .overlay {
                        ProgressView()
                            .controlSize(.small)
                    }

            case .failure:
                placeholder

            @unknown default:
                placeholder
            }
        }
        .frame(
            maxWidth: .infinity
        )
        .aspectRatio(
            16 / 9,
            contentMode: .fit
        )
        .clipShape(
            RoundedRectangle(
                cornerRadius: 10,
                style: .continuous
            )
        )
    }

    private var artworkURL: URL? {
        guard
            let rawURL = stream.streamIcon?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !rawURL.isEmpty
        else {
            return nil
        }

        return URL(string: rawURL)
    }

    private var placeholder: some View {
        ZStack {
            Color.secondary.opacity(0.12)

            Image(
                systemName: streamKind == .live
                    ? "tv"
                    : "film"
            )
            .font(.title2)
            .foregroundStyle(.secondary)
        }
    }
}
