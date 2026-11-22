import XCTest
@testable import Silo

/// Proves Kyro Labs and stable Kyro cannot share local data or routing, and that stable's names
/// are exactly Build 110's.
///
/// Foundation, XCTest and the shared-storage files only, so it also runs on macOS through the
/// standalone swiftc harness (no Simulator). The configuration checks read the repository's own
/// project files, so a later edit that points Labs back at a stable name fails here.
final class KyroLabsIdentityTests: XCTestCase {
    private let stable = KyroAppIdentity.stable
    private let labs = KyroAppIdentity.labs

    // MARK: Stable is preserved

    /// Golden values copied from the Build 110 source (`cc9e29e1`: `SharedStorage.swift`,
    /// `Signing/Silo.xcconfig`, `Info.plist`). Stable Kyro's update path and its stored sessions
    /// depend on every one of them, so a change here is a stable-app break, not a refactor.
    func testStableIdentityIsBuild110Exactly() {
        XCTAssertEqual(stable.variant, .stable)
        XCTAssertEqual(stable.displayName, "Kyro")
        XCTAssertEqual(stable.bundleID, "com.cubbiestream.kyro")
        XCTAssertEqual(stable.appGroup, "group.com.cubbiestream.kyro")
        XCTAssertEqual(stable.keychainGroupSuffix, "com.cubbiestream.kyro.shared")
        XCTAssertEqual(stable.keychainService, "com.cubbiestream.kyro")
        XCTAssertEqual(stable.keychainAccountPrefix, "com.cubbiestream.kyro.")
        XCTAssertEqual(stable.liveTVKeychainService, "com.cubbiestream.kyro.livetv")
        XCTAssertEqual(stable.epgKeyKeychainService, "com.cubbiestream.kyro.livetv.epg-source-key")
        XCTAssertEqual(stable.urlScheme, "kyro")
        XCTAssertEqual(stable.legacyURLSchemes, ["silo"])
        XCTAssertEqual(stable.legacyKeychainService, "com.continuum.app")
        XCTAssertEqual(stable.legacyKeychainAccountPrefix, "com.continuum.")
    }

    func testMissingOrUnknownVariantMeansStable() {
        XCTAssertEqual(KyroAppIdentity.identity(forVariant: nil), stable)
        XCTAssertEqual(KyroAppIdentity.identity(forVariant: ""), stable)
        XCTAssertEqual(KyroAppIdentity.identity(forVariant: "$(KYRO_APP_VARIANT)"), stable)
        XCTAssertEqual(KyroAppIdentity.identity(forVariant: "beta"), stable)
        XCTAssertEqual(KyroAppIdentity.identity(forVariant: "labs"), labs)
        XCTAssertEqual(KyroAppIdentity.identity(forVariant: " LABS\n"), labs)
    }

    // MARK: Bundle ID, keychain, group and scheme isolation

    func testLabsHasTheRequestedBundleIdentity() {
        XCTAssertEqual(labs.variant, .labs)
        XCTAssertEqual(labs.displayName, "Kyro Labs")
        XCTAssertEqual(labs.bundleID, "com.cubbiestream.kyro.labs")
    }

    func testNoIsolatedNameIsSharedBetweenStableAndLabs() {
        for (name, stableValue) in stable.isolatedNames {
            XCTAssertNotEqual(stableValue, labs.isolatedNames[name], "\(name) is shared by both apps")
        }
        XCTAssertEqual(Set(stable.isolatedNames.keys), Set(labs.isolatedNames.keys))
    }

    /// The OS compares keychain service and group names exactly, so only the two names Kyro
    /// itself matches by shape matter: account names are found with `hasPrefix`, and the access
    /// group with `hasSuffix`. Neither app's pattern may match the other's.
    func testNeitherAppsPrefixOrSuffixPatternMatchesTheOther() {
        XCTAssertFalse(labs.keychainAccountPrefix.hasPrefix(stable.keychainAccountPrefix))
        XCTAssertFalse(stable.keychainAccountPrefix.hasPrefix(labs.keychainAccountPrefix))
        XCTAssertFalse(labs.keychainGroupSuffix.hasSuffix("." + stable.keychainGroupSuffix))
        XCTAssertFalse(stable.keychainGroupSuffix.hasSuffix("." + labs.keychainGroupSuffix))
    }

