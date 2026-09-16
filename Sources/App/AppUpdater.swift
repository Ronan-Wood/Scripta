import AppKit
import Combine
import OSLog
import Sparkle

private let updaterLog = Logger(subsystem: "com.ronanwood.Scripta", category: "Updater")

/// In-app updates, over Sparkle.
///
/// THE FEED IS THE LATEST GITHUB RELEASE. `SUFeedURL` points at
/// `releases/latest/download/appcast.xml`, which GitHub redirects to whichever release is
/// currently marked Latest — so publishing a release IS publishing the feed, and there is no
/// branch, no Pages site and no second host to keep in step. The cost is that the appcast
/// describes ONE version: the newest, with its full dmg and whatever deltas were built for it.
///
/// WHAT MAKES AN UPDATE ACCEPTABLE is the EdDSA key and nothing else, and that takes two Info.plist
/// keys (in `project.yml`, with the reasoning). `SUVerifyUpdateBeforeExtraction` checks the
/// archive against `SUPublicEDKey` before anything is extracted — without it Sparkle falls back to
/// accepting an archive signed with this team's Developer ID when the EdDSA check fails.
/// `SURequireSignedFeed` puts the same key's signature on the appcast itself.
///
/// NOTHING IS CHECKED UNTIL THE OPERATOR AGREES. `SUEnableAutomaticChecks` is absent, so Sparkle
/// asks on the second launch; before that, the only request is one made from Check for Updates….
///
/// AN UPDATE SHOULD NOT CUT A RECORDING SHORT. Sparkle installs by quitting the app, and quitting
/// while a call is live STOPS the recording (`applicationShouldTerminate` → `finishBeforeTermination`)
/// — the rest of the call would simply not be captured. Three pieces guard that:
///   - the relaunch is held while a recording is starting, running, or producing its transcript;
///   - once released, `MenuController.startRecording` refuses to start one until the app quits, the
///     Sparkle session ends, or a grace period passes (`isQuittingToInstall`);
///   - a later install request in the same session — the retry Sparkle keeps after a declined quit,
///     which never consults the hold — is refused while a recording is live, aborting that install
///     instead (`updaterShouldRelaunchApplication`).
///
/// WHAT IS NOT GUARDED: an install Sparkle performs when the operator quits Scripta themselves. That
/// quit stops a recording by the operator's own choice, as any quit does. Every install the APP starts
/// passes both checks: Sparkle gives its installer the go-ahead from one place only
/// (`SPUInstallerDriver.installWithToolAndRelaunch`), and that path asks
/// `updaterShouldRelaunchApplication` and then the hold. Read in Sparkle 2.10.0's source.
@MainActor
final class AppUpdater: ObservableObject {
    static let shared = AppUpdater()

    /// The target of every "Check for Updates…" menu item. Sparkle validates the item itself —
    /// disabled while a check is already running or the updater has not started — which is why the
    /// items point at the controller and not at this class.
    let controller: SPUStandardUpdaterController

    /// Sparkle holds its delegate weakly; this is the strong reference.
    private let relaunchPolicy: RelaunchAfterRecording

    /// Mirrors `SPUUpdater.canCheckForUpdates` for SwiftUI, which cannot observe KVO directly.
    @Published private(set) var canCheckForUpdates = false
    private var observation: NSKeyValueObservation?
    private var sessionObservation: NSKeyValueObservation?

    private init() {
        let policy = RelaunchAfterRecording()
        relaunchPolicy = policy
        // Started explicitly from `applicationDidFinishLaunching` rather than on first access, so
        // when the updater begins is a line in the launch sequence, not a side effect of whichever
        // menu happens to be built first.
        controller = SPUStandardUpdaterController(startingUpdater: false,
                                                  updaterDelegate: policy, userDriverDelegate: nil)
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) {
            [weak self] updater, _ in
            let value = updater.canCheckForUpdates
            Task { @MainActor in self?.canCheckForUpdates = value }
        }
        // THE HOLD'S STATE BELONGS TO ONE SESSION, and it is cleared at BOTH edges: at the end, so an
        // install that aborts after the release leaves nothing behind, and at the start, so a session
        // can never inherit a release or a hold from one whose end was missed. Sparkle sets
        // `sessionInProgress` through its setter, so KVO sees both edges.
        sessionObservation = controller.updater.observe(\.sessionInProgress, options: [.new]) {
            updater, _ in
            let edge = updater.sessionInProgress
            // Sparkle writes this on the main thread, so the reset normally runs in the same turn. Off
            // the main thread it is deferred and runs only if the flag still reads the same, because a
            // reset landing after the next edge would wipe the state of the session that edge began.
            if Thread.isMainThread {
                MainActor.assumeIsolated { policy.resetForSessionBoundary() }
            } else {
                updaterLog.error("sessionInProgress changed off the main thread; deferring the reset")
                DispatchQueue.main.async {
                    guard updater.sessionInProgress == edge else { return }
                    MainActor.assumeIsolated { policy.resetForSessionBoundary() }
                }
            }
        }
    }

    /// The app is about to quit to install an update: a held relaunch was released, or Sparkle found
    /// nothing to hold. Cleared when that Sparkle session ends, and after a grace period, so a declined
    /// quit cannot refuse recordings indefinitely; a retried install after that is checked on its own.
    var isQuittingToInstall: Bool { relaunchPolicy.isReleased }

    /// Call once from `applicationDidFinishLaunching`.
    func start() {
        controller.startUpdater()
    }

    /// Sparkle keeps this in its own defaults key, so it is not mirrored in `AppSettings`. It is
    /// false until the operator answers Sparkle's second-launch question (or flips it in Settings).
    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    static let menuTitle = "Check for Updates…"
    static let menuAction = #selector(SPUStandardUpdaterController.checkForUpdates(_:))

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}

