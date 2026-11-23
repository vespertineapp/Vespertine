//
// Vespertine: playing the queue on a network renderer, shaped like PlaybackEngine for the app: the same commands, the same
// `EngineSnapshot` and `EngineEvent`s. The queue stays Vespertine's: the renderer holds the song playing and the next one,
// and is told again whenever the next one changes. Its own clock decides when a song starts; position comes from polling it.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import os
import VespertineAudio

/// Makes the processed stream of a song: Vespertine's chain applied, encoded as 24-bit FLAC at the source rate, from
/// `startSeconds` on. Returns the file being written and the format of what it holds.
public protocol ProcessedStreamMaking: Sendable {
    func makeStream(item: PlayableItem, url: URL, settings: RendererSettings, startSeconds: TimeInterval) throws -> (GrowingFile, SourceFormat)
    /// The same for a player that takes less than the source has: the stream is made as `target` says (a rate, at most so
    /// many channels).
    func makeStream(item: PlayableItem, url: URL, settings: RendererSettings, startSeconds: TimeInterval, target: NetworkRender.Target) throws -> (GrowingFile, SourceFormat)
}

extension ProcessedStreamMaking {
    public func makeStream(item: PlayableItem, url: URL, settings: RendererSettings, startSeconds: TimeInterval, target: NetworkRender.Target) throws -> (GrowingFile, SourceFormat) {
        try makeStream(item: item, url: url, settings: settings, startSeconds: startSeconds)
    }
}

public final class RendererPlayback: @unchecked Sendable {
    /// The renderer and the way to it. Both change together when it is found again somewhere else (see `relocate`).
    private let link: Locked<(renderer: RendererDevice, transport: any RendererTransport)>
    public var renderer: RendererDevice { link.withLock { $0.renderer } }
    private var transport: any RendererTransport { link.withLock { $0.transport } }
    private let media: MediaServer
    private let processed: (any ProcessedStreamMaking)?
    private let log = Logger(subsystem: "org.szeremeta.vespertine.player", category: "renderer")

    /// Called on the worker when a song is playing: the one after it, as for gapless playback.
    public var nextItemProvider: (@Sendable (PlayableItem) -> PlayableItem?)? {
        get { hooks.withLock { $0.next } }
        set { hooks.withLock { $0.next = newValue } }
    }
    /// The file to open for an item (a local copy of a network file), as the engine's.
    public var urlResolver: (@Sendable (PlayableItem) -> URL)? {
        get { hooks.withLock { $0.resolver } }
        set { hooks.withLock { $0.resolver = newValue } }
    }
    /// Title, artist and album for the renderer's display.
    public var metadataProvider: (@Sendable (PlayableItem) -> RendererTrackInfo?)? {
        get { hooks.withLock { $0.metadata } }
        set { hooks.withLock { $0.metadata = newValue } }
    }
    public var eventHandler: (@Sendable @MainActor (EngineEvent) -> Void)? {
        get { hooks.withLock { $0.events } }
        set { hooks.withLock { $0.events = newValue } }
    }
    /// Looks for the renderer again when it doesn't answer at the address Vespertine has for it: the renderer as it is on
    /// the network now when that differs from `renderer` (it restarted on another port, or got a new address), else nil.
    /// A player that sat unused for a while is often somewhere else by the time Play is pressed; without this the first
    /// Play goes to where it was.
    public var relocate: (@Sendable (RendererDevice) async -> RendererDevice?)? {
        get { hooks.withLock { $0.relocate } }
        set { hooks.withLock { $0.relocate = newValue } }
    }

    private struct Hooks {
        var next: (@Sendable (PlayableItem) -> PlayableItem?)?
        var resolver: (@Sendable (PlayableItem) -> URL)?
        var metadata: (@Sendable (PlayableItem) -> RendererTrackInfo?)?
        var events: (@Sendable @MainActor (EngineEvent) -> Void)?
        var relocate: (@Sendable (RendererDevice) async -> RendererDevice?)?
    }
    private let hooks = Locked(Hooks())

    /// One song as sent to the renderer.
    struct Entry {
        var item: PlayableItem
        var mediaURL: URL
        var track: RendererTrack
        var path: SignalPath
        var processedFile: GrowingFile?
        /// A streamed song's whole copy in the transient playback cache (the media server serves it, or it is decoded); deleted when
        /// the entry is let go. Nil for local and share files.
        var staged: StagedRemoteFile? = nil
        /// Where the stream starts in the song (a processed stream restarted at a position).
        var startOffset: TimeInterval
        var duration: TimeInterval?
        /// Became audible (the renderer reported it playing).
        var announced = false
        /// Say so with `trackStarted` (not for a restart of the same song at a position).
        var announces = true
    }

    private struct State {
        var snapshot = EngineSnapshot()
        var settings = RendererSettings()
        var current: Entry?
        var next: Entry?
        /// Next songs the player held that are no longer next: it may still go on to them (a clear it didn't confirm), or
        /// may have gone on to one just before a change it did confirm. Their addresses and copies are kept, and a player
        /// found playing one is put right (`poll`), until the player's current song is reconciled: a status asked for after
        /// the change was confirmed shows it on another song. Never the queue's next song.
        var staleNexts: [Entry] = []
        /// The player confirmed what it holds next after these became stale (a clear, or a new next song): no clear is tried
        /// again, the next poll only reconciles.
        var staleConfirmed = false
        /// Clears of `staleNexts` tried again by the polls (a few, then they are only watched for), and when the last was
        /// tried (the clear that failed first counts as one, at that time).
        var staleClearTries = 0
        var staleTriedAt: Date?
        var anchor: (position: TimeInterval, at: Date)?
        var pendingSeek: TimeInterval?
        var pendingSeekTries = 0
        var failedPolls = 0
        /// When the polls began to fail (the renderer is lost once they have failed for `lostAfter`).
        var failingSince: Date?
        var wantsPlaying = false
        var shutDown = false
        /// A poll is waiting in the queue or running: the poller adds no other (a slow renderer builds no backlog).
        var pollQueued = false
        /// When the renderer was last told to play a song it hasn't started yet.
        var awaitingStartSince: Date?
        /// Polls in a row that found the renderer stopped.
        var stoppedPolls = 0
        /// The renderer has reported a position past the start of the song playing (some never report one).
        var reportsPosition = false
        /// How long the song playing has been heard, by Vespertine's own clock: what a song's end is judged by on a
        /// renderer that reports no position.
        var heard: TimeInterval = 0
        var lastPlayingPoll: Date?
        /// The play (`generation`) the song playing was started for: a next song is planned for that play only, so one
        /// planned after a stop or a skip that came while the song was being loaded is never published.
        var currentGeneration = 0
    }
    private let state = Locked(State())