    /// Whichever app this is, its access-group policy refuses the other app's group.
    func testAccessGroupPolicyRejectsTheOtherAppsGroup() {
        let other = KyroAppIdentity.current.isLabs ? stable : labs
        for allowsUnprefixed in [true, false] {
            XCTAssertNil(SideloadKeychainFallbackPolicy.resolvedAccessGroup(
                from: other.keychainGroupSuffix, allowsUnprefixedSideloadGroup: allowsUnprefixed))
            XCTAssertNil(SideloadKeychainFallbackPolicy.resolvedAccessGroup(
                from: "TEAMID.\(other.keychainGroupSuffix)", allowsUnprefixedSideloadGroup: allowsUnprefixed))
        }
        XCTAssertNil(SideloadKeychainFallbackPolicy.teamPrefix(from: "TEAMID.\(other.keychainGroupSuffix)"))
    }

    func testLabsNeverMigratesOrAcceptsStableLegacyState() {
        XCTAssertNil(labs.legacyKeychainService)
        XCTAssertNil(labs.legacyKeychainAccountPrefix)
        XCTAssertEqual(labs.legacyURLSchemes, [])
        XCTAssertFalse(labs.legacyURLSchemes.contains(stable.urlScheme))
    }

    /// `SharedStorage` and `SiloURLScheme` are the production readers of these names.
    func testProductionConstantsFollowTheBuildsIdentity() {
        let current = KyroAppIdentity.current
        XCTAssertEqual(SharedStorage.appGroup, current.appGroup)
        XCTAssertEqual(SharedStorage.keychainService, current.keychainService)
        XCTAssertEqual(SharedStorage.keychainAccountPrefix, current.keychainAccountPrefix)
        XCTAssertEqual(SharedStorage.legacyKeychainService, current.legacyKeychainService)
        XCTAssertEqual(SiloURLScheme.current, current.urlScheme)
        XCTAssertEqual(SharedStorage.accessTokenAccount(for: "s"), current.keychainAccountPrefix + "s.accessToken")
        XCTAssertEqual(SharedStorage.mirroredAccessTokenAccount, current.keychainAccountPrefix + "topshelf.accessToken")
    }

    func testLabsLegacyAccountMappingIsIdentityNotARename() {
        guard KyroAppIdentity.current.isLabs else { return }
        let account = SharedStorage.refreshTokenAccount(for: "server")
        XCTAssertEqual(SharedStorage.legacyKeychainAccount(for: account), account)
        XCTAssertNil(SharedStorage.legacyKeychainService)
    }

    func testLabsOnlyOpensItsOwnLinks() throws {
        guard KyroAppIdentity.current.isLabs else { return }
        XCTAssertTrue(SiloURLScheme.isAppURL(try XCTUnwrap(URL(string: "kyrolabs://search?q=x"))))
        XCTAssertFalse(SiloURLScheme.isAppURL(try XCTUnwrap(URL(string: "kyro://search?q=x"))))
        XCTAssertFalse(SiloURLScheme.isAppURL(try XCTUnwrap(URL(string: "silo://search?q=x"))))
    }

    // MARK: Build configuration (reads the repository's own files)

    private static let iosAppDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()

    private func text(_ relative: String) throws -> String {
        try String(contentsOf: Self.iosAppDir.appendingPathComponent(relative), encoding: .utf8)
    }

