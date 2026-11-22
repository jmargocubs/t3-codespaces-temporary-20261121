import Foundation
import XCTest
@testable import Silo

final class EPGProgramSearchIndexTests: XCTestCase {
    private let provider = UUID(uuidString: "A1F4C8A0-CB4C-4B3D-9F73-9AA2BDA7C6B0")!
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testRankingMinimumLengthAndWhitespace() async throws {
        let guide = makeGuide([
            program("one", 0, "Abacus"), program("two", 60, "News About Cats"),
            program("three", 120, "Evening", subtitle: "Abacus special")
        ])
        let index = try await makeIndex(guide, channels: [channel("one", "One"), channel("two", "Two"), channel("three", "Three")])
        let short = await index.search(query: "a", now: now)
        XCTAssertEqual(short?.count, 0)
        let result = try unwrap(await index.search(query: "  ab  ", now: now))
        XCTAssertEqual(result.map(\.quality), [.titlePrefix, .titleWordPrefix, .subtitle])
        XCTAssertEqual(result.map(\.channelID), ["one", "two", "three"])
    }

    func testUnicodeAndLocaleUseFoundationOracle() async throws {
        let values = ["Café", "CAFE", "İstanbul", "ıstanbul", "Straße", "Ｗｉｄｅ", "😀 News"]
        let guide = makeGuide(values.enumerated().map { program("c\($0.offset)", TimeInterval($0.offset * 60), $0.element) })
        let channels = values.enumerated().map { channel("c\($0.offset)", "C\($0.offset)") }
        let index = try await makeIndex(guide, channels: channels)
        for query in ["cafe", "istanbul", "strasse", "wide", "😀 n"] {
            let expected = values.enumerated().compactMap { values[$0.offset].localizedStandardContains(query) ? "c\($0.offset)" : nil }
            let actual = (await index.search(query: query, now: now) ?? []).map(\.channelID).sorted()
            XCTAssertEqual(actual, expected.sorted(), query)
        }
        let turkishGuide = makeGuide([program("tr", 0, "İstanbul")])
        let turkish = try await makeIndex(turkishGuide, channels: [channel("tr", "TR")])
        let turkishResult = await turkish.search(query: "istanbul", now: now,
                                                 matchingLocale: Locale(identifier: "tr_TR")) ?? []
        XCTAssertEqual(turkishResult.count, "İstanbul".localizedStandardContains("istanbul") ? 1 : 0)
    }

    /// The byte fast path and the Foundation path together must select exactly the programmes
    /// `localizedStandardContains` selects, in either locale family.
    func testMatchSetEqualsFoundationOracleOnMixedCorpus() async throws {
        let words = ["News", "news", "NEWS24", "Café", "cafe", "CAFÉ", "Straße", "strasse", "İstanbul", "ıstanbul",
                     "ISTANBUL", "Ｗｉｄｅ", "wide", "Ünïcode", "Match-Point", "match point", "😀 Live", "Kids", "naïve", "Æon"]
        var programs: [EPGProgram] = []
        for slot in 0..<300 {
            let title = "\(words[slot % words.count]) \(words[(slot * 7) % words.count])"
            let subtitle = slot.isMultiple(of: 3) ? "Part \(words[(slot * 11) % words.count])" : nil
            programs.append(program("c\(slot % 30)", TimeInterval((slot / 30) * 600 - 1_200), title,
                                    subtitle: subtitle, duration: 600))
        }
        let guide = makeGuide(programs)
        let channels = (0..<30).map { channel("c\($0)", "C\($0)") }
        let queries = ["ne", "news", "cafe", "café", "CAFE", "strasse", "straße", "istanbul", "İstanbul", "ıst",
                       "wide", "ｗｉ", "match p", "😀 l", "nai", "part ca"]
        for localeID in ["en_US", "tr_TR"] {
            let locale = Locale(identifier: localeID)
            let index = try await makeIndex(guide, channels: channels)
            for query in queries {
                let expected = Set(programs.filter { item in
                    item.end > now && (item.title.localizedStandardContains(query)
                        || item.subtitle?.localizedStandardContains(query) == true)
                }.map(\.id))
                let actual = try unwrap(await index.search(query: query, now: now, limit: .max, matchingLocale: locale))
                XCTAssertEqual(Set(actual.map(\.programID)), expected, "\(localeID) \(query)")
                XCTAssertEqual(actual.count, expected.count, "no duplicates for \(localeID) \(query)")
            }
        }
    }

