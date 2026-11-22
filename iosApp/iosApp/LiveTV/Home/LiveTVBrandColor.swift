import CoreGraphics
import Nuke
import SwiftUI

/// The surface color behind a channel logo: the logo's strongest hue, else a fixed palette
/// color picked from the channel name.
///
/// Sampling decodes the shared 64 px palette thumbnail, redraws it at 24 px off the main actor,
/// and keeps at most `capacity` results for the session. Results are never persisted: logo URLs
/// can carry provider tokens.
enum LiveTVBrandColor {
    struct RGB: Equatable, Sendable {
        var r: Double
        var g: Double
        var b: Double

        var color: Color { Color(red: r, green: g, blue: b) }
    }

    static let capacity = 256
    private static let sampleEdge = 24

    /// Rich, dark-enough colors for white logos and text, with no purples.
    /// Used only when a logo has no usable hue; sampled logo colors are kept.
    static let palette: [RGB] = [
        RGB(r: 0.004, g: 0.051, b: 0.624), // deep blue (C3 #010D9F)
        RGB(r: 0.043, g: 0.122, b: 0.420), // navy
        RGB(r: 0.114, g: 0.306, b: 0.847), // blue
        RGB(r: 0.059, g: 0.463, b: 0.431), // teal
        RGB(r: 0.725, g: 0.110, b: 0.110), // crimson
        RGB(r: 0.604, g: 0.204, b: 0.071), // ember
        RGB(r: 0.639, g: 0.039, b: 0.204), // rose (C3 pink-red, darkened)
        RGB(r: 0.200, g: 0.255, b: 0.333), // slate
    ]

    /// Stable across launches (unlike `hashValue`), so a channel keeps its color.
    static func fallback(for name: String) -> RGB {
        var hash: UInt32 = 2_166_136_261
        for byte in name.lowercased().utf8 {
            hash = (hash ^ UInt32(byte)) &* 16_777_619
        }
        return palette[Int(hash % UInt32(palette.count))]
    }

    /// The strongest hue among opaque, colored pixels of straight-alpha RGBA bytes. Transparent,
    /// near-black, near-white and gray pixels are ignored, so a white wordmark on a clear
    /// background gives nil rather than white. The result is held to a range white text reads on.
    static func sample(rgba bytes: [UInt8]) -> RGB? {
        let bucketCount = 12
        var weights = [Double](repeating: 0, count: bucketCount)
        var sums = [RGB](repeating: RGB(r: 0, g: 0, b: 0), count: bucketCount)
        var opaque = 0
        for index in stride(from: 0, to: bytes.count - 3, by: 4) {
            let alpha = Double(bytes[index + 3]) / 255
            guard alpha >= 0.6 else { continue }
            opaque += 1
            let r = Double(bytes[index]) / 255, g = Double(bytes[index + 1]) / 255, b = Double(bytes[index + 2]) / 255
            let maximum = max(r, g, b), minimum = min(r, g, b)
            let saturation = maximum == 0 ? 0 : (maximum - minimum) / maximum
            guard maximum >= 0.15, saturation >= 0.25 else { continue }
            let hue = hueDegrees(r: r, g: g, b: b, maximum: maximum, minimum: minimum)
            let bucket = min(bucketCount - 1, Int(hue / 360 * Double(bucketCount)))
            let weight = (saturation * maximum) * (saturation * maximum)
            weights[bucket] += weight
            sums[bucket].r += r * weight
            sums[bucket].g += g * weight
            sums[bucket].b += b * weight
        }
        guard opaque > 0, let best = weights.indices.max(by: { weights[$0] < weights[$1] }),
              weights[best] > 0.02 * Double(opaque) else { return nil }
        let weight = weights[best]
        return normalized(RGB(r: sums[best].r / weight, g: sums[best].g / weight, b: sums[best].b / weight))
    }

    /// Caps brightness and saturation so the hue reads as a surface, not a highlight.
    static func normalized(_ rgb: RGB) -> RGB {
        let maximum = max(rgb.r, rgb.g, rgb.b)
        guard maximum > 0 else { return rgb }
        let scale = min(1, 0.78 / maximum)
        return RGB(r: rgb.r * scale, g: rgb.g * scale, b: rgb.b * scale)
    }

    private static func hueDegrees(r: Double, g: Double, b: Double, maximum: Double, minimum: Double) -> Double {
        let delta = maximum - minimum
        guard delta > 0 else { return 0 }
        var hue: Double
        if maximum == r {
            hue = (g - b) / delta
        } else if maximum == g {
            hue = 2 + (b - r) / delta
        } else {
            hue = 4 + (r - g) / delta
        }
        hue *= 60
        return hue < 0 ? hue + 360 : hue
    }

    /// What one logo sample tells a surface: its brand hue, and whether it is a dark mark on a
    /// transparent background that disappears on a dark card without a light plate.
    struct LogoTraits: Equatable, Sendable {
        var color: RGB?
        var hasDarkMark: Bool

        static let unknown = LogoTraits(color: nil, hasDarkMark: false)
    }

    static func traits(rgba bytes: [UInt8]) -> LogoTraits {
        LogoTraits(color: sample(rgba: bytes), hasDarkMark: hasDarkMark(rgba: bytes))
    }

