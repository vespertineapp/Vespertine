//
// Vespertine Remote: a share's scan carries on when the app leaves the screen. Reading a large library the first time
// takes a while, and it used to stop the moment the app went to the background (it then started over from the last
// 200 songs kept). Now it keeps going for as long as iOS allows right then, and asks for more time later: iOS gives it
// when it chooses, mostly with the phone idle and on its charger. What is read is kept every few seconds either way.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import BackgroundTasks
import UIKit

@MainActor
final class ShareBackgroundScan {
    /// Listed under BGTaskSchedulerPermittedIdentifiers in Info.plist.
    nonisolated static let identifier = "org.szeremeta.VespertineRemote.share-scan"
    static let shared = ShareBackgroundScan()

    private weak var model: RemoteAppModel?
    /// The few seconds iOS gives an app that has just left the screen, while a scan runs.
    private var grace: UIBackgroundTaskIdentifier = .invalid
    private var waiting: Task<Void, Never>?

    /// Once, as the app launches: iOS only runs the task for an app that said at launch what it does.
    func register(_ model: RemoteAppModel) {
        self.model = model
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.identifier, using: .main) { task in
            MainActor.assumeIsolated { ShareBackgroundScan.shared.run(task) }
        }
    }

    /// The app left the screen. True when a share is being scanned: its libraries stay open while iOS lets the app
    /// run, `away` (letting them go) is called when that time ends or the scan does, and more time is asked for later.
    func appLeft(away: @escaping @MainActor () -> Void) -> Bool {
        guard let model, model.sharesScanning else { return false }
        Self.askForTime()
        endGrace()
        grace = UIApplication.shared.beginBackgroundTask(withName: "Share scan") { [weak self] in
            MainActor.assumeIsolated {
                self?.waiting?.cancel()
                away()
                self?.endGrace()
            }
        }
        waiting = Task { [weak self] in
            while !Task.isCancelled, model.sharesScanning { try? await Task.sleep(for: .seconds(1)) }
            guard !Task.isCancelled else { return }
            away()
            self?.endGrace()
        }
        return true
    }

    /// The app is on the screen again: the scan goes on there as it was.
    func appCameBack() {
        waiting?.cancel()
        waiting = nil
        endGrace()
    }

    private func endGrace() {
        guard grace != .invalid else { return }
        UIApplication.shared.endBackgroundTask(grace)
        grace = .invalid
    }

    /// Asks iOS for time later to carry on. It needs the network; it doesn't need the charger, though iOS mostly waits
    /// for one.
    private static func askForTime() {
        let request = BGProcessingTaskRequest(identifier: identifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        try? BGTaskScheduler.shared.submit(request)
    }

    /// iOS gave the app time: the libraries are opened (a share whose first scan never finished carries on from what
    /// was kept), and let go again when the scans are done or the time is up.
    private func run(_ task: BGTask) {
        guard let model, model.hasUnfinishedShare else {
            task.setTaskCompleted(success: true)
            return
        }
        var done = false
        func finish(_ success: Bool) {
            guard !done else { return }
            done = true
            if !model.isInFront { model.letLibrariesRest() }
            if model.hasUnfinishedShare { Self.askForTime() }
            task.setTaskCompleted(success: success)
        }
        let job = Task {
            model.openLibraries()
            // The scan starts as the share opens; a moment for it to.
            for _ in 0..<10 where !model.sharesScanning { try? await Task.sleep(for: .milliseconds(500)) }
            while !Task.isCancelled, model.sharesScanning { try? await Task.sleep(for: .seconds(2)) }
            guard !Task.isCancelled else { return }
            finish(!model.hasUnfinishedShare)
        }
        task.expirationHandler = {
            Task { @MainActor in
                job.cancel()
                finish(false)
            }
        }
    }
}
