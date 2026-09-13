import SwiftUI

/// GlassTabBar custom rimossa: l'animazione "blob liquido" reale (vista in
/// Files tra Sfoglia/Condivisi/Recenti) usa un framework privato esclusivo
/// dei componenti di sistema come UITabBar, non riproducibile con le API
/// pubbliche GlassEffectContainer/glassEffectID. ContentView ora usa il
/// TabView nativo di SwiftUI, che adotta Liquid Glass automaticamente su
/// iOS 26 senza alcun codice custom. Questo file resta solo per
/// GlassOrMaterial, riutilizzato altrove (es. i chip categoria in
/// ChannelGridView).
struct GlassOrMaterial: ViewModifier {
    let isSelected: Bool
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(isSelected ? .regular.tint(.accentColor).interactive() : .regular, in: .capsule)
        } else {
            content.background(.ultraThinMaterial, in: Capsule())
        }
    }
}
