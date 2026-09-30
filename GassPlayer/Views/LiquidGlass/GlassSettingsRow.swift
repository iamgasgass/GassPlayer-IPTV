import SwiftUI

/// Riga d'azione in stile Liquid Glass: icona in un cerchio colorato,
/// titolo, e a destra uno tra chevron / spinner di caricamento / nulla.
/// Estratta da `SourceManageView` così la stessa identica riga può essere
/// riusata da `EPGManageView` e `SourceManagerView` senza duplicare lo
/// stile (icona 36×36, angolo del testo, colori) in tre punti diversi.
struct GlassSettingsRow: View {
    let icon: String
    let title: String
    var subtitle: String? = nil
    var tint: Color = .primary
    var showChevron: Bool = true
    var showsProgress: Bool = false
    var isDisabled: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 36, height: 36)
                    .background(tint.opacity(0.14), in: Circle())

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body.weight(.medium))
                        .foregroundStyle(tint == .red ? .red : .primary)

                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                if showsProgress {
                    ProgressView().controlSize(.small)
                } else if showChevron {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(showsProgress || isDisabled)
    }
}

/// Variante della riga con un `Toggle` al posto del chevron, per le
/// preferenze booleane (es. "Aggiorna automaticamente" in Gestisci guida TV).
struct GlassSettingsToggleRow: View {
    let icon: String
    let title: String
    var subtitle: String? = nil
    var tint: Color = .green

    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 36, height: 36)
                .background(tint.opacity(0.14), in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.weight(.medium))

                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .tint(tint)
        }
        .padding(.vertical, 13)
    }
}

/// Divider standard usato tra le righe delle card "Impostazioni" (indentato
/// per allinearsi al testo, non all'icona).
struct GlassRowDivider: View {
    var leading: CGFloat = 58

    var body: some View {
        Divider().padding(.leading, leading)
    }
}
