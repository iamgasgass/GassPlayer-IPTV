import SwiftUI

struct GlassTabItem: Identifiable {
    let id = UUID()
    let title: String
    let systemImage: String
}

/// Tab bar Liquid Glass — fix allineamento ombra (round 5).
///
/// CAUSA CONFERMATA DA SCREENSHOT: lo sfondo dell'intera barra e
/// l'indicatore scorrevole erano DUE forme di vetro SOVRAPPOSTE
/// (l'indicatore vive sempre dentro i confini dello sfondo) nello stesso
/// GlassEffectContainer. Con due forme di vetro annidate/sovrapposte, il
/// container applica una logica di fusione (pensata per forme ADIACENTI
/// che si toccano, come in un segmented control) che sposta la geometria
/// finale dell'indicatore rispetto a dove l'ho effettivamente posizionato
/// con .offset() — da cui l'ombra visibilmente disallineata a sinistra
/// nello screenshot, mentre il livello di testo/icona (fuori dal
/// container, non toccato da questo problema) restava correttamente
/// posizionato.
///
/// Fix: lo sfondo della barra torna a un materiale semplice, NON vetro
/// (nessun bisogno di calcoli di fusione per uno sfondo statico pieno).
/// L'UNICA forma di vetro rimasta e' l'indicatore, da solo nel proprio
/// GlassEffectContainer: frame e offset si applicano al container stesso
/// (una vista dimensionata in modo esplicito), esattamente con la stessa
/// semantica di posizionamento della riga di bottoni — nessuna geometria
/// nascosta di mezzo, nessuna ambiguita' possibile.
struct GlassTabBar: View {
    let items: [GlassTabItem]
    @Binding var selection: Int

    private let barHeight: CGFloat = 64
    private let indicatorInset: CGFloat = 4

    var body: some View {
        GeometryReader { geometry in
            let itemWidth = geometry.size.width / CGFloat(max(items.count, 1))
            let indicatorWidth = itemWidth - indicatorInset * 2
            let indicatorHeight = barHeight - 16

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.ultraThinMaterial)
                    .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 1))

                if #available(iOS 26.0, *) {
                    GlassEffectContainer(spacing: 0) {
                        Capsule()
                            .fill(.clear)
                            .glassEffect(.regular.tint(.white.opacity(0.2)).interactive(), in: .capsule)
                    }
                    .frame(width: indicatorWidth, height: indicatorHeight)
                    .offset(x: itemWidth * CGFloat(selection) + indicatorInset, y: 8)
                    .animation(.spring(response: 0.4, dampingFraction: 0.8), value: selection)
                } else {
                    Capsule()
                        .fill(Color.white.opacity(0.14))
                        .frame(width: indicatorWidth, height: indicatorHeight)
                        .offset(x: itemWidth * CGFloat(selection) + indicatorInset, y: 8)
                        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: selection)
                }

                HStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                        tabButton(index, item)
                            .frame(width: itemWidth)
                    }
                }
            }
        }
        .frame(height: barHeight)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private func tabButton(_ index: Int, _ item: GlassTabItem) -> some View {
        let isSelected = selection == index
        return Button {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { selection = index }
        } label: {
            VStack(spacing: 2) {
                Image(systemName: item.systemImage).font(.system(size: 20, weight: .semibold))
                Text(item.title).font(.system(size: 10, weight: .medium)).lineLimit(1).minimumScaleFactor(0.7)
            }
            .foregroundStyle(isSelected ? Color.white : Color.secondary)
            .frame(maxWidth: .infinity)
            .frame(height: barHeight - 16)
            .contentShape(Rectangle())
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
