//
// Vespertine: keeping music while the app is in the background, through the background tasks iOS offers and nothing else
// (the app never plays silence to stay awake).
//
// On iOS 26 and later, choosing Keep on This Device starts a continued processing task: iOS lets the fetching go on after
// the app is left and shows its progress itself, until it is done or iOS needs the time back. On any version, when the app
// goes to the background with songs left, an overnight processing task is asked for (on power and a network); iOS chooses
// when it runs. Either way a song cut off part way carries on from where it stopped, and a run that can't move (no
// connection, no room, cellular data off) gives its time back after a minute rather than holding on to it.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

import BackgroundTasks
import UIKit
import VespertinePhonePlayer

@MainActor
final class KeepInBackground {
    static let shared = KeepInBackground()
    /// Both are in Info.plist's BGTaskSchedulerPermittedIdentifiers (the continued one under its `.*` wildcard).
    static let overnightID = "org.szeremeta.VespertineRemote.keep.overnight"
    static let continuedID = "org.szeremeta.VespertineRemote.keep.continued.music"

    /// A background task is keeping music now: the connections it needs stay up when the app goes to the background.
    private(set) var running = false
    /// Connects what keeping needs (set by the app's model): a run that iOS started with the app in the background.
    var wake: @MainActor () -> Void = {}
    /// A run ended: the model lets go of connections nothing else needs.
    var ended: @MainActor () -> Void = {}

    private var run: KeepingRun?
    private var watcher: Task<Void, Never>?
    private var continuedRegistered = false

    private var shelf: KeptShelf { .shared }

    /// At launch, before it finishes (iOS requires it there for the overnight task).
    func registerAtLaunch() {
        _ = BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.overnightID, using: .main) { task in
            MainActor.assumeIsolated { KeepInBackground.shared.began(task) }
        }
    }

    /// The person chose Keep on This Device. On iOS 26 and later the fetching may go on after the app is left.
    func userChoseToKeep() {
        guard #available(iOS 26, *) else { return }
        if running {
            // Already keeping in the background: the run takes in what was added.
            if let run { self.run?.noteMore(remaining: shelf.remaining, completed: run.completed(remaining: shelf.remaining, fraction: shelf.fraction)) }
            return
        }
        // Continued processing handlers may be registered any time, but only once.
        if !continuedRegistered {
            continuedRegistered = BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.continuedID, using: .main) { task in
                MainActor.assumeIsolated { KeepInBackground.shared.began(task) }
            }
        }
        guard continuedRegistered else { return }
        let request = BGContinuedProcessingTaskRequest(identifier: Self.continuedID, title: Self.title, subtitle: Self.subtitle(done: 0, total: shelf.remaining))
        try? BGTaskScheduler.shared.submit(request)
    }

    /// The app is going to the background: with songs left, iOS is asked for time overnight (on power and a network).
    func scheduleOvernight() {
        guard shelf.remaining > 0 else { return }
        let request = BGProcessingTaskRequest(identifier: Self.overnightID)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = true
        try? BGTaskScheduler.shared.submit(request)
    }

    // MARK: A run

    private static var title: String { String(localized: "Fetching to Keep on This Device") }

    private static func subtitle(done: Int, total: Int) -> String { String(localized: "Songs: \(done) of \(total)") }

    private func began(_ task: BGTask) {
        guard !running else {
            task.setTaskCompleted(success: true)
            return
        }
        running = true
        wake()
        shelf.resumeAll()
        var run = KeepingRun(remaining: shelf.remaining)
        self.run = run
        let progress = (task as? ProgressReporting)?.progress
        progress?.totalUnitCount = max(1, run.units)
        task.expirationHandler = {
            Task { @MainActor in KeepInBackground.shared.end(task, success: false, expired: true) }
        }
        watcher = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let remaining = self.shelf.remaining
                run = self.run ?? run
                let done = run.completed(remaining: remaining, fraction: self.shelf.fraction)
                progress?.totalUnitCount = max(1, run.units)
                progress?.completedUnitCount = done
                if #available(iOS 26, *), let continued = task as? BGContinuedProcessingTask {
                    let total = Int(run.units / 100)
                    continued.updateTitle(Self.title, subtitle: Self.subtitle(done: Int(done / 100), total: total))
                }
                switch run.step(remaining: remaining, idle: self.shelf.isIdle, now: Date()) {
                case .working:
                    self.run = run
                case .finished:
                    self.end(task, success: true, expired: false)
                    return
                case .stalled:
                    self.end(task, success: false, expired: false)
                    return
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func end(_ task: BGTask, success: Bool, expired: Bool) {
        guard running else { return }
        watcher?.cancel()
        watcher = nil
        running = false
        run = nil
        // iOS wants its time back: fetching stops now, unless the app is in front again (then it simply carries on).
        if expired, UIApplication.shared.applicationState != .active { shelf.pauseAll() }
        task.setTaskCompleted(success: success)
        if UIApplication.shared.applicationState != .active {
            scheduleOvernight()
            ended()
        }
    }
}
