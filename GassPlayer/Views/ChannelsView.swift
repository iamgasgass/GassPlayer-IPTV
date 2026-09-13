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
