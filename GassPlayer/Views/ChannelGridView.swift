import SwiftUI

struct ChannelGridView: View {
    let streamKind: XtreamStreamKind
    @ObservedObject var catalog: XtreamCatalogStore
    @EnvironmentObject private var accountStore: AccountStore
    @State private var selectedCategoryID: String?
    @State private var searchText = ""
    @State private var refreshing = false

    private var categories: [XtreamCategory] { catalog.categories(for: streamKind) }

    private var streams: [XtreamStream] {
        let text = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return catalog.streams(for: streamKind).filter { stream in
            let categoryMatches = selectedCategoryID == nil || stream.categoryId == selectedCategoryID
            let queryMatches = text.isEmpty || stream.name.localizedCaseInsensitiveContains(text)
            return categoryMatches && queryMatches
        }
    }

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 12)]

    var body: some View {
        ZStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if !categories.isEmpty {
                        categoryPicker
                    }
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(streams, id: \.streamId) { stream in
                            StreamTile(stream: stream, kind: streamKind)
                        }
                    }
                    .padding(.horizontal)
                }
                .padding(.vertical)
            }
            CatalogLoadOverlay(state: catalog.state, isEmpty: streams.isEmpty)
        }
        .navigationTitle(streamKind.title)
        .searchable(text: $searchText, prompt: "Cerca \(streamKind.title.lowercased())")
        .refreshable { await refresh() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { Task { await refresh() } } label: {
                    Label("Aggiorna", systemImage: "arrow.clockwise")
                }
                .disabled(refreshing || accountStore.activeAccount?.xtreamCredentials == nil)
            }
        }
    }

    private var categoryPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Button("Tutti") { selectedCategoryID = nil }
                    .buttonStyle(.borderedProminent)
                    .tint(selectedCategoryID == nil ? .accentColor : .secondary)
                ForEach(categories, id: \.categoryId) { category in
                    Button(category.categoryName) { selectedCategoryID = category.categoryId }
                        .buttonStyle(.bordered)
                        .tint(selectedCategoryID == category.categoryId ? .accentColor : .secondary)
                }
            }
            .padding(.horizontal)
        }
    }

    private func refresh() async {
        guard let credentials = accountStore.activeAccount?.xtreamCredentials, !refreshing else { return }
        refreshing = true
        await catalog.refresh(credentials: credentials, kind: streamKind)
        refreshing = false
    }
}

private struct StreamTile: View {
    let stream: XtreamStream
    let kind: XtreamStreamKind

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            AsyncImage(url: URL(string: stream.streamIcon ?? "")) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                ZStack {
                    Color.secondary.opacity(0.12)
                    Image(systemName: kind == .live ? "tv" : "film")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 10))

            Text(stream.name)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}
