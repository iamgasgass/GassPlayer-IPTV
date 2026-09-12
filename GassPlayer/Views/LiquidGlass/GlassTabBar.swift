import SwiftUI

struct GlassTabItem: Identifiable {
    let id = UUID()
    let title: String
    let systemImage: String
}

struct GlassTabBar: View {
    let items: [GlassTabItem]
    @Binding var selection: Int

    var body: some View {
        content
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
    }

    @ViewBuilder
    private var content: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer { tabRow(useGlass: true) }
        } else {
            tabRow(useGlass: false)
        }
    }

    @ViewBuilder
    private func tabRow(useGlass: Bool) -> some View {
        HStack(spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                Button {
                    withAnimation(.snappy) { selection = index }
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: item.systemImage).font(.system(size: 18, weight: .semibold))
                        Text(item.title).font(.caption2)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .foregroundStyle(selection == index ? .primary : .secondary)
                }
                .modifier(GlassOrMaterial(isSelected: selection == index))
            }
        }
        .padding(6)
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
