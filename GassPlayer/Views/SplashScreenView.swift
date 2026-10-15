import SwiftUI
import UIKit

/// Loads the icon selected by the active Xcode build configuration.
///
/// The build-generated CFBundleIconName points to the primary AppIcon set in
/// Assets.xcassets. Reading that asset at runtime means the splash always uses
/// the same image as the installed app icon, without keeping a second PNG copy
/// that could become outdated. CFBundleIconFiles and the conventional AppIcon
/// asset name are compatibility fallbacks for older or custom build setups.
private extension UIApplication {
    var primaryAppIcon: UIImage? {
        let bundle = Bundle.main
        let primaryIcon = (bundle.infoDictionary?["CFBundleIcons"] as? [String: Any])?["CFBundlePrimaryIcon"] as? [String: Any]

        // Prefer the exact primary icon asset selected by Xcode for this build.
        if let assetName = primaryIcon?["CFBundleIconName"] as? String,
           let image = UIImage(named: assetName, in: bundle, compatibleWith: nil) {
            return image
        }

        // Older build configurations may expose only generated icon filenames.
        var iconNames = Array((primaryIcon?["CFBundleIconFiles"] as? [String] ?? []).reversed())
        if !iconNames.contains("AppIcon") {
            iconNames.append("AppIcon")
        }

        // Pick the highest-resolution image available instead of arbitrarily
        // selecting a small device-specific icon variant.
        let candidates = iconNames.compactMap {
            UIImage(named: $0, in: bundle, compatibleWith: nil)
        }
        return candidates.max { pixelArea(of: $0) < pixelArea(of: $1) }
    }

    private func pixelArea(of image: UIImage) -> CGFloat {
        let pixelWidth = image.size.width * image.scale
        let pixelHeight = image.size.height * image.scale
        return pixelWidth * pixelHeight
    }
}

/// Minimal, X-inspired launch animation:
/// the app icon settles in the centre, briefly pulls back, then zooms forward
/// as the splash layer fades away to reveal the app underneath.
struct SplashScreenView: View {
    var onFinished: () -> Void

    @State private var iconScale: CGFloat = 0.78
    @State private var splashOpacity: Double = 1
    @State private var hasStarted = false
    @State private var hasFinished = false

    private let iconSize: CGFloat = 108
    private let iconCornerRadius: CGFloat = 24

    var body: some View {
        GeometryReader { geometry in
            let zoomScale = max(geometry.size.width, geometry.size.height) / iconSize * 1.2

            ZStack {
                Color.black
                    .ignoresSafeArea()

                appIconView
                    .frame(width: iconSize, height: iconSize)
                    .clipShape(
                        RoundedRectangle(cornerRadius: iconCornerRadius, style: .continuous)
                    )
                    .scaleEffect(iconScale)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
            .opacity(splashOpacity)
            .onAppear {
                guard !hasStarted else { return }
                hasStarted = true
                startAnimation(zoomScale: zoomScale)
            }
        }
        .ignoresSafeArea()
        .accessibilityLabel("GassPlayer")
    }

    private func startAnimation(zoomScale: CGFloat) {
        // 1. The icon appears with a soft spring, like the app launch icon.
        withAnimation(.spring(response: 0.38, dampingFraction: 0.72)) {
            iconScale = 1
        }

        // 2. A short pull-back gives the animation its characteristic rhythm.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.40) {
            guard !hasFinished else { return }
            withAnimation(.easeInOut(duration: 0.14)) {
                iconScale = 0.92
            }

            // 3. The icon rushes forward; the splash then fades to reveal the app.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
                guard !hasFinished else { return }
                withAnimation(.easeInOut(duration: 0.56)) {
                    iconScale = zoomScale
                }

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.38) {
                    guard !hasFinished else { return }
                    withAnimation(.easeOut(duration: 0.26)) {
                        splashOpacity = 0
                    }

                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.26) {
                        guard !hasFinished else { return }
                        hasFinished = true
                        onFinished()
                    }
                }
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
                Color.black
                Image(systemName: "play.rectangle.fill")
                    .resizable()
                    .scaledToFit()
                    .padding(18)
                    .foregroundStyle(.white)
            }
        }
    }
}
