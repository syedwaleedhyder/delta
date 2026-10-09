import AppKit
import CryptoKit
import Foundation

/// Compares dotted version strings such as "0.10.1" or "v1.2".
enum AppVersion {
    static func parse(_ text: String) -> [Int]? {
        let trimmed = text.hasPrefix("v") ? String(text.dropFirst()) : text
        let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false).compactMap { Int($0) }
        return parts.isEmpty || parts.count != trimmed.split(separator: ".", omittingEmptySubsequences: false).count
            ? nil : parts
    }

    static func isNewer(_ candidate: String, than current: String) -> Bool {
        guard var a = parse(candidate), var b = parse(current) else { return false }
        let length = max(a.count, b.count)
        a += [Int](repeating: 0, count: length - a.count)
        b += [Int](repeating: 0, count: length - b.count)
        return b.lexicographicallyPrecedes(a)
    }
}

/// The newest published GitHub release and the `.dmg` attached to it.
struct ReleaseInfo: Equatable, Sendable {
    var version: String
    var dmgURL: URL
    var sha256: String?
    var pageURL: URL?

    static func parse(_ data: Data) -> ReleaseInfo? {
        struct Payload: Decodable {
            struct Asset: Decodable {
                let name: String
                let browser_download_url: URL
                let digest: String?
            }
            let tag_name: String
            let draft: Bool?
            let prerelease: Bool?
            let html_url: URL?
            let assets: [Asset]
        }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.draft != true, payload.prerelease != true,
              AppVersion.parse(payload.tag_name) != nil,
              let asset = payload.assets.first(where: { $0.name.hasSuffix(".dmg") })
        else { return nil }
        let version = payload.tag_name.hasPrefix("v") ? String(payload.tag_name.dropFirst()) : payload.tag_name
        let checksum = asset.digest.flatMap { $0.hasPrefix("sha256:") ? String($0.dropFirst(7)) : nil }
        return ReleaseInfo(version: version, dmgURL: asset.browser_download_url,
                           sha256: checksum, pageURL: payload.html_url)
    }
}

enum UpdateError: LocalizedError {
    case noRelease, download, checksum, invalidApp(String), command(String, String)

    var errorDescription: String? {
        switch self {
        case .noRelease: "Couldn't read the latest release from GitHub."
        case .download: "The update couldn't be downloaded."
        case .checksum: "The downloaded update didn't match its checksum, so it was discarded."
        case let .invalidApp(reason): "The downloaded update isn't valid (\(reason))."
        case let .command(tool, output): "\(tool) failed: \(output)"
        }
    }
}