    private let commands: AsyncStream<Command>
    private let enqueue: AsyncStream<Command>.Continuation
    private var worker: Task<Void, Never>?
    /// Signalled when the worker has run its last command.
    private let workerDone = DispatchSemaphore(value: 0)
    private var poller: Task<Void, Never>?
    /// Every play, stop and restart counts up, so a slow one that was overtaken drops its result.
    private let generation = Locked(0)
    /// Keeps the Mac awake while the renderer is meant to be playing: nothing plays through Core Audio then, so macOS
    /// would otherwise let the Mac sleep in the middle of an album, and the renderer would lose the server it reads from.
    private let activity = PlaybackActivity(reason: "Playing to a network player")
    /// A renderer that hasn't started a song this long after being told to has failed to play it.
    let startTimeout: TimeInterval
    /// How long a player that wants whole files waits for a processed stream to be written before it is offered as it grows.
    var wholeFileWait: TimeInterval = 120
    /// Status polls failing for this long (and at least three times) mean the renderer is gone.
    let lostAfter: TimeInterval
    /// The time, for everything judged by how long it has been (a renderer that has stopped answering, a song that hasn't
    /// started). The tests hand in a clock they move themselves.
    private let now: @Sendable () -> Date
    /// The wait after a change of settings while a song plays, before the song is restarted with them (300 ms: a volume
    /// drag restarts the stream once). The tests hand in one they end themselves.
    private let settingsPause: @Sendable () async -> Void

    enum Command {
        case play(PlayableItem, at: TimeInterval, announce: Bool, generation: Int), pause, resume, seek(TimeInterval), stop, queueChanged, settings(RendererSettings), poll
        /// A poll a test asked for, which is told when it is done.
        case step(CheckedContinuation<Void, Never>)
        /// The next song, prepared off the worker, is ready (or couldn't be): handed to the renderer if it is still wanted.
        case nextPrepared(NextPreparation)
    }

    /// The next song being prepared off the worker: which song, after which, for which play. Given up (`cancel`) the moment
    /// it no longer matters: a skip or a stop, the output let go of, the queue wanting another song next.
    final class NextPreparation: @unchecked Sendable {
        let item: PlayableItem
        /// The media URL of the song it is to follow.
        let after: URL
        let generation: Int
        private let lock = NSLock()
        private var cancelled = false
        private var result: Entry?
        private var running: Task<Void, Never>?

        init(item: PlayableItem, after: URL, generation: Int) {
            self.item = item
            self.after = after
            self.generation = generation
        }

        var isCancelled: Bool { lock.withLock { cancelled } }
        func cancel() { lock.withLock { cancelled = true } }
        func keep(_ entry: Entry?) { lock.withLock { result = entry } }
        /// The prepared entry, once: whoever takes it lets go of it or hands it over.
        func take() -> Entry? { lock.withLock { defer { result = nil }; return result } }
        var task: Task<Void, Never>? {
            get { lock.withLock { running } }
            set { lock.withLock { running = newValue } }
        }
    }
    private let preparingNext = Locked<NextPreparation?>(nil)
    /// Every next song's preparation still running, given up or not: `stopAndWait` waits for them too.
    private let livePreparations = DispatchGroup()

