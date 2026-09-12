import SwiftUI

struct GlassCard<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        content
            .padding()
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.white.opacity(0.15), lineWidth: 1))
    }
}
