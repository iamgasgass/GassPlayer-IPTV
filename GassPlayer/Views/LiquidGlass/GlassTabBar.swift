import SwiftUI

struct GlassTabItem: Identifiable {
    let id = UUID()
    let title: String
    let systemImage: String
}

struct GlassTabBar: View {
    let items: [GlassTabItem]
    @Binding var selection: Int

    private let pillWidth: CGFloat = 60
    private let pillHeight: CGFloat = 52

    var body: some View {
        HStack(spacing: 10) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                tabPill(index, item)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 8)
    }

    private func tabPill(_ index: Int, _ item: GlassTabItem) -> some View {
        let isSelected = selection == index
        let label = VStack(spacing: 2) {
            Image(systemName: item.systemImage)
                .font(.system(size: 17, weight: .semibold))
            Text(item.title)
                .font(.system(size: 9, weight: .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .foregroundStyle(isSelected ? Color.white : Color.secondary)
        .scaleEffect(isSelected ? 1.06 : 1.0)
        .frame(width: pillWidth, height: pillHeight)

        return Group {
            if #available(iOS 26.0, *) {
                GlassEffectContainer {
                    Button {
                        selection = index
                    } label: { label }
                    .buttonStyle(.plain)
                    .glassEffect(
                        isSelected ? .regular.tint(.accentColor).interactive() : .regular.interactive(),
                        in: .rect(cornerRadius: 18)
                    )
                }
            } else {
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { selection = index }
                } label: { label }
                .buttonStyle(.plain)
                .background(isSelected ? Color.accentColor.opacity(0.9) : Color.clear, in: RoundedRectangle(cornerRadius: 18))
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
            }
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
