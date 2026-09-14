import SwiftUI

struct GlassSearchButton: View {
    @EnvironmentObject private var overlayState: NavigationOverlayState

    var body: some View {
        GlassIconButton(
            systemImage: "magnifyingglass",
            isInSystemToolbar: true,
            accessibilityLabel: "Cerca"
        ) {
            overlayState.showSearch = true
        }
    }
}

struct GlassSettingsButton: View {
    @EnvironmentObject private var overlayState: NavigationOverlayState

    var body: some View {
        GlassIconButton(
            systemImage: "gearshape",
            isInSystemToolbar: true,
            accessibilityLabel: "Impostazioni"
        ) {
            overlayState.showSettings = true
        }
    }
}
