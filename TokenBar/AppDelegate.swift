import AppKit
import SwiftUI
@preconcurrency import UserNotifications

private let limitResetNotificationPrefix = "TokenBar.limitReset."
private let lowLimitNotificationPrefix = "TokenBar.lowLimit."

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    nonisolated override init() { super.init() }

    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var settingsWindow: NSWindow?
    private var pollTimer: Timer?
    private var reducingTimer: Timer?
    private var clickMonitor: Any?
    private var localClickMonitor: Any?
    private var popoverClosedAt: Date?
    // Drives the poll cadence. Explicit rather than reading popover.isShown, which is
    // mid-transition inside the show/close paths that need to reschedule the timer.
    private var popoverIsOpen = false
    var state: AppState!

    func applicationDidFinishLaunching(_ notification: Notification) {
        state = AppState()
        popover = NSPopover()
        NSApp.setActivationPolicy(.accessory)
        installEditMenu()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let btn = statusItem.button {
            btn.image = IconRenderer.placeholder()
            btn.action = #selector(togglePopover)
            btn.target = self
            // Fire on mouse-down so the toggle runs in a fixed order relative to the
            // click monitors; on mouse-up a monitor could interleave between the two.
            btn.sendAction(on: [.leftMouseDown])
        }

        // .applicationDefined, not .transient: a transient popover closes itself on
        // the status-item mouse-down *before* the button action runs, so togglePopover
        // would see isShown == false and immediately reopen it — the icon could never
        // dismiss it. We own every close instead, via the click monitors below.
        popover.behavior = .applicationDefined
        popover.animates = false
        popover.delegate = self
        let vc = NSHostingController(
            rootView: MenuView(
                state: state,
                onRefresh: { [weak self] force in await self?.refresh(force: force) },
                onSettings: { [weak self] in self?.openSettings() }
            )
        )
        // Keep the popover sized to the SwiftUI content; without this the hosting
        // view can report a stale/ambiguous size and the popover draws clipped.
        vc.sizingOptions = .preferredContentSize
        popover.contentViewController = vc

        Task { await refresh() }
        startPollTimer()

        // Recover cleanly when the Mac wakes: the token may have expired during sleep
        // and several apps poll the shared OAuth token at once on wake (→ 429).
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(systemDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
    }

    @objc private func systemDidWake() {
        // Drop any stale rate-limit backoff from before sleep, re-arm a clean timer,
        // and refetch after a short delay so the network is back and we don't pile
        // onto the wake-time burst. The scan self-refreshes an expired token.
        claudeBackoffUntil = nil
        claudeRateLimitStreak = 0
        claudeLastScanAt = nil
        startPollTimer()
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            await self?.refresh(force: true)
        }
    }

    // Don't re-fetch on open if a poll just landed — otherwise rapid open/close
    // hammers the provider APIs.
    private static let popoverOpenRefreshStaleness: TimeInterval = 15

    // With the popover closed, the only consumer of a poll is the menu-bar icon, so
    // back off to the user's Idle Polling rate and top up when the popover opens.
    private var currentPollInterval: TimeInterval {
        popoverIsOpen ? state.refreshInterval.seconds : state.idleRefreshSeconds
    }

    // (Re)schedules the background poll at the cadence for the popover's current
    // state. Invalidating the old timer first is critical — otherwise a new one
    // stacks on it. Called on every open/close so the cadence follows the popover.
    private func startPollTimer() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: currentPollInterval,
                                         repeats: true) { [weak self] _ in
            Task { await self?.refresh() }
        }
    }

    @objc private func togglePopover() {
        if popover.isShown {
            closePopover()
            return
        }
        // Backstop for the reopen bug: if something already closed the popover for
        // *this* click (a monitor firing before the button action), the click was a
        // dismissal, not a request to open. Shorter than a double-click interval, so
        // a deliberate click-outside-then-click-icon still opens normally.
        if let closedAt = popoverClosedAt, Date().timeIntervalSince(closedAt) < 0.15 {
            return
        }
        showPopover()
    }

    private func showPopover() {
        guard let btn = statusItem.button else { return }
        popover.show(relativeTo: btn.bounds, of: btn, preferredEdge: .minY)
        // Default anchoring drops the popover a full content-height too low here,
        // so re-pin its top edge just beneath the menu bar from the button's real
        // screen frame. Vertical only — horizontal stays as the system anchored it,
        // keeping the arrow centered under the icon at any popover height.
        if let pwin = popover.contentViewController?.view.window,
           let btnWindow = btn.window {
            let onScreen = btnWindow.convertToScreen(btn.convert(btn.bounds, to: nil))
            var f = pwin.frame
            f.origin.y = onScreen.minY - f.height
            pwin.setFrame(f, display: true)
        }
        startClickMonitor()
        // Back to the full rate while the numbers are actually on screen, and top up
        // once immediately — the idle cadence may have left the data several minutes old.
        popoverIsOpen = true
        startPollTimer()
        let stale = state.lastRefreshed.map {
            Date().timeIntervalSince($0) >= Self.popoverOpenRefreshStaleness
        } ?? true
        if stale {
            Task { await refresh() }
        }
    }

    private func closePopover() {
        popover.performClose(nil)
        stopClickMonitor()
    }

    // Nothing auto-closes an .applicationDefined popover, so we watch clicks
    // ourselves. The global monitor covers other apps / the desktop; the local one
    // covers our own windows (e.g. Settings sitting behind the popover), which a
    // global monitor never sees. Both must ignore clicks on the status item — those
    // belong to togglePopover, and closing here first recreates the reopen bug.
    private func startClickMonitor() {
        stopClickMonitor()
        clickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            guard let self, !self.clickIsOnStatusItem() else { return }
            self.closePopover()
        }
        localClickMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self else { return event }
            if event.window !== self.popover.contentViewController?.view.window,
               !self.clickIsOnStatusItem() {
                self.closePopover()
            }
            return event
        }
    }

    // Hit-test the pointer against the status item's screen frame rather than
    // comparing event.window: a global monitor's events carry no window at all, so
    // identity checks can't recognise a status-item click and the monitor would
    // close the popover a moment before the button action reopens it.
    private func clickIsOnStatusItem() -> Bool {
        guard let btn = statusItem.button, let win = btn.window else { return false }
        return win.convertToScreen(btn.convert(btn.bounds, to: nil))
            .contains(NSEvent.mouseLocation)
    }

    private func stopClickMonitor() {
        if let monitor = clickMonitor {
            NSEvent.removeMonitor(monitor)
            clickMonitor = nil
        }
        if let monitor = localClickMonitor {
            NSEvent.removeMonitor(monitor)
            localClickMonitor = nil
        }
    }

    // Clean up the monitor however the popover closes (outside click, Settings, etc.),
    // and record when — togglePopover uses it to tell a genuine open from a reopen
    // triggered by the very click that just dismissed the popover.
    func popoverDidClose(_ notification: Notification) {
        popoverClosedAt = Date()
        stopClickMonitor()
        // Every close path lands here, so this is the one place that has to drop the
        // poll back to the idle cadence.
        popoverIsOpen = false
        startPollTimer()
    }

    private func openSettings() {
        closePopover()

        if let window = settingsWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hosting = NSHostingController(
            rootView: SettingsView(state: state, onLiveChange: { [weak self] in
                self?.applySettingsLive()
            })
            // Forced dark: the glass/gutter look is tuned against a dark chrome —
            // in light mode the sidebar vibrancy reads muddy and the hairline card
            // border disappears. Scoped to this window only, not the whole app.
            .preferredColorScheme(.dark)
        )
        let window = NSWindow(contentViewController: hosting)
        window.title = ""
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        // Non-opaque so the window's glass background (NSGlassEffectView on
        // macOS 26+, .behindWindow vibrancy before that) can show real desktop
        // blur through it. The floating content card blocks the see-through over
        // its own area via its own opaque fill, regardless of the window's opacity.
        window.isOpaque = false
        window.backgroundColor = .clear
        hosting.view.wantsLayer = true
        hosting.view.layer?.backgroundColor = .clear
        // Background dragging would steal mouse-downs from in-content drag gestures
        // (e.g. reordering provider rows). The window stays movable via the native
        // title-bar hit region at the top (still present under the traffic lights
        // thanks to .titled + fullSizeContentView) without that conflict.
        window.isMovableByWindowBackground = false
        window.contentMinSize = NSSize(width: 760, height: 560)
        window.setContentSize(NSSize(width: 1_040, height: 720))
        window.setFrameAutosaveName("TokenBarSettingsWindow")
        window.isReleasedWhenClosed = false
        window.center()
        settingsWindow = window

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // Settings apply live (no Save button): the moment any setting changes, redraw
    // the icon immediately for instant feedback, pick up a changed poll interval,
    // and refetch in the background.
    private func applySettingsLive() {
        renderIcon()
        startPollTimer()
        reconcileLimitResetNotifications()
        reconcileLowLimitNotifications()
        Task { await refresh() }
    }

    // An accessory (LSUIElement) app has no main menu, so keyboard shortcuts like
    // ⌘C/⌘V/⌘X/⌘A are never routed to the first responder. Install a minimal Edit
    // menu that wires those shortcuts to the standard responder actions.
    private func installEditMenu() {
        let mainMenu = NSMenu()

        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editItem.submenu = editMenu

        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        NSApp.mainMenu = mainMenu
    }

    // Claude usage-endpoint rate-limit guard (HTTP 429): coalesce bursts and back
    // off after a 429 so we stop hammering the endpoint, while keeping the last
    // good usage on screen.
    private var claudeBackoffUntil: Date?
    private var claudeRateLimitStreak = 0
    private var claudeLastScanAt: Date?

    // Identifiers ("providerID.windowID.resetAtEpoch") of low-limit notifications
    // already fired for the current reset cycle, so we notify once per dip below
    // threshold rather than on every poll while it stays low.
    private var lowLimitFiredIdentifiers: Set<String> = []

    func refresh(force: Bool = false) async {
        state.isLoading = true
        state.deepseekError = nil
        state.antigravityError = nil

        let apiKey = state.deepseekApiKey
        let claudeOn = state.claudeEnabled
        let deepseekOn = state.deepseekEnabled
        let antigravityOn = state.antigravityEnabled
        let geminiOn = state.geminiEnabled
        let codexOn = state.codexEnabled

        // Skip the usage call while backing off from a 429, or if we already fetched
        // a moment ago (coalesces window-toggle / settings / manual-refresh bursts).
        // A user-initiated (force) refresh ignores both gates so it always retries.
        let now = Date()
        let inBackoff = !force && (claudeBackoffUntil.map { now < $0 } ?? false)
        let scannedRecently = !force && (claudeLastScanAt.map { now.timeIntervalSince($0) < 20 } ?? false)
        let scanClaude = claudeOn && !inBackoff && !scannedRecently
        let scanAntigravity = antigravityOn

        // Run every enabled provider scan concurrently; a disabled provider yields
        // nil and its last-known state is left untouched below.
        async let claudeScan: ClaudeUsage? = scanClaude ? ClaudeScanner.scan() : nil
        async let deepseekScan: DeepSeekBalance? = deepseekOn ? DeepSeekClient.fetchBalance(apiKey: apiKey) : nil
        async let antigravityScan: AntigravityUsage? = scanAntigravity ? AntigravityScanner.scan() : nil
        async let geminiScan: GeminiWebUsage? = geminiOn ? GeminiScanner.scan() : nil
        async let codexScan: CodexUsage? = codexOn ? CodexScanner.scan() : nil

        let claudeOpt = await claudeScan
        let deepseek = await deepseekScan
        let antigravityOpt = await antigravityScan
        let geminiOpt = await geminiScan
        let codexOpt = await codexScan

        if let claude = claudeOpt {
            claudeLastScanAt = Date()
            applyClaude(claude)
        }
        // claudeOpt == nil (disabled / backing off / coalesced) → keep last usage.

        if deepseekOn {
            if let ds = deepseek {
                state.deepseekBalance = ds.balance
                state.deepseekCurrency = ds.currency
            } else if !state.deepseekApiKey.isEmpty {
                state.deepseekError = "Failed to fetch balance"
            }
        }

        if scanAntigravity {
            if let ag = antigravityOpt {
                state.antigravityAvailable = ag.available
                state.antigravityLatestThreads = ag.latestThreads
                state.antigravityGeminiWeeklyRemainingPercent = ag.gemini.weekly.remainingPercent
                state.antigravityGeminiWeeklyResetAt = ag.gemini.weekly.resetAt
                state.antigravityGeminiWeeklyDescription = ag.gemini.weekly.description
                state.antigravityGemini5hRemainingPercent = ag.gemini.fiveHour.remainingPercent
                state.antigravityGemini5hResetAt = ag.gemini.fiveHour.resetAt
                state.antigravityGemini5hDescription = ag.gemini.fiveHour.description
                
                state.antigravityClaudeGptWeeklyRemainingPercent = ag.claudeGpt.weekly.remainingPercent
                state.antigravityClaudeGptWeeklyResetAt = ag.claudeGpt.weekly.resetAt
                state.antigravityClaudeGptWeeklyDescription = ag.claudeGpt.weekly.description
                state.antigravityClaudeGpt5hRemainingPercent = ag.claudeGpt.fiveHour.remainingPercent
                state.antigravityClaudeGpt5hResetAt = ag.claudeGpt.fiveHour.resetAt
                state.antigravityClaudeGpt5hDescription = ag.claudeGpt.fiveHour.description
                
                state.antigravityError = ag.error
            } else {
                state.antigravityAvailable = false
                state.antigravityError = "Failed to scan Antigravity"
            }
        }

        if let gemini = geminiOpt {
            applyGemini(gemini)
        }

        if let codex = codexOpt {
            applyCodex(codex)
        }

        // Refresh the live THB rate when THB display is on; on failure the cached
        // rate is kept so the balance still converts.
        if deepseekOn, state.deepseekShowTHB, let ds = deepseek {
            if let rate = await FXClient.thbRate(from: ds.currency) {
                state.deepseekThbRateBase = ds.currency
                state.deepseekThbRate = rate
            }
        }

        // Update 7-day usage tracking
        let reduced = state.trackUsageUpdate(
            claudeSession: state.claudeAvailable ? state.claudeSessionPercent : nil,
            deepseekBalance: state.deepseekEnabled && state.deepseekError == nil ? state.deepseekBalance : nil,
            geminiWeeklyRemaining: state.antigravityAvailable ? state.antigravityGeminiWeeklyRemainingPercent : nil,
            claudeGptWeeklyRemaining: state.antigravityAvailable ? state.antigravityClaudeGptWeeklyRemainingPercent : nil,
            geminiWebSession: state.geminiAvailable ? state.geminiSessionPercent : nil
        )

        if reduced && state.showReductionIndicator {
            state.isReducing = true
            reducingTimer?.invalidate()
            reducingTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: false) { [weak self] _ in
                Task { @MainActor in
                    self?.state.isReducing = false
                    self?.renderIcon()
                }
            }
        }

        state.isLoading = false
        state.lastRefreshed = Date()
        reconcileLimitResetNotifications()
        reconcileLowLimitNotifications()
        renderIcon()
    }

    // Redraws the menu bar icon from current state (no network) — used for instant
    // feedback the moment a setting changes.
    private func renderIcon() {
        let image = IconRenderer.render(
            isReducing: state.isReducing && state.showReductionIndicator
        )
        statusItem.button?.image = image
    }

    // Folds a Claude scan result into state. Transient failures (429/5xx/network)
    // keep the last good usage and arm a backoff; only hard failures clear data.
    private func applyClaude(_ claude: ClaudeUsage) {
        // Latest threads come from local session files, independent of the usage API —
        // keep them current regardless of the API outcome.
        state.claudeLatestThreads = claude.latestThreads
        if claude.available {
            state.claudeAvailable = true
            state.claudeSessionPercent = claude.sessionPercent
            state.claudeSessionResetAt = claude.sessionResetAt
            state.claudeWeekPercent = claude.weekPercent
            state.claudeWeekResetAt = claude.weekResetAt
            state.claudeFableWeekPercent = claude.fableWeekPercent
            state.claudeFableWeekResetAt = claude.fableWeekResetAt
            state.claudeError = nil
            state.persistClaudeUsage()
            claudeBackoffUntil = nil
            claudeRateLimitStreak = 0
        } else if claude.transient {
            claudeRateLimitStreak += 1
            let step = min(claudeRateLimitStreak - 1, 5)             // 30, 60, 120, 240, 480, 900s
            // Back off further on sustained rate-limiting (up to 15 min) so TokenBar
            // stops re-polling every cycle and contributing to the shared-token limit
            // while an active Claude Code session is consuming the budget.
            let wait = claude.retryAfter ?? Double(min(30 * (1 << step), 900))
            claudeBackoffUntil = Date().addingTimeInterval(wait)
            // Keep the last usage on screen; only message when we have nothing to show.
            state.claudeError = state.claudeAvailable ? nil : "Rate limited — retrying shortly"
        } else {
            state.claudeAvailable = false
            state.claudeSessionPercent = 0
            state.claudeSessionResetAt = nil
            state.claudeWeekPercent = 0
            state.claudeWeekResetAt = nil
            state.claudeFableWeekPercent = nil
            state.claudeFableWeekResetAt = nil
            state.claudeError = claude.error
            state.clearPersistedClaudeUsage()
            claudeBackoffUntil = nil
            claudeRateLimitStreak = 0
        }
    }

    // Folds a Gemini scan result into state. A transient failure keeps the last good
    // usage on screen; a hard failure clears it and surfaces the error.
    private func applyGemini(_ gemini: GeminiWebUsage) {
        if gemini.available {
            state.geminiAvailable = true
            state.geminiSessionPercent = gemini.sessionPercent
            state.geminiSessionResetAt = gemini.sessionResetAt
            state.geminiWeekPercent = gemini.weekPercent
            state.geminiWeekResetAt = gemini.weekResetAt
            state.geminiError = nil
        } else if gemini.transient {
            // Keep the last usage on screen; only message when we have nothing to show.
            state.geminiError = state.geminiAvailable ? nil : gemini.error
        } else {
            state.geminiAvailable = false
            state.geminiSessionPercent = 0
            state.geminiSessionResetAt = nil
            state.geminiWeekPercent = 0
            state.geminiWeekResetAt = nil
            state.geminiError = gemini.error
        }
    }

    private func applyCodex(_ codex: CodexUsage) {
        if codex.available {
            state.codexAvailable = true
            state.codexTodayTokens = codex.todayTokens
            state.codexWeekTokens = codex.weekTokens
            state.codexLimitPercent = codex.limitPercent
            state.codexLimitResetAt = codex.limitResetAt
            state.codexIsLimited = codex.isLimited
            state.codexSessionPercent = codex.sessionPercent
            state.codexSessionResetAt = codex.sessionResetAt
            state.codexWeekPercent = codex.weekPercent
            state.codexWeekResetAt = codex.weekResetAt
            state.codexActiveThreadTitle = codex.activeThread?.title ?? ""
            state.codexActiveThreadTokens = codex.activeThread?.tokens ?? 0
            state.codexActiveThreadUpdatedAt = codex.activeThread?.updatedAt
            state.codexLatestThreads = codex.latestThreads
            state.codexHistory = codex.history
            state.codexError = nil
        } else {
            state.codexAvailable = false
            state.codexTodayTokens = 0
            state.codexWeekTokens = 0
            state.codexLimitPercent = 0
            state.codexLimitResetAt = nil
            state.codexIsLimited = false
            state.codexSessionPercent = 0
            state.codexSessionResetAt = nil
            state.codexWeekPercent = 0
            state.codexWeekResetAt = nil
            state.codexActiveThreadTitle = ""
            state.codexActiveThreadTokens = 0
            state.codexActiveThreadUpdatedAt = nil
            state.codexLatestThreads = []
            state.codexError = codex.error
        }
    }

    private struct LimitResetNotification {
        enum Kind: Hashable {
            case atReset
            case leadTime(minutes: Int)
        }

        let kind: Kind
        let providerID: String
        let providerName: String
        let windowID: String
        let windowName: String
        let resetAt: Date

        // When the notification should actually fire — the reset moment itself for
        // .atReset, or that many minutes earlier for .leadTime.
        var fireAt: Date {
            switch kind {
            case .atReset:
                return resetAt
            case .leadTime(let minutes):
                return resetAt.addingTimeInterval(-Double(minutes * 60))
            }
        }

        var identifier: String {
            let timestamp = Int(resetAt.timeIntervalSince1970)
            switch kind {
            case .atReset:
                return "\(limitResetNotificationPrefix)\(providerID).\(windowID).\(timestamp)"
            case .leadTime(let minutes):
                return "\(limitResetNotificationPrefix)\(providerID).\(windowID).lead\(minutes).\(timestamp)"
            }
        }

        var title: String {
            switch kind {
            case .atReset:
                return "\(providerName) \(windowName) limit reset"
            case .leadTime(let minutes):
                return "\(providerName) \(windowName) limit resets in \(minutes) min"
            }
        }

        var body: String {
            switch kind {
            case .atReset:
                return "Your \(providerName) \(windowName.lowercased()) limit should be available again."
            case .leadTime(let minutes):
                return "Your \(providerName) \(windowName.lowercased()) limit resets in \(minutes) minutes."
            }
        }
    }

    private func reconcileLimitResetNotifications() {
        guard state.limitResetNotificationsEnabled else {
            Self.removePendingLimitResetNotifications()
            return
        }

        let notifications = currentLimitResetNotifications()
        guard !notifications.isEmpty else {
            Self.removePendingLimitResetNotifications()
            return
        }

        UNUserNotificationCenter.current().getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                Self.syncPendingLimitResetNotifications(notifications)
            case .notDetermined:
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    guard granted else { return }
                    Self.syncPendingLimitResetNotifications(notifications)
                }
            case .denied:
                break
            @unknown default:
                break
            }
        }
    }

    private nonisolated static func syncPendingLimitResetNotifications(_ notifications: [LimitResetNotification]) {
        let center = UNUserNotificationCenter.current()
        center.getPendingNotificationRequests { requests in
            let desiredIDs = Set(notifications.map(\.identifier))
            let existingIDs = Set(
                requests
                    .map(\.identifier)
                    .filter { $0.hasPrefix(limitResetNotificationPrefix) }
            )
            let staleIDs = existingIDs.subtracting(desiredIDs)
            if !staleIDs.isEmpty {
                center.removePendingNotificationRequests(withIdentifiers: Array(staleIDs))
            }

            for notification in notifications where !existingIDs.contains(notification.identifier) {
                let interval = notification.fireAt.timeIntervalSinceNow
                guard interval > 1 else { continue }

                let content = UNMutableNotificationContent()
                content.title = notification.title
                content.body = notification.body
                content.sound = .default

                let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
                let request = UNNotificationRequest(
                    identifier: notification.identifier,
                    content: content,
                    trigger: trigger
                )
                center.add(request)
            }
        }
    }

    private nonisolated static func removePendingLimitResetNotifications() {
        let center = UNUserNotificationCenter.current()
        center.getPendingNotificationRequests { requests in
            let ids = requests
                .map(\.identifier)
                .filter { $0.hasPrefix(limitResetNotificationPrefix) }
            guard !ids.isEmpty else { return }
            center.removePendingNotificationRequests(withIdentifiers: ids)
        }
    }

    private func currentLimitResetNotifications() -> [LimitResetNotification] {
        let minimumLeadTime: TimeInterval = 5
        let now = Date()
        var notifications: [LimitResetNotification] = []

        let leadMinutes = state.limitResetLeadMinutes

        func append(
            enabled: Bool,
            available: Bool,
            providerID: String,
            providerName: String,
            windowID: String,
            windowName: String,
            resetAt: Date?
        ) {
            guard enabled, available, let resetAt else { return }

            if resetAt.timeIntervalSince(now) > minimumLeadTime {
                notifications.append(
                    LimitResetNotification(
                        kind: .atReset,
                        providerID: providerID,
                        providerName: providerName,
                        windowID: windowID,
                        windowName: windowName,
                        resetAt: resetAt
                    )
                )
            }

            for minutes in leadMinutes {
                let fireAt = resetAt.addingTimeInterval(-Double(minutes * 60))
                guard fireAt.timeIntervalSince(now) > minimumLeadTime else { continue }
                notifications.append(
                    LimitResetNotification(
                        kind: .leadTime(minutes: minutes),
                        providerID: providerID,
                        providerName: providerName,
                        windowID: windowID,
                        windowName: windowName,
                        resetAt: resetAt
                    )
                )
            }
        }

        append(
            enabled: state.claudeEnabled,
            available: state.claudeAvailable,
            providerID: "claude",
            providerName: "Claude",
            windowID: "session",
            windowName: "session",
            resetAt: state.claudeSessionResetAt
        )
        append(
            enabled: state.claudeEnabled,
            available: state.claudeAvailable,
            providerID: "claude",
            providerName: "Claude",
            windowID: "week",
            windowName: "weekly",
            resetAt: state.claudeWeekResetAt
        )
        append(
            enabled: state.antigravityEnabled,
            available: state.antigravityAvailable,
            providerID: "antigravity-gemini",
            providerName: "Antigravity Gemini",
            windowID: "session",
            windowName: "session",
            resetAt: state.antigravityGeminiSessionResetAt
        )
        append(
            enabled: state.antigravityEnabled,
            available: state.antigravityAvailable,
            providerID: "antigravity-gemini",
            providerName: "Antigravity Gemini",
            windowID: "week",
            windowName: "weekly",
            resetAt: state.antigravityGeminiWeekResetAt
        )
        append(
            enabled: state.antigravityEnabled,
            available: state.antigravityAvailable,
            providerID: "antigravity-claude-gpt",
            providerName: "Antigravity Claude/GPT",
            windowID: "session",
            windowName: "session",
            resetAt: state.antigravityClaudeGptSessionResetAt
        )
        append(
            enabled: state.antigravityEnabled,
            available: state.antigravityAvailable,
            providerID: "antigravity-claude-gpt",
            providerName: "Antigravity Claude/GPT",
            windowID: "week",
            windowName: "weekly",
            resetAt: state.antigravityClaudeGptWeekResetAt
        )
        append(
            enabled: state.geminiEnabled,
            available: state.geminiAvailable,
            providerID: "gemini",
            providerName: "Gemini",
            windowID: "session",
            windowName: "session",
            resetAt: state.geminiSessionResetAt
        )
        append(
            enabled: state.geminiEnabled,
            available: state.geminiAvailable,
            providerID: "gemini",
            providerName: "Gemini",
            windowID: "week",
            windowName: "weekly",
            resetAt: state.geminiWeekResetAt
        )
        append(
            enabled: state.codexEnabled,
            available: state.codexAvailable,
            providerID: "codex",
            providerName: "Chat GPT",
            windowID: "session",
            windowName: "session",
            resetAt: state.codexSessionResetAt
        )
        append(
            enabled: state.codexEnabled,
            available: state.codexAvailable,
            providerID: "codex",
            providerName: "Chat GPT",
            windowID: "week",
            windowName: "weekly",
            resetAt: state.codexWeekResetAt
        )

        return notifications
    }

    // MARK: - Low-limit notifications
    //
    // Unlike reset notifications (which fire at a known future clock time), a
    // "remaining < threshold" crossing depends on live usage and can only be
    // detected reactively — checked at the end of every refresh() and whenever
    // notification settings change live. Each qualifying window fires at most once
    // per reset cycle (tracked by an identifier keyed on that window's resetAt).

    private struct LowLimitNotification {
        let providerID: String
        let providerName: String
        let windowID: String
        let windowName: String
        let resetAt: Date
        let remainingPercent: Double

        var identifier: String {
            "\(lowLimitNotificationPrefix)\(providerID).\(windowID).\(Int(resetAt.timeIntervalSince1970))"
        }

        var title: String {
            "\(providerName) \(windowName) limit low"
        }

        var body: String {
            "Your \(providerName) \(windowName.lowercased()) limit has \(Int(remainingPercent.rounded()))% remaining."
        }
    }

    private func reconcileLowLimitNotifications() {
        guard state.lowLimitNotificationsEnabled else { return }

        let threshold = state.lowLimitThresholdPercent
        let now = Date()
        let candidates = currentLowLimitCandidates()

        let due = candidates.filter { candidate in
            candidate.remainingPercent <= threshold && !lowLimitFiredIdentifiers.contains(candidate.identifier)
        }

        // Prune fired identifiers whose reset cycle is well in the past so the set
        // doesn't grow unbounded across a long-running session.
        lowLimitFiredIdentifiers = Set(lowLimitFiredIdentifiers.filter { identifier in
            guard let epoch = Double(identifier.split(separator: ".").last ?? "") else { return false }
            return Date(timeIntervalSince1970: epoch) > now.addingTimeInterval(-86_400)
        })

        guard !due.isEmpty else { return }
        for candidate in due { lowLimitFiredIdentifiers.insert(candidate.identifier) }
        Self.postLowLimitNotifications(due)
    }

    private nonisolated static func postLowLimitNotifications(_ notifications: [LowLimitNotification]) {
        func send() {
            let center = UNUserNotificationCenter.current()
            for notification in notifications {
                let content = UNMutableNotificationContent()
                content.title = notification.title
                content.body = notification.body
                content.sound = .default
                let request = UNNotificationRequest(
                    identifier: notification.identifier,
                    content: content,
                    trigger: nil
                )
                center.add(request)
            }
        }

        UNUserNotificationCenter.current().getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                send()
            case .notDetermined:
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    guard granted else { return }
                    send()
                }
            case .denied:
                break
            @unknown default:
                break
            }
        }
    }

    private func currentLowLimitCandidates() -> [LowLimitNotification] {
        let now = Date()
        var candidates: [LowLimitNotification] = []

        func append(
            enabled: Bool,
            available: Bool,
            providerID: String,
            providerName: String,
            windowID: String,
            windowName: String,
            resetAt: Date?,
            remainingPercent: Double
        ) {
            // A resetAt in the future anchors the identifier to a specific cycle so
            // the same dip isn't renotified every poll; without one there's no cycle
            // boundary to key off, so skip rather than notify only once ever.
            guard enabled, available, let resetAt, resetAt > now else { return }
            candidates.append(
                LowLimitNotification(
                    providerID: providerID,
                    providerName: providerName,
                    windowID: windowID,
                    windowName: windowName,
                    resetAt: resetAt,
                    remainingPercent: remainingPercent
                )
            )
        }

        append(
            enabled: state.claudeEnabled,
            available: state.claudeAvailable,
            providerID: "claude",
            providerName: "Claude",
            windowID: "session",
            windowName: "session",
            resetAt: state.claudeSessionResetAt,
            remainingPercent: 100 - state.claudeSessionPercent
        )
        append(
            enabled: state.claudeEnabled,
            available: state.claudeAvailable,
            providerID: "claude",
            providerName: "Claude",
            windowID: "week",
            windowName: "weekly",
            resetAt: state.claudeWeekResetAt,
            remainingPercent: 100 - state.claudeWeekPercent
        )
        append(
            enabled: state.antigravityEnabled,
            available: state.antigravityAvailable,
            providerID: "antigravity-gemini",
            providerName: "Antigravity Gemini",
            windowID: "session",
            windowName: "session",
            resetAt: state.antigravityGeminiSessionResetAt,
            remainingPercent: state.antigravityGemini5hRemainingPercent
        )
        append(
            enabled: state.antigravityEnabled,
            available: state.antigravityAvailable,
            providerID: "antigravity-gemini",
            providerName: "Antigravity Gemini",
            windowID: "week",
            windowName: "weekly",
            resetAt: state.antigravityGeminiWeekResetAt,
            remainingPercent: state.antigravityGeminiWeeklyRemainingPercent
        )
        append(
            enabled: state.antigravityEnabled,
            available: state.antigravityAvailable,
            providerID: "antigravity-claude-gpt",
            providerName: "Antigravity Claude/GPT",
            windowID: "session",
            windowName: "session",
            resetAt: state.antigravityClaudeGptSessionResetAt,
            remainingPercent: state.antigravityClaudeGpt5hRemainingPercent
        )
        append(
            enabled: state.antigravityEnabled,
            available: state.antigravityAvailable,
            providerID: "antigravity-claude-gpt",
            providerName: "Antigravity Claude/GPT",
            windowID: "week",
            windowName: "weekly",
            resetAt: state.antigravityClaudeGptWeekResetAt,
            remainingPercent: state.antigravityClaudeGptWeeklyRemainingPercent
        )
        append(
            enabled: state.geminiEnabled,
            available: state.geminiAvailable,
            providerID: "gemini",
            providerName: "Gemini",
            windowID: "session",
            windowName: "session",
            resetAt: state.geminiSessionResetAt,
            remainingPercent: 100 - state.geminiSessionPercent
        )
        append(
            enabled: state.geminiEnabled,
            available: state.geminiAvailable,
            providerID: "gemini",
            providerName: "Gemini",
            windowID: "week",
            windowName: "weekly",
            resetAt: state.geminiWeekResetAt,
            remainingPercent: 100 - state.geminiWeekPercent
        )
        append(
            enabled: state.codexEnabled,
            available: state.codexAvailable,
            providerID: "codex",
            providerName: "Chat GPT",
            windowID: "session",
            windowName: "session",
            resetAt: state.codexSessionResetAt,
            remainingPercent: 100 - state.codexSessionPercent
        )
        append(
            enabled: state.codexEnabled,
            available: state.codexAvailable,
            providerID: "codex",
            providerName: "Chat GPT",
            windowID: "week",
            windowName: "weekly",
            resetAt: state.codexWeekResetAt,
            remainingPercent: 100 - state.codexWeekPercent
        )

        return candidates
    }

}