/// Holds Sparkle's relaunch while a recording is starting, running, or producing its transcript.
private final class RelaunchAfterRecording: NSObject, SPUUpdaterDelegate {
    private var waiting: AnyCancellable?

    /// When the relaunch was last allowed to proceed. Compared when read rather than cleared by a
    /// timer: the refusal simply stops applying once the grace period has passed.
    private var releasedAt: SuspendingClock.Instant?

    /// How long the recording refusal may outlive a release, on a clock that STOPS WHILE THE MAC
    /// SLEEPS, so a quit delayed across sleep does not find the refusal already expired. Sparkle's
    /// helper normally sends the quit within seconds. The margin is a trade: past it a declined quit
    /// stops blocking recordings, and a quit arriving later still would cut a call. Five minutes makes
    /// that second case need a stuck install rather than a slow one. A retry Sparkle keeps after a
    /// declined quit is checked separately, by `updaterShouldRelaunchApplication`.
    private static let quitGracePeriod: Duration = .seconds(300)

    /// This session has already been through the hold, which Sparkle consults only once per install.
    private var holdConsulted = false

    @MainActor var isReleased: Bool {
        guard let releasedAt else { return false }
        return SuspendingClock.now - releasedAt < Self.quitGracePeriod
    }

    @MainActor private func markReleased() {
        releasedAt = .now
    }

    /// A Sparkle session began or ended, so nothing from before it applies: drop any hold still
    /// waiting, and let recordings start again.
    @MainActor func resetForSessionBoundary() {
        waiting = nil
        releasedAt = nil
        holdConsulted = false
    }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        // Sparkle calls its delegate on the main thread.
        MainActor.assumeIsolated {
            waiting = nil
            releasedAt = nil
            holdConsulted = true
            guard Self.recordingIsBusy() else {
                markReleased()
                return false
            }
            releaseWhenIdle(installHandler)
            return true
        }
    }

    /// Sparkle asks this at the start of EVERY install request, ahead of the hold. The first request
    /// in a session is allowed, so the hold decides. A later one — the retry Sparkle keeps after a
    /// declined quit, which skips the hold — is refused while a recording is live, which aborts that
    /// install rather than quitting mid-call. Allowed, it re-arms the recording refusal.
    func updaterShouldRelaunchApplication(_ updater: SPUUpdater) -> Bool {
        MainActor.assumeIsolated {
            guard holdConsulted else { return true }
            guard !Self.recordingIsBusy() else {
                updaterLog.notice("refused a repeated install request while a recording is in progress")
                // SAID, because refusing aborts the install and Sparkle's window simply goes away.
                NotificationManager.shared.notifyUpdateNotInstalledDuringRecording()
                return false
            }
            markReleased()
            return true
        }
    }

    @MainActor private static func recordingIsBusy() -> Bool {
        let model = AppModel.shared
        return model.recordingState != .idle || model.isStartingRecording
    }

    /// `@Published` publishes from willSet, so an idle value is re-checked on the next run-loop turn,
    /// when both values are final. The check and the release share that main-thread turn, so no
    /// recording can start between them.
    @MainActor private func releaseWhenIdle(_ installHandler: @escaping () -> Void) {
        let model = AppModel.shared
        waiting = model.$recordingState.combineLatest(model.$isStartingRecording)
            .filter { state, starting in state == .idle && !starting }
            .first()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.waiting = nil
                    guard !Self.recordingIsBusy() else {
                        self.releaseWhenIdle(installHandler)
                        return
                    }
                    self.markReleased()
                    installHandler()
                }
            }
    }
}
