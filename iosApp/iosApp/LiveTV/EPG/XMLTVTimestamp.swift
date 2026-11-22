import Foundation

/// Parses XMLTV timestamps (`YYYYMMDDhhmmss ±hhmm`) into UTC instants.
///
/// Adapted from Telly's `XmltvTimestamp` (MIT, Copyright (c) 2026 John Corser,
/// johnpc/telly-apple@66c74301701822bed92bc245c7d887d9f78beb01). Kyro returns `Date`, reads bytes
/// directly instead of running a regular expression per programme, rejects out-of-range fields
/// instead of letting `Calendar` roll them over, accepts the minute-precision form, `±hh:mm`,
/// `Z`, `UTC` and `GMT`, and resolves offset-less times in a fallback zone with explicit
/// daylight-saving rules.
enum XMLTVTimestamp {
    static func parse(_ raw: String?, fallbackTimeZone: TimeZone) -> Date? {
        guard var raw else { return nil }
        return raw.withUTF8 { parse($0, fallbackTimeZone: fallbackTimeZone) }
    }

    /// Seconds since 1970 for a wall-clock time in `timeZone`.
    ///
    /// - A repeated hour (clocks going back) resolves to its first occurrence.
    /// - A skipped hour (clocks going forward) moves forward by the size of the gap, so
    ///   02:30 on a spring-forward night in New York becomes 03:30 daylight time.
    static func instant(civilSeconds civil: Int64, in timeZone: TimeZone) -> Int64 {
        func offset(_ seconds: Int64) -> Int64 {
            Int64(timeZone.secondsFromGMT(for: Date(timeIntervalSince1970: TimeInterval(seconds))))
        }
        let before = offset(civil - 43_200)
        let after = offset(civil + 43_200)
        guard before != after else { return civil - before }
        let early = civil - before
        let late = civil - after
        switch (offset(early) == before, offset(late) == after) {
        case (true, true): return min(early, late)
        case (true, false): return early
        case (false, true): return late
        case (false, false): return early
        }
    }

    private static func parse(_ bytes: UnsafeBufferPointer<UInt8>, fallbackTimeZone: TimeZone) -> Date? {
        var index = 0
        let count = bytes.count
        while index < count, isSpace(bytes[index]) { index += 1 }
        let digitsStart = index
        while index < count, isDigit(bytes[index]) { index += 1 }
        let digitCount = index - digitsStart
        guard digitCount == 12 || digitCount == 14 else { return nil }

        func number(_ offset: Int, _ length: Int) -> Int {
            var value = 0
            for position in digitsStart + offset ..< digitsStart + offset + length {
                value = value * 10 + Int(bytes[position] &- 0x30)
            }
            return value
        }
        let year = number(0, 4), month = number(4, 2), day = number(6, 2)
        let hour = number(8, 2), minute = number(10, 2)
        let second = digitCount == 14 ? number(12, 2) : 0
        guard (1970...2200).contains(year), (1...12).contains(month),
              (1...daysInMonth(month, year: year)).contains(day),
              hour < 24, minute < 60, second < 60 else { return nil }

        let civil = Int64(daysFromCivil(year: year, month: month, day: day)) * 86_400
            + Int64(hour * 3_600 + minute * 60 + second)

        while index < count, isSpace(bytes[index]) { index += 1 }
        var end = count
        while end > index, isSpace(bytes[end - 1]) { end -= 1 }
        guard index < end else {
            return Date(timeIntervalSince1970: TimeInterval(instant(civilSeconds: civil, in: fallbackTimeZone)))
        }
        guard let offset = utcOffset(bytes, from: index, to: end) else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(civil - Int64(offset)))
    }

    /// Seconds east of UTC for `±hhmm`, `±hh:mm`, `Z`, `UTC` or `GMT`; nil for anything else.
    private static func utcOffset(_ bytes: UnsafeBufferPointer<UInt8>, from start: Int, to end: Int) -> Int? {
        let length = end - start
        if length == 1, bytes[start] | 0x20 == UInt8(ascii: "z") { return 0 }
        if length == 3 {
            let word = String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<end]), as: UTF8.self).uppercased()
            return word == "UTC" || word == "GMT" ? 0 : nil
        }
        let sign = bytes[start]
        guard sign == UInt8(ascii: "+") || sign == UInt8(ascii: "-") else { return nil }
        var digits: [Int] = []
        for position in start + 1 ..< end {
            let byte = bytes[position]
            if isDigit(byte) { digits.append(Int(byte &- 0x30)) }
            else if byte == UInt8(ascii: ":"), digits.count == 2 { continue }
            else { return nil }
        }
        guard digits.count == 4 else { return nil }
        let hours = digits[0] * 10 + digits[1]
        let minutes = digits[2] * 10 + digits[3]
        guard hours <= 14, minutes < 60 else { return nil }
        let magnitude = hours * 3_600 + minutes * 60
        return sign == UInt8(ascii: "-") ? -magnitude : magnitude
    }

    /// Days from 1970-01-01 to a proleptic Gregorian date (Howard Hinnant's `days_from_civil`).
    private static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let shiftedYear = month <= 2 ? year - 1 : year
        let era = (shiftedYear >= 0 ? shiftedYear : shiftedYear - 399) / 400
        let yearOfEra = shiftedYear - era * 400
        let dayOfYear = (153 * (month > 2 ? month - 3 : month + 9) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    private static func daysInMonth(_ month: Int, year: Int) -> Int {
        switch month {
        case 2: return (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 ? 29 : 28
        case 4, 6, 9, 11: return 30
        default: return 31
        }
    }

    private static func isDigit(_ byte: UInt8) -> Bool { byte >= 0x30 && byte <= 0x39 }
    private static func isSpace(_ byte: UInt8) -> Bool { byte == 0x20 || byte == 0x09 }
}