    /// Block matching must return exactly what checking every text on its own returns (same
    /// programmes, order and qualities), and both must agree with `localizedStandardContains`.
    func testBlockMatchingEqualsPerTextFoundationMatchingOnUnicodeCorpus() async throws {
        let stems = Self.unicodeStems
        var programs: [EPGProgram] = []
        // Enough texts for many 64-text blocks in both the ASCII and non-ASCII groups.
        for slot in 0..<900 {
            let title = "\(stems[slot % stems.count]) \(slot % 7 == 0 ? stems[(slot * 5) % stems.count] : "")"
                .trimmingCharacters(in: .whitespaces)
            let subtitle: String? = slot.isMultiple(of: 4) ? "\(stems[(slot * 13) % stems.count]) \(slot)" : nil
            programs.append(program("c\(slot % 45)", TimeInterval((slot / 45) * 600 - 1_200),
                                    slot.isMultiple(of: 9) ? "Plain Title \(slot)" : title, subtitle: subtitle,
                                    duration: 600))
        }
        let guide = makeGuide(programs)
        let channels = (0..<45).map { channel("c\($0)", "C\($0)") }
        let queries = Self.unicodeQueries(from: stems)

        for localeID in ["en_US", "tr_TR"] {
            let locale = Locale(identifier: localeID)
            let blocks = try await makeIndex(guide, channels: channels)
            let perText = try unwrap(await EPGProgramSearchIndex.build(
                identity: .init(providerID: provider, catalogRevision: 1, guideGeneration: 1), guide: guide,
                channels: channels, now: now, foundationMatching: .perText))
            for query in queries {
                let fast = try unwrap(await blocks.search(query: query, now: now, limit: .max, matchingLocale: locale))
                let reference = try unwrap(await perText.search(query: query, now: now, limit: .max, matchingLocale: locale))
                XCTAssertEqual(fast, reference, "\(localeID) \(query.debugDescription)")
                let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed.count >= 2 else {
                    XCTAssertEqual(fast, [])
                    continue
                }
                let expected = Set(programs.filter { item in
                    item.end > now && (item.title.localizedStandardContains(trimmed)
                        || item.subtitle?.localizedStandardContains(trimmed) == true)
                }.map(\.id))
                XCTAssertEqual(Set(fast.map(\.programID)), expected, "\(localeID) oracle \(query.debugDescription)")
            }
        }
    }

    /// Texts ending in CR join the "\n" block separator in one grapheme cluster. Trimmed queries
    /// never end in CR, so block matching must still find every such text, wherever it sits.
    func testCarriageReturnTerminatedTextsInOneBlockMatchLikePerText() async throws {
        let titles = ["ab\r", "xb\r", "zz", "Café\r", "Line\nTwo", "Line\rBreak", "", "ab\r", "Fab\r\r"]
        let guide = makeGuide(titles.enumerated().map { program("c\($0.offset)", TimeInterval($0.offset * 60), $0.element) })
        let channels = titles.indices.map { channel("c\($0)", "C\($0)") }
        let blocks = try await makeIndex(guide, channels: channels)
        let perText = try unwrap(await EPGProgramSearchIndex.build(
            identity: .init(providerID: provider, catalogRevision: 1, guideGeneration: 1), guide: guide,
            channels: channels, now: now, foundationMatching: .perText))
        for query in ["b\r", "ab\r", "ab", "xb", "é\r", "fé", "afé\r", "e\nt", "e\nT", "e\rb", "ne", "fab\r", "ab\r\n"] {
            let fast = try unwrap(await blocks.search(query: query, now: now, limit: .max))
            let reference = try unwrap(await perText.search(query: query, now: now, limit: .max))
            XCTAssertEqual(fast, reference, query.debugDescription)
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            let expected = trimmed.count < 2 ? [] : titles.enumerated()
                .filter { $0.element.localizedStandardContains(trimmed) }.map { "c\($0.offset)" }
            XCTAssertEqual(fast.map(\.channelID).sorted(), expected.sorted(), "oracle \(query.debugDescription)")
        }
    }

