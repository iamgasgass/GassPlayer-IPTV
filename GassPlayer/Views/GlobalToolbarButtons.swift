import SwiftUI

struct GlassSearchButton: View {
    @EnvironmentObject var overlayState: NavigationOverlayState
    var body: some View {
        GlassIconButton(systemImage: "magnifyingglass") {
            overlayState.showSearch = true
        }
    }
}

struct GlassSettingsButton: View {
    @EnvironmentObject var overlayState: NavigationOverlayState
    var body: some View {
        GlassIconButton(systemImage: "gearshape") {
            overlayState.showSettings = true
        }
    }
}
