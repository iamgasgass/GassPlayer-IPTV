import SwiftUI

struct GlassTabItem: Identifiable {
    let id = UUID()
    let title: String
    let systemImage: String
}

/// Tab bar Liquid Glass con morph reale del blob di selezione.
///
/// FIX rispetto alla versione precedente: il vetro non puo' "campionare"
/// altro vetro (regola esplicita di Apple per Liquid Glass). Avere lo
/// sfondo della barra e il blob di selezione come due .glassEffect()
/// indipendenti, ciascuno fuori da un GlassEffectContainer, li fa
/// renderizzare in isolamento: il risultato SEMBRA vetro ma l'animazione
/// di spostamento non ha la fisica "liquida" reale (nessuna rifrazione
/// coordinata, nessun blending), perche' ogni livello di vetro calcola la
/// propria distorsione separatamente. La correzione e' avvolgere l'intera
/// barra in un unico GlassEffectContainer, cosi' i due livelli condividono
/// la stessa regione di campionamento e il sistema puo' davvero fondere le
/// forme durante l'animazione — esattamente il comportamento visto nello
/// screenshot di riferimento.
struct GlassTabBar: View {
    let items: [GlassTabItem]
    @Binding var selection: Int
    @Namespace private var glassNamespace

    private let barHeight: CGFloat = 64

    var body: some View {
        Group {
            if #available(iOS 26.0, *) {
                GlassEffectContainer(spacing: 24) {
                    ZStack {
                        Capsule().fill(.clear)
                            .glassEffect(.regular, in: .capsule)

                        HStack(spacing: 0) {
                            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                                modernTabButton(index, item)
                            }
                        }
                        .padding(.horizontal, 8)
                    }
                }
                .frame(height: barHeight)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            } else {
                legacyBar
            }
        }
    }

    @available(iOS 26.0, *)
    private func modernTabButton(_ index: Int, _ item: GlassTabItem) -> some View {
        let isSelected = selection == index
        return Button {
            withAnimation(.smooth(duration: 0.35)) { selection = index }
        } label: {
            VStack(spacing: 2) {
                Image(systemName: item.systemImage).font(.system(size: 20, weight: .semibold))
                Text(item.title).font(.system(size: 10, weight: .medium)).lineLimit(1).minimumScaleFactor(0.7)
            }
            .foregroundStyle(isSelected ? Color.white : Color.secondary)
            .frame(maxWidth: .infinity)
            .frame(height: barHeight - 16)
            .background {
                if isSelected {
                    Capsule()
                        .fill(.clear)
                        .glassEffect(.regular.tint(.white.opacity(0.16)).interactive(), in: .capsule)
                        .glassEffectID("selectionBlob", in: glassNamespace)
                        .matchedGeometryEffect(id: "selectionBlob", in: glassNamespace)
                }
            }
        }
        .buttonStyle(.plain)
        .glassEffectTransition(.matchedGeometry)
    }

    private var legacyBar: some View {
        ZStack {
            Capsule()
                .fill(.ultraThinMaterial)
                .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 1))

            HStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    legacyTabButton(index, item)
                }
            }
            .padding(.horizontal, 8)
        }
        .frame(height: barHeight)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private func legacyTabButton(_ index: Int, _ item: GlassTabItem) -> some View {
        let isSelected = selection == index
        return Button {
            withAnimation(.interactiveSpring(response: 0.4, dampingFraction: 0.75)) { selection = index }
        } label: {
            VStack(spacing: 2) {
                Image(systemName: item.systemImage).font(.system(size: 20, weight: .semibold))
                Text(item.title).font(.system(size: 10, weight: .medium)).lineLimit(1).minimumScaleFactor(0.7)
            }
            .foregroundStyle(isSelected ? Color.white : Color.secondary)
            .frame(maxWidth: .infinity)
            .frame(height: barHeight - 16)
            .background {
                if isSelected {
                    Capsule().fill(Color.white.opacity(0.14))
                        .matchedGeometryEffect(id: "legacyBlob", in: glassNamespace)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

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
