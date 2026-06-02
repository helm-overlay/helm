import Foundation
import UserNotifications
import HelmCore

/// Posts a macOS notification when a watched session crosses into an attention state
/// (done / needs-input) while the overlay is dismissed. Fed by AppDelegate's always-on
/// poll; the transition detection itself is `HelmCore.NotificationPlanner` (pure, tested).
///
/// Design notes:
/// - Notifications fire **only while the panel is closed** — when you're already looking at
///   the LIVE rail a banner is just noise. While visible we still advance the baseline so a
///   completion the moment you dismiss doesn't replay a backlog.
/// - The **first** reconcile primes the baseline silently, so launching Helm next to a pile
///   of already-finished sessions doesn't fire a burst.
/// - Banner identity is per session (`notificationId`), so a newer state for the same
///   session replaces its banner rather than stacking; banners thread by project.
@MainActor
final class SessionNotifier: NSObject, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()
    private let onResume: (_ sessionId: String, _ agent: AgentKind, _ cwd: String?) -> Void

    /// Last attention verdict we saw per session id — the planner's carry-forward state.
    private var baseline: [String: IdleReason] = [:]
    private var primed = false

    private static let category = "HELM_ATTENTION"
    private static let resumeAction = "HELM_RESUME"

    init(onResume: @escaping (_ sessionId: String, _ agent: AgentKind, _ cwd: String?) -> Void) {
        self.onResume = onResume
        super.init()
        center.delegate = self
        let resume = UNNotificationAction(identifier: Self.resumeAction, title: "Resume",
                                          options: [.foreground])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.category, actions: [resume],
                                   intentIdentifiers: [], options: [])
        ])
    }

    /// Ask once; the OS remembers the grant. No-op effect if the user declined — posts are
    /// simply dropped by the system.
    func requestAuthorization() {
        center.requestAuthorization(options: [.alert, .sound]) { _, error in
            if let error { NSLog("Helm: notification authorization failed: \(error)") }
        }
    }

    /// Diff `rows` against the baseline and post for fresh attention crossings. `panelVisible`
    /// gates posting (not baseline tracking) so banners never compete with the open overlay.
    func reconcile(_ rows: [ChatSession], panelVisible: Bool) {
        guard HelmConfig.load().notificationsEnabled else { return }
        let (notifications, state) = NotificationPlanner.plan(previous: baseline, rows: rows)
        baseline = state
        guard primed else { primed = true; return }   // first pass primes silently
        guard !panelVisible else { return }            // you're already looking
        notifications.forEach(post)
    }

    private func post(_ n: SessionNotification) {
        let content = UNMutableNotificationContent()
        content.title = "\(emoji(for: n.reason)) \(n.label)"
        content.subtitle = "\(n.project) · \(verb(for: n.reason))"
        content.body = n.summary ?? defaultBody(for: n.reason)
        content.threadIdentifier = n.project
        content.categoryIdentifier = Self.category
        content.userInfo = ["sessionId": n.sessionId, "agent": n.agent.rawValue, "cwd": n.cwd]
        content.sound = .default
        // `.active`, not `.timeSensitive`: time-sensitive requires the
        // `usernotifications.time-sensitive` entitlement + signing, which a local build
        // can't carry — and without it the system silently DROPS the notification. The
        // needs-input vs done distinction is carried by the emoji/title instead.
        content.interruptionLevel = .active

        center.add(UNNotificationRequest(identifier: n.notificationId, content: content, trigger: nil)) { error in
            if let error { NSLog("Helm: failed to post notification: \(error)") }
        }
    }

    private func emoji(for reason: IdleReason) -> String {
        reason == .needsInput ? "🟡" : "🟣"
    }

    private func verb(for reason: IdleReason) -> String {
        reason == .needsInput ? "needs you" : "done"
    }

    private func defaultBody(for reason: IdleReason) -> String {
        reason == .needsInput ? "Waiting for your input." : "Finished — ready for review."
    }

    // MARK: UNUserNotificationCenterDelegate

    /// Tapping the banner (or its Resume action) jumps back into the session.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let sessionId = info["sessionId"] as? String
        let agent = (info["agent"] as? String).flatMap(AgentKind.init(rawValue:)) ?? .claude
        let cwd = info["cwd"] as? String
        if response.actionIdentifier == Self.resumeAction
            || response.actionIdentifier == UNNotificationDefaultActionIdentifier,
           let sessionId {
            MainActor.assumeIsolated { self.onResume(sessionId, agent, cwd) }
        }
        completionHandler()
    }

    /// Show the banner even on the rare occasion Helm is the frontmost app.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
