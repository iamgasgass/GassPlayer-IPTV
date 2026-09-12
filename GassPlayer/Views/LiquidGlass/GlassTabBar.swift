import SwiftUI

struct GlassTabItem: Identifiable {
    let id = UUID()
    let title: String
    let systemImage: String
}

/// Tab bar flottante in stile Liquid Glass: un unico "blob" di vetro scivola
/// fisicamente da un'icona all'altra quando cambia la selezione (via
/// matchedGeometryEffect), invece di limitarsi a un fade/scale sull'icona
/// selezionata come nella versione precedente. Riproduce l'effetto visto
/// nello screenshot di riferimento: indicatore capsula translucido che si
/// muove con una molla morbida, con l'icona/testo sopra che restano nitidi
/// mentre il vetro dietro si sposta e si deforma leggermente in transito.
struct GlassTabBar: View {
    let items: [GlassTabItem]
    @Binding var selection: Int
    @Namespace private var glassNamespace

    private let horizontalPadding: CGFloat = 12
    private let barHeight: CGFloat = 64

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                tabButton(index, item)
            }
        }
        .padding(.horizontal, horizontalPadding)
        .frame(height: barHeight)
        .modifier(GlassBarBackground())
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private func tabButton(_ index: Int, _ item: GlassTabItem) -> some View {
        let isSelected = selection == index
        return Button {
            withAnimation(.interactiveSpring(response: 0.45, dampingFraction: 0.72, blendDuration: 0.2)) {
                selection = index
            }
        } label: {
            VStack(spacing: 2) {
                Image(systemName: item.systemImage)
                    .font(.system(size: 20, weight: .semibold))
                Text(item.title)
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .foregroundStyle(isSelected ? Color.white : Color.secondary)
            .frame(maxWidth: .infinity)
            .frame(height: barHeight - 12)
            .background {
                if isSelected {
                    Capsule()
                        .fill(.clear)
                        .modifier(GlassBlobBackground())
                        .matchedGeometryEffect(id: "glassBlob", in: glassNamespace)
                }
            }
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

private struct GlassBlobBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular.tint(.white.opacity(0.14)).interactive(), in: .capsule)
        } else {
            content
                .background(.ultraThinMaterial, in: Capsule())
                .background(Color.white.opacity(0.10), in: Capsule())
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
