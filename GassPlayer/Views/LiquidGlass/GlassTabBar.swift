import SwiftUI

struct GlassTabItem: Identifiable {
    let id = UUID()
    let title: String
    let systemImage: String
}

/// Tab bar Liquid Glass — fix strutturale definitivo.
///
/// CAUSA REALE della corruzione (round 4, confermata da screenshot): un
/// GlassEffectContainer e' documentato per contenere SOLO forme con
/// .glassEffect() applicato — e' una pipeline di compositing dedicata al
/// vetro, non uno ZStack generico. Le versioni precedenti mettevano anche
/// l'HStack dei bottoni (contenuto normale: icone SF Symbols, testo) DENTRO
/// il container insieme alle Capsule di vetro. Il container trattava quel
/// contenuto come se fosse ulteriore vetro da compositare, risultando in
/// icone/testo che sparivano lasciando solo la sfocatura rossastra visibile
/// nello screenshot (il vetro che campiona i canali Rai sottostanti).
///
/// Fix: SOLO le due Capsule (sfondo barra + indicatore) stanno dentro
/// GlassEffectContainer. L'HStack di bottoni (icone + testo, contenuto
/// completamente normale) sta FUORI, come livello successivo dello stesso
/// ZStack esterno — quindi disegnato sopra, con la semantica standard di
/// SwiftUI, garantita a prescindere da qualunque comportamento speciale
/// del compositor di vetro.
struct GlassTabBar: View {
    let items: [GlassTabItem]
    @Binding var selection: Int

    private let barHeight: CGFloat = 64
    private let indicatorInset: CGFloat = 4

    var body: some View {
        GeometryReader { geometry in
            let itemWidth = geometry.size.width / CGFloat(max(items.count, 1))

            ZStack(alignment: .leading) {
                // Livello 1: SOLO vetro, dentro il container dedicato.
                if #available(iOS 26.0, *) {
                    GlassEffectContainer(spacing: 24) {
                        ZStack(alignment: .leading) {
                            Capsule().fill(.clear).glassEffect(.regular, in: .capsule)

                            Capsule()
                                .fill(.clear)
                                .glassEffect(.regular.tint(.white.opacity(0.18)).interactive(), in: .capsule)
                                .frame(width: itemWidth - indicatorInset * 2, height: barHeight - 16)
                                .offset(x: itemWidth * CGFloat(selection) + indicatorInset, y: 8)
                                .animation(.spring(response: 0.4, dampingFraction: 0.78), value: selection)
                        }
                    }
                } else {
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(.ultraThinMaterial)
                            .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 1))

                        Capsule()
                            .fill(Color.white.opacity(0.14))
                            .frame(width: itemWidth - indicatorInset * 2, height: barHeight - 16)
                            .offset(x: itemWidth * CGFloat(selection) + indicatorInset, y: 8)
                            .animation(.spring(response: 0.4, dampingFraction: 0.78), value: selection)
                    }
                }

                // Livello 2: contenuto NORMALE (icone/testo), fuori dal
                // container, disegnato sopra come qualunque vista SwiftUI.
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
            withAnimation(.spring(response: 0.4, dampingFraction: 0.78)) { selection = index }
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
