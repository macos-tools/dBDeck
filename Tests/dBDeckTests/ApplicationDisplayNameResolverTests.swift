import Foundation

enum ApplicationDisplayNameResolverVerificationFailure: Error {
    case unexpectedName(String)
}

@main
enum ApplicationDisplayNameResolverVerifier {
    static func main() throws {
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

        let name = ApplicationDisplayNameResolver.name(
            for: applicationURL,
            preferredLanguages: ["zh-Hans-CN"]
        )
        guard name == "腾讯会议" else {
            throw ApplicationDisplayNameResolverVerificationFailure.unexpectedName(name)
        }

        print("Localized application display name verification passed")
    }

    private static func propertyListData(_ propertyList: [String: String]) throws -> Data {
        try PropertyListSerialization.data(
            fromPropertyList: propertyList,
            format: .xml,
            options: 0
        )
    }
}
