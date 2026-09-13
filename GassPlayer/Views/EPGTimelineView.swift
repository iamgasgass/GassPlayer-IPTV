import SwiftUI

struct EPGTimelineView: View {
    let credentials: XtreamCredentials
    let streams: [XtreamStream]

    @State private var programsByStream: [Int: [EPGProgram]] = [:]
    @State private var failedStreamIDs = Set<Int>()
    @State private var isLoading = false
    @State private var now = Date()
    @State private var timelineStart = Calendar.current.startOfDay(for: Date())

    private let pixelsPerMinute: CGFloat = 2.4
    private let channelColumnWidth: CGFloat = 152
    private let rowHeight: CGFloat = 54
    private let maxConcurrentRequests = 4
    private let calendar = Calendar.autoupdatingCurrent

    private var timelineEnd: Date {
        calendar.date(byAdding: .day, value: 1, to: timelineStart) ?? timelineStart.addingTimeInterval(86_400)
    }

    private var timelineWidth: CGFloat {
        CGFloat(timelineEnd.timeIntervalSince(timelineStart) / 60) * pixelsPerMinute
    }

    var body: some View {
        ZStack {
            ScrollView([.horizontal, .vertical], showsIndicators: true) {
                VStack(alignment: .leading, spacing: 8) {
                    timeRuler
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(streams) { stream in
                            channelRow(for: stream)
                        }
                    }
                }
                .padding(12)
            }

            if isLoading {
                ProgressView("Caricamento guida TV…")
                    .padding(16)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
        .task(id: streamIdentity) {
            await reloadEPG()
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in
            timelineStart = calendar.startOfDay(for: Date())
            now = Date()
            Task { await reloadEPG() }
        }
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { date in
            now = date
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Guida elettronica dei programmi")
    }

    private var streamIdentity: String {
        streams.map { String($0.streamId) }.joined(separator: ",")
    }

    private var timeRuler: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: channelColumnWidth, height: 22)
            ForEach(0...24, id: \.self) { hour in
                Text(String(format: "%02d:00", hour % 24))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 60 * pixelsPerMinute, alignment: .leading)
            }
        }
        .frame(width: channelColumnWidth + timelineWidth, alignment: .leading)
    }

    private func channelRow(for stream: XtreamStream) -> some View {
        HStack(spacing: 8) {
            channelLabel(for: stream)

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.thinMaterial)
                    .frame(width: timelineWidth, height: rowHeight)

                ForEach(programsByStream[stream.streamId] ?? []) { program in
                    programBlock(program)
                }

                if failedStreamIDs.contains(stream.streamId) {
                    Text("EPG non disponibile")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                }
            }
            .frame(width: timelineWidth, height: rowHeight, alignment: .leading)
        }
    }

    private func channelLabel(for stream: XtreamStream) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(stream.name)
                .font(.caption.weight(.semibold))
                .lineLimit(2)

            if let current = currentProgram(for: stream) {
                Text(current.title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(width: channelColumnWidth, height: rowHeight, alignment: .leading)
        .padding(.horizontal, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityLabel(accessibilityLabel(for: stream))
    }

    private func programBlock(_ program: EPGProgram) -> some View {
        let clippedStart = max(program.start, timelineStart)
        let clippedEnd = min(program.end, timelineEnd)
        let startMinutes = max(0, clippedStart.timeIntervalSince(timelineStart) / 60)
        let durationMinutes = max(1, clippedEnd.timeIntervalSince(clippedStart) / 60)
        let width = max(CGFloat(durationMinutes) * pixelsPerMinute, 28)

        return VStack(alignment: .leading, spacing: 2) {
            Text(program.title)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
            if let description = program.description, !description.isEmpty {
                Text(description)
                    .font(.caption2)
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .frame(width: width, height: rowHeight - 8, alignment: .leading)
        .background(program.hasArchive ? Color.accentColor.opacity(0.28) : Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
        }
        .offset(x: CGFloat(startMinutes) * pixelsPerMinute)
        .accessibilityLabel("\(program.title), \(program.start.formatted(date: .omitted, time: .shortened)) fino alle \(program.end.formatted(date: .omitted, time: .shortened))\(program.hasArchive ? ", disponibile in archivio" : "")")
    }

    private func currentProgram(for stream: XtreamStream) -> EPGProgram? {
        programsByStream[stream.streamId]?.first { $0.start <= now && $0.end > now }
    }

    private func accessibilityLabel(for stream: XtreamStream) -> String {
        guard let current = currentProgram(for: stream) else {
            return "\(stream.name), nessun programma corrente disponibile"
        }
        return "\(stream.name), in onda: \(current.title), fino alle \(current.end.formatted(date: .omitted, time: .shortened))"
    }

    @MainActor
    private func reloadEPG() async {
        programsByStream = [:]
        failedStreamIDs = []
        guard !streams.isEmpty else { return }

        isLoading = true
        defer { isLoading = false }

        let service = EPGService(credentials: credentials)
        let streamIDs = streams.map(\.streamId)
        let chunks = stride(from: 0, to: streamIDs.count, by: maxConcurrentRequests).map {
            Array(streamIDs[$0..<min($0 + maxConcurrentRequests, streamIDs.count)])
        }

        for chunk in chunks {
            await withTaskGroup(of: (Int, Result<[EPGProgram], Error>).self) { group in
                for streamID in chunk {
                    group.addTask {
                        do {
                            return (streamID, .success(try await service.shortEPG(streamId: streamID, limit: 24)))
                        } catch {
                            return (streamID, .failure(error))
                        }
                    }
                }

                for await (streamID, result) in group {
                    switch result {
                    case .success(let programs):
                        programsByStream[streamID] = programs
                    case .failure:
                        failedStreamIDs.insert(streamID)
                    }
                }
            }
        }
    }
}
