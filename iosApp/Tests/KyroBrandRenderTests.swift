#if os(iOS)
import SwiftUI
import UIKit
import XCTest
@testable import Silo

/// Renders the splash and introduction pages at small, standard and large
/// iPhone sizes for visual review of clipping and placement. Skipped unless
/// `TEST_RUNNER_KYRO_BRAND_RENDER_DIR` is set.
@MainActor
final class KyroBrandRenderTests: XCTestCase {
    private let phones: [(name: String, size: CGSize)] = [
        ("iphone-se", CGSize(width: 375, height: 667)),
        ("iphone-17", CGSize(width: 402, height: 874)),
        ("iphone-17-pro-max", CGSize(width: 440, height: 956)),
    ]

    private func outputDirectory() throws -> URL {
        guard let directory = ProcessInfo.processInfo.environment["KYRO_BRAND_RENDER_DIR"] else {
            throw XCTSkip("Set TEST_RUNNER_KYRO_BRAND_RENDER_DIR to render the Kyro brand screens.")
        }
        return URL(fileURLWithPath: directory)
    }

    func testRenderIntroductionPages() throws {
        let directory = try outputDirectory()
        for phone in phones {
            for page in KyroIntroduction.pages.indices {
                try render(
                    KyroIntroductionView(initialPage: page) {},
                    size: phone.size,
                    to: directory.appendingPathComponent("\(phone.name)-intro-\(page + 1).png")
                )
            }
            try render(
                KyroIntroductionView(initialPage: 0) {}.dynamicTypeSize(.accessibility3),
                size: phone.size,
                to: directory.appendingPathComponent("\(phone.name)-intro-1-largest-text.png")
            )
        }
    }

    func testRenderSplash() throws {
        let directory = try outputDirectory()
        for phone in phones {
            try render(
                KyroCinematicSplashView {},
                size: phone.size,
                to: directory.appendingPathComponent("\(phone.name)-splash.png"),
                settle: 2.0
            )
        }
    }

    /// The shared wordmark at each iOS placement, plus the loading screen.
    /// The header row mimics Home's 44pt icon buttons for scale only.
    func testRenderAppWordmarkPlacements() throws {
        let directory = try outputDirectory()
        let placements = VStack(alignment: .leading, spacing: 28) {
            HStack(spacing: 12) {
                Circle().fill(.white.opacity(0.12)).frame(width: 44, height: 44)
                AppWordmarkView(placement: .compactHeader).frame(height: 44)
                Spacer()
                Circle().fill(.white.opacity(0.12)).frame(width: 44, height: 44)
                Circle().fill(.white.opacity(0.12)).frame(width: 44, height: 44)
            }
            AppWordmarkView(placement: .topBar)
            AppWordmarkView(placement: .loading)
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        try render(placements, size: CGSize(width: 402, height: 420),
                   to: directory.appendingPathComponent("wordmark-placements.png"))
        try render(LoadingView(message: "Loading profiles..."), size: CGSize(width: 402, height: 874),
                   to: directory.appendingPathComponent("loading-view.png"))
    }

    private func render(_ view: some View, size: CGSize, to url: URL, settle: TimeInterval = 1.5) throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        window.overrideUserInterfaceStyle = .dark
        window.rootViewController = UIHostingController(rootView: view)
        window.isHidden = false
        RunLoop.main.run(until: Date().addingTimeInterval(settle))
        let image = UIGraphicsImageRenderer(size: size).image { _ in
            _ = window.drawHierarchy(in: CGRect(origin: .zero, size: size), afterScreenUpdates: true)
        }
        window.isHidden = true
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try XCTUnwrap(image.pngData()).write(to: url)
    }
}
#endif
