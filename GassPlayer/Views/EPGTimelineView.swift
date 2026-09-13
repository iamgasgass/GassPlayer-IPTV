import SwiftUI

struct EPGTimelineView: View {
    let credentials: XtreamCredentials
    let streams: [XtreamStream]

    @Environment(\.dismiss) private var dismiss

    @State private var programsByStream: [Int: [EPGProgram]] = [:]
    @State private var isLoading = false
    @State private var selectedProgram: EPGProgram?
    @State private var selectedStreamName = ""

    private let pixelsPerMinute: CGFloat = 2.5
    private let channelColumnWidth: CGFloat = 150
    private let timelineStart = Calendar.current.startOfDay(for: Date())

    var body: some View {
        NavigationStack {
            ScrollView([.horizontal, .vertical]) {
                VStack(alignment: .leading, spacing: 8) {
                    timeRuler

                    ForEach(streams) { stream in
                        channelRow(for: stream)
                    }
                }
                .padding()
                .overlay(alignment: .topLeading) {
                    nowIndicator
                }
            }
            .background(Color.black.ignoresSafeArea())
            .overlay {
                if isLoading {
                    ProgressView("Caricamento guida TV…")
                        .padding()
                        .background(
                            .ultraThinMaterial,
                            in: RoundedRectangle(cornerRadius: 16)
                        )
                }
            }
            .navigationTitle("Guida TV")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Chiudi") {
                        dismiss()
                    }
                }
            }
            .task {
                await loadEPGWithBoundedConcurrency()
            }
            .sheet(item: $selectedProgram) { program in
                EPGProgramDetailView(
                    program: program,
                    channelName: selectedStreamName
                )
            }
        }
    }

    private var timeRuler: some View {
        HStack(spacing: 0) {
            Color.clear
                .frame(width: channelColumnWidth)

            ForEach(0..<24, id: \.self) { hour in
                Text(String(format: "%02d:00", hour))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(
                        width: 60 * pixelsPerMinute,
                        alignment: .leading
                    )
            }
        }
        .padding(.bottom, 4)
    }

    private func channelRow(for stream: XtreamStream) -> some View {
        HStack(spacing: 0) {
            Text(stream.name)
                .font(.caption)
                .lineLimit(1)
                .frame(
                    width: channelColumnWidth,
                    alignment: .leading
                )
                .padding(.trailing, 8)

            ZStack(alignment: .leading) {
                ForEach(programsByStream[stream.streamId] ?? []) { program in
                    programBlock(program, streamName: stream.name)
                }
            }
            .frame(
                width: 24 * 60 * pixelsPerMinute,
                height: 48,
                alignment: .leading
            )
        }
    }

    private func programBlock(
        _ program: EPGProgram,
        streamName: String
    ) -> some View {
        let offsetMinutes = program.start.timeIntervalSince(timelineStart) / 60
        let durationMinutes = program.end.timeIntervalSince(program.start) / 60

        let width = max(
            CGFloat(durationMinutes) * pixelsPerMinute,
            28
        )

        let isCurrent = program.start <= Date() && program.end > Date()

        return Button {
            selectedStreamName = streamName
            selectedProgram = program
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(program.title)
                    .font(.caption2.weight(isCurrent ? .semibold : .regular))
                    .lineLimit(1)

                Text(
                    "\(program.start.formatted(date: .omitted, time: .shortened)) – " +
                    "\(program.end.formatted(date: .omitted, time: .shortened))"
                )
                .font(.system(size: 8))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            .padding(.horizontal, 6)
            .frame(width: width, height: 42, alignment: .leading)
            .background {
                if #available(iOS 26.0, *) {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(
                            program.hasArchive
                                ? Color.accentColor.opacity(0.35)
                                : Color.white.opacity(0.12)
                        )
                        .glassEffect(
                            isCurrent
                                ? .regular.tint(Color.accentColor.opacity(0.45))
                                : .regular,
                            in: .rect(cornerRadius: 8)
                        )
                } else {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(
                            program.hasArchive
                                ? Color.accentColor.opacity(0.35)
                                : Color.white.opacity(0.14)
                        )
                }
            }
        }
        .buttonStyle(.plain)
        .offset(x: max(CGFloat(offsetMinutes) * pixelsPerMinute, 0))
    }

    private var nowIndicator: some View {
        let minutesSinceStart = Date().timeIntervalSince(timelineStart) / 60

        return Rectangle()
            .fill(Color.red)
            .frame(width: 2)
            .frame(height: max(CGFloat(streams.count) * 56, 80))
            .offset(
                x: channelColumnWidth +
                    max(CGFloat(minutesSinceStart) * pixelsPerMinute, 0),
                y: 28
            )
    }

    /// Carica al massimo quattro canali simultaneamente.
    private func loadEPGWithBoundedConcurrency() async {
        isLoading = true

        defer {
            isLoading = false
        }

        let service = EPGService(credentials: credentials)
        let limitedStreams = Array(streams.prefix(80))

        guard !limitedStreams.isEmpty else {
            return
        }

        await withTaskGroup(of: (Int, [EPGProgram]).self) { group in
            var nextIndex = 0
            let initialTaskCount = min(4, limitedStreams.count)

            for _ in 0..<initialTaskCount {
                let stream = limitedStreams[nextIndex]
                nextIndex += 1

                group.addTask {
                    let programs = (
                        try? await service.shortEPG(
                            streamId: stream.streamId,
                            limit: 20
                        )
                    ) ?? []

                    return (stream.streamId, programs)
                }
            }

            for await (streamId, programs) in group {
                programsByStream[streamId] = programs

                guard nextIndex < limitedStreams.count else {
                    continue
                }

                let stream = limitedStreams[nextIndex]
                nextIndex += 1

                group.addTask {
                    let programs = (
                        try? await service.shortEPG(
                            streamId: stream.streamId,
                            limit: 20
                        )
                    ) ?? []

                    return (stream.streamId, programs)
                }
            }
        }
    }
}

private struct EPGProgramDetailView: View {
    let program: EPGProgram
    let channelName: String

    @Environment(\.dismiss) private var dismiss

    private var isLive: Bool {
        program.start <= Date() && program.end > Date()
    }

    private var progress: Double {
        let total = program.end.timeIntervalSince(program.start)

        guard total > 0 else {
            return 0
        }

        return min(
            max(Date().timeIntervalSince(program.start) / total, 0),
            1
        )
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Label(channelName, systemImage: "tv")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Text(program.title)
                    .font(.title2.bold())

                Text(
                    "\(program.start.formatted(date: .abbreviated, time: .shortened)) – " +
                    "\(program.end.formatted(date: .omitted, time: .shortened))"
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)

                if isLive {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("In onda ora", systemImage: "dot.radiowaves.left.and.right")
                            .foregroundStyle(.red)

                        ProgressView(value: progress)
                            .tint(.accentColor)
                    }
                }

                if let description = program.description,
                   !description.isEmpty
                {
                    Text(description)
                        .font(.body)
                }

                if program.hasArchive {
                    Label(
                        "Disponibile in archivio",
                        systemImage: "clock.arrow.circlepath"
                    )
                    .foregroundStyle(.secondary)
                }

                Spacer()
            }
            .padding()
            .navigationTitle("Programma")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Chiudi") {
                        dismiss()
                    }
                }
            }
        }
    }
}
