import XCTest
@testable import Delta

final class UpdaterTests: XCTestCase {
    func testVersionComparison() {
        XCTAssertTrue(AppVersion.isNewer("0.3.1", than: "0.3.0"))
        XCTAssertTrue(AppVersion.isNewer("0.10.0", than: "0.9.9"))
        XCTAssertTrue(AppVersion.isNewer("v1.0.0", than: "0.9"))
        XCTAssertTrue(AppVersion.isNewer("1.0.1", than: "1.0"))
        XCTAssertFalse(AppVersion.isNewer("0.3.0", than: "0.3.0"))
        XCTAssertFalse(AppVersion.isNewer("1.0", than: "1.0.0"))
        XCTAssertFalse(AppVersion.isNewer("0.2.9", than: "0.3.0"))
        XCTAssertFalse(AppVersion.isNewer("nightly", than: "0.3.0"))
        XCTAssertFalse(AppVersion.isNewer("0.4.0-beta", than: "0.3.0"))
    }

    func testParsesLatestReleaseJSON() {
        let json = """
        {"tag_name":"v0.4.0","draft":false,"prerelease":false,
         "html_url":"https://github.com/o/r/releases/tag/v0.4.0",
         "assets":[{"name":"Notes.txt","browser_download_url":"https://example.com/Notes.txt"},
                   {"name":"Delta-0.4.0.dmg","browser_download_url":"https://example.com/Delta-0.4.0.dmg",
                    "digest":"sha256:ABC123"}]}
        """
        let release = ReleaseInfo.parse(Data(json.utf8))
        XCTAssertEqual(release?.version, "0.4.0")
        XCTAssertEqual(release?.dmgURL.lastPathComponent, "Delta-0.4.0.dmg")
        XCTAssertEqual(release?.sha256, "ABC123")
    }

    func testIgnoresDraftsPrereleasesAndReleasesWithoutADMG() {
        XCTAssertNil(ReleaseInfo.parse(Data(#"{"tag_name":"v1.0.0","draft":true,"assets":[]}"#.utf8)))
        XCTAssertNil(ReleaseInfo.parse(Data(#"{"tag_name":"v1.0.0","prerelease":true,"assets":[]}"#.utf8)))
        XCTAssertNil(ReleaseInfo.parse(Data(#"{"tag_name":"v1.0.0","assets":[]}"#.utf8)))
        XCTAssertNil(ReleaseInfo.parse(Data("not json".utf8)))
    }

    /// Runs the real installer script against throwaway folders: the new app replaces the old one,
    /// and the staging folder is cleaned up.
    func testInstallerScriptReplacesTheApp() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("delta-updater-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let dest = root.appendingPathComponent("Applications/Delta.app")
        let staged = root.appendingPathComponent("staging/Delta.app")
        for (dir, text) in [(dest, "old"), (staged, "new")] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try text.write(to: dir.appendingPathComponent("marker"), atomically: true, encoding: .utf8)
        }
        let script = root.appendingPathComponent("install.sh")
        try Updater.installerScript.write(to: script, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        // A pid that doesn't exist, so the script doesn't wait.
        process.arguments = [script.path, "99999999", staged.path, dest.path, "0"]
        try process.run()
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(try String(contentsOf: dest.appendingPathComponent("marker"), encoding: .utf8), "new")
        XCTAssertFalse(fm.fileExists(atPath: dest.path + ".updating"))
        XCTAssertFalse(fm.fileExists(atPath: staged.deletingLastPathComponent().path))
    }
}
