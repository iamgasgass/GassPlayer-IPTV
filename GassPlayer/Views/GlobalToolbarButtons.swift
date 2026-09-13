import SwiftUI

struct GlassSearchButton: View {
    @EnvironmentObject var overlayState: NavigationOverlayState
    var body: some View {
        GlassIconButton(systemImage: "magnifyingglass", isInSystemToolbar: true) {
            overlayState.showSearch = true
        }
    }
}

struct GlassSettingsButton: View {
    @EnvironmentObject var overlayState: NavigationOverlayState
    var body: some View {
        GlassIconButton(systemImage: "gearshape", isInSystemToolbar: true) {
            overlayState.showSettings = true
        }
    }
}