    /// `pollInterval` 0: the renderer is asked for its state only when `settleForTests` says so (a test that steps the
    /// polls itself).
    public init(renderer: RendererDevice, transport: any RendererTransport, media: MediaServer, processed: (any ProcessedStreamMaking)? = nil,
                pollInterval: TimeInterval = 0.5, startTimeout: TimeInterval = 15, lostAfter: TimeInterval = 10,
                now: @escaping @Sendable () -> Date = { Date() },
                settingsPause: @escaping @Sendable () async -> Void = { try? await Task.sleep(for: .milliseconds(300)) }) {
        self.startTimeout = startTimeout
        self.lostAfter = lostAfter
        self.now = now
        self.settingsPause = settingsPause
        link = Locked((renderer, transport))
        self.media = media
        self.processed = processed
        (commands, enqueue) = AsyncStream<Command>.makeStream()
        let done = workerDone
        worker = Task { [weak self, commands] in
            defer { done.signal() }
            for await command in commands {
                guard let self else { return }
                await self.run(command)
            }
        }
        guard pollInterval > 0 else { return }
        poller = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(pollInterval))
                guard let self else { return }
                let due = self.state.withLock { s -> Bool in
                    guard s.current != nil, !s.shutDown, !s.pollQueued else { return false }
                    s.pollQueued = true
                    return true
                }
                if due { self.enqueue.yield(.poll) }
            }
        }
    }

    deinit {
        worker?.cancel()
        poller?.cancel()
    }

    // MARK: Commands (any thread)

    public func play(_ item: PlayableItem) { play(item, at: 0, announce: true) }

    /// Plays `item` from `seconds` in (an output change carrying a song over): the position is reached once the renderer
    /// plays, not asked of it while it is still loading.
    public func play(_ item: PlayableItem, at seconds: TimeInterval) { play(item, at: seconds, announce: true) }

    private func play(_ item: PlayableItem, at seconds: TimeInterval, announce: Bool) {
        play(item, at: seconds, announce: announce, ifStill: nil)
    }

    /// `ifStill`: played only while that is still the current play (a song put right by a poll that began then); a stop or
    /// a song asked for since wins. The check, the new generation and what the snapshot says are done under the generation
    /// lock, as `stop()` does them, so no command comes in between. Returns whether it plays.
    @discardableResult
    private func play(_ item: PlayableItem, at seconds: TimeInterval, announce: Bool, ifStill expected: Int?) -> Bool {
        let g = generation.withLock { g -> Int? in
            guard expected.map({ $0 == g }) ?? true else { return nil }
            g += 1
            state.withLock {
                // A restart of the song at a position (a seek in a processed stream, a change of settings) keeps what the
                // listener asked for: a paused song stays paused.
                if announce { $0.wantsPlaying = true }
                $0.snapshot.state = $0.wantsPlaying ? .playing : .paused
                $0.snapshot.item = item
                $0.snapshot.position = seconds
                if announce { $0.snapshot.signalPath = nil }
            }
            return g
        }
        guard let g else { return false }
        // Whatever was being prepared to follow the song playing doesn't follow this one.
        cancelNextPreparation()
        refreshActivity()
        enqueue.yield(.play(item, at: seconds, announce: announce, generation: g))
        return true
    }

    /// The queue's end reached, as found by a poll that began during play `expected`: stopped only while that is still the
    /// current play (checked under the generation lock, as `play` does). Returns whether it was.
    private func endQueue(ifStill expected: Int) -> Bool {
        let ended = generation.withLock { g -> Bool in
            guard g == expected else { return false }
            state.withLock { s in s.snapshot.state = .stopped; s.wantsPlaying = false; s.anchor = nil }
            return true
        }
        if ended { refreshActivity() }
        return ended
    }

    private func refreshActivity() {
        activity.set(state.withLock { $0.wantsPlaying && !$0.shutDown })
    }

    public func pause() {
        state.withLock { $0.wantsPlaying = false; if $0.snapshot.state == .playing { $0.snapshot.state = .paused } }
        refreshActivity()
        enqueue.yield(.pause)
    }
    public func resume() {
        state.withLock { s in
            s.wantsPlaying = true
            if s.snapshot.state == .paused { s.snapshot.state = .playing }
            if s.current?.announced == false { s.awaitingStartSince = now() }
        }
        refreshActivity()
        enqueue.yield(.resume)
    }
    public func seek(to seconds: TimeInterval) { state.withLock { $0.snapshot.position = seconds; $0.anchor = nil }; enqueue.yield(.seek(seconds)) }
    public func stop() {
        // Under the generation lock, so a song put right by a poll (`play(_:at:announce:ifStill:)`) is either before it or
        // finds it.
        generation.withLock { g in g += 1; state.withLock { $0.wantsPlaying = false; $0.snapshot.state = .stopped } }
        cancelNextPreparation()
        refreshActivity()
        enqueue.yield(.stop)
    }
    public func queueChanged() { enqueue.yield(.queueChanged) }
    /// New settings. While a song plays, changes that restart it are applied 300 ms after the last one (a volume drag restarts
    /// the stream once, not at every step); with nothing playing they apply at once.
    public func update(settings: RendererSettings) {
        let g = settingsGeneration.withLock { $0 += 1; return $0 }
        guard state.withLock({ $0.current != nil }) else { enqueue.yield(.settings(settings)); return }
        Task { [weak self, settingsPause] in
            await settingsPause()
            guard let self, self.settingsGeneration.withLock({ $0 }) == g else { return }
            self.enqueue.yield(.settings(settings))
        }
    }
    private let settingsGeneration = Locked(0)

    /// Stops and lets go of the renderer (the output changed).
    public func shutdown() {
        stop()
        state.withLock { $0.shutDown = true }
        cancelNextPreparation()
        refreshActivity()
        enqueue.finish()
        poller?.cancel()
    }

    /// Gives up the next song being prepared, from any thread: its wait for a stream to be written ends within 20 ms, and
    /// what it made is let go of (an encoder writing for nobody stops).
    private func cancelNextPreparation() {
        guard let preparation = preparingNext.withLock({ s -> NextPreparation? in defer { s = nil }; return s }) else { return }
        preparation.cancel()
        preparation.take().map(release)
    }

    /// Stops, lets go of the renderer, and waits (up to `timeout` in all) for the worker's last command and for any next song
    /// still being prepared to have been given up (its encoder stopped, its download cancelled).
    public func stopAndWait(timeout: TimeInterval) {
        let deadline = DispatchTime.now() + timeout
        shutdown()
        _ = workerDone.wait(timeout: deadline)
        _ = livePreparations.wait(timeout: deadline)
    }

    /// A song is loaded on the renderer and it is answering: the renderer is there, whatever a search on the network says.
    public var isEngaged: Bool { state.withLock { $0.current != nil && !$0.shutDown && $0.failingSince == nil } }

    /// Told to play a song that isn't on the renderer yet. While it is, a renderer that turns up at another address is
    /// followed there by this playback itself (`relocate`); the song isn't started a second time by another one.
    public var isStarting: Bool { state.withLock { $0.wantsPlaying && $0.current == nil && !$0.shutDown } }

    /// The song playing started again at `seconds`, as a seek in a processed stream or a change of settings does.
    func restartForTests(at seconds: TimeInterval) {
        guard let item = state.withLock({ $0.current?.item }) else { return }
        play(item, at: seconds, announce: false)
    }

    /// Returns once every command asked for before this call has been carried out (a pause with its second try, a song
    /// loaded on the renderer) and the renderer has been asked for its state once more after them. The commands run one
    /// at a time in the order they were asked for, so a test that waits here has seen their whole effect, however slow
    /// the machine.
    /// The next song being prepared off the worker counts as one of those commands: it is waited for, and handed over.
    func settleForTests() async {
        while true {
            await withCheckedContinuation { done in
                if case .enqueued = enqueue.yield(.step(done)) {} else { done.resume() }
            }
            guard let preparation = preparingNext.withLock({ $0 }), !state.withLock({ $0.shutDown }) else { return }
            if let task = preparation.task { await task.value } else { await Task.yield() }
        }
    }

    /// Queues a poll now, as the poller does (behind whatever the worker is doing): the order against a command asked for
    /// next is then certain.
    func queuePollForTests() {
        state.withLock { $0.pollQueued = true }
        enqueue.yield(.poll)
    }

    /// The addresses of the songs Vespertine still keeps (their token and their copy) as the player's next song.
    var heldNextURIsForTests: [String] { state.withLock { ([$0.next].compactMap { $0 } + $0.staleNexts).map(\.mediaURL.absoluteString) } }

    /// How many times the song at this address was let go of (once is right; never is a leak, twice a double release).
    private let releases = Locked<[String: Int]>([:])
    func releasesForTests(_ uri: String) -> Int { releases.withLock { $0[uri] ?? 0 } }

    /// Vespertine means the player to be playing (not paused or stopped by the listener).
    var wantsPlaying: Bool { state.withLock { $0.wantsPlaying } }

    /// The state, with the position moved on since the last poll while playing.
    public var snapshot: EngineSnapshot {
        state.withLock { s in
            var snap = s.snapshot
            if snap.state == .playing, let anchor = s.anchor {
                snap.position = anchor.position + now().timeIntervalSince(anchor.at)
                if snap.duration > 0 { snap.position = min(snap.position, snap.duration) }
            }
            return snap
        }
    }

    // MARK: Worker

    private func emit(_ event: EngineEvent) {
        guard let handler = eventHandler else { return }
        Task { @MainActor in handler(event) }
    }

    private func run(_ command: Command) async {
        do {
            switch command {
            case .play(let item, let at, let announce, let g):
                guard generation.withLock({ $0 }) == g else { return }   // overtaken by a later skip or stop
                try await start(item, at: at, announce: announce, generation: g)
            case .pause: await retrying(.pause, resync: true) { try await self.transport.pause() }
            case .resume: await retrying(.play, resync: true) { try await self.transport.play() }
            case .seek(let seconds): await retrying(.seek, resync: false) { try await self.seek(seconds) }
            case .stop:
                // A next song planned after `stop()` was called (by a start that was still loading its song then) is given
                // up here too.
                cancelNextPreparation()
                try? await transport.stop()
                let old = state.withLock { s -> [Entry] in
                    defer { s.current = nil; s.next = nil; s.staleNexts = []; s.anchor = nil; s.snapshot = EngineSnapshot() }
                    return [s.current, s.next].compactMap { $0 } + s.staleNexts
                }
                old.forEach(release)
            case .queueChanged:
                await planNextQuietly()
            case .settings(let settings):
                do { try await apply(settings) } catch {
                    log.error("Renderer \(self.renderer.name, privacy: .public), settings: \(String(describing: error), privacy: .public)")
                }
            case .poll:
                // Let go of (the output changed) before this poll's turn came: nothing more is asked of the renderer.
                let skip = state.withLock { s -> Bool in s.pollQueued = false; return s.shutDown }
                if !skip { await poll() }
            case .step(let done):
                if !state.withLock({ $0.shutDown }) { await poll() }
                done.resume()
            case .nextPrepared(let preparation):
                await handOver(preparation)
            }
        } catch {
            let item = state.withLock { $0.current?.item ?? $0.snapshot.item }
            log.error("Renderer \(self.renderer.name, privacy: .public): \(String(describing: error), privacy: .public)")
            fail(item, error)
        }
    }

    /// Pause, play and seek: a renderer busy changing state refuses them now and then (UPnP 701, "transition not available").
    /// Tried again once after a moment; refused again, the listener is told and the song plays on as it was.
    /// `resync`: pause and play were shown at once (optimistically); refused, the snapshot and what Vespertine wants go back to what
    /// the player is really doing, so the interface doesn't say paused while it plays.
    private func retrying(_ what: RefusedAction, resync: Bool, _ body: @escaping () async throws -> Void) async {
        do { try await body(); return } catch {}
        try? await Task.sleep(for: .milliseconds(300))
        do { try await body() } catch {
            if resync, let status = try? await transport.status() {
                state.withLock { s in
                    switch status.state {
                    case .playing, .transitioning: s.wantsPlaying = true; s.snapshot.state = .playing
                    case .paused: s.wantsPlaying = false; s.snapshot.state = .paused; s.anchor = nil
                    case .stopped, .noMedia: s.wantsPlaying = false; s.snapshot.state = .stopped; s.anchor = nil
                    }
                }
            }
            refreshActivity()
            emit(.notice(what.message(player: renderer.name, reason: (error as? UPnPError)?.message ?? error.localizedDescription)))
        }
    }

    /// What a renderer refused, as a whole sentence for each (a sentence built from a verb can't be translated).
    enum RefusedAction {
        case pause, play, seek

        func message(player: String, reason: String) -> String {
            switch self {
            case .pause: String(localized: "\(player) didn't pause (\(reason)).", comment: "%1$@ is a network player's name, %2$@ the reason it gave.")
            case .play: String(localized: "\(player) didn't carry on playing (\(reason)).", comment: "%1$@ is a network player's name, %2$@ the reason it gave. The listener pressed Play on a paused song.")
            case .seek: String(localized: "\(player) didn't seek (\(reason)).", comment: "%1$@ is a network player's name, %2$@ the reason.")
            }
        }
    }

    private func fail(_ item: PlayableItem?, _ error: Error) {
        let message = failureMessage(error)
        state.withLock { Self.markFailed(&$0, message) }
        refreshActivity()
        emit(.failed(item, message))
    }

    /// What the listener is told when the renderer couldn't play a song.
    private func failureMessage(_ error: Error) -> String {
        var reason = (error as? UPnPError)?.message ?? (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        if let hint = Self.sonosHint(error, isSonos: renderer.isSonos) { reason += ". " + hint }
        return String(localized: "\(renderer.name) couldn't play the song (\(reason)).", comment: "%1$@ is a network player's name, %2$@ the reason.")
    }

    private static func markFailed(_ s: inout State, _ message: String) {
        s.snapshot.state = .stopped; s.snapshot.lastError = message; s.wantsPlaying = false; s.awaitingStartSince = nil
    }

    /// Changes the state only while `polled` (the play a poll inspects) is still the current play, checked under the
    /// generation lock as `play` and `stop()` change it: a poll queued before a stop or a song chosen does nothing to the
    /// song that replaces its own. Returns what `body` did, or nil for a play no longer current.
    private func ifStill<T>(_ polled: Int, _ body: (inout State) -> T) -> T? {
        generation.withLock { g in g == polled ? state.withLock(body) : nil }
    }

    /// What to check when a Sonos refuses a song with one of its two usual codes: 714 (it fetched something it can't play)
    /// and 716 (it couldn't fetch the song from this Mac at all, which is nearly always the Mac's firewall).
    static func sonosHint(_ error: Error, isSonos: Bool) -> String? {
        guard isSonos, case .fault(let code, _)? = error as? UPnPError else { return nil }
        switch code {
        case 716: return String(localized: "Sonos couldn't fetch the song from this Mac: allow Vespertine incoming connections in System Settings › Network › Firewall, and check both are on the same network", comment: "Added to the reason a Sonos couldn't play a song. No full stop at the end.")
        case 714: return String(localized: "Sonos fetched the song and couldn't play its format", comment: "Added to the reason a Sonos couldn't play a song. No full stop at the end.")
        case 800: return String(localized: "this speaker now follows another room: open the output list again and choose the room that leads the group", comment: "Added to the reason a Sonos couldn't play a song. No full stop at the end.")
        default: return nil
        }
    }

    private func release(_ entry: Entry) {
        let url = entry.mediaURL, media = media
        releases.withLock { $0[url.absoluteString, default: 0] += 1 }
        // A processed stream nobody heard (a song skipped while it was being prepared) goes at once: its encoder would
        // otherwise write the whole song for nothing.
        if entry.processedFile != nil, !entry.announced {
            media.release(url)
            return
        }
        // Renderers ask again for a while (a retry, a second range): a grace period before the token goes.
        Task.detached {
            try? await Task.sleep(for: .seconds(30))
            media.release(url)
        }
    }

    /// Preparing a song opens its file (a probe, a decoder, an encoder), which can block on a disk or a share: it runs on a
    /// queue of its own, never on Swift's cooperative pool.
    public static let preparationQueueLabel = "org.szeremeta.vespertine.upnp.prepare"
    private static let preparation = DispatchQueue(label: preparationQueueLabel, qos: .userInitiated)

    /// `cancelled`: the entry is no longer wanted (a skip, a stop, the output let go of); a wait for a stream to be written
    /// ends then, and the preparation throws `CancellationError`.
    func entry(for item: PlayableItem, at seconds: TimeInterval, cancelled: @escaping @Sendable () -> Bool = { false }) async throws -> Entry {
        try await withCheckedThrowingContinuation { continuation in
            Self.preparation.async {
                continuation.resume(with: Result { try self.prepareEntry(for: item, at: seconds, cancelled: cancelled) })
            }
        }
    }

    /// Prepares `item` to be sent: its media URL, metadata and signal path.
    private func prepareEntry(for item: PlayableItem, at seconds: TimeInterval, cancelled: () -> Bool) throws -> Entry {
        if cancelled() { throw CancellationError() }
        let resolved = urlResolver?(item) ?? item.url
        // A stream is copied whole first: the renderer pulls a file, and the decoder reads one.
        // Given up while it downloads (a skip, a stop, the output let go of): this preparation lets go of the copy and the
        // shared preparation queue is free again within moments, for the song that is wanted now. The download itself is
        // cancelled only when nobody else holds it (the Mac's engine may be playing the same song from it: the listener
        // switched from this player to the Mac).
        let staged = resolved.isFileURL ? nil : try StagedRemoteFile.stage(item, cancelled: cancelled)
        let url = staged?.url ?? resolved
        // Given up while it was copied: nothing is probed, and no encoder made.
        if cancelled() { throw CancellationError() }
        let described = try? SourceDescription.describe(item, url: url)
        let settings = state.withLock { $0.settings }
        let limits = renderer.limits
        let wholeFile = item.regionStartFrame == nil && item.regionFrameLength == nil && item.sacdArea == nil && item.dvd == nil
            && item.audioStream == nil && url.isFileURL
        let fitted = limits.flatMap { limits in described.map { StreamNegotiation.plan(source: $0.format, mime: wholeFile ? MediaType.mime(forExtension: url.pathExtension) : nil, limits: limits) } }
        let decision = RendererMode.decide(item: item, url: url, source: described?.format, settings: settings, capabilities: renderer.capabilities, limits: limits)
        let info = metadataProvider?(item) ?? RendererTrackInfo(title: url.deletingPathExtension().lastPathComponent)
        var processing: [SignalPath.RendererStage.Processing] = []
        let resource: MediaResource
        var sent: SourceFormat? = described?.format
        var file: GrowingFile?
        let mime: String
        switch decision {
        case .unplayable(let reason):
            throw RendererPlaybackError.unplayable(reason)
        case .passThrough(let type):
            mime = type
            resource = .file(url, mime: type)
        case .processed(let reasons):
            guard let processed else { throw RendererPlaybackError.unplayable(String(localized: "Processed streams aren't available.")) }
            processing = reasons
            if cancelled() { throw CancellationError() }
            // A player with limits gets a stream made to them, even when only the listener's own processing made one needed
            // (a Sonos S1 takes 16 bits, whatever the reason the song is processed).
            let (growing, format) = if let fitted, let limits {
                try processed.makeStream(item: item, url: url, settings: settings, startSeconds: seconds, target: .init(fitted, limits: limits))
            } else {
                try processed.makeStream(item: item, url: url, settings: settings, startSeconds: seconds)
            }
            // A player that wants whole files is offered the stream once it is written (encoding runs many times faster than
            // the music plays). One that takes long is offered as it grows after all, rather than keep the listener waiting.
            if limits?.wholeFiles == true {
                let deadline = Date().addingTimeInterval(wholeFileWait)
                while !growing.isFinished, !growing.isAbandoned, !cancelled(), Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
            }
            // No longer wanted while it was written: the encoder stops, and nothing is offered.
            if cancelled() {
                growing.abandon()
                throw CancellationError()
            }
            file = growing
            sent = format
            mime = "audio/flac"
            resource = .growing(growing, mime: mime)
        }
        guard let mediaURL = media.register(resource, toward: renderer.host) else {
            throw RendererPlaybackError.unplayable(String(localized: "no network interface reaches it"))
        }
        // A processed stream that is already whole is described like a file: its length lets the player show and seek it.
        let sizedFile = file.map { $0.isFinished ? $0.url : nil } ?? url
        let size = sizedFile.flatMap { (try? FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? Int64) ?? nil }
        let didl = DIDLLite.item(id: item.id.uuidString, info: info, url: mediaURL, mime: mime, size: size, format: sent)
        let source = described?.format ?? SourceFormat(encoding: .pcm, codec: url.pathExtension.uppercased(), sampleRate: 0, bitDepth: nil, channels: 2)
        var warnings = sent.map { renderer.capabilities.warnings(for: $0, sending: mime).map(\.message) } ?? []
        // What fitting the song to the player cost, each in a sentence: nothing is taken away without saying so.
        if let limits, let fitted, file != nil { warnings += fitted.changes.filter(\.changesSamples).map { $0.message(player: limits.playerKind) } }
        let stage = SignalPath.RendererStage(name: renderer.name, protocolName: renderer.kind.protocolName, processing: processing,
                                             sentCodec: file == nil ? source.codec : "FLAC", sentSampleRate: sent?.sampleRate ?? source.sampleRate,
                                             sentBitDepth: file == nil ? source.bitDepth : sent?.bitDepth ?? 24, sentChannels: sent?.channels ?? source.channels,
                                             gapless: transport.gapless, warnings: warnings)
        let volume: SignalPath.VolumeStage = settings.activeVolumeDB.map { .digital(dB: $0) } ?? .fixed
        let path = SignalPath.renderer(stage, source: source, decoderName: described?.decoderName ?? "", volume: volume,
                                       replayGainDB: processing.contains(.replayGain) ? item.replayGainDB : nil,
                                       equalizer: processing.contains(.equalizer) ? settings.activeEqualizer?.name : nil,
                                       roomCorrection: processing.contains(.roomCorrection) ? settings.activeRoomCorrection?.name : nil)
        return Entry(item: item, mediaURL: mediaURL, track: RendererTrack(uri: mediaURL, metadata: didl), path: path, processedFile: file, staged: staged,
                     startOffset: file == nil ? 0 : seconds, duration: info.duration)
    }

    private func start(_ item: PlayableItem, at seconds: TimeInterval, announce: Bool, generation g: Int) async throws {
        var current: Entry
        // The song already prepared as the next one (the listener skipped to it, or the renderer stopped before it) is
        // used as it is: a stream copied whole isn't copied again.
        let prepared = state.withLock { s -> Entry? in
            guard seconds == 0, let next = s.next, next.item.id == item.id else { return nil }
            s.next = nil
            return next
        }
        // Overtaken (a later skip or stop) or let go of while it is prepared: a wait for its stream ends there.
        let overtaken: @Sendable () -> Bool = { [generation, state] in generation.withLock { $0 } != g || state.withLock { $0.shutDown } }
        if let prepared { current = prepared } else {
            do { current = try await entry(for: item, at: seconds, cancelled: overtaken) } catch {
                if !overtaken() { fail(item, error) }
                return
            }
        }
        current.announces = announce
        guard generation.withLock({ $0 }) == g else { release(current); return }
        // The song is sent first, alone: the one after it is prepared (a stream is copied whole) while this one plays.
        let next: Entry? = nil
        do {
            do { try await load(current.track) } catch let error as UPnPError where error.isLinkFailure {
                // It doesn't answer where Vespertine has it. Found somewhere else, the song goes there, prepared again
                // (its address on this Mac's side and what the renderer takes may have changed with it).
                guard generation.withLock({ $0 }) == g else { release(current); return }
                guard await relocated() else { throw error }
                guard generation.withLock({ $0 }) == g else { release(current); return }
                release(current)
                do { current = try await entry(for: item, at: seconds, cancelled: overtaken) } catch {
                    if !overtaken() { fail(item, error) }
                    return
                }
                current.announces = announce
                guard generation.withLock({ $0 }) == g else { release(current); return }
                try await load(current.track)
            }
        } catch {
            release(current)
            // What it was playing before isn't what Vespertine shows any more. A renderer that can't be reached isn't asked:
            // waiting for that to time out as well would only keep the listener from being told.
            if (error as? UPnPError)?.isLinkFailure != true { try? await transport.stop() }
            throw error
        }
        let old = state.withLock { s -> [Entry] in
            defer {
                s.current = current
                s.currentGeneration = g
                s.next = next
                // The song just loaded replaced what the player plays, and its next song with it (`load` clears it).
                s.staleNexts = []; s.staleConfirmed = false; s.staleClearTries = 0
                s.anchor = nil
                s.failedPolls = 0
                s.failingSince = nil
                s.stoppedPolls = 0
                s.reportsPosition = false; s.heard = 0; s.lastPlayingPoll = nil
                s.awaitingStartSince = s.wantsPlaying ? now() : nil
                s.pendingSeek = current.processedFile == nil && seconds > 0 ? seconds : nil
                s.pendingSeekTries = 0
                s.snapshot.item = item
                s.snapshot.signalPath = current.path
                s.snapshot.position = seconds
                s.snapshot.duration = current.duration ?? 0
                s.snapshot.lastError = nil
                s.snapshot.state = s.wantsPlaying ? .playing : .paused
            }
            return [s.current, s.next].compactMap { $0 } + s.staleNexts.filter { $0.mediaURL != current.mediaURL && $0.mediaURL != next?.mediaURL }
        }
        old.forEach(release)
        if !state.withLock({ $0.wantsPlaying }) { try await transport.pause() }
        await planNextQuietly()
    }

    /// Sends `track` as the song to play, once more after a moment when the renderer is still changing state (UPnP 701).
    private func load(_ track: RendererTrack) async throws {
        do { try await transport.load(current: track, next: nil) } catch let error where Self.isTransient(error) {
            try await Task.sleep(for: .milliseconds(300))
            try await transport.load(current: track, next: nil)
        }
    }

    /// Looks for the renderer again; true when it was found somewhere else and is talked to there from now on.
    private func relocated() async -> Bool {
        let known = renderer
        guard let relocate, let found = await relocate(known), found.uid == known.uid, found.description != known.description,
              let transport = try? found.makeTransport() else { return false }
        link.withLock { $0 = (found, transport) }
        log.info("Renderer \(found.name, privacy: .public) found again at \(found.host, privacy: .public)")
        return true
    }

    private func seek(_ seconds: TimeInterval) async throws {
        guard let current = state.withLock({ $0.current }) else { return }
        if let stream = current.processedFile, renderer.limits?.wholeFiles == true, stream.isFinished, seconds >= current.startOffset {
            // A processed stream that was written whole before it was offered is a file like any other to the player.
            try await transport.seek(to: seconds - current.startOffset)
            state.withLock { $0.anchor = nil; $0.snapshot.position = seconds; $0.heard = seconds - current.startOffset }
        } else if current.processedFile != nil {
            // A processed stream is written ahead and can't be seeked by the renderer: it starts again at the position.
            play(current.item, at: seconds, announce: false)
        } else {
            try await transport.seek(to: seconds)
            state.withLock { $0.anchor = nil; $0.snapshot.position = seconds; $0.heard = seconds }
        }
    }

    /// A next song the renderer wasn't told about is no reason to stop the one playing: Vespertine starts it itself when
    /// this one ends.
    private func planNextQuietly() async {
        do { try await replanNext() } catch {
            log.error("Renderer \(self.renderer.name, privacy: .public), next song: \(String(describing: error), privacy: .public)")
        }
    }

    /// Sees that the renderer holds the song the queue wants next. Preparing it can take long (a stream copied whole, a
    /// processed stream written whole for a player that wants files), so it is done off the worker (`NextPreparation`) and
    /// handed to the renderer when it is ready (`handOver`); the worker goes on with pause, seek, stop and the polls
    /// meanwhile. `force`: prepared again even when it is the one held (the settings it is made with changed).
    private func replanNext(force: Bool = false) async throws {
        guard let current = state.withLock({ $0.current }) else { return }
        let wanted = nextItemProvider?(current.item)
        let have = state.withLock { $0.next?.item }
        if !force, wanted?.id == have?.id {
            // Held already. One being prepared for another song is given up; one made again for the same song (new
            // settings) carries on.
            if preparingNext.withLock({ $0.map { $0.item.id != wanted?.id } ?? false }) { cancelNextPreparation() }
            return
        }
        // The play the song playing belongs to: after a stop or a skip it is no longer the current play, and nothing is
        // planned for it.
        let g = state.withLock { $0.currentGeneration }
        // Already being prepared, to follow this very song.
        if !force, let wanted, let preparing = preparingNext.withLock({ $0 }), preparing.item.id == wanted.id, preparing.after == current.mediaURL,
           preparing.generation == g, !preparing.isCancelled { return }
        cancelNextPreparation()
        // The song the player holds as the next one is no longer next (the queue was edited): it is taken off the player at
        // once, not when the new one is ready; a song that ends meanwhile then doesn't go on to it, and Vespertine starts
        // the right one itself.
        var cleared = false
        if !force, have != nil {
            cleared = true
            do { try await takeNextOff() } catch {
                log.error("Renderer \(self.renderer.name, privacy: .public), clearing the next song: \(String(describing: error), privacy: .public)")
            }
        }
        guard let wanted else {
            guard !cleared else { return }
            // Nothing after this song: the renderer is told so at once (no preparing to wait for).
            try await takeNextOff()
            return
        }
        let preparation = NextPreparation(item: wanted, after: current.mediaURL, generation: g)
        // Published only while its play is still the current one and the output is still held, checked together with
        // publishing: a stop or a shutdown moves the generation (or sets `shutDown`) before it gives up what is published,
        // so it either finds this preparation and gives it up, or this preparation finds it and isn't published at all.
        let published = preparingNext.withLock { slot -> Bool in
            guard generation.withLock({ $0 }) == g, !state.withLock({ $0.shutDown }) else { return false }
            slot = preparation
            return true
        }
        guard published else { return }
        let log = self.log, name = renderer.name, live = livePreparations
        live.enter()
        preparation.task = Task.detached { [weak self] in
            defer { live.leave() }
            guard let self else { return }
            do {
                preparation.keep(try await self.entry(for: wanted, at: 0, cancelled: { preparation.isCancelled }))
            } catch {
                // Played (and failed) when it's reached, as the engine does with a file that won't open.
                if !preparation.isCancelled {
                    log.error("Next song for \(name, privacy: .public) not prepared: \(String(describing: error), privacy: .public)")
                }
            }
            // Given up while it was prepared, or nobody left to hand it to: let go of here.
            if preparation.isCancelled { preparation.take().map(self.release); return }
            if case .enqueued = self.enqueue.yield(.nextPrepared(preparation)) {} else { preparation.take().map(self.release) }
        }
    }

    /// On the worker: the next song is prepared. Told to the renderer when it still follows the song playing and is still
    /// the one the queue wants; else let go of (and the right one planned).
    private func handOver(_ preparation: NextPreparation) async {
        let entry = preparation.take()
        // It stays the one being prepared until it is handed over (a test settling waits for that), then it isn't.
        let mine = preparingNext.withLock { $0 === preparation }
        defer { preparingNext.withLock { if $0 === preparation { $0 = nil } } }
        let current = state.withLock { $0.shutDown ? nil : $0.current }
        guard mine, !preparation.isCancelled, generation.withLock({ $0 }) == preparation.generation, let current,
              current.mediaURL == preparation.after else {
            entry.map(release)
            return
        }
        guard nextItemProvider?(current.item)?.id == preparation.item.id else {
            // The queue changed while it was prepared.
            entry.map(release)
            await planNextQuietly()
            return
        }
        do { try await setNext(entry) } catch {
            // Not told: Vespertine starts it itself when this one ends. What the player held as its next song is still
            // on it, unconfirmed: kept as stale (see `takeNextOff`).
            entry.map(release)
            keepNextAsStale()
            log.error("Renderer \(self.renderer.name, privacy: .public), next song: \(String(describing: error), privacy: .public)")
            return
        }
        // The player holds this one now as its next song, and nothing it held before; it may have gone on to one of those
        // just before the change reached it, so they are kept until the next poll has seen the song it is on.
        retire(replacedBy: entry)
    }

    /// The player confirmed `next` (nil: nothing) as its next song: what it held next before is stale until reconciled.
    private func retire(replacedBy next: Entry?) {
        state.withLock { s in
            if let old = s.next, old.mediaURL != next?.mediaURL { s.staleNexts.append(old) }
            s.next = next
            s.staleClearTries = 0
            s.staleConfirmed = !s.staleNexts.isEmpty
        }
    }

    /// Takes the next song off the player (an empty NextURI). Confirmed: what it held is stale until the next poll has
    /// seen the song the player is on (it may have gone on to it just before the clear). Not confirmed (the player refused,
    /// or didn't answer): the song is stale, with its address and its copy, since the player may still go on to it; the
    /// polls try the clear again, and put a player found playing it right. Throws the failure.
    private func takeNextOff() async throws {
        do { try await setNext(nil) } catch {
            keepNextAsStale()
            throw error
        }
        retire(replacedBy: nil)
    }

    /// The next song held is no longer next, and the player wasn't confirmed to have dropped it: it becomes stale, and
    /// the clear is to be tried again (for every stale song: the player is told what it is to hold next, `next`).
    private func keepNextAsStale() {
        let at = now()
        state.withLock { s in
            guard let next = s.next else { return }
            s.staleNexts.append(next); s.next = nil
            s.staleConfirmed = false; s.staleClearTries = 0; s.staleTriedAt = at
        }
    }

    /// Clears a stale next song again (the player may answer now): what it is to hold is `next` (nil: nothing). A few tries,
    /// then the polls only watch for the player going on to it.
    private func retryStaleClear() async {
        let at = now()
        let next = state.withLock { s -> Entry?? in
            guard !s.staleNexts.isEmpty, !s.staleConfirmed, s.staleClearTries < Self.staleClearAttempts,
                  s.staleTriedAt.map({ at.timeIntervalSince($0) >= staleClearSpacing }) ?? true else { return .none }
            s.staleClearTries += 1
            s.staleTriedAt = at
            return .some(s.next)
        }
        guard case .some(let next) = next else { return }
        do { try await transport.replaceNext(next?.track) } catch {
            log.error("Renderer \(self.renderer.name, privacy: .public), clearing the old next song again: \(String(describing: error), privacy: .public)")
            return
        }
        // Confirmed: kept until the next poll has seen the song the player is on (it may have gone on to a stale one after
        // the poll that sent this clear asked, and before the clear reached it).
        state.withLock { s in if !s.staleNexts.isEmpty { s.staleConfirmed = true; s.staleClearTries = 0 } }
    }
    /// Tries of a stale clear (one a second), then only watched for: a renderer that always refuses an empty NextURI isn't
    /// asked for ever.
    static let staleClearAttempts = 10
    /// A test spaces them closer.
    var staleClearSpacing: TimeInterval = 1

    /// "Transition not available": the renderer is between two states and takes the same command a moment later.
    static func isTransient(_ error: Error) -> Bool {
        if case .fault(code: 701, description: _)? = error as? UPnPError { return true }
        return false
    }

    /// Tells the renderer its next song, once more after a moment when it refuses (UPnP 701 while it changes state).
    private func setNext(_ next: Entry?) async throws {
        do { try await transport.replaceNext(next?.track) } catch let error where Self.isTransient(error) {
            try await Task.sleep(for: .milliseconds(300))
            try await transport.replaceNext(next?.track)
        }
    }

    private func apply(_ settings: RendererSettings) async throws {
        let before = state.withLock { s -> RendererSettings in defer { s.settings = settings }; return s.settings }
        guard before != settings, let current = state.withLock({ $0.current }) else { return }
        let url = current.staged?.url ?? urlResolver?(current.item) ?? current.item.url
        let decision = RendererMode.decide(item: current.item, url: url, source: current.path.source, settings: settings, capabilities: renderer.capabilities,
                                           limits: renderer.limits)
        let processing: [SignalPath.RendererStage.Processing] = if case .processed(let r) = decision { r } else { [] }
        // The song playing restarts where it is when what's done to it changes; the next one is prepared again either way.
        if processing != (current.path.renderer?.processing ?? []) || current.processedFile != nil {
            play(current.item, at: snapshot.position, announce: false)
        } else {
            try await replanNext(force: true)
        }
    }

    /// The player went on to a next song no longer next (`staleNexts`): `ended` played to its end, and what
    /// follows it in the queue now is what plays; at the queue's end the player is stopped. The stale song is let go of then,
    /// and never announced.
    /// `polled`: the play the poll that found it began in. A stop or a song chosen while that poll waited for the player's
    /// answer wins: nothing is put right then (the command itself replaces or stops what the player plays, and lets go of
    /// the stale song).
    private func putRight(after ended: Entry, polled: Int) async {
        let following = nextItemProvider?(ended.item)
        if let following {
            // The start loads the right song in its place (and lets go of the one that ended).
            guard play(following, at: 0, announce: true, ifStill: polled) else { return }
        } else {
            guard endQueue(ifStill: polled) else { return }
        }
        log.notice("Renderer \(self.renderer.name, privacy: .public) went on to a song no longer next; playing the queue's")
        // Let go of at once, so the polls put this right once only (were the right song then to fail, they'd start it again
        // at every poll).
        releaseStale()
        guard following == nil else { return }
        try? await transport.stop()
        emit(.queueEnded)
    }

    /// Lets go of every stale next song (put right, or reconciled).
    private func releaseStale() {
        let stale = state.withLock { s -> [Entry] in defer { s.staleNexts = []; s.staleConfirmed = false; s.staleClearTries = 0 }; return s.staleNexts }
        stale.forEach(release)
    }

    private func poll() async {
        // What the player holds next was confirmed before this status was asked for: what it answers settles the stale songs.
        let reconciles = state.withLock { $0.staleConfirmed }
        let status: RendererStatus
        do { status = try await transport.status() } catch {
            // Gone once it has failed to answer for a while, not at a moment's trouble on the network: it may well be
            // playing on, and letting go of its songs would cut them off.
            let lostAfter = self.lostAfter
            let lost = state.withLock { s -> Bool in
                s.failedPolls += 1
                s.anchor = nil
                let since = s.failingSince ?? now()
                s.failingSince = since
                return s.failedPolls >= 3 && now().timeIntervalSince(since) >= lostAfter
            }
            if lost {
                let old = state.withLock { s -> [Entry] in
                    defer {
                        s.current = nil; s.next = nil; s.staleNexts = []; s.anchor = nil; s.snapshot.state = .stopped; s.wantsPlaying = false
                        s.failedPolls = 0; s.failingSince = nil; s.awaitingStartSince = nil
                    }
                    return [s.current, s.next].compactMap { $0 } + s.staleNexts
                }
                old.forEach(release)
                refreshActivity()
                emit(.deviceLost(renderer.name))
            }
            return
        }
        state.withLock { $0.failedPolls = 0; $0.failingSince = nil }
        // The song this poll inspects, and the play it was loaded for: what the poll finds is acted on only while that is
        // still the current play. Not the generation when the poll began: a poll queued before a stop or a song chosen can
        // begin after the command moved the generation on, while the old song is still loaded (the command's own turn on
        // the worker comes after it).
        guard let (loaded, polled) = state.withLock({ s in s.current.map { ($0, s.currentGeneration) } }) else { return }
        var current = loaded
        // Next songs the player held that are no longer next. Gone on to one all the same (the song playing ended): it
        // isn't the queue's, so it isn't taken for the next song; Vespertine plays the one the queue has after the song that
        // ended, or stops at the queue's end. Else, once the change was confirmed, they are let go of; until then the clear
        // is tried again.
        let stale = state.withLock { $0.staleNexts }
        if !stale.isEmpty {
            if let uri = status.currentURI, stale.contains(where: { $0.mediaURL == uri }) {
                await putRight(after: current, polled: polled)
                return
            }
            // On another song, asked after the change was confirmed: it can't go on to them any more.
            if reconciles { releaseStale() } else { await retryStaleClear() }
        }
        var advanced = false
        // The renderer moved on to the next song by itself.
        if let uri = status.currentURI, let next = state.withLock({ $0.next }), uri == next.mediaURL {
            // The song now playing first; the one after it is prepared and sent by the queue's own step.
            // Only for the play it is part of: a stop or a song chosen queued behind this poll replaces both songs.
            guard let old = ifStill(polled, { s -> Entry? in
                defer {
                    s.current = next; s.next = nil; s.snapshot.item = next.item; s.snapshot.signalPath = next.path
                    s.snapshot.duration = next.duration ?? 0; s.snapshot.position = 0; s.stoppedPolls = 0
                    s.reportsPosition = false; s.heard = 0; s.lastPlayingPoll = nil
                    s.awaitingStartSince = s.wantsPlaying ? now() : nil
                }
                return s.current
            }) else { return }
            old.map(release)
            current = next
            advanced = true
        }
        if status.currentURI == current.mediaURL, !current.announced, status.state == .playing || status.state == .transitioning {
            // A song the listener has moved on from isn't announced as started.
            guard ifStill(polled, { s -> Void in s.current?.announced = true; s.awaitingStartSince = nil }) != nil else { return }
            current.announced = true
            if current.announces { emit(.trackStarted(current.item)) }
        }
        // The song after the one it moved on to is prepared and sent now, while this one plays.
        if advanced { await planNextQuietly() }
        // A seek pending for a play no longer current isn't sent (the command queued behind this poll replaces the song).
        if status.state == .playing, status.currentURI == current.mediaURL, let seek = ifStill(polled, { $0.pendingSeek }) ?? nil {
            do {
                try await transport.seek(to: seek)
                _ = ifStill(polled) { s -> Void in s.pendingSeek = nil; s.heard = seek }
            } catch {
                // Still settling: tried again at the next polls, then given up on (the song plays from where it is).
                let giveUp = ifStill(polled) { s -> Bool in s.pendingSeekTries += 1; if s.pendingSeekTries >= 5 { s.pendingSeek = nil; return true }; return false } ?? false
                if giveUp { emit(.notice(String(localized: "\(renderer.name) didn't seek (\((error as? UPnPError)?.message ?? error.localizedDescription)).", comment: "%1$@ is a network player's name, %2$@ the reason."))) }
            }
            return
        }
        // Told to play and still not playing: the renderer couldn't fetch or decode the song, and says nothing about it.
        if !current.announced, let since = state.withLock({ $0.wantsPlaying ? $0.awaitingStartSince : nil }),
           now().timeIntervalSince(since) >= startTimeout {
            let message = failureMessage(RendererPlaybackError.unplayable(String(localized: "it didn't start playing", comment: "The reason a network player couldn't play a song, inside “%1$@ couldn't play the song (%2$@).”: told to play, it never started. Lowercase, no full stop.")))
            // Failed only while its play is the current one, and in the same step: a song chosen meanwhile (queued behind
            // this poll) isn't left paused by the old song's failure, and the old song isn't reported as failed.
            guard let old = ifStill(polled, { s -> [Entry] in
                defer { s.current = nil; s.next = nil; s.staleNexts = []; s.anchor = nil; Self.markFailed(&s, message) }
                return [s.current, s.next].compactMap { $0 } + s.staleNexts
            }) else { return }
            old.forEach(release)
            try? await transport.stop()
            refreshActivity()
            emit(.failed(current.item, message))
            return
        }
        enum Outcome { case nothing, ended, stoppedThere }
        // Under the generation lock, as `play` and `stop()` change the snapshot: a play no longer current (a stop or a song
        // chosen is queued behind this poll) isn't shown, and its song stopped isn't taken for the chosen one paused.
        let outcome = generation.withLock { g -> Outcome in
            guard g == polled else { return .nothing }
            return state.withLock { s -> Outcome in
                let position = status.position + current.startOffset
                if let d = status.duration { s.snapshot.duration = d + current.startOffset }
                switch status.state {
                case .playing:
                    s.stoppedPolls = 0
                    let at = now()
                    if status.position >= 1 { s.reportsPosition = true }
                    // A long gap between two polls (the Mac slept, the renderer was slow to answer) isn't counted as heard.
                    if let last = s.lastPlayingPoll { s.heard += min(at.timeIntervalSince(last), 2) }
                    s.lastPlayingPoll = at
                    s.snapshot.position = position
                    s.anchor = (position, at)
                    if s.wantsPlaying { s.snapshot.state = .playing }
                case .paused:
                    s.stoppedPolls = 0
                    s.lastPlayingPoll = nil
                    s.snapshot.position = position
                    s.anchor = nil
                    s.snapshot.state = .paused
                case .transitioning:
                    // Buffering: the position waits with it.
                    s.anchor = nil
                    s.lastPlayingPoll = nil
                case .stopped, .noMedia:
                    s.anchor = nil
                    s.lastPlayingPoll = nil
                    guard current.announced, s.wantsPlaying else { break }
                    // Twice in a row: a renderer passes through "stopped" for a moment after a seek or between two songs.
                    s.stoppedPolls += 1
                    guard s.stoppedPolls >= 2 else { break }
                    s.stoppedPolls = 0
                    // At the song's end (or with no length to judge by) it played to the end. Anywhere else it was stopped
                    // on the renderer itself, or lost its stream (the Mac slept): the song stays where it is, paused.
                    let duration = s.snapshot.duration
                    let reached = s.reportsPosition ? s.snapshot.position : current.startOffset + s.heard
                    if duration <= 0 || reached >= duration - 10 { return .ended }
                    s.snapshot.state = .paused
                    s.wantsPlaying = false
                    return .stoppedThere
                }
                return .nothing
            }
        }
        switch outcome {
        case .nothing:
            break
        case .stoppedThere:
            refreshActivity()
        case .ended:
            // The renderer didn't go on by itself (it holds no next song, wasn't told in time, or doesn't join songs):
            // Vespertine starts the next one, and a song that can't be played fails there, as it does on the engine.
            // A stop or a song chosen while this poll waited for the player's answer wins.
            if let following = nextItemProvider?(current.item) {
                play(following, at: 0, announce: true, ifStill: polled)
            } else if endQueue(ifStill: polled) {
                emit(.queueEnded)
            }
        }
    }
}

public enum RendererPlaybackError: Error, LocalizedError {
    case unplayable(String)
    public var errorDescription: String? {
        switch self {
        case .unplayable(let reason): reason
        }
    }
}
