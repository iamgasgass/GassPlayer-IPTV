import SwiftUI

struct SplashScreenView: View {
    var onFinished: () -> Void

    @State private var scale: CGFloat = 0.7
    @State private var opacity: Double = 0
    @State private var glowRadius: CGFloat = 8

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.black, Color.indigo.opacity(0.55), Color.black],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 20) {
                ZStack {
                    Circle()
                        .fill(.ultraThinMaterial)
                        .frame(width: 120, height: 120)
                        .shadow(color: Color.accentColor.opacity(0.6), radius: glowRadius)

                    Image(systemName: "antenna.radiowaves.left.and.right.circle.fill")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 64, height: 64)
                        .foregroundStyle(.white, Color.accentColor)
                }
                .scaleEffect(scale)

                Text("GassPlayer")
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)

                Text("IPTV · Xtream Codes · VPN integrata")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.7))

                ProgressView().tint(.white).padding(.top, 12)
            }
            .opacity(opacity)
        }
        .onAppear {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.7)) {
                scale = 1.0; opacity = 1.0
            }
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                glowRadius = 20
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                withAnimation(.easeOut(duration: 0.4)) { opacity = 0 }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { onFinished() }
            }
        }
    }
}