    func testASCIIFastPathIsDecidedByTheMatchingLocaleAlone() {
        for id in ["en_US", "en", "fr_FR", "de_DE", "cs_CZ", "hu_HU", "da_DK", "cy_GB", "lt_LT", "ja_JP"] {
            XCTAssertTrue(EPGProgramSearchIndex.usesASCIIFastPath(query: "istanbul", matchingLocale: Locale(identifier: id)), id)
        }
        for id in ["tr_TR", "tr", "tr-TR", "az_AZ", "az-Latn-AZ", "az"] {
            XCTAssertFalse(EPGProgramSearchIndex.usesASCIIFastPath(query: "istanbul", matchingLocale: Locale(identifier: id)), id)
        }
        let english = Locale(identifier: "en_US")
        XCTAssertFalse(EPGProgramSearchIndex.usesASCIIFastPath(query: "café", matchingLocale: english))
        XCTAssertFalse(EPGProgramSearchIndex.usesASCIIFastPath(query: "a\u{0}b", matchingLocale: english))
    }

    /// en_US → tr_TR → en_US with one store: the same index serves every locale (no rebuild), each
    /// query uses the locale current at that moment, and results equal per-text Foundation matching.
    func testLocaleTransitionsReuseTheIndexAndMatchInTheCurrentLocale() async throws {
        let titles = ["ISTANBUL Live", "İstanbul Gece", "ıstanbul", "Igdir Report", "Late Show", "Café Turc"]
        let guide = makeGuide(titles.enumerated().map { program("c\($0.offset)", TimeInterval($0.offset * 60), $0.element) })
        let channels = titles.indices.map { channel("c\($0)", "C\($0)") }
        let locale = LocaleBox(Locale(identifier: "en_US"))
        let store = EPGProgramSearchIndexStore(matchingLocale: { locale.value })
        let reference = try unwrap(await EPGProgramSearchIndex.build(
            identity: .init(providerID: provider, catalogRevision: 1, guideGeneration: 1), guide: guide,
            channels: channels, now: now, foundationMatching: .perText))
        let current = EPGProgramSearchIndexStore.Input(identity: .init(providerID: provider, catalogRevision: 1, guideGeneration: 1),
                                                       guide: guide, channels: channels)

        for (step, id) in ["en_US", "tr_TR", "en_US", "az_AZ", "en_US"].enumerated() {
            locale.value = Locale(identifier: id)
            for query in ["istanbul", "ISTANBUL", "is", "IG", "late", "café"] {
                let outcome = await store.search(query: query, input: current, now: now)
                let expected = try unwrap(await reference.search(query: query, now: now, limit: EPGProgramSearchIndex.defaultResultLimit,
                                                                 matchingLocale: Locale(identifier: id)))
                XCTAssertEqual(outcome, .results(expected), "step \(step) \(id) \(query)")
                let used = await store.lastMatchingLocaleIdentifierForTesting
                XCTAssertEqual(used, id, "each query reads the locale current at that moment")
            }
            let builds = await store.buildCountForTesting
            XCTAssertEqual(builds, 1, "a locale change alone never rebuilds (step \(step))")
        }
    }

    func testWorkerLimitIsClampedAndNeverChangesResults() async throws {
        XCTAssertEqual(EPGProgramSearchIndex.Configuration(foundationWorkerLimit: 0).foundationWorkerLimit, 1)
        XCTAssertLessThanOrEqual(EPGProgramSearchIndex.Configuration.production.foundationWorkerLimit, 2)
        XCTAssertGreaterThanOrEqual(EPGProgramSearchIndex.Configuration.production.foundationWorkerLimit, 1)

        let stems = Self.unicodeStems
        let guide = makeGuide((0..<400).map { slot in
            program("c\(slot % 20)", TimeInterval((slot / 20) * 600 - 600), "\(stems[slot % stems.count]) \(slot)", duration: 600)
        })
        let channels = (0..<20).map { channel("c\($0)", "C\($0)") }
        let single = try await makeIndex(guide, channels: channels, configuration: .init(foundationWorkerLimit: 1))
        for limit in [2, 4, 8] {
            let wide = try await makeIndex(guide, channels: channels, configuration: .init(foundationWorkerLimit: limit))
            for query in ["café", "istanbul", "東京", "news", "😀 l", "ss"] {
                let expected = await single.search(query: query, now: now, limit: .max)
                let actual = await wide.search(query: query, now: now, limit: .max)
                XCTAssertEqual(actual, expected, "\(limit) workers, \(query)")
            }
        }
    }

