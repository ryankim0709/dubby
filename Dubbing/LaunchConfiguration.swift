import Foundation
import os
import UIKit

/// Launch arguments for UI tests and QA runs. They are read only in DEBUG builds and builds that define
/// DUBIT_QA; any other build ignores them.
nonisolated struct LaunchConfiguration: Equatable, Sendable {
    /// `-DUBIT_UI_TEST 1`: start from a clean state with animations off.
    let isUITest: Bool
    /// `-DUBIT_DEMO_SCENE <sceneID>`: the scene listed first.
    let demoSceneID: String?
    /// `-DUBIT_EXPORT_STEP_DELAY_MS <n>`: a pause before each export phase, so cancelling and backgrounding can be exercised.
    let exportStepDelayMilliseconds: Int?

    static let inactive = LaunchConfiguration(arguments: [])

    init(arguments: [String]) {
        func value(of key: String) -> String? {
            guard let index = arguments.firstIndex(of: key), arguments.indices.contains(index + 1) else { return nil }
            return arguments[index + 1]
        }
        isUITest = value(of: "-DUBIT_UI_TEST") == "1"
        demoSceneID = value(of: "-DUBIT_DEMO_SCENE")
        exportStepDelayMilliseconds = value(of: "-DUBIT_EXPORT_STEP_DELAY_MS").flatMap { Int($0) }.flatMap { $0 > 0 ? $0 : nil }
    }

    static var current: LaunchConfiguration {
        #if DEBUG || DUBIT_QA
        LaunchConfiguration(arguments: ProcessInfo.processInfo.arguments)
        #else
        .inactive
        #endif
    }

    /// Lists the demo scene first, leaving the rest in their order.
    func ordering(_ clips: [LibraryClip]) -> [LibraryClip] {
        guard let demoSceneID, let demo = clips.first(where: { $0.sceneID == demoSceneID }) else { return clips }
        return [demo] + clips.filter { $0 != demo }
    }
}

extension LibraryClip {
    /// The clip's file name without its extension, which is how QA runs name a scene.
    nonisolated var sceneID: String { url.deletingPathExtension().lastPathComponent }
}

/// Deletes what a previous run left behind, for a UI test that must start clean.
nonisolated enum CleanState {
    private static let logger = Logger(subsystem: "com.ryankim.Dubbing", category: "cleanState")

    /// The folder every dub's working files live under (see `ImportedClip.init(clip:)`).
    static var workingFolder: URL {
        FileManager.default.temporaryDirectory.appending(path: "DubProjects", directoryHint: .isDirectory)
    }

    static func wipe(folders: [URL]) {
        for folder in folders where FileManager.default.fileExists(atPath: folder.path(percentEncoded: false)) {
            do {
                try FileManager.default.removeItem(at: folder)
            } catch {
                logger.warning("Couldn't remove \(folder.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

extension LaunchConfiguration {
    /// Applies a UI test's clean state before the first screen loads. Never touches system permissions.
    @MainActor
    func prepareProcess() {
        guard isUITest else { return }
        CleanState.wipe(folders: [DubLibrary.defaultFolder, CleanState.workingFolder])
        if let domain = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: domain)
        }
        UIView.setAnimationsEnabled(false)
    }
}
