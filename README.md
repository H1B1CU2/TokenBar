# TokenBar

**Your AI usage, always in sight — never in the way.**

TokenBar is a native macOS menu bar application that brings real-time visibility to your AI provider token usage, API balances, and remaining quotas. Track your spending and limits for Claude, DeepSeek, and Antigravity from a single, elegantly designed popover — all while keeping your menu bar refined and clutter-free.

<p align="center">
  <img src="assets/popover_screenshot.png" width="320" alt="TokenBar Popover Screenshot">
</p>

---

## Why TokenBar

Modern development increasingly runs on metered AI services, yet usage and balances remain buried behind dashboards, logins, and disparate provider portals. TokenBar consolidates that information into one purpose-built surface — instant, glanceable, and engineered for the people who depend on these tools every day.

- **Always current.** Background polling keeps your figures live without interrupting your workflow.
- **Genuinely native.** Built in SwiftUI for macOS, with the performance and polish you expect from a first-class Mac application.
- **Privacy-first.** Credentials never leave your machine; sensitive keys are stored exclusively in the macOS Keychain.

---

## Features

### Minimalist Menu Bar Icon
- Presents a single, refined **brain glyph** in the macOS menu bar — designed to inform without adding clutter.
- Includes a subtle **reduction indicator** in the upper-right corner when token reduction or optimization is active.
- Dynamically trims transparent boundaries so the menu item sits perfectly flush within the menu bar.

### Multi-Provider Tracking
- **Claude (Anthropic API):** Monitor official session and weekly utilization limits, with your active quota window presented in a metrics card. Also tracks **Latest Threads** from local Claude Code session files with real-time status indicators (e.g., coding, done, idle).
- **Codex:** Summarize local Codex thread token usage for today and the last 7 days. Also monitors your **Latest Threads** read from your local Codex database with status indicators.
- **DeepSeek:** Track your platform API balance (USD/CNY), see the live Peak or Off-Peak billing period and next rate change, and reference current V4 Flash/Pro pricing — with optional live conversion to Thai Baht (฿) using European Central Bank reference rates via the Frankfurter API.
- **Antigravity:** Follow remaining quotas and reset times across Gemini, Claude, and GPT models.

### Latest Threads Tracking
- **Real-Time Status Monitoring:** Automatically watches active development threads for Claude and Codex, displaying the latest thread titles and active status directly in their respective cards.
- **Dynamic Coding Indicators:** Shows visual status dots (orange for active coding sessions, green for completed runs, and secondary color for idle threads) so you always know which sessions are currently drawing tokens.

### Side-by-Side Multi-Column Layout
- Enable **Side-by-Side** views for the Claude and Antigravity sections to display Session and Weekly limits in parallel columns.
- Maximizes vertical efficiency and presents your metrics together, separated by clean vertical dividers.

### Interactive 7-Day Usage Graphs
- Visualizes daily token consumption for each active provider.
- **Current-day highlighting** automatically emphasizes today's weekday label for immediate context.
- Configurable **first day of week** (Sunday or Monday) to match your calendar.
- **Fused graphs** combine multiple model tracks (for example, Gemini alongside Claude and GPT in Antigravity) into a single unified chart.
- Switch between a shared global scale or independently auto-scaled peaks.

### Thoughtful Customization
- **Remaining mode:** Display remaining quotas and balances instead of used values, globally.
- **Provider ordering:** Drag to arrange providers in the order that suits you.
- **Polling intervals:** Choose your background refresh cadence — 30 seconds, 1, 2, or 5 minutes.

### Secure by Design, Native Throughout
- **Keychain integration:** Sensitive credentials, such as your DeepSeek API key, are stored locally and securely in the macOS Keychain.
- **Native SVG arc rendering:** Parses and draws custom SVG paths directly in SwiftUI, including robust approximation of elliptical arcs (`A`/`a` commands) via cubic Bézier curves, for pixel-perfect provider icons.

---

## Getting Started

### Requirements
- **macOS** 14.0 (Sonoma) or newer, on Apple Silicon
- **Xcode** 15.0 or newer (to build from source)
- **Swift** 5.9 or newer

### Installation

1. **Clone the repository:**
   ```bash
   git clone https://github.com/H1B1CU2/TokenBar.git
   cd TokenBar
   ```

2. **Open the project in Xcode:**
   ```bash
   open TokenBar.xcodeproj
   ```

3. **Build and run:**
   - Select the `TokenBar` scheme.
   - Choose your Mac as the run destination.
   - Press `⌘R` to build and launch.

---

## Configuration

### Claude
TokenBar reads your official Claude usage through your Claude Code access token, resolved automatically from the macOS Keychain or your local credentials file. The token is refreshed transparently as needed — no manual setup required.

### DeepSeek
Enter your DeepSeek API key (`sk-...`) in the **DeepSeek** tab of Settings. Your balance can optionally be converted to Thai Baht (฿) using live reference rates. TokenBar also shows DeepSeek's current Peak/Off-Peak billing period, next local-time transition, and the official V4 Flash/Pro input and output rates per million tokens.

### Antigravity
Connects to your local Antigravity instance on its default ports to query session and weekly limits for Gemini, Claude, and GPT models.

### Codex
Reads local thread token totals from `~/.codex/state_5.sqlite` and limit/reset lockout messages from local Codex logs. No API key or network request is required.

---

## License

TokenBar is released under the MIT License.