    func testLiveFirstAndChronologicalOrderHoldForFoundationMatches() async throws {
        let guide = makeGuide([
            program("b", 1_200, "Café Later"), program("a", 600, "Café Soon"),
            program("c", -60, "Le Café Live", duration: 600), program("a", -60, "Café Live", duration: 600)
        ])
        let index = try await makeIndex(guide, channels: [channel("a", "A"), channel("b", "B"), channel("c", "C")])
        let results = try unwrap(await index.search(query: "café", now: now))
        XCTAssertEqual(results.map(\.title), ["Café Live", "Le Café Live", "Café Soon", "Café Later"])
        XCTAssertEqual(results.map(\.isLive), [true, true, false, false])
    }

    func testCancelledFoundationSearchReturnsNil() async throws {
        let guide = makeLargeGuide(channels: 400, perChannel: 100, title: "Épisode")
        let index = try await makeIndex(guide.index, channels: guide.channels)
        let task = Task { await index.search(query: "épisode", now: now, limit: .max) }
        task.cancel()
        let result = await task.value
        XCTAssertNil(result)
    }

    static let unicodeStems: [String] = [
        // Accented Latin, precomposed and decomposed, and letters without decompositions.
        "Café", "Cafe\u{301}", "CAFÉ", "Crème brûlée", "Ångström", "Søren", "Łódź", "Đorđe", "Ærø", "Œuvre",
        "naïve", "Straße", "STRASSE", "ẞ Groß", "Ñandú",
        // Turkish and Azeri casing.
        "İstanbul", "ISTANBUL", "ıstanbul", "istanbul", "Iğdır", "DİYARBAKIR", "Ağrı", "Əli", "Şəki", "ƏLİ",
        // Combining marks, including a text that starts with one.
        "e\u{301}\u{302}tude", "\u{301}leading mark", "z\u{335}\u{336}alg\u{334}o", "a\u{308}b\u{308}c",
        // Full-width and half-width forms.
        "Ｗｉｄｅ Ｎｅｗｓ", "ﾆｭｰｽ", "ＡＢＣ１２３",
        // Emoji: plain, ZWJ sequence, flag, skin tone, variation selector.
        "😀 Live", "👨‍👩‍👧 Family", "🇹🇷 Türkiye", "👍🏽 Sports", "⚽️ Match",
        // CJK and Hangul (precomposed and conjoining jamo).
        "東京ニュース", "新闻联播", "뉴스 9", "ニュース", "한국어 방송", "\u{1112}\u{1161}\u{11AB}글",
        // Other scripts and compatibility characters.
        "Ελληνικά ΣΟΦΟΣ σοφος", "Москва Ёлка", "العربية", "עִבְרִית", "हिन्दी समाचार", "ﬁnal ﬂight",
        "Mat\u{AD}ch", "News\u{A0}Hour", "Late\r", "Ⅻ Roman", "²nd Half", "a\u{200D}b", "x\u{200C}y",
        // CR-terminated, embedded line breaks, and an empty text.
        "Café\r", "ab\r", "xb\r", "Line\nTwo", "Line\rBreak", "",
        // Plain ASCII.
        "News", "Match Point", "Champions League"
    ]

