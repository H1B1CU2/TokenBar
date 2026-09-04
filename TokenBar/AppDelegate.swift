import AppKit
import SwiftUI
@preconcurrency import UserNotifications

private let limitResetNotificationPrefix = "TokenBar.limitReset."
private let lowLimitNotificationPrefix = "TokenBar.lowLimit."
private let earlyResetNotificationPrefix = "TokenBar.earlyReset."

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    nonisolated override init() { super.init() }

    private var statusItem: NSStatusItem!
    private var popover: GlassMenuPanel!
    private var settingsWindow: NSWindow?
    private var claudeSignInWindow: NSWindow?
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
        NSApp.setActivationPolicy(.accessory)
        installEditMenu()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = IconRenderer.placeholder()
        if #available(macOS 27.0, *) {
            // AppKit's own lifecycle for a status item that opens a window rather than
            // an NSMenu. It drives open and close, which buys keyboard navigation and
            // menu-bar tracking (drag across the menu bar, Escape) that a target/action
            // toggle cannot have. Setting an action as well would fight it: the click
            // would both begin a session and toggle the panel, closing it in the same
            // gesture that opened it.
            statusItem.expandedInterfaceDelegate = self
        } else if let btn = statusItem.button {
            btn.action = #selector(togglePopover)
            btn.target = self
            // Fire on mouse-down so the toggle runs in a fixed order relative to the
            // click monitors; on mouse-up a monitor could interleave between the two.
            btn.sendAction(on: [.leftMouseDown])
        }

        // Nothing closes this window by itself — no transient behaviour to fight —
        // so every close goes through the click monitors below. That is deliberate:
        // a self-closing popover dismissed itself on the status-item mouse-down
        // *before* the button action ran, so togglePopover saw isShown == false and
        // immediately reopened it, and the icon could never dismiss the menu.
        popover = GlassMenuPanel(
            rootView: MenuView(
                state: state,
                onRefresh: { [weak self] force in await self?.refresh(force: force) },
                onSettings: { [weak self] in self?.openSettings() },
                onClaudeSignIn: { [weak self] in self?.beginClaudeSignIn() }
            )
        )
        popover.onClose = { [weak self] in self?.popoverDidClose() }

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
        // Anchoring (menu-bar thickness, notch padding, multi-display clamping) lives
        // in the panel itself — see menuBarPopoverAnchor.
        popover.show(relativeTo: btn)
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
        popover.close()
        stopClickMonitor()
    }

    /// Dismissal requested by us rather than by AppKit. On macOS 27 the status item
    /// owns the session, so it has to be cancelled through the session — closing the
    /// window behind AppKit's back leaves the menu bar still tracking a dead item.
    private func endSession() {
        if #available(macOS 27.0, *), let session = statusItem.expandedInterfaceSession {
            session.cancel()
        } else {
            closePopover()
        }
    }

    // Nothing auto-closes an .applicationDefined popover, so we watch clicks
    // ourselves. The global monitor covers other apps / the desktop; the local one
    // covers our own windows (e.g. Settings sitting behind the popover), which a
    // global monitor never sees. A click on the status item itself is a dismissal too —
    // the icon has to toggle — but only when the popover is already open; closing on a
    // click that is about to *open* it is what recreates the reopen bug.
    private func startClickMonitor() {
        stopClickMonitor()
        clickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            guard let self else { return }
            if self.clickIsOnStatusItem() {
                // Second click on the icon closes what the first opened. AppKit's
                // expanded-interface session does not do this for us — it tracks the
                // menu bar, not the toggle — so the icon has to dismiss explicitly or
                // the menu can only ever be closed by clicking somewhere else.
                if self.popoverIsOpen { self.endSession() }
                return
            }
            self.endSession()
        }
        localClickMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self else { return event }
            if self.clickIsOnStatusItem() {
                if self.popoverIsOpen { self.endSession() }
            } else if event.window !== self.popover.window {
                self.endSession()
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
    private func popoverDidClose() {
        popoverClosedAt = Date()
        stopClickMonitor()
        // Every close path lands here, so this is the one place that has to drop the
        // poll back to the idle cadence.
        popoverIsOpen = false
        startPollTimer()
    }

    private func openSettings() {
        endSession()

        if let window = settingsWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hosting = NSHostingController(
            rootView: SettingsView(state: state, onLiveChange: { [weak self] in
                self?.applySettingsLive()
            })
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

    // MARK: - Claude sign-in

    /// Opens the authorize page and the window that takes the code back.
    ///
    /// One challenge per window: the PKCE verifier and state have to survive the trip
    /// to the browser, so they are captured here and handed to the view rather than
    /// regenerated when the user finally pastes.
    private func beginClaudeSignIn() {
        endSession()

        // Re-using a stale window would re-use its dead challenge with it.
        claudeSignInWindow?.close()
        claudeSignInWindow = nil

        let challenge = ClaudeScanner.beginLogin()
        NSWorkspace.shared.open(challenge.url)

        let hosting = NSHostingController(
            rootView: ClaudeSignInView(
                challenge: challenge,
                onSuccess: { [weak self] in
                    guard let self else { return }
                    self.closeClaudeSignIn()
                    // Force past the backoff: the user just fixed the thing the
                    // backoff exists to protect, and wants to see it clear now.
                    Task { await self.refresh(force: true) }
                },
                onCancel: { [weak self] in self?.closeClaudeSignIn() }
            )
        )
        let window = NSWindow(contentViewController: hosting)
        window.title = "Sign in to Claude"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        claudeSignInWindow = window

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func closeClaudeSignIn() {
        claudeSignInWindow?.close()
        claudeSignInWindow = nil
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

    // Last observed (percent, resetAt) per weekly window, keyed "providerID.windowID".
    // An early reset is only visible as a change BETWEEN polls, so the previous poll
    // has to be kept somewhere; persisted so a rollover that happened while the app
    // was quit is still caught on the next launch's first fetch.
    private var weeklyWindowSnapshots: [String: WeeklyWindowSnapshot] = AppDelegate.loadWeeklyWindowSnapshots() {
        didSet {
            guard let data = try? JSONEncoder().encode(weeklyWindowSnapshots) else { return }
            UserDefaults.standard.set(data, forKey: "weeklyWindowSnapshots")
        }
    }

    private static func loadWeeklyWindowSnapshots() -> [String: WeeklyWindowSnapshot] {
        guard let data = UserDefaults.standard.data(forKey: "weeklyWindowSnapshots"),
              let stored = try? JSONDecoder().decode([String: WeeklyWindowSnapshot].self, from: data)
        else { return [:] }
        return stored
    }

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
        detectEarlyLimitResets()
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

    // MARK: - Early-reset detection
    //
    // Providers sometimes hand back a weekly window before the reset time they were
    // advertising — a manual grant on their side. Nothing announces it, so the only
    // evidence is the shape of the change between two polls: usage FALLING while the
    // previously advertised reset was still in the future. Within a cycle usage only
    // ever climbs, so a drop has no innocent explanation.
    //
    // A forward jump in the advertised reset time is deliberately NOT evidence.
    // Antigravity re-anchors its weekly bucket to "now + 7 days" on every poll while
    // the bucket sits untouched, so its reset time drifts forward a few minutes at a
    // time — which read as an early reset on literally every refresh.
    //
    // Weekly windows only; a 5h session window legitimately re-anchors itself whenever
    // a new session starts, which would read as an early reset on every idle gap.

    private struct WeeklyWindowSnapshot: Codable {
        let percent: Double
        let resetAt: Date
    }

    // A drop this large can't be normal usage (usage only climbs within a cycle), and
    // is loose enough to survive the provider rounding its percentage.
    private static let earlyResetDropPoints: Double = 10
    private struct WeeklyWindow {
        let providerID: String
        let providerName: String
        let windowID: String
        let windowName: String
        let percent: Double
        let resetAt: Date

        var key: String { "\(providerID).\(windowID)" }
    }

    private func detectEarlyLimitResets() {
        let now = Date()
        let windows = currentWeeklyWindows()
        var fresh: [EarlyResetEvent] = []

        for window in windows {
            defer {
                weeklyWindowSnapshots[window.key] =
                    WeeklyWindowSnapshot(percent: window.percent, resetAt: window.resetAt)
            }

            guard let previous = weeklyWindowSnapshots[window.key] else { continue }
            // The old cycle was due to end already — this is the reset the provider
            // promised, not an early one.
            guard previous.resetAt > now else { continue }

            guard previous.percent - window.percent >= Self.earlyResetDropPoints else { continue }

            let event = EarlyResetEvent(
                providerID: window.providerID,
                providerName: window.providerName,
                windowID: window.windowID,
                windowName: window.windowName,
                expectedResetAt: previous.resetAt,
                detectedAt: now
            )
            // At most one live notice per window: a second early reset in the same
            // window supersedes the first rather than stacking beside it, which caps
            // the footer at one row per tracked window no matter what a provider does.
            guard !state.earlyResetEvents.contains(where: { $0.id == event.id }) else { continue }
            fresh.removeAll { $0.providerID == event.providerID && $0.windowID == event.windowID }
            fresh.append(event)
        }

        // Prune expired banners on every pass so the popover self-cleans even when
        // nothing new is detected.
        let superseded = Set(fresh.map { "\($0.providerID).\($0.windowID)" })
        let kept = state.earlyResetEvents.filter {
            $0.expiresAt > now && !superseded.contains("\($0.providerID).\($0.windowID)")
        }
        if kept.count != state.earlyResetEvents.count || !fresh.isEmpty {
            state.earlyResetEvents = kept + fresh
        }

        guard state.earlyResetNotificationsEnabled, !fresh.isEmpty else { return }
        Self.postEarlyResetNotifications(fresh)
    }

    private nonisolated static func postEarlyResetNotifications(_ events: [EarlyResetEvent]) {
        func send() {
            let center = UNUserNotificationCenter.current()
            let formatter = DateFormatter()
            formatter.dateStyle = .none
            formatter.timeStyle = .short

            for event in events {
                let content = UNMutableNotificationContent()
                content.title = "\(event.providerName) \(event.windowName) limit reset early"
                content.body = "It was not due until \(formatter.string(from: event.expectedResetAt)) — your quota is available again now."
                content.sound = .default
                let request = UNNotificationRequest(
                    identifier: "\(earlyResetNotificationPrefix)\(event.id)",
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

    private func currentWeeklyWindows() -> [WeeklyWindow] {
        var windows: [WeeklyWindow] = []

        func append(
            enabled: Bool,
            available: Bool,
            providerID: String,
            providerName: String,
            windowID: String,
            windowName: String,
            percent: Double,
            resetAt: Date?
        ) {
            // Without a reset time there is no "due" moment to call a reset early
            // against, and an unavailable provider reports 0% — which would look like
            // a full reset the moment it came back.
            guard enabled, available, let resetAt else { return }
            windows.append(
                WeeklyWindow(
                    providerID: providerID,
                    providerName: providerName,
                    windowID: windowID,
                    windowName: windowName,
                    percent: percent,
                    resetAt: resetAt
                )
            )
        }

        append(
            enabled: state.claudeEnabled,
            available: state.claudeAvailable,
            providerID: "claude",
            providerName: "Claude",
            windowID: "week",
            windowName: "weekly",
            percent: state.claudeWeekPercent,
            resetAt: state.claudeWeekResetAt
        )
        append(
            enabled: state.claudeEnabled,
            available: state.claudeAvailable && state.claudeFableWeekPercent != nil,
            providerID: "claude",
            providerName: "Claude Fable",
            windowID: "fable-week",
            windowName: "weekly",
            percent: state.claudeFableWeekPercent ?? 0,
            resetAt: state.claudeFableWeekResetAt
        )
        append(
            enabled: state.antigravityEnabled,
            available: state.antigravityAvailable,
            providerID: "antigravity-gemini",
            providerName: "Antigravity Gemini",
            windowID: "week",
            windowName: "weekly",
            percent: state.antigravityGeminiWeekPercent,
            resetAt: state.antigravityGeminiWeekResetAt
        )
        append(
            enabled: state.antigravityEnabled,
            available: state.antigravityAvailable,
            providerID: "antigravity-claude-gpt",
            providerName: "Antigravity Claude/GPT",
            windowID: "week",
            windowName: "weekly",
            percent: state.antigravityClaudeGptWeekPercent,
            resetAt: state.antigravityClaudeGptWeekResetAt
        )
        append(
            enabled: state.geminiEnabled,
            available: state.geminiAvailable,
            providerID: "gemini",
            providerName: "Gemini",
            windowID: "week",
            windowName: "weekly",
            percent: state.geminiWeekPercent,
            resetAt: state.geminiWeekResetAt
        )
        append(
            enabled: state.codexEnabled,
            available: state.codexAvailable,
            providerID: "codex",
            providerName: "Chat GPT",
            windowID: "week",
            windowName: "weekly",
            percent: state.codexWeekPercent,
            resetAt: state.codexWeekResetAt
        )

        return windows
    }

}

// ---------------------------------------------------------------------------
// macOS 27: AppKit owns the open/close lifecycle.
//
// The status item posts a session when the user activates it and ends that
// session when the menu bar decides the interface is done (Escape, a drag onto
// another status item, the app being hidden). Our job is only to put the window
// on screen and take it away again — the click monitors stay, because a click in
// another app is still ours to notice, but they now cancel the session rather
// than closing the window behind AppKit's back.
// ---------------------------------------------------------------------------

@available(macOS 27.0, *)
extension AppDelegate: NSStatusItemExpandedInterfaceDelegate {
    func statusItem(_ statusItem: NSStatusItem,
                    didBegin session: NSStatusItemExpandedInterfaceSession) {
        // The click that just dismissed the menu can also begin a fresh session —
        // the same reopen bug the pre-27 target/action toggle had, one layer up.
        // Anything this soon after a close is that echo, not a new request.
        if let popoverClosedAt, Date().timeIntervalSince(popoverClosedAt) < 0.15 {
            session.cancel()
            return
        }
        showPopover()
    }

    func statusItemDidEndExpandedInterfaceSession(_ statusItem: NSStatusItem, animated: Bool) {
        closePopover()
    }
}

// ===========================================================================
// The menu's own window.
//
// NSPopover's chrome on macOS 26+ is the *clear* Liquid Glass variant, which
// next to the system's own menus reads as barely-there — the desktop shows
// straight through it. Drawing the surface ourselves gets the regular glass
// (NSGlassEffectView), the same density MSG's menu-bar popovers use, with the
// body and arrow traced as one path so the arrow is part of the same sheet.
// Ported from MSG's HardwareStatusItem, deliberately by copy: the two apps
// share this look, not a module.
// ===========================================================================

// ---------------------------------------------------------------------------
// PopoverShellView — the popover's entire visual shell as one continuous
// piece: rounded body + arrow (HIG: "popover arrow"; AppKit internally calls
// it the anchor — see NSPopover's shouldHideAnchor) traced as a single
// outline, with one vibrancy layer and one hairline stroke. A real NSPopover
// draws this as one shape via its private _NSPopoverFrame; drawing the body
// and arrow as two separate pieces leaves the body's own top edge/stroke
// showing as a flat seam across the arrow's base, so both live on one path.
// ---------------------------------------------------------------------------

private final class PopoverShellView: NSView {
    private let effect = NSVisualEffectView()
    /// Solid stand-in for `effect`/`glassEffect` when the user has Reduce
    /// Transparency on — System Settings ▸ Accessibility ▸ Display.
    private let opaqueBacking = NSView()
    /// Liquid Glass surface (macOS 26+), swapped in for `effect` so the
    /// popover matches the system's own Clear/Tinted glass style instead of
    /// looking frozen in the pre-26 vibrancy look.
    private var glassEffect: NSView?
    private let maskLayer = CAShapeLayer()
    private let strokeLayer = CAShapeLayer()

    private let cornerRadius: CGFloat
    private let arrowWidth: CGFloat
    private let arrowHeight: CGFloat

    /// Horizontal center of the arrow, in this view's own bounds.
    var arrowCenterX: CGFloat {
        didSet { needsLayout = true }
    }

    init(cornerRadius: CGFloat, arrowWidth: CGFloat, arrowHeight: CGFloat) {
        self.cornerRadius = cornerRadius
        self.arrowWidth = arrowWidth
        self.arrowHeight = arrowHeight
        self.arrowCenterX = 0
        super.init(frame: .zero)
        wantsLayer = true

        effect.material = .fullScreenUI
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.autoresizingMask = [.width, .height]
        addSubview(effect)

        opaqueBacking.wantsLayer = true
        opaqueBacking.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        opaqueBacking.autoresizingMask = [.width, .height]
        opaqueBacking.isHidden = true
        addSubview(opaqueBacking)

        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = cornerRadius
            glass.wantsLayer = true
            glass.autoresizingMask = [.width, .height]
            glass.isHidden = true
            if #available(macOS 27.0, *) {
                // Glass that reacts to the pointer, the way the system's own menu-bar
                // surfaces do on 27. Purely a surface property — it does not make the
                // view eat clicks meant for the SwiftUI content above it.
                glass.effectIsInteractive = true
            }
            addSubview(glass)
            glassEffect = glass
        }

        strokeLayer.fillColor = NSColor.clear.cgColor
        strokeLayer.strokeColor = NSColor.white.withAlphaComponent(0.1).cgColor
        strokeLayer.lineWidth = 0.5
        layer?.addSublayer(strokeLayer)

        refreshAppearance()
        // Posted on the workspace's own centre, not NotificationCenter.default.
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(refreshAppearance),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    /// Re-reads Reduce Transparency and the system's Liquid Glass tint style
    /// (Clear/Tinted) and picks the matching surface. Reduce Transparency is
    /// pushed live via notification; the tint style has no public change
    /// notification, so callers also invoke this each time the popover opens.
    @objc func refreshAppearance() {
        let reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        opaqueBacking.isHidden = !reduceTransparency
        if #available(macOS 26.0, *), let glass = glassEffect as? NSGlassEffectView {
            glass.isHidden = reduceTransparency
            effect.isHidden = true
            glass.style = UserDefaults.standard.bool(forKey: "AppleReduceDesktopTinting") ? .clear : .regular
        } else {
            effect.isHidden = reduceTransparency
        }
        needsLayout = true
    }

    /// Whichever surface is currently visible — the one that owns the mask.
    private var activeSurfaceLayer: CALayer? {
        if !opaqueBacking.isHidden { return opaqueBacking.layer }
        if let glass = glassEffect, !glass.isHidden { return glass.layer }
        return effect.layer
    }

    override func layout() {
        super.layout()
        effect.frame = bounds
        opaqueBacking.frame = bounds
        glassEffect?.frame = bounds
        let path = Self.shellPath(size: bounds.size, radius: cornerRadius,
                                   arrowWidth: arrowWidth, arrowHeight: arrowHeight,
                                   arrowCenterX: arrowCenterX)
        // The window frame animation (popover resize) already interpolates
        // bounds smoothly; letting these layers pick up their own implicit
        // path animation on top of that makes the mask chase a moving
        // target and lag/wobble behind it. Snap them to the current bounds
        // every frame instead.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        maskLayer.path = path
        maskLayer.frame = bounds
        activeSurfaceLayer?.mask = maskLayer
        strokeLayer.path = path
        strokeLayer.frame = bounds
        CATransaction.commit()
    }

    /// Rounded-rect body with the arrow notch cut directly into its top
    /// edge, built from true circular corner arcs (never Apple's
    /// "continuous" squircle curve, which would leave an uneven gap against
    /// the real menu-bar/status-item chrome this popover sits under).
    private static func shellPath(size: CGSize, radius r: CGFloat,
                                   arrowWidth: CGFloat, arrowHeight: CGFloat,
                                   arrowCenterX: CGFloat) -> CGPath {
        let minX: CGFloat = 0, minY: CGFloat = 0, maxX = size.width
        let bodyTop = size.height - arrowHeight
        let arrowLeftX = arrowCenterX - arrowWidth / 2
        let arrowRightX = arrowCenterX + arrowWidth / 2
        // Soft anchor like the native popover: rounded apex, and concave
        // fillets where the arrow's slopes flare into the body's top edge.
        let tipRadius: CGFloat = 3.5
        let baseRadius: CGFloat = 2

        let path = CGMutablePath()
        path.move(to: CGPoint(x: minX + r, y: bodyTop))
        path.addArc(tangent1End: CGPoint(x: arrowLeftX, y: bodyTop),
                    tangent2End: CGPoint(x: arrowCenterX, y: size.height), radius: baseRadius)
        path.addArc(tangent1End: CGPoint(x: arrowCenterX, y: size.height),
                    tangent2End: CGPoint(x: arrowRightX, y: bodyTop), radius: tipRadius)
        path.addArc(tangent1End: CGPoint(x: arrowRightX, y: bodyTop),
                    tangent2End: CGPoint(x: maxX - r, y: bodyTop), radius: baseRadius)
        path.addLine(to: CGPoint(x: maxX - r, y: bodyTop))
        path.addArc(tangent1End: CGPoint(x: maxX, y: bodyTop),
                    tangent2End: CGPoint(x: maxX, y: bodyTop - r), radius: r)
        path.addLine(to: CGPoint(x: maxX, y: minY + r))
        path.addArc(tangent1End: CGPoint(x: maxX, y: minY),
                    tangent2End: CGPoint(x: maxX - r, y: minY), radius: r)
        path.addLine(to: CGPoint(x: minX + r, y: minY))
        path.addArc(tangent1End: CGPoint(x: minX, y: minY),
                    tangent2End: CGPoint(x: minX, y: minY + r), radius: r)
        path.addLine(to: CGPoint(x: minX, y: bodyTop - r))
        path.addArc(tangent1End: CGPoint(x: minX, y: bodyTop),
                    tangent2End: CGPoint(x: minX + r, y: bodyTop), radius: r)
        path.closeSubpath()
        return path
    }
}

/// Where a menu-bar popover's window should sit, given the status button it
/// hangs off. Shared by every popover in this file — the math is fiddly
/// (notch padding, off-screen menu bars, multi-display clamping) and two
/// hand-kept copies drift.
///
/// Returns the window origin plus the arrow's x within the shell, or nil when
/// the button has no host window: there is no anchor then, and a `.zero`
/// fallback would place the popover off the bottom-left of the display.
fileprivate func menuBarPopoverAnchor(
    button: NSStatusBarButton,
    windowSize: NSSize,
    popWidth: CGFloat,
    arrowWidth: CGFloat
) -> (origin: NSPoint, arrowCenterX: CGFloat)? {
    guard let buttonWindow = button.window else { return nil }
    let buttonRect = button.convert(button.bounds, to: nil)
    let screenRect = buttonWindow.convertToScreen(buttonRect)
    // The button's own bounds can be taller than the menu bar's visual
    // content (macOS pads status items to clear notch camera housing),
    // so anchor from the top edge minus the standard thickness instead
    // of the bottom edge — otherwise the popover floats well below the icon.
    let menuBarBottom = screenRect.maxY - NSStatusBar.system.thickness
    var origin = NSPoint(x: screenRect.midX - windowSize.width / 2,
                         y: menuBarBottom - windowSize.height - 4)

    // `screen` is nil while the host window sits off-screen (the menu bar
    // mid-reveal in a fullscreen space). Pick the display the button overlaps
    // most instead of the one containing its midpoint: mid-reveal slides the
    // rect off the top edge, so its center can leave every display's frame
    // while the rect itself still clearly belongs to one of them.
    let hostScreen = buttonWindow.screen
        ?? NSScreen.screens
            .filter { $0.frame.intersects(screenRect) }
            .max(by: { a, b in
                let ia = a.frame.intersection(screenRect), ib = b.frame.intersection(screenRect)
                return ia.width * ia.height < ib.width * ib.height
            })
        ?? NSScreen.main
        ?? NSScreen.screens.first

    if let screen = hostScreen {
        let vf = screen.visibleFrame
        if origin.x + windowSize.width > vf.maxX { origin.x = vf.maxX - windowSize.width - 4 }
        if origin.x < vf.minX { origin.x = vf.minX + 4 }
        // Hard clamp into the display. Anything above depends on the menu
        // bar's reported geometry, which is unreliable while it animates;
        // landing partly off-screen is recoverable, landing entirely off
        // it reads as "the popover doesn't open".
        //
        // Clamp order matters: the top bound is applied last, so a popover
        // taller than the display overflows off the *bottom* and keeps its
        // top edge — the arrow, and the first card — on screen.
        let full = screen.frame
        origin.y = min(max(origin.y, full.minY + 4), full.maxY - windowSize.height - 4)
    }

    // Point the arrow at the button's horizontal center, clamped clear
    // of the rounded corners.
    let minCenter = 16 + arrowWidth / 2
    let maxCenter = popWidth - 16 - arrowWidth / 2
    let wanted = screenRect.midX - origin.x
    return (origin, max(minCenter, min(maxCenter, wanted)))
}


/// NSHostingView that reports when SwiftUI's own idea of its size changes, so
/// the window can follow content that grows (a provider finishing a refresh,
/// a thread list appearing) the way NSPopover's sizingOptions used to.
private final class SizingHostingView<Content: View>: NSHostingView<Content> {
    var onSizeChange: (() -> Void)?

    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        DispatchQueue.main.async { [weak self] in self?.onSizeChange?() }
    }
}

@MainActor
final class GlassMenuPanel {
    /// Must match MenuView's own `.frame(width:)`.
    private let popWidth: CGFloat = 320
    private let shellRadius: CGFloat = 20
    private let arrowWidth: CGFloat = 16
    private let arrowHeight: CGFloat = 8

    private let panel: NSPanel
    private let root = NSView()
    private let shell: PopoverShellView
    private let hosting: SizingHostingView<MenuView>

    /// Called on every close path, whatever triggered it.
    var onClose: (() -> Void)?

    /// False the moment a close begins, not when the fade finishes — a click during
    /// the fade-out is a request to reopen, and the caller must not read the still-
    /// visible window as "already open" and swallow it.
    var isShown: Bool { panel.isVisible && !isClosing }
    private var isClosing = false

    // Asymmetric on purpose, and this is what the system does: a menu-bar window
    // appears instantly — it has to feel like it was already there under the cursor —
    // and only fades on the way out. Fading it in reads as lag, not polish.
    private static let fadeOutDuration: TimeInterval = 0.25
    /// The window clicks are matched against by the local click monitor.
    var window: NSWindow { panel }

    init(rootView: MenuView) {
        shell = PopoverShellView(cornerRadius: shellRadius,
                                 arrowWidth: arrowWidth,
                                 arrowHeight: arrowHeight)
        hosting = SizingHostingView(rootView: rootView)

        root.frame = NSRect(x: 0, y: 0, width: popWidth, height: 200)
        shell.frame = root.bounds
        shell.autoresizingMask = [.width, .height]
        root.addSubview(shell)

        hosting.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(hosting)
        // The arrow strip is the window's top edge; content starts below it.
        NSLayoutConstraint.activate([
            hosting.topAnchor.constraint(equalTo: root.topAnchor, constant: arrowHeight),
            hosting.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            hosting.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])

        panel = NSPanel(contentRect: root.frame,
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        panel.contentView = root
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isFloatingPanel = true
        // Key only when a control actually asks for it, so opening the menu never
        // steals focus from whatever the user was typing in.
        panel.becomesKeyOnlyIfNeeded = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary, .canJoinAllSpaces]
        panel.isReleasedWhenClosed = false

        hosting.onSizeChange = { [weak self] in self?.applyContentSize() }
    }

    func show(relativeTo button: NSStatusBarButton) {
        // Neither Reduce Transparency nor the Clear/Tinted tint style has a public
        // change notification for the latter, so re-read both on every open.
        shell.refreshAppearance()
        root.layoutSubtreeIfNeeded()
        panel.setContentSize(fittingSize)

        guard let anchor = menuBarPopoverAnchor(button: button,
                                                windowSize: panel.frame.size,
                                                popWidth: popWidth,
                                                arrowWidth: arrowWidth) else { return }
        shell.arrowCenterX = anchor.arrowCenterX
        shell.layoutSubtreeIfNeeded()
        panel.setFrameOrigin(anchor.origin)

        // No animation on the way in. alphaValue is set explicitly rather than assumed:
        // a show that lands mid-fade-out inherits whatever alpha the fade had reached.
        isClosing = false
        panel.alphaValue = 1
        panel.orderFrontRegardless()
    }

    func close() {
        guard panel.isVisible, !isClosing else { return }
        isClosing = true
        // State first, animation second: `onClose` stops the click monitors and stamps
        // the reopen guard, and neither may wait out a fade the user cannot see.
        onClose?()
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Self.fadeOutDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, self.isClosing else { return }   // a reopen beat the fade
            self.panel.orderOut(nil)
            self.panel.alphaValue = 1
            self.isClosing = false
        })
    }

    private var fittingSize: NSSize {
        NSSize(width: popWidth, height: ceil(hosting.fittingSize.height) + arrowHeight)
    }

    /// Grow or shrink around a fixed top edge — the arrow stays put under the
    /// status item while the content below it changes height.
    private func applyContentSize() {
        guard panel.isVisible else { return }
        let size = fittingSize
        guard size.height > arrowHeight, size != panel.frame.size else { return }
        var f = panel.frame
        f.origin.y = f.maxY - size.height
        f.size = size
        panel.setFrame(f, display: true)
    }
}
