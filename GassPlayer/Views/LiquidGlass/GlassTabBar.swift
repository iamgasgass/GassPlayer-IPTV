import SwiftUI

struct GlassTabItem: Identifiable {
    let id = UUID()
    let title: String
    let systemImage: String
}

struct GlassTabBar: View {
    let items: [GlassTabItem]
    @Binding var selection: Int

    private let barHeight: CGFloat = 64
    private let indicatorInset: CGFloat = 4

    var body: some View {
        Group {
            if #available(iOS 26.0, *) {
                GlassEffectContainer(spacing: 24) {
                    barContent(isModernGlass: true)
                }
                .frame(height: barHeight)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            } else {
                barContent(isModernGlass: false)
                    .frame(height: barHeight)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }
        }
    }

    @ViewBuilder
    private func barContent(isModernGlass: Bool) -> some View {
        GeometryReader { geometry in
            let itemWidth = geometry.size.width / CGFloat(max(items.count, 1))

            ZStack(alignment: .leading) {
                Capsule().fill(.clear).modifier(GlassBarBackground())

                Capsule()
                    .fill(.clear)
                    .modifier(GlassIndicatorBackground())
                    .frame(width: itemWidth - indicatorInset * 2, height: barHeight - 16)
                    .offset(x: itemWidth * CGFloat(selection) + indicatorInset, y: 8)
                    .animation(.spring(response: 0.4, dampingFraction: 0.78), value: selection)

                HStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                        tabButton(index, item)
                            .frame(width: itemWidth)
                    }
                }
            }
        }
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

private struct GlassBarBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: .capsule)
        } else {
            content
                .background(.ultraThinMaterial, in: Capsule())
                .background(Color.black.opacity(0.35), in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 1))
        }
    }
}

private struct GlassIndicatorBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular.tint(.white.opacity(0.18)).interactive(), in: .capsule)
        } else {
            content
                .background(.ultraThinMaterial, in: Capsule())
                .background(Color.white.opacity(0.12), in: Capsule())
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
