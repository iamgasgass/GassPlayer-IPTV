import SwiftUI

struct GlassTabItem: Identifiable {
    let id = UUID()
    let title: String
    let systemImage: String
}

/// Tab bar Liquid Glass con morph reale del blob di selezione.
///
/// FIX (round 2): la versione precedente applicava CONTEMPORANEAMENTE
/// .glassEffectID e .matchedGeometryEffect con lo stesso id sullo stesso
/// elemento. Sono due motori di animazione della geometria indipendenti che
/// competono per il controllo dello stesso frame nello stesso momento:
/// risultato, artefatti visivi (la "corruzione/sfocatura" segnalata) e
/// l'animazione che non si vede perche' i due sistemi si annullano a
/// vicenda. La regola corretta (verificata sulla documentazione Apple e sul
/// pattern usato nell'app di esempio Landmarks, WWDC 2025): per un
/// indicatore che scorre in continuazione tra elementi SEMPRE presenti si
/// usa SOLO matchedGeometryEffect, dentro un unico GlassEffectContainer.
/// glassEffectID si usa invece per transizioni tra elementi che compaiono
/// e scompaiono (caso diverso dal nostro).
struct GlassTabBar: View {
    let items: [GlassTabItem]
    @Binding var selection: Int
    @Namespace private var glassNamespace

    private let barHeight: CGFloat = 64

    var body: some View {
        Group {
            if #available(iOS 26.0, *) {
                GlassEffectContainer(spacing: 24) {
                    ZStack {
                        Capsule().fill(.clear)
                            .glassEffect(.regular, in: .capsule)

                        HStack(spacing: 0) {
                            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                                modernTabButton(index, item)
                            }
                        }
                        .padding(.horizontal, 8)
                    }
                }
                .frame(height: barHeight)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            } else {
                legacyBar
            }
        }
    }

    @available(iOS 26.0, *)
    private func modernTabButton(_ index: Int, _ item: GlassTabItem) -> some View {
        let isSelected = selection == index
        return Button {
            withAnimation(.smooth(duration: 0.35)) { selection = index }
        } label: {
            VStack(spacing: 2) {
                Image(systemName: item.systemImage).font(.system(size: 20, weight: .semibold))
                Text(item.title).font(.system(size: 10, weight: .medium)).lineLimit(1).minimumScaleFactor(0.7)
            }
            .foregroundStyle(isSelected ? Color.white : Color.secondary)
            .frame(maxWidth: .infinity)
            .frame(height: barHeight - 16)
            .background(alignment: .center) {
                if isSelected {
                    Capsule()
                        .fill(.clear)
                        .glassEffect(.regular.tint(.white.opacity(0.16)).interactive(), in: .capsule)
                        .matchedGeometryEffect(id: "selectionBlob", in: glassNamespace)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var legacyBar: some View {
        ZStack {
            Capsule()
                .fill(.ultraThinMaterial)
                .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 1))

            HStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    legacyTabButton(index, item)
                }
            }
            .padding(.horizontal, 8)
        }
        .frame(height: barHeight)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private func legacyTabButton(_ index: Int, _ item: GlassTabItem) -> some View {
        let isSelected = selection == index
        return Button {
            withAnimation(.interactiveSpring(response: 0.4, dampingFraction: 0.75)) { selection = index }
        } label: {
            VStack(spacing: 2) {
                Image(systemName: item.systemImage).font(.system(size: 20, weight: .semibold))
                Text(item.title).font(.system(size: 10, weight: .medium)).lineLimit(1).minimumScaleFactor(0.7)
            }
            .foregroundStyle(isSelected ? Color.white : Color.secondary)
            .frame(maxWidth: .infinity)
            .frame(height: barHeight - 16)
            .background(alignment: .center) {
                if isSelected {
                    Capsule().fill(Color.white.opacity(0.14))
                        .matchedGeometryEffect(id: "legacyBlob", in: glassNamespace)
                }
            }
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
