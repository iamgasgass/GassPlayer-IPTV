import SwiftUI

struct ChannelsView: View {
    let streamKind: XtreamStreamKind
    @ObservedObject var catalog: XtreamCatalogStore
    let credentials: XtreamCredentials?

    var body: some View {
        NavigationStack {
            ChannelGridView(
                streamKind: streamKind,
                catalog: catalog,
                credentials: credentials
            )
        }
    }
}

extension XtreamStreamKind {
    var title: String {
        switch self {
        case .live:
            return "Canali"

        case .movie:
            return "Film"

        case .series:
            return "Serie"
        }
    }
}
