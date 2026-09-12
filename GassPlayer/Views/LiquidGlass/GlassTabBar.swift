import SwiftUI

struct GlassTabItem: Identifiable {
    let id = UUID()
    let title: String
    let systemImage: String
}

/// Prima ogni tab aveva padding fisso (12pt orizzontali) e testo a
/// dimensione normale: con 7 tab la somma delle larghezze superava lo
/// schermo, causando overflow e la capsula del tab selezionato che si
/// deformava in un cerchio tagliato a sinistra (visibile nello screenshot).
/// Ora ogni tab usa `.frame(maxWidth: .infinity)`: la HStack distribuisce
/// lo spazio disponibile in parti esattamente uguali, senza mai eccedere
/// la larghezza dello schermo, qualunque sia il numero di tab.
struct GlassTabBar: View {
    let items: [GlassTabItem]
    @Binding var selection: Int

    var body: some View {
        content
            .padding(.horizontal, 8)
            .padding(.bottom, 4)
    }

    @ViewBuilder
    private var content: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer { tabRow }
        } else {
            tabRow
        }
    }

    private var tabRow: some View {
        HStack(spacing: 2) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                Button {
                    withAnimation(.snappy) { selection = index }
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: item.systemImage)
                            .font(.system(size: 16, weight: .semibold))
                        Text(item.title)
                            .font(.system(size: 9, weight: .medium))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .foregroundStyle(selection == index ? .primary : .secondary)
                }
                .buttonStyle(.plain)
                .modifier(GlassOrMaterial(isSelected: selection == index))
            }
        }
        .padding(4)
    }
}

struct GlassOrMaterial: ViewModifier {
    let isSelected: Bool
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(isSelected ? .regular.tint(.accentColor).interactive() : .regular, in: .rect(cornerRadius: 14))
        } else {
            content.background(isSelected ? Color.accentColor.opacity(0.25) : Color.clear, in: RoundedRectangle(cornerRadius: 14))
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        }
    }
}