    static func unicodeQueries(from stems: [String]) -> [String] {
        var queries = ["cafe", "café", "CAFÉ", "e\u{301}", "strasse", "straße", "ss", "STRASSE", "groß", "gross",
                       "istanbul", "İstanbul", "ISTANBUL", "ıs", "is", "igdir", "IĞDIR", "diyarbakir", "agri", "əli",
                       "ƏL", "seki", "soren", "søren", "lodz", "dorde", "aero", "oeuvre", "nandu", "etude",
                       "leading", "zalgo", "abc", "wide", "ｗｉ", "ＡＢＣ", "abc123", "ニュース", "ﾆｭｰｽ", "新闻",
                       "東京", "뉴스", "한국", "\u{1112}\u{1161}", "😀 L", "👨‍👩‍👧", "🇹🇷", "👍", "⚽ m", "σοφος",
                       "ΣΟΦΟΣ", "ёлка", "елка", "final", "fl", "match", "news hour", "late", "xii", "2nd",
                       "ab", "xy", "un", "\u{301}l", "ab\r", "a", "  ", "zz",
                       "b\r", "é\r", "afé\r", "e\nt", "e\rb", "late\r", "xb"]
        // Two- and three-character slices of every stem, plus case variants.
        for stem in stems {
            let characters = Array(stem)
            for length in [2, 3] where characters.count >= length {
                let start = (characters.count - length) / 2
                let slice = String(characters[start..<(start + length)])
                queries += [slice, slice.uppercased(), slice.lowercased()]
            }
        }
        return queries
    }

    func testEndedProgramsAreExcludedAtQueryTimeAndLiveFirst() async throws {
        let guide = makeGuide([program("a", -120, "Alpha", duration: 60), program("a", 0, "Alpha Live"), program("a", 600, "Alpha Later")])
        let index = try await makeIndex(guide, channels: [channel("a", "A")])
        let result = try unwrap(await index.search(query: "alpha", now: now))
        XCTAssertEqual(result.map(\.title), ["Alpha Live", "Alpha Later"])
        XCTAssertEqual(result.map(\.isLive), [true, false])
        let repeatResult = await index.search(query: "alpha", now: now)
        XCTAssertEqual(result, repeatResult)
    }

