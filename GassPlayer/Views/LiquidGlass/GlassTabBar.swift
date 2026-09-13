import SwiftUI

struct GlassTabItem: Identifiable {
    let id = UUID()
    let title: String
    let systemImage: String
}

/// Tab bar Liquid Glass con vero blob organico che si fonde tra le sezioni.
///
/// MECCANISMO REALE DEL "BLOB LIQUIDO": non e' un singolo elemento che
/// scorre con .offset() (quello produce solo una traslazione lineare,
/// nessuna fisica di fluido). La vera fusione organica di Liquid Glass si
/// ottiene con `.glassEffectID(_:in:)`: si creano tante istanze della
/// stessa forma di vetro — una per ogni possibile posizione — ma se ne
/// mostra SOLO UNA alla volta (quella della tab selezionata), tutte con lo
/// STESSO identificatore condiviso in un unico GlassEffectContainer.
/// Quando la tab cambia, l'istanza alla vecchia posizione scompare e una
/// nuova appare alla nuova posizione: il compositor di sistema, vedendo lo
/// stesso glassEffectID "nascere" altrove, non fa un semplice cross-fade ma
/// interpola una vera fusione liquida — il blob si allunga, si restringe,
/// rifrange la luce durante il tragitto, poi si "solidifica" nella nuova
/// posizione. E' la stessa tecnica usata nei componenti nativi iOS 26 (es.
/// nella toolbar di Landmarks, l'app di esempio Apple per WWDC25).
///
/// Precondizione gia' soddisfatta da questa base di codice: il container
/// contiene SOLO forme di vetro (nessun bottone/icona/testo mescolato,
/// causa della corruzione vista in precedenza) e lo sfondo statico della
/// barra e' materiale semplice, non vetro — quindi il blob e' l'unica
/// entita' di vetro con cui il sistema deve ragionare, senza ambiguita'.
struct GlassTabBar: View {
    let items: [GlassTabItem]
    @Binding var selection: Int
    @Namespace private var glassNamespace

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
                    GlassEffectContainer(spacing: 40) {
                        ForEach(Array(items.indices), id: \.self) { index in
                            if selection == index {
                                Capsule()
                                    .fill(.clear)
                                    .glassEffect(.regular.tint(.white.opacity(0.2)).interactive(), in: .capsule)
                                    .frame(width: indicatorWidth, height: indicatorHeight)
                                    .position(
                                        x: itemWidth * (CGFloat(index) + 0.5),
                                        y: barHeight / 2
                                    )
                                    .glassEffectID("liquidBlob", in: glassNamespace)
                            }
                        }
                    }
                    .frame(width: geometry.size.width, height: barHeight)
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
            withAnimation(.smooth(duration: 0.45)) { selection = index }
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
