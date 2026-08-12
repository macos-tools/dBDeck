import Foundation
import Testing
@testable import dBDeck

@Suite("Application display names")
struct ApplicationDisplayNameResolverTests {
    @Test func usesPreferredLocalizedDisplayName() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("dBDeck-display-name-\(UUID().uuidString)")
        let applicationURL = temporaryRoot.appendingPathComponent("TencentMeeting.app")
        let contentsURL = applicationURL.appendingPathComponent("Contents")
        let localizationURL = contentsURL
            .appendingPathComponent("Resources/zh-Hans.lproj")
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        try FileManager.default.createDirectory(
            at: localizationURL,
            withIntermediateDirectories: true
        )
        try propertyListData([
            "CFBundleDisplayName": "TencentMeeting",
            "CFBundleIdentifier": "com.tencent.meeting",
            "CFBundleName": "腾讯会议",
            "CFBundlePackageType": "APPL"
        ]).write(to: contentsURL.appendingPathComponent("Info.plist"))
        try propertyListData([
            "CFBundleDisplayName": "腾讯会议",
            "CFBundleName": "腾讯会议"
        ]).write(to: localizationURL.appendingPathComponent("InfoPlist.strings"))

        #expect(
            ApplicationDisplayNameResolver.name(
                for: applicationURL,
                preferredLanguages: ["zh-Hans-CN"]
            ) == "腾讯会议"
        )
    }

    @Test func fallsBackToApplicationFilename() {
        let applicationURL = URL(fileURLWithPath: "/missing/Example App.app")
        #expect(ApplicationDisplayNameResolver.name(for: applicationURL) == "Example App")
    }

    @Test func resolvesOutermostContainingApplication() {
        let nestedHelper = URL(
            fileURLWithPath: "/Applications/Browser.app/Contents/Frameworks/Helper.app"
        )
        #expect(
            ApplicationBundleResolver.outermostApplicationURL(containing: nestedHelper)?.path
                == "/Applications/Browser.app"
        )
    }

    private func propertyListData(_ propertyList: [String: String]) throws -> Data {
        try PropertyListSerialization.data(
            fromPropertyList: propertyList,
            format: .xml,
            options: 0
        )
    }
}