    func testDeduplicatesRepresentativeAndNameMapping() async throws {
        let guide = makeGuide([program("guide", 0, "Show")], names: ["guide": "Display"])
        let channels = [channel("first", "First", guideID: "guide"), channel("second", "Second", guideID: "guide"), channel("named", "Display", guideID: "")]
        let index = try await makeIndex(guide, channels: channels)
        let results = try unwrap(await index.search(query: "show", now: now))
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].channelID, "first")
    }

    func testIndexDoesNotRetainURLsOrChannels() async throws {
        let guide = makeGuide([program("a", 0, "News")])
        let index = try await makeIndex(guide, channels: [channel("a", "News")])
        let mirror = String(reflecting: index)
        XCTAssertFalse(mirror.contains("LiveTVChannel"))
        XCTAssertFalse(mirror.contains("URL"))
    }

    func testStoreReuseReplacementAndInvalidateGuard() async throws {
        let store = EPGProgramSearchIndexStore()
        let guide = makeGuide([program("a", 0, "News")])
        let input = EPGProgramSearchIndexStore.Input(identity: .init(providerID: provider, catalogRevision: 1, guideGeneration: 1), guide: guide, channels: [channel("a", "A")])
        let first = await store.search(query: "news", input: input, now: now)
        if case let .results(results) = first {
            XCTAssertEqual(results.map(\.title), ["News"])
        } else {
            XCTFail("expected results")
        }
        _ = await store.search(query: "news", input: input, now: now)
        #if DEBUG
        let buildCount = await store.buildCountForTesting
        XCTAssertEqual(buildCount, 1)
        #endif
        await store.invalidate(providerID: UUID())
        let activeIdentity = await store.currentIdentity
        XCTAssertNotNil(activeIdentity)
        await store.invalidate(providerID: provider)
        let clearedIdentity = await store.currentIdentity
        XCTAssertNil(clearedIdentity)
    }

    func testAmbiguousDisplayNameDoesNotMapAndUnclaimedGuideChannelsAreAbsent() async throws {
        // Two guide channels share "Sports One", so nameMap leaves the name out; "orphan" has no
        // playlist channel at all.
        let names = EPGIndex.nameMap([EPGChannel(id: "s1", displayNames: ["Sports One"]),
                                      EPGChannel(id: "s1b", displayNames: ["Sports One"])])
        let guide = EPGIndex(fetchedAt: now,
                             programsByChannel: ["s1": [program("s1", 0, "Final")], "s1b": [program("s1b", 0, "Final")],
                                                 "orphan": [program("orphan", 0, "Final")]],
                             channelIDsByName: names, statistics: .init())
        let index = try await makeIndex(guide, channels: [channel("byName", "Sports One HD", guideID: "")])
        let results = try unwrap(await index.search(query: "final", now: now))
        XCTAssertEqual(results, [])
    }

    func testStoreRebuildsForEveryIdentityComponentAndKeepsOldResultsOut() async throws {
        let store = EPGProgramSearchIndexStore()
        let oldGuide = makeGuide([program("a", 0, "Old News")])
        let newGuide = makeGuide([program("a", 0, "New News")])
        let first = input(revision: 1, generation: 1, guide: oldGuide)
        let firstOutcome = await store.search(query: "news", input: first, now: now)
        XCTAssertEqual(titles(firstOutcome), ["Old News"])

        for (step, next) in [input(revision: 1, generation: 2, guide: newGuide),
                             input(revision: 2, generation: 2, guide: newGuide),
                             input(revision: 2, generation: 2, guide: newGuide, provider: UUID())].enumerated() {
            let outcome = await store.search(query: "news", input: next, now: now)
            XCTAssertEqual(titles(outcome), ["New News"])
            let builds = await store.buildCountForTesting
            XCTAssertEqual(builds, step + 2, "identity \(next.identity) must rebuild")
            let identity = await store.currentIdentity
            XCTAssertEqual(identity, next.identity)
        }
    }

    func testStoreOutcomesForShortQueryMissingGuideAndSQLiteGuide() async throws {
        let store = EPGProgramSearchIndexStore()
        let guide = makeGuide([program("a", 0, "News")])
        let short = await store.search(query: " n ", input: input(revision: 1, generation: 1, guide: guide), now: now)
        XCTAssertEqual(short, .queryTooShort)
        let missing = await store.search(query: "news", input: input(revision: 1, generation: 1, guide: nil), now: now)
        XCTAssertEqual(missing, .noGuide)

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EPGProgramSearch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let xml = "<tv><channel id=\"a\"><display-name>A</display-name></channel>"
            + "<programme channel=\"a\" start=\"20231114221320 +0000\" stop=\"20231114231320 +0000\"><title>News</title></programme></tv>"
        let built = try EPGSQLiteBuilder.build(xml: Data(xml.utf8), filter: nil, limits: EPGLimits(), fetchedAt: now,
                                               providerID: provider,
                                               fingerprint: Data(repeating: 0x42, count: EPGSourceFingerprint.length),
                                               destination: directory.appendingPathComponent("guide.sqlite"))
        let sqliteGuide = EPGIndex(sqlite: built.index, statistics: built.statistics)
        let sqlite = await store.search(query: "news", input: input(revision: 1, generation: 2, guide: sqliteGuide), now: now)
        XCTAssertEqual(titles(sqlite), ["News"], "a SQLite-backed guide is searched on disk")
        let builds = await store.buildCountForTesting
        XCTAssertEqual(builds, 1, "only the SQLite guide prepares a search source")
    }

    func testSupersededQueryCannotPublish() async throws {
        let store = EPGProgramSearchIndexStore()
        let guide = makeLargeGuide(channels: 400, perChannel: 100)
        let current = input(revision: 1, generation: 1, guide: guide.index, channels: guide.channels)
        let older = Task { await store.search(query: "episode", input: current, now: now, limit: .max) }
        // The older query has reached the store once it has adopted the identity.
        while await store.currentIdentity == nil { await Task.yield() }
        let newer = await store.search(query: "news", input: current, now: now)
        let olderOutcome = await older.value
        XCTAssertNotNil(newer)
        if case .results = olderOutcome { XCTFail("an older query finished after a newer one started and still published") }
    }

    /// Typing cancels the query that started the lazy build. The shared build must survive it,
    /// and the store must still answer the next query for the same identity.
    func testCancellingTheQueryThatStartedABuildKeepsTheStoreUsable() async throws {
        let store = EPGProgramSearchIndexStore()
        let guide = makeLargeGuide(channels: 400, perChannel: 100)
        let current = input(revision: 1, generation: 1, guide: guide.index, channels: guide.channels)
        let clock = ContinuousClock()

        let cancelled = Task { await store.search(query: "news", input: current, now: now) }
        cancelled.cancel()
        let started = clock.now
        let cancelledOutcome = await cancelled.value
        XCTAssertNil(cancelledOutcome)
        XCTAssertLessThan(started.duration(to: clock.now), .milliseconds(250), "a cancelled waiter returns promptly")

        let next = await store.search(query: "news", input: current, now: now)
        guard case .results(let results)? = next else { return XCTFail("store stuck after a cancelled build waiter: \(String(describing: next))") }
        XCTAssertFalse(results.isEmpty)
        let builds = await store.buildCountForTesting
        XCTAssertLessThanOrEqual(builds, 2)
    }

    func testCancelledIndexSearchReturnsNil() async throws {
        let guide = makeLargeGuide(channels: 400, perChannel: 100)
        let index = try await makeIndex(guide.index, channels: guide.channels)
        let task = Task { await index.search(query: "episode", now: now, limit: .max) }
        task.cancel()
        let result = await task.value
        XCTAssertNil(result)
    }

    private func input(revision: Int, generation: Int, guide: EPGIndex?, channels: [LiveTVChannel]? = nil,
                       provider: UUID? = nil) -> EPGProgramSearchIndexStore.Input {
        .init(identity: .init(providerID: provider ?? self.provider, catalogRevision: revision, guideGeneration: generation),
              guide: guide, channels: channels ?? [channel("a", "A")])
    }

    private func titles(_ outcome: EPGProgramSearchIndexStore.Outcome?) -> [String]? {
        guard case .results(let results)? = outcome else { return nil }
        return results.map(\.title)
    }

    private func makeLargeGuide(channels: Int, perChannel: Int,
                                title: String = "Episode") -> (index: EPGIndex, channels: [LiveTVChannel]) {
        var programs: [String: [EPGProgram]] = [:]
        var playlist: [LiveTVChannel] = []
        for number in 0..<channels {
            let key = "ch\(number)"
            programs[key] = (0..<perChannel).map { slot in
                program(key, TimeInterval(slot * 300), slot.isMultiple(of: 3) ? "News \(slot)" : "Show \(number)-\(slot)",
                        subtitle: "\(title) \(number * perChannel + slot)")
            }
            playlist.append(channel(key, "Channel \(number)"))
        }
        return (EPGIndex(fetchedAt: now, programsByChannel: programs, channelIDsByName: [:], statistics: .init()), playlist)
    }

    private func makeIndex(_ guide: EPGIndex, channels: [LiveTVChannel],
                           configuration: EPGProgramSearchIndex.Configuration = .production) async throws -> EPGProgramSearchIndex {
        try unwrap(await EPGProgramSearchIndex.build(identity: .init(providerID: provider, catalogRevision: 1, guideGeneration: 1), guide: guide, channels: channels, now: now, configuration: configuration))
    }
    private func unwrap<T>(_ value: T?) throws -> T { try XCTUnwrap(value) }
    private func makeGuide(_ programs: [EPGProgram], names: [String: String] = [:]) -> EPGIndex {
        let grouped = Dictionary(grouping: programs, by: \.channelID)
        return EPGIndex(fetchedAt: now, programsByChannel: grouped,
                        channelIDsByName: names.reduce(into: [:]) { $0[EPGChannelKey.name($1.value)!] = $1.key }, statistics: .init())
    }
    private func program(_ channel: String, _ offset: TimeInterval, _ title: String, subtitle: String? = nil, duration: TimeInterval = 300) -> EPGProgram {
        EPGProgram(channelID: channel, start: now.addingTimeInterval(offset), end: now.addingTimeInterval(offset + duration), title: title, subtitle: subtitle)
    }
    private func channel(_ id: String, _ name: String, guideID: String? = nil) -> LiveTVChannel {
        LiveTVChannel(id: id, guideID: guideID == nil ? id : (guideID!.isEmpty ? nil : guideID), name: name, streamURL: URL(string: "https://invalid.example/\(id)")!, logoURL: nil, category: "TV")
    }
}

/// A locale the test changes between queries; read from the store's actor.
private final class LocaleBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Locale
    init(_ locale: Locale) { stored = locale }
    var value: Locale {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}
