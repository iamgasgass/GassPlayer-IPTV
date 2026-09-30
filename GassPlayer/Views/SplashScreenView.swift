import SwiftUI
import UIKit

/// FIX "splash screen con l'icona reale dell'app": prima veniva mostrato
/// un SF Symbol generico (antenna.radiowaves...) al posto dell'icona vera
/// del progetto. Duplicare il PNG dell'AppIcon in un nuovo image set
/// separato e' la via "standard" ma rischiosa da fare qui: richiederebbe
/// trasferire un file binario come se fosse testo, con rischio reale di
/// corromperlo. La tecnica corretta e documentata da Apple per accedere
/// in modo affidabile all'icona effettivamente installata, senza toccare
/// alcun asset binario, e' leggerla a runtime da Info.plist
/// (CFBundleIcons -> CFBundlePrimaryIcon -> CFBundleIconFiles), che punta
/// esattamente ai file gia' generati da Xcode a partire da AppIcon-1024.png.
private extension UIApplication {
    var primaryAppIcon: UIImage? {
        guard let icons = Bundle.main.infoDictionary?["CFBundleIcons"] as? [String: Any],
              let primaryIcon = icons["CFBundlePrimaryIcon"] as? [String: Any],
              let iconFiles = primaryIcon["CFBundleIconFiles"] as? [String],
              let lastIconName = iconFiles.last
        else { return nil }
        return UIImage(named: lastIconName)
    }
}

struct SplashScreenView: View {
    var onFinished: () -> Void

    @State private var scale: CGFloat = 0.7
    @State private var opacity: Double = 0
    @State private var glowRadius: CGFloat = 8

    private static let iconCornerRadiusRatio: CGFloat = 0.2237
    private let iconSize: CGFloat = 120

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color.accentColor.opacity(0.12),
                    Color(uiColor: .systemBackground),
                    Color.purple.opacity(0.08)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 20) {
                ZStack {
                    Circle()
                        .fill(.ultraThinMaterial)
                        .frame(width: iconSize + 20, height: iconSize + 20)
                        .shadow(color: Color.accentColor.opacity(0.6), radius: glowRadius)

                    appIconView
                        .frame(width: iconSize, height: iconSize)
                        .clipShape(RoundedRectangle(cornerRadius: iconSize * Self.iconCornerRadiusRatio, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: iconSize * Self.iconCornerRadiusRatio, style: .continuous)
                                .strokeBorder(.white.opacity(0.25), lineWidth: 1)
                        }
                        .shadow(color: .black.opacity(0.35), radius: 12, y: 6)
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

    @ViewBuilder
    private var appIconView: some View {
        if let uiImage = UIApplication.shared.primaryAppIcon {
            Image(uiImage: uiImage)
                .resizable()
                .scaledToFill()
        } else {
            ZStack {
                Color.accentColor.opacity(0.25)
                Image(systemName: "antenna.radiowaves.left.and.right.circle.fill")
                    .resizable()
                    .scaledToFit()
                    .padding(20)
                    .foregroundStyle(.white, Color.accentColor)
            }
        }
    }
}
