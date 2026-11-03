import Foundation
import Observation
import Sparkle
import SwiftUI

/// Checks the appcast in the background and keeps a found update waiting for the user,
/// instead of letting Sparkle open its own window on a timer.
@MainActor
@Observable
final class AppUpdater: NSObject {
    /// The version a background check found; nil when there is nothing to install.
    private(set) var availableVersion: String?
    private(set) var canCheckForUpdates = false

    @ObservationIgnored private var controller: SPUStandardUpdaterController!
    @ObservationIgnored private var canCheckObservation: NSKeyValueObservation?

    override init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: self)
        // `swift run` has no app bundle to replace, so only the packaged app updates itself.
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        canCheckObservation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            let canCheck = updater.canCheckForUpdates
            Task { @MainActor in self?.canCheckForUpdates = canCheck }
        }
        do {
            try controller.updater.start()
        } catch {
            // A missing or placeholder signing key lands here. The app works without updates.
            NSLog("git-sight: updater did not start: %@", error.localizedDescription)
        }
    }

    /// Opens Sparkle's window: the waiting update if there is one, otherwise a fresh check.
    func checkForUpdates() {
        controller.updater.checkForUpdates()
    }
}

extension AppUpdater: SPUStandardUserDriverDelegate {
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem,
        andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        false
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        let version = update.displayVersionString
        MainActor.assumeIsolated { availableVersion = version }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        MainActor.assumeIsolated { availableVersion = nil }
    }
}

/// A toolbar pill that appears only while an update is waiting.
struct UpdatePill: View {
    let updater: AppUpdater

    var body: some View {
        if let version = updater.availableVersion {
            Button(action: updater.checkForUpdates) {
                Label("Update to \(version)", systemImage: "arrow.down.circle")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .help("Download git-sight \(version) and restart")
        }
    }
}
