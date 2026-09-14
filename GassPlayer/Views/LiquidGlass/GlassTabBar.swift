import SwiftUI

/// Il TabView nativo adotta automaticamente la barra Liquid Glass sulle
/// versioni iOS che la supportano. Questo modificatore resta disponibile per
/// chip, filtri e controlli selezionabili nelle altre viste dell'app.
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
            // FIX "type 'some View' has no member 'ultraThinMaterial'":
            // un ternario che mescola `Color` (tint.opacity) e `Material`
            // (.ultraThinMaterial) come argomento di `.background(_:in:)`
            // non compila perché Swift non riesce a unificare i due tipi
            // in un unico ShapeStyle. Le due varianti vengono quindi
            // separate in rami `if/else` espliciti, ciascuno con il proprio
            // tipo di background concreto.
            if isSelected {
                content
                    .background(tint.opacity(0.20), in: Capsule())
                    .overlay {
                        Capsule()
                            .strokeBorder(
                                Color.white.opacity(0.22),
                                lineWidth: 0.5
                            )
                    }
            } else {
                content
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay {
                        Capsule()
                            .strokeBorder(
                                Color.white.opacity(0.14),
                                lineWidth: 0.5
                            )
                    }
            }
        }
    }
}

extension View {
    func glassChip(isSelected: Bool, tint: Color = .accentColor) -> some View {
        modifier(GlassOrMaterial(isSelected: isSelected, tint: tint))
    }
}
