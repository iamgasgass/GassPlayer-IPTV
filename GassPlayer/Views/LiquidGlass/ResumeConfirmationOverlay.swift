import SwiftUI

/// Alert "Riprendi la visione?" mostrato all'apertura di un film o un
/// episodio con una posizione salvata. A differenza del vecchio
/// comportamento (ripresa automatica silenziosa + toast), qui il motore
/// resta fermo a 0 finché l'utente non sceglie: il consenso è esplicito,
/// come chiesto per la funzione "Riprendi la visione".
///
/// Stile Liquid Glass nativo (`.glassEffect`) su iOS 26+, con fallback
/// `.ultraThinMaterial` identico nello spirito sulle versioni precedenti.
struct ResumeConfirmationOverlay: View {
    let time: TimeInterval
    let formattedTime: String
    let onResume: () -> Void
    let onRestart: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.55)
                .ignoresSafeArea()

            card
                .padding(.horizontal, 36)
        }
    }

    private var card: some View {
        GlassCard(cornerRadius: 26, padding: 20) {
            VStack(spacing: 18) {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.top, 4)

                VStack(spacing: 6) {
                    Text("Riprendi la visione?")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)

                    Text("Ti eri fermato a \(formattedTime)")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.7))
                }
                .multilineTextAlignment(.center)

                VStack(spacing: 10) {
                    Button(action: onResume) {
                        Text("Riprendi da \(formattedTime)")
                            .font(.system(size: 15, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 13)
                    }
                    .modifier(NativeOrLegacyGlassNeutralCapsule())

                    Button(action: onRestart) {
                        Text("Ricomincia da capo")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.white.opacity(0.75))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 13)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxWidth: 320)
    }
}
