import Foundation

/// One real future programme paired with the playlist channel that will display it.
/// The channel is kept with the programme so the Home can use its logo and brand surface without
/// looking up the full catalog again.
struct LiveTVUpNextItem: Identifiable, Hashable, Sendable {
    let channel: LiveTVChannel
    let program: EPGProgram

    var id: String { "\(channel.id)|\(program.id)" }
}

/// Pure, bounded selection for the Home rail. The service supplies only favorite-channel
/// candidates, so this never scans the provider catalog or the whole guide.
enum LiveTVUpNextResolver {
    static let defaultLimit = 8

    struct Candidate: Sendable {
        let channel: LiveTVChannel
        let programs: [EPGProgram]

        init(channel: LiveTVChannel, programs: [EPGProgram]) {
            self.channel = channel
            self.programs = programs
        }
    }

    static func resolve(candidates: [Candidate], providerID: UUID, now: Date,
                        guideIsUsable: Bool = true, limit: Int = defaultLimit) -> [LiveTVUpNextItem] {
        guard guideIsUsable, limit > 0 else { return [] }

        var seen = Set<String>()
        var items: [LiveTVUpNextItem] = []
        for candidate in candidates {
            guard LiveTVRecentChannel.belongs(candidate.channel.id, to: providerID) else { continue }
            for program in candidate.programs {
                let title = program.title.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty, program.start > now, program.end > program.start else { continue }

                // Guide IDs can differ only by case or by the playlist alias that matched them.
                // Use the normalized guide channel and start instant so the same listing cannot
                // appear twice when two favorites resolve to that one guide channel.
                let channelKey = EPGChannelKey.guideID(program.channelID)
                    ?? program.channelID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let identity = "\(channelKey)|\(Int64(program.start.timeIntervalSince1970.rounded()))"
                guard seen.insert(identity).inserted else { continue }
                items.append(LiveTVUpNextItem(channel: candidate.channel, program: program))
            }
        }

        return items.sorted {
            if $0.program.start != $1.program.start { return $0.program.start < $1.program.start }
            if $0.channel.name != $1.channel.name { return $0.channel.name.localizedCaseInsensitiveCompare($1.channel.name) == .orderedAscending }
            return $0.id < $1.id
        }.prefix(limit).map { $0 }
    }
}