    /// True for a cut-out logo (a real share of transparent pixels) whose visible pixels are dark.
    /// A fully opaque logo brings its own background and never needs a plate.
    static func hasDarkMark(rgba bytes: [UInt8]) -> Bool {
        var opaque = 0, clear = 0
        var luminance = 0.0
        for index in stride(from: 0, to: bytes.count - 3, by: 4) {
            let alpha = bytes[index + 3]
            if alpha < 26 { clear += 1; continue }
            guard alpha >= 153 else { continue }
            opaque += 1
            luminance += (0.2126 * Double(bytes[index]) + 0.7152 * Double(bytes[index + 1])
                          + 0.0722 * Double(bytes[index + 2])) / 255
        }
        let total = bytes.count / 4
        guard opaque > 0, total > 0, Double(clear) / Double(total) >= 0.15 else { return false }
        return luminance / Double(opaque) < 0.28
    }

    // MARK: Session cache

    /// A logo that failed to load is stored as `.unknown`, so it is not retried this session.
    @MainActor private static var cache: [String: LogoTraits] = [:]
    @MainActor private static var order: [String] = []
    @MainActor private static var inFlight: [String: Task<LogoTraits, Never>] = [:]

    /// nil when this logo has not been sampled yet. A channel without a logo has nothing to sample.
    @MainActor static func cachedTraits(for url: URL?) -> LogoTraits? {
        guard let url else { return .unknown }
        return cache[url.absoluteString]
    }

    /// Samples each logo once per session; concurrent callers share the same work.
    @MainActor static func traits(for url: URL) async -> LogoTraits {
        let key = url.absoluteString
        if let hit = cache[key] { return hit }
        if let running = inFlight[key] { return await running.value }
        let task = Task<LogoTraits, Never> {
            guard let image = try? await ImagePipeline.shared.image(for: PosterImageCache.paletteSampleRequest(for: url)) else {
                return .unknown
            }
            return await Task.detached(priority: .utility) { LiveTVBrandColor.sample(image: image) }.value
        }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil
        store(result, for: key)
        return result
    }

    @MainActor private static func store(_ value: LogoTraits, for key: String) {
        if cache.updateValue(value, forKey: key) == nil { order.append(key) }
        while order.count > capacity { cache[order.removeFirst()] = nil }
    }

    private static func sample(image: PlatformImage) -> LogoTraits {
        #if canImport(UIKit)
        guard let cgImage = image.cgImage else { return .unknown }
        #elseif canImport(AppKit)
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return .unknown }
        #endif
        let edge = sampleEdge
        var bitmap = [UInt8](repeating: 0, count: edge * edge * 4)
        let drawn = bitmap.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: edge, height: edge, bitsPerComponent: 8,
                                          bytesPerRow: edge * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: edge, height: edge))
            return true
        }
        guard drawn else { return .unknown }
        // Undo premultiplication so a half-transparent edge keeps its hue.
        for index in stride(from: 0, to: bitmap.count, by: 4) where bitmap[index + 3] > 0 && bitmap[index + 3] < 255 {
            let alpha = Double(bitmap[index + 3]) / 255
            for channel in 0..<3 {
                bitmap[index + channel] = UInt8(min(255, (Double(bitmap[index + channel]) / alpha).rounded()))
            }
        }
        return traits(rgba: bitmap)
    }
}

/// Loads a logo's traits once and keeps them in view state. Starts from the session cache, so a
/// logo sampled earlier paints correctly on its first frame; later results swap in without animation.
private struct LiveTVLogoTraitsReader<Content: View>: View {
    let logoURL: URL?
    let content: (LiveTVBrandColor.LogoTraits?) -> Content
    @State private var traits: LiveTVBrandColor.LogoTraits?

    init(logoURL: URL?, @ViewBuilder content: @escaping (LiveTVBrandColor.LogoTraits?) -> Content) {
        self.logoURL = logoURL
        self.content = content
        _traits = State(initialValue: LiveTVBrandColor.cachedTraits(for: logoURL))
    }

    var body: some View {
        content(traits)
            .task(id: logoURL) {
                guard traits == nil, let logoURL else { return }
                traits = await LiveTVBrandColor.traits(for: logoURL)
            }
    }
}

/// A channel's brand gradient: the logo's hue, else a stable palette color for the channel name.
struct LiveTVBrandSurface: View {
    let channel: LiveTVChannel
    var angle: UnitPoint = .topTrailing

    var body: some View {
        LiveTVLogoTraitsReader(logoURL: channel.logoURL) { traits in
            let base = (traits?.color ?? LiveTVBrandColor.fallback(for: channel.name)).color
            LinearGradient(colors: [base, base.mix(with: .black, by: 0.55), Color(hex: "#08080B")],
                           startPoint: angle, endPoint: UnitPoint(x: 1 - angle.x, y: 1 - angle.y))
        }
    }
}

/// A channel logo for a colored card. A dark cut-out logo gets a light plate so it stays legible;
/// white and opaque logos are drawn as they are. Decorative, so VoiceOver skips it.
struct LiveTVLogoMark: View {
    let channel: LiveTVChannel
    let size: CGSize

    var body: some View {
        LiveTVLogoTraitsReader(logoURL: channel.logoURL) { traits in
            let plated = traits?.hasDarkMark == true
            LiveTVChannelLogo(channel: channel,
                              size: plated ? CGSize(width: size.width - 16, height: size.height - 12) : size,
                              placeholderStyle: .clear)
                .padding(.horizontal, plated ? 8 : 0)
                .padding(.vertical, plated ? 6 : 0)
                .background {
                    if plated {
                        RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.9))
                    }
                }
        }
        .accessibilityHidden(true)
    }
}