    private func plist(_ relative: String) throws -> [String: Any] {
        let data = try Data(contentsOf: Self.iosAppDir.appendingPathComponent(relative))
        return try XCTUnwrap(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    private func settings(_ relative: String) throws -> [String: String] {
        var result: [String: String] = [:]
        for raw in try text(relative).split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("//"), !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { continue }
            result[line[..<eq].trimmingCharacters(in: .whitespaces)] =
                line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        }
        return result
    }

    func testVariantConfigurationMatchesTheLabsIdentity() throws {
        let v = try settings("Signing/KyroVariant.xcconfig")
        XCTAssertEqual(v["KYRO_APP_VARIANT"], "labs")
        XCTAssertEqual(v["KYRO_DISPLAY_NAME"], labs.displayName)
        XCTAssertEqual(v["KYRO_APP_GROUP"], labs.appGroup)
        XCTAssertEqual(v["KYRO_KEYCHAIN_GROUP"], labs.keychainGroupSuffix)
        XCTAssertEqual(v["KYRO_URL_SCHEME"], labs.urlScheme)
        XCTAssertEqual(v["KYRO_URL_NAME"], labs.bundleID)
        XCTAssertEqual(v["SILO_IOS_BUNDLE_ID"], labs.bundleID)
        XCTAssertEqual(v["SILO_NOTIFICATION_SERVICE_BUNDLE_ID"], labs.bundleID + ".NotificationService")
        XCTAssertEqual(v["SILO_DOWNLOADS_ACTIVITY_BUNDLE_ID"], labs.bundleID + ".DownloadsActivity")
        XCTAssertEqual(v["KYRO_APP_ICON_NAME"], "KyroLabsAppIcon")
        for (key, value) in v where key.hasSuffix("_BUNDLE_ID") {
            XCTAssertTrue(value.hasPrefix(labs.bundleID), "\(key) = \(value) is outside Labs's bundle ID")
        }
    }

    func testEveryIOSTargetIncludesTheVariantAndNoneNamesAStableBundleID() throws {
        for name in ["Silo", "SiloNotificationService", "SiloDownloadsActivity"] {
            let file = "Signing/\(name).xcconfig"
            let body = try text(file)
            XCTAssertTrue(body.contains("#include \"KyroVariant.xcconfig\""), "\(file) must include the variant")
            XCTAssertFalse(body.contains("= \(stable.bundleID)\n"), "\(file) names stable's bundle ID")
            XCTAssertFalse(body.contains(stable.bundleID + ".NotificationService"), file)
            XCTAssertFalse(body.contains(stable.bundleID + ".DownloadsActivity"), file)
        }
        let silo = try settings("Signing/Silo.xcconfig")
        XCTAssertEqual(silo["PRODUCT_BUNDLE_IDENTIFIER"], "$(SILO_IOS_BUNDLE_ID)")
    }

    func testLabsEntitlementsUseOnlyLabsGroupsAndNoPush() throws {
        for file in ["SiloLabs.entitlements", "NotificationService/NotificationService.labs.entitlements"] {
            let e = try plist(file)
            XCTAssertEqual(e["com.apple.security.application-groups"] as? [String], ["$(KYRO_APP_GROUP)"], file)
            XCTAssertEqual(e["keychain-access-groups"] as? [String],
                           ["$(AppIdentifierPrefix)$(KYRO_KEYCHAIN_GROUP)"], file)
            XCTAssertNil(e["aps-environment"], "\(file) must not request push")
        }
        let personal = try plist("SiloLabs.personal.entitlements")
        XCTAssertEqual(personal["keychain-access-groups"] as? [String],
                       ["$(AppIdentifierPrefix)$(KYRO_KEYCHAIN_GROUP)"])
        XCTAssertNil(personal["com.apple.security.application-groups"])
        let selected = try settings("Signing/KyroVariant.xcconfig")
        XCTAssertEqual(selected["SILO_IOS_ENTITLEMENTS"], "SiloLabs.entitlements")
        XCTAssertEqual(selected["SILO_NOTIFICATION_SERVICE_ENTITLEMENTS"],
                       "NotificationService/NotificationService.labs.entitlements")
    }

    func testInfoPlistsTakeTheirIdentityFromTheVariantAndNameNothingStable() throws {
        let app = try plist("iosApp/Info.plist")
        XCTAssertEqual(app["CFBundleDisplayName"] as? String, "$(KYRO_DISPLAY_NAME)")
        XCTAssertEqual(app["CFBundleIconName"] as? String, "$(KYRO_APP_ICON_NAME)")
        XCTAssertEqual(app["KyroAppVariant"] as? String, "$(KYRO_APP_VARIANT)")
        XCTAssertEqual(app["SiloKeychainAccessGroup"] as? String, "$(AppIdentifierPrefix)$(KYRO_KEYCHAIN_GROUP)")
        let urlTypes = try XCTUnwrap(app["CFBundleURLTypes"] as? [[String: Any]])
        XCTAssertEqual(urlTypes.count, 1)
        XCTAssertEqual(urlTypes[0]["CFBundleURLName"] as? String, "$(KYRO_URL_NAME)")
        XCTAssertEqual(urlTypes[0]["CFBundleURLSchemes"] as? [String], ["$(KYRO_URL_SCHEME)"])

        let service = try plist("NotificationService/Info.plist")
        XCTAssertEqual(service["KyroAppVariant"] as? String, "$(KYRO_APP_VARIANT)")
        XCTAssertEqual(service["SiloKeychainAccessGroup"] as? String,
                       "$(AppIdentifierPrefix)$(KYRO_KEYCHAIN_GROUP)")

        for file in ["iosApp/Info.plist", "NotificationService/Info.plist"] {
            let body = try text(file)
            XCTAssertFalse(body.contains(stable.keychainGroupSuffix), "\(file) names stable's keychain group")
            XCTAssertFalse(body.contains("<string>\(stable.urlScheme)</string>"), "\(file) registers stable's scheme")
        }
    }

    func testProjectWiresTheVariantIconAndGivesTheExtensionTheIdentityFile() throws {
        let project = try text("project.yml")
        XCTAssertTrue(project.contains("ASSETCATALOG_COMPILER_APPICON_NAME: $(KYRO_APP_ICON_NAME)"))
        XCTAssertTrue(project.contains("- path: iosApp/Shared/KyroAppIdentity.swift"),
                      "the Notification Service reads SharedStorage and must get the identity file")
    }

    func testLabsIconAssetExistsAndStableIconIsUntouched() throws {
        let brand = "iosApp/Kyro/KyroBrand.xcassets"
        let contents = try Data(contentsOf: Self.iosAppDir
            .appendingPathComponent("\(brand)/KyroLabsAppIcon.appiconset/Contents.json"))
        let labsSet = try XCTUnwrap(try JSONSerialization.jsonObject(with: contents) as? [String: Any])
        let images = try XCTUnwrap(labsSet["images"] as? [[String: Any]])
        XCTAssertEqual(images.first?["filename"] as? String, "Kyro_Labs_AppIcon_1024.png")
        let image = Self.iosAppDir.appendingPathComponent("\(brand)/KyroLabsAppIcon.appiconset/Kyro_Labs_AppIcon_1024.png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: image.path))
        let stableImage = Self.iosAppDir.appendingPathComponent("\(brand)/KyroAppIcon.appiconset/Kyro_C3_AppIcon_1024.png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: stableImage.path))
        let a = try Data(contentsOf: image), b = try Data(contentsOf: stableImage)
        XCTAssertNotEqual(a, b, "Labs must be visually distinct from stable")
    }

    // MARK: No stable name is hard-coded anywhere else

    /// Any new `"group.com.cubbiestream.kyro"`-style literal outside `KyroAppIdentity.swift`
    /// would bypass the isolation (and break it silently after an upstream merge).
    func testStableStorageNamesAreWrittenOnlyInTheIdentityFile() throws {
        let forbidden = [stable.appGroup, stable.keychainGroupSuffix, stable.keychainAccountPrefix,
                         stable.liveTVKeychainService, stable.epgKeyKeychainService,
                         stable.legacyKeychainService ?? "", stable.legacyKeychainAccountPrefix ?? ""]
        // The bundle ID doubles as the Silo server's push topic and the external sign-in callback
        // scheme. Both are server contracts, not storage, and Labs's push is refused (see
        // KyroLabsPushContractTests).
        let bundleIDContracts: Set<String> = ["ApplePushRegistration.swift", "ExternalSignIn.swift"]
        let root = Self.iosAppDir.appendingPathComponent("iosApp")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        var scanned = 0
        for case let url as URL in files where url.pathExtension == "swift" {
            let name = url.lastPathComponent
            if name == "KyroAppIdentity.swift" { continue }
            scanned += 1
            let source = try String(contentsOf: url, encoding: .utf8)
            for literal in forbidden where !literal.isEmpty {
                XCTAssertFalse(source.contains("\"\(literal)\""), "\(name) hard-codes \"\(literal)\"")
            }
            if !bundleIDContracts.contains(name) {
                // Logger subsystems and queue labels name no stored data.
                let storageLines = source.split(whereSeparator: \.isNewline).filter {
                    !$0.contains("subsystem:") && !$0.contains("bundleIdentifier ??")
                        && !$0.contains("DispatchQueue(label:")
                }
                for line in storageLines {
                    XCTAssertFalse(line.contains("\"\(stable.keychainService)\""),
                                   "\(name) hard-codes stable's keychain service: \(line)")
                }
            }
        }
        XCTAssertGreaterThan(scanned, 300, "the scan must actually cover the app sources")
    }
}
