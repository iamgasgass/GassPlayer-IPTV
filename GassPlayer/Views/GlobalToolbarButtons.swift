import SwiftUI

struct GlobalToolbarButtons: View {
    @EnvironmentObject var overlayState: NavigationOverlayState

    var body: some View {
        HStack(spacing: 4) {
            Button { overlayState.showSearch = true } label: {
                Image(systemName: "magnifyingglass")
            }
            Button { overlayState.showSettings = true } label: {
                Image(systemName: "gearshape")
            }
        }
    }
}
