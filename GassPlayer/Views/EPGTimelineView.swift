import SwiftUI

/// Griglia EPG a timeline orizzontale: ogni riga è un canale, ogni blocco
/// è un programma con larghezza proporzionale alla sua durata reale,
/// con una linea verticale che indica l'orario corrente.
struct EPGTimelineView: View {
    let credentials: XtreamCredentials
    let streams: [XtreamStream]

    @State private var programsByStream: [Int: [EPGProgram]] = [:]
    @State private var isLoading = false
    private let pixelsPerMinute: CGFloat = 4
    private let timelineStart = Calendar.current.startOfDay(for: Date())

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            VStack(alignment: .leading, spacing: 8) {
                timeRuler
                ForEach(streams) { stream in
                    channelRow(for: stream)
                }
            }
            .overlay(alignment: .topLeading) { nowIndicator }
        }
        .task { await loadAllEPG() }
        .overlay { if isLoading { ProgressView() } }
    }

    private var timeRuler: some View {
        HStack(spacing: 0) {
            ForEach(0..<24, id: \.self) { hour in
                Text(String(format: "%02d:00", hour))
                    .font(.caption2)
                    .frame(width: 60 * pixelsPerMinute, alignment: .leading)
            }
        }
        .padding(.leading, 140)
    }

    private func channelRow(for stream: XtreamStream) -> some View {
        HStack(spacing: 0) {
            Text(stream.name)
                .font(.caption)
                .frame(width: 130, alignment: .leading)
                .lineLimit(1)

            ZStack(alignment: .leading) {
                ForEach(programsByStream[stream.streamId] ?? []) { program in
                    programBlock(program)
                }
            }
            .frame(height: 44)
        }
    }

    private func programBlock(_ program: EPGProgram) -> some View {
        let offsetMinutes = program.start.timeIntervalSince(timelineStart) / 60
        let durationMinutes = program.end.timeIntervalSince(program.start) / 60
        return Text(program.title)
            .font(.caption2)
            .lineLimit(1)
            .padding(.horizontal, 4)
            .frame(width: max(CGFloat(durationMinutes) * pixelsPerMinute, 20), height: 40, alignment: .leading)
            .background(program.hasArchive ? Color.accentColor.opacity(0.3) : Color.gray.opacity(0.2), in: RoundedRectangle(cornerRadius: 6))
            .offset(x: CGFloat(offsetMinutes) * pixelsPerMinute)
    }

    private var nowIndicator: some View {
        let minutesSinceStart = Date().timeIntervalSince(timelineStart) / 60
        return Rectangle()
            .fill(Color.red)
            .frame(width: 2)
            .offset(x: 140 + CGFloat(minutesSinceStart) * pixelsPerMinute)
    }

    private func loadAllEPG() async {
        isLoading = true
        let service = EPGService(credentials: credentials)
        await withTaskGroup(of: (Int, [EPGProgram]).self) { group in
            for stream in streams {
                group.addTask {
                    let programs = (try? await service.shortEPG(streamId: stream.streamId, limit: 20)) ?? []
                    return (stream.streamId, programs)
                }
            }
            for await (streamId, programs) in group {
                programsByStream[streamId] = programs
            }
        }
        isLoading = false
    }
}
