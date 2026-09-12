import SwiftUI

struct GlassTabItem: Identifiable {
    let id = UUID()
    let title: String
    let systemImage: String
}

struct GlassTabBar: View {
    let items: [GlassTabItem]
    @Binding var selection: Int

    private let circleDiameter: CGFloat = 54

    var body: some View {
        HStack(spacing: 14) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                tabCircle(index, item)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .padding(.bottom, 8)
    }

    private func tabCircle(_ index: Int, _ item: GlassTabItem) -> some View {
        let isSelected = selection == index
        return VStack(spacing: 4) {
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                    selection = index
                }
            } label: {
                Image(systemName: item.systemImage)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(isSelected ? Color.white : Color.primary)
                    .frame(width: circleDiameter, height: circleDiameter)
            }
            .buttonStyle(.plain)
            .modifier(TabCircleGlass(isSelected: isSelected))
            .contentShape(Circle())
            .scaleEffect(isSelected ? 1.08 : 1.0)

            Text(item.title)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }
}

struct TabCircleGlass: ViewModifier {
    let isSelected: Bool
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .background {
                    Circle()
                        .fill(.clear)
                        .glassEffect(isSelected ? .regular.tint(.accentColor) : .regular, in: .circle)
                }
        } else {
            content
                .background(isSelected ? Color.accentColor.opacity(0.85) : Color.clear, in: Circle())
                .background(.ultraThinMaterial, in: Circle())
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
