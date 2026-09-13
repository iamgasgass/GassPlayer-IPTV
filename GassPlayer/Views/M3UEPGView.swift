import SwiftUI

struct M3UEPGView: View {
    let channels: [M3UChannel]
    @EnvironmentObject private var settings: AppSettings
    @State private var programsByID: [String: [EPGProgram]] = [:]
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Aggiornamento guida TV…")
                } else if let errorMessage {
                    ContentUnavailableView("EPG non disponibile", systemImage: "calendar.badge.exclamationmark", description: Text(errorMessage))
                } else if channels.filter({ $0.tvgId != nil }).isEmpty {
                    ContentUnavailableView("Nessun tvg-id", systemImage: "rectangle.slash", description: Text("Questa playlist non espone un identificativo XMLTV per i canali."))
                } else {
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            ForEach(channels.filter { $0.tvgId != nil }) { channel in
                                M3UEPGChannelCard(channel: channel, programs: programsByID[channel.tvgId ?? ""] ?? [])
                            }
                        }
                        .padding()
                    }
                }
            }
            .navigationTitle("Guida TV")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { Task { await load() } } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            .task { await load() }
        }
    }

    private func load() async {
        guard let url = URL(string: settings.epgURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              !settings.epgURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = "Configura un URL XMLTV nelle Impostazioni."
            return
        }
        isLoading = true
        errorMessage = nil
        do {
            programsByID = try await XMLTVEPGService().load(from: url)
        } catch {
            errorMessage = "Impossibile leggere il feed XMLTV: \(error.localizedDescription)"
        }
        isLoading = false
    }
}

private struct M3UEPGChannelCard: View {
    let channel: M3UChannel
    let programs: [EPGProgram]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                AsyncImage(url: URL(string: channel.logoURL ?? "")) { phase in
                    if case .success(let image) = phase {
                        image.resizable().scaledToFit()
                    } else {
                        Image(systemName: "tv").foregroundStyle(.secondary)
                    }
                }
                .frame(width: 36, height: 36)
                .clipShape(RoundedRectangle(cornerRadius: 9))
                Text(channel.title).font(.headline).lineLimit(1)
                Spacer()
                Text(channel.tvgId ?? "").font(.caption2).foregroundStyle(.tertiary)
            }
            if programs.isEmpty {
                Text("Nessun programma nel feed.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(programs.filter { $0.end > Date() }.prefix(5)) { program in
                    HStack(spacing: 8) {
                        Text(program.start, style: .time)
                            .font(.caption.monospacedDigit())
                            .frame(width: 48, alignment: .leading)
                        Text(program.title).font(.subheadline).lineLimit(1)
                        Spacer()
                        if program.start <= Date() && program.end > Date() {
                            Text("IN ONDA")
                                .font(.system(size: 9, weight: .bold))
                                .padding(.horizontal, 7).padding(.vertical, 4)
                                .background(.tint.opacity(0.18), in: Capsule())
                        }
                    }
                }
            }
        }
        .padding(12)
        .background {
            if #available(iOS 26.0, *) {
                RoundedRectangle(cornerRadius: 20).fill(.clear).glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20))
            } else {
                RoundedRectangle(cornerRadius: 16).fill(.ultraThinMaterial)
            }
        }
    }
}
