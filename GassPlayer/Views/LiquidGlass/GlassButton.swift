import SwiftUI

struct GlassIconButton: View {
    let systemImage: String
    var tint: Color? = nil
    var size: CGFloat = 44
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size * 0.41, weight: .semibold))
                .frame(width: size, height: size)
        }
        .buttonStyle(.plain)
        .contentShape(Circle())
        .modifier(GlassCircleModifier(tint: tint))
    }
}

struct GlassCircleModifier: ViewModifier {
    let tint: Color?
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(tint != nil ? .regular.tint(tint!).interactive() : .regular.interactive(), in: .circle)
        } else {
            content.background(.ultraThinMaterial, in: Circle())
        }
    }
}

struct GlassPrimaryButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title).font(.headline).padding(.horizontal, 24).padding(.vertical, 12)
        }
        .buttonStyle(.plain)
        .modifier(GlassCapsuleModifier())
    }
}

struct GlassCapsuleModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular.tint(.accentColor).interactive(), in: .capsule)
        } else {
            content.background(.ultraThinMaterial, in: Capsule())
        }
    }
}
