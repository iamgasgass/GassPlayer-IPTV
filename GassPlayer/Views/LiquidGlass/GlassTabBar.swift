import SwiftUI

struct GlassTabItem: Identifiable {
    let id = UUID()
    let title: String
    let systemImage: String
}

struct GlassTabBar: View {
    let items: [GlassTabItem]
    @Binding var selection: Int

    private let horizontalPadding: CGFloat = 20
    private let interItemSpacing: CGFloat = 12
    private let minCircleDiameter: CGFloat = 52
    private let maxCircleDiameter: CGFloat = 68

    var body: some View {
        GeometryReader { geometry in
            let availableWidth = geometry.size.width - (horizontalPadding * 2)
            let totalSpacing = interItemSpacing * CGFloat(items.count - 1)
            let rawDiameter = (availableWidth - totalSpacing) / CGFloat(items.count)
            let diameter = min(max(rawDiameter, minCircleDiameter), maxCircleDiameter)

            HStack(spacing: interItemSpacing) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    tabColumn(index, item, diameter: diameter)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, horizontalPadding)
        }
        .frame(height: 92)
        .padding(.bottom, 8)
    }

    private func tabColumn(_ index: Int, _ item: GlassTabItem, diameter: CGFloat) -> some View {
        let isSelected = selection == index
        return VStack(spacing: 6) {
            GlassIconButton(
                systemImage: item.systemImage,
                tint: isSelected ? .accentColor : nil,
                size: diameter
            ) {
                selection = index
            }
            .scaleEffect(isSelected ? 1.08 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isSelected)

            Text(item.title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
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
