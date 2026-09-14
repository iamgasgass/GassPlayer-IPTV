import SwiftUI

/// Il TabView nativo adotta automaticamente la barra Liquid Glass sulle
/// versioni iOS che la supportano. Questo modificatore resta disponibile per
/// chip, filtri e controlli selezionabili nelle altre viste dell’app.
struct GlassOrMaterial: ViewModifier {
    let isSelected: Bool
    var tint: Color = .accentColor

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .glassEffect(
                    isSelected
                        ? .regular.tint(tint).interactive()
                        : .regular,
                    in: .capsule
                )
        } else {
            content
                .background(
                    isSelected ? tint.opacity(0.20) : .ultraThinMaterial,
                    in: Capsule()
                )
                .overlay {
                    Capsule()
                        .strokeBorder(
                            Color.white.opacity(isSelected ? 0.22 : 0.14),
                            lineWidth: 0.5
                        )
                }
        }
    }
}

extension View {
    func glassChip(isSelected: Bool, tint: Color = .accentColor) -> some View {
        modifier(GlassOrMaterial(isSelected: isSelected, tint: tint))
    }
}
