import SwiftUI

struct GlassIconButton: View {
    let systemImage: String
    var tint: Color? = nil
    var size: CGFloat = 44
    var isInSystemToolbar = false
    var accessibilityLabel: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            GlassIconGlyph(systemImage: systemImage, size: size)
        }
        .modifier(
            NativeOrLegacyGlassCircle(
                tint: tint,
                isInSystemToolbar: isInSystemToolbar
            )
        )
        .accessibilityLabel(accessibilityLabel ?? systemImage)
    }
}

/// Solo il glifo di `GlassIconButton` (icona + frame + `contentShape`),
/// senza alcun `Button` attorno: pensato per essere usato come `label` di
/// un `Menu` che deve avere lo stesso aspetto ma senza innestarvi un
/// `Button` proprio. Un `Button` dentro la label di un `Menu` intercetta
/// il gesto e impedisce l'apertura del menu stesso: è esattamente il bug
/// che aveva reso irraggiungibili tutte le voci del menu "…" nel player.
struct GlassIconGlyph: View {
    let systemImage: String
    var size: CGFloat = 44

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size * 0.41, weight: .semibold))
            .frame(width: size, height: size)
            .contentShape(Circle())
    }
}

struct NativeOrLegacyGlassCircle: ViewModifier {
    let tint: Color?
    let isInSystemToolbar: Bool

    func body(content: Content) -> some View {
        if isInSystemToolbar {
            content
                .buttonStyle(.plain)
                .foregroundStyle(tint ?? .primary)
        } else if #available(iOS 26.0, *) {
            content
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .tint(tint)
        } else {
            content
                .buttonStyle(.plain)
                .foregroundStyle(tint ?? .primary)
                .background(.ultraThinMaterial, in: Circle())
                .overlay {
                    Circle()
                        .strokeBorder(Color.white.opacity(0.16), lineWidth: 0.5)
                }
        }
    }
}

struct GlassPrimaryButton: View {
    let title: String
    var systemImage: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let systemImage {
                    Image(systemName: systemImage)
                }
                Text(title)
            }
            .font(.headline)
            .padding(.horizontal, 22)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
        }
        .modifier(NativeOrLegacyGlassCapsule())
    }
}

private struct NativeOrLegacyGlassCapsule: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.capsule)
                .tint(.accentColor)
        } else {
            content
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .background(Color.accentColor, in: Capsule())
                .overlay {
                    Capsule()
                        .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5)
                }
        }
    }
}
