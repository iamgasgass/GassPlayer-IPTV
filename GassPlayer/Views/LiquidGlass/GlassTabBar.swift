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
        HStack(spacing: 14) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                tabColumn(index, item)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 8)
    }

    private func tabColumn(_ index: Int, _ item: GlassTabItem) -> some View {
        let isSelected = selection == index
        return VStack(spacing: 4) {
            GlassIconButton(
                systemImage: item.systemImage,
                tint: isSelected ? .accentColor : nil
            ) {
                selection = index
            }
            .scaleEffect(isSelected ? 1.08 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isSelected)

            Text(item.title)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
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