/// Checks GitHub Releases for a newer version while the app is running, downloads it in the background
/// and installs it when Delta quits (or right away on "Restart to Update").
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    enum State: Equatable {
        case idle, checking, downloading(String), ready(ReleaseInfo)
    }

    nonisolated private static let latestReleaseURL = URL(string: "https://api.github.com/repos/syedwaleedhyder/delta/releases/latest")!
    private static let checkInterval: Duration = .seconds(6 * 3600)
    private static let automaticChecksKey = "automaticUpdateChecks"

    @Published private(set) var state: State = .idle
    @Published var automaticChecks: Bool {
        didSet { UserDefaults.standard.set(automaticChecks, forKey: Self.automaticChecksKey) }
    }

    private var stagedApp: URL?
    private var installerLaunched = false
    private var loop: Task<Void, Never>?

    var isBusy: Bool {
        switch state {
        case .checking, .downloading: true
        case .idle, .ready: false
        }
    }

    private init() {
        automaticChecks = UserDefaults.standard.object(forKey: Self.automaticChecksKey) as? Bool ?? true
    }

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// Only an app that lives in a writable, permanent location can replace itself. A copy run from the
    /// disk image, a quarantined (translocated) copy or a development build can't.
    static var canSelfUpdate: Bool {
        let url = Bundle.main.bundleURL
        let path = url.path
        guard !path.contains("/AppTranslocation/"), !path.hasPrefix("/Volumes/"), !path.contains("/DerivedData/")
        else { return false }
        return FileManager.default.isWritableFile(atPath: url.deletingLastPathComponent().path)
    }

    // MARK: - Checking

    /// Checks shortly after launch, then every few hours for as long as the app stays open.
    func startAutomaticChecks() {
        guard loop == nil, ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        loop = Task {
            try? await Task.sleep(for: .seconds(5))
            while !Task.isCancelled {
                if automaticChecks { await check(userInitiated: false) }
                try? await Task.sleep(for: Self.checkInterval)
            }
        }
    }

    func checkNow() {
        Task { await check(userInitiated: true) }
    }

    private func check(userInitiated: Bool) async {
        guard !isBusy else { return }
        if case let .ready(release) = state {
            if userInitiated { offerRestart(release) }
            return
        }

        state = .checking
        do {
            let release = try await Self.latestRelease()
            guard AppVersion.isNewer(release.version, than: Self.currentVersion) else {
                state = .idle
                if userInitiated { alert("Delta is up to date", "You have the latest version (\(Self.currentVersion)).") }
                return
            }
            guard Self.canSelfUpdate else {
                state = .idle
                if userInitiated { offerManualDownload(release) }
                return
            }
            state = .downloading(release.version)
            stagedApp = try await Self.stage(release)
            state = .ready(release)
            if userInitiated { offerRestart(release) }
        } catch {
            state = .idle
            if userInitiated { alert("Couldn't check for updates", error.localizedDescription) }
        }
    }

    // MARK: - Installing

    func installAndRestart() {
        guard launchInstaller(relaunch: true) else { return }
        NSApp.terminate(nil)
    }

    /// Called when the app quits: an update that was already downloaded replaces this copy.
    func installPendingUpdateIfAny() {
        if case .ready = state { _ = launchInstaller(relaunch: false) }
    }

    /// Starts a small shell script that waits for this process to exit, swaps the app bundle and
    /// optionally reopens it.
    private func launchInstaller(relaunch: Bool) -> Bool {
        guard !installerLaunched, let staged = stagedApp else { return false }
        let script = staged.deletingLastPathComponent().appendingPathComponent("install.sh")
        do {
            try Self.installerScript.write(to: script, atomically: true, encoding: .utf8)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [script.path, String(ProcessInfo.processInfo.processIdentifier),
                                 staged.path, Bundle.main.bundleURL.path, relaunch ? "1" : "0"]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            installerLaunched = true
            return true
        } catch {
            alert("Couldn't install the update", error.localizedDescription)
            return false
        }
    }

    /// Arguments: the running app's pid, the new app, the app to replace, and whether to reopen it.
    nonisolated static let installerScript = """
        #!/bin/bash
        PID="$1"; NEW="$2"; DEST="$3"; RELAUNCH="$4"
        while kill -0 "$PID" 2>/dev/null; do sleep 0.2; done
        OLD="$DEST.updating"
        rm -rf "$OLD"
        if mv "$DEST" "$OLD"; then
          if ditto "$NEW" "$DEST"; then
            xattr -dr com.apple.quarantine "$DEST" 2>/dev/null
            rm -rf "$OLD" "$(dirname "$NEW")"
          else
            rm -rf "$DEST"
            mv "$OLD" "$DEST"
          fi
        fi
        [ "$RELAUNCH" = "1" ] && open "$DEST"
        exit 0

        """

    // MARK: - Dialogs

    private func offerRestart(_ release: ReleaseInfo) {
        let alert = NSAlert()
        alert.messageText = "Delta \(release.version) is ready to install"
        alert.informativeText = "Restart now to update. Otherwise it installs the next time you quit Delta."
        alert.addButton(withTitle: "Restart Now")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn { installAndRestart() }
    }

    private func offerManualDownload(_ release: ReleaseInfo) {
        let alert = NSAlert()
        alert.messageText = "Delta \(release.version) is available"
        alert.informativeText = "This copy of Delta can't update itself because of where it is. "
            + "Move it to your Applications folder, or download the new version."
        alert.addButton(withTitle: "Open Download Page")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn, let page = release.pageURL {
            NSWorkspace.shared.open(page)
        }
    }

    private func alert(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }

    // MARK: - Network and disk (off the main actor)

    nonisolated static func latestRelease() async throws -> ReleaseInfo {
        var request = URLRequest(url: latestReleaseURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Delta-Updater", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, let release = ReleaseInfo.parse(data)
        else { throw UpdateError.noRelease }
        return release
    }

    /// Downloads the `.dmg`, checks it, and copies the app out of it into the caches folder.
    nonisolated static func stage(_ release: ReleaseInfo) async throws -> URL {
        let fm = FileManager.default
        let root = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Delta/Updates/\(release.version)")
        try? fm.removeItem(at: root)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        let (temporary, response) = try await URLSession.shared.download(from: release.dmgURL)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError.download }
        let dmg = root.appendingPathComponent("Delta.dmg")
        try fm.moveItem(at: temporary, to: dmg)

        if let expected = release.sha256 {
            let digest = SHA256.hash(data: try Data(contentsOf: dmg, options: .mappedIfSafe))
            guard digest.map({ String(format: "%02x", $0) }).joined() == expected.lowercased()
            else { throw UpdateError.checksum }
        }

        let mount = root.appendingPathComponent("mount")
        let app = root.appendingPathComponent("Delta.app")
        try fm.createDirectory(at: mount, withIntermediateDirectories: true)
        try await run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noverify", "-mountpoint", mount.path, dmg.path])
        do {
            try await run("/usr/bin/ditto", [mount.appendingPathComponent("Delta.app").path, app.path])
        } catch {
            _ = try? await run("/usr/bin/hdiutil", ["detach", mount.path, "-force"])
            throw error
        }
        _ = try? await run("/usr/bin/hdiutil", ["detach", mount.path, "-force"])

        try await run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        let info = Bundle(url: app)?.infoDictionary
        guard info?["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier else {
            throw UpdateError.invalidApp("wrong bundle identifier")
        }
        guard info?["CFBundleShortVersionString"] as? String == release.version else {
            throw UpdateError.invalidApp("version doesn't match the release")
        }
        try? fm.removeItem(at: dmg)
        try? fm.removeItem(at: mount)
        return app
    }

    @discardableResult
    nonisolated static func run(_ tool: String, _ arguments: [String]) async throws -> String {
        try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let output = String(decoding: data, as: UTF8.self)
            guard process.terminationStatus == 0 else { throw UpdateError.command(tool, output) }
            return output
        }.value
    }
}
