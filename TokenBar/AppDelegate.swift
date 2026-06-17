import AppKit
import SwiftUI


@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    nonisolated override init() { super.init() }

    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var settingsWindow: NSWindow?
    private var pollTimer: Timer?
    private var reducingTimer: Timer?
    private var clickMonitor: Any?
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
        }

        popover.behavior = .transient
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

    // (Re)schedules the background poll at the user's chosen interval. Invalidating
    // the old timer first is critical — otherwise a new one stacks on it.
    private func startPollTimer() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: state.refreshInterval.seconds,
                                         repeats: true) { [weak self] _ in
            Task { await self?.refresh() }
        }
    }

    @objc private func togglePopover() {
        if popover.isShown {
            closePopover()
        } else {
            showPopover()
        }
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
    }

    private func closePopover() {
        popover.performClose(nil)
        stopClickMonitor()
    }

    // .transient doesn't reliably close the popover on an outside click for an
    // accessory app (its window never becomes key), so watch for mouse-downs in
    // other apps / the desktop and close it. Clicks on our own status item or inside
    // the popover are this app's own events, which a global monitor ignores.
    private func startClickMonitor() {
        stopClickMonitor()
        clickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            self?.closePopover()
        }
    }

    private func stopClickMonitor() {
        if let monitor = clickMonitor {
            NSEvent.removeMonitor(monitor)
            clickMonitor = nil
        }
    }

    // Clean up the monitor however the popover closes (outside click, Settings, etc.).
    func popoverDidClose(_ notification: Notification) {
        stopClickMonitor()
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
        )
        let window = NSWindow(contentViewController: hosting)
        window.title = "TokenBar Settings"
        window.styleMask = [.titled, .closable]
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

    func refresh(force: Bool = false) async {
        state.isLoading = true
        state.deepseekError = nil
        state.antigravityError = nil

        let apiKey = state.deepseekApiKey
        let claudeOn = state.claudeEnabled
        let deepseekOn = state.deepseekEnabled
        let antigravityOn = state.antigravityEnabled

        // Skip the usage call while backing off from a 429, or if we already fetched
        // a moment ago (coalesces window-toggle / settings / manual-refresh bursts).
        // A user-initiated (force) refresh ignores both gates so it always retries.
        let now = Date()
        let inBackoff = !force && (claudeBackoffUntil.map { now < $0 } ?? false)
        let scannedRecently = !force && (claudeLastScanAt.map { now.timeIntervalSince($0) < 20 } ?? false)
        let scanClaude = claudeOn && !inBackoff && !scannedRecently
        let scanAntigravity = antigravityOn

        var claudeOpt: ClaudeUsage?
        var deepseek: DeepSeekBalance?
        var antigravityOpt: AntigravityUsage?

        // We can run all enabled scans in parallel using async let
        if scanClaude && deepseekOn && scanAntigravity {
            async let c = ClaudeScanner.scan()
            async let d = DeepSeekClient.fetchBalance(apiKey: apiKey)
            async let a = AntigravityScanner.scan()
            claudeOpt = await c
            deepseek = await d
            antigravityOpt = await a
        } else if scanClaude && deepseekOn {
            async let c = ClaudeScanner.scan()
            async let d = DeepSeekClient.fetchBalance(apiKey: apiKey)
            claudeOpt = await c
            deepseek = await d
        } else if scanClaude && scanAntigravity {
            async let c = ClaudeScanner.scan()
            async let a = AntigravityScanner.scan()
            claudeOpt = await c
            antigravityOpt = await a
        } else if deepseekOn && scanAntigravity {
            async let d = DeepSeekClient.fetchBalance(apiKey: apiKey)
            async let a = AntigravityScanner.scan()
            deepseek = await d
            antigravityOpt = await a
        } else if scanClaude {
            claudeOpt = await ClaudeScanner.scan()
        } else if deepseekOn {
            deepseek = await DeepSeekClient.fetchBalance(apiKey: apiKey)
        } else if scanAntigravity {
            antigravityOpt = await AntigravityScanner.scan()
        }

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
            claudeGptWeeklyRemaining: state.antigravityAvailable ? state.antigravityClaudeGptWeeklyRemainingPercent : nil
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
        if claude.available {
            state.claudeAvailable = true
            state.claudeSessionPercent = claude.sessionPercent
            state.claudeSessionResetAt = claude.sessionResetAt
            state.claudeWeekPercent = claude.weekPercent
            state.claudeWeekResetAt = claude.weekResetAt
            state.claudeError = nil
            state.persistClaudeUsage()
            claudeBackoffUntil = nil
            claudeRateLimitStreak = 0
        } else if claude.transient {
            claudeRateLimitStreak += 1
            let step = min(claudeRateLimitStreak - 1, 4)             // 30, 60, 120, 240, 480s
            let wait = claude.retryAfter ?? Double(min(30 * (1 << step), 600))
            claudeBackoffUntil = Date().addingTimeInterval(wait)
            // Keep the last usage on screen; only message when we have nothing to show.
            state.claudeError = state.claudeAvailable ? nil : "Rate limited — retrying shortly"
        } else {
            state.claudeAvailable = false
            state.claudeSessionPercent = 0
            state.claudeSessionResetAt = nil
            state.claudeWeekPercent = 0
            state.claudeWeekResetAt = nil
            state.claudeError = claude.error
            state.clearPersistedClaudeUsage()
            claudeBackoffUntil = nil
            claudeRateLimitStreak = 0
        }
    }

}
