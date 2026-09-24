# UsageBar

A native macOS menu bar app that tracks your AI coding-agent quotas in one place:
**Claude Code**, **OpenAI Codex**, **Cursor**, **OpenCode**, plus experimental **Gemini CLI** and **Antigravity** support.

- Color-coded 5h / 7d / monthly bars with live countdown timers to the next reset
- Pace projection ("will I run out before the reset?") with Healthy / Risky / Over verdicts
- Extra-usage (overage) tracking for Claude and Cursor on-demand spend
- White menu bar icon by default in every theme; optional usage text with pace indicators
- Service health chips from each vendor's status page
- Notifications when you cross 75 / 90 / 100 % and when a window resets
- Dashboard with a limit-usage trend chart and a GitHub-style activity heatmap built from your local session logs
- Live sessions: recent activity and individually identified running sessions, with structured Claude/Codex metadata and 15-second local refreshes
- Backs off automatically when a vendor rate-limits the usage endpoint, keeping the last good numbers on screen
- Disable Sleep control in both popup sizes and Settings, backed by `pmset -b disablesleep 1` / `0`
- Codex banked reset counts, including the number currently applicable
- Direct Dashboard button and a fixed-size popup with scrolling content; History, Analysis and Settings live in the dashboard sidebar
- Usage & effort analysis across a custom 1–120 day range: tokens per assistant turn, model/effort groups, editable API cost estimates and monthly subscription allocation
- Launch at login and configurable refresh interval
- Everything stays on your Mac: no accounts, no telemetry, no servers of ours

## Install a release

Download the latest DMG from [Releases](https://github.com/kubilayege/UsageBar/releases), open it and drag UsageBar to Applications. Builds are ad-hoc signed and not notarized: on first launch right-click → Open, or run `xattr -d com.apple.quarantine /Applications/UsageBar.app`.

Starting with **1.3.0**, UsageBar uses [Sparkle](https://sparkle-project.org/) for in-app updates. It checks once a day (toggle in **Settings → Updates**) and shows an **Update** chip in the popup when a newer version exists. **Check for Updates…** opens Sparkle's dialog, which downloads the signed update, verifies it, and offers to install and restart UsageBar. The feed is a public release asset, so update checks do not use GitHub's REST API quota. Only a published release with a higher version triggers an update; workflow artifacts alone do not.

**Upgrading from 1.2.x:** install 1.3.0 from the DMG once to get the new updater. Subsequent updates can be installed inside the app. The updater downloads a full app archive; binary delta patches are not currently generated. Your settings and usage history remain in place.

## Requirements

- macOS 14 Sonoma or newer
- Xcode Command Line Tools (`xcode-select --install`) — full Xcode is not required

## Build & run

App bundles and DMGs are built by the GitHub Actions **Build** workflow. Use its artifact download for an unpublished build, or download a published release. Do not install or replace UsageBar on the development machine.

For development:

```sh
swift build && .build/debug/UsageBar          # run without a bundle (no notifications / launch-at-login)
.build/debug/UsageBar --probe                 # fetch every provider once and print the result
.build/debug/UsageBar --probe --no-activity   # same, skipping the local log scan
make preview                                  # render the popover and dashboard to PNG with demo data
```

The shared app artwork is [`Sources/UsageBar/Resources/AppLogo.png`](Sources/UsageBar/Resources/AppLogo.png). SwiftPM includes it for development; the workflow embeds it in the bundle and generates the full macOS `AppIcon.icns` size set. The popup, dashboard, and Settings use the same logo, with a simplified white mark in the menu bar. The generation prompt is recorded in [`docs/branding/app-logo.md`](docs/branding/app-logo.md).

Click **Dashboard** in the popup to open Overview, then use the sidebar for History, Analysis and Settings. **⌘,** and the menu bar icon’s right-click menu open Settings in that same window; **Usage → Analyze Usage & Effort…** opens the Analysis page. **Open Dashboard** is also available in the menu bar icon’s right-click menu and the **Usage** menu (**⇧⌘D**). Reopening UsageBar returns to the dashboard overview.

## How each provider is read

| Provider | Credential source | Endpoint |
| --- | --- | --- |
| Claude Code | `Claude Code-credentials` item in the login keychain (fallback `~/.claude/.credentials.json`) | `api.anthropic.com/api/oauth/usage` — 5h, 7d, per-model 7d, extra usage |
| Codex | `~/.codex/auth.json` (ChatGPT sign-in) | `chatgpt.com/backend-api/wham/usage` — primary/secondary windows, plan, credits |
| Cursor | session token from `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb` | `cursor.com/api/usage-summary` — plan spend, billing cycle, on-demand |
| OpenCode | `~/.local/share/opencode/opencode.db` (local only) | none — tokens and cost per day / 7d / month. Set a daily token budget in Settings to get a bar |
| Gemini CLI (beta) | `~/.gemini/oauth_creds.json` | `cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota` |
| Antigravity (beta) | running Antigravity language server (discovered via `ps` + `lsof`) | local `GetUserStatus` RPC |

The first time UsageBar reads the Claude keychain item macOS may ask you to allow access — choose **Always Allow**.

Gemini and Antigravity are implemented from public knowledge of those tools but were not verified against a signed-in install; expect rough edges. Refreshing an expired Gemini token needs the Gemini CLI's OAuth client, which is not in this repository: UsageBar reads it from an installed Gemini CLI (`oauth2.js`) or from `GEMINI_OAUTH_CLIENT_ID` / `GEMINI_OAUTH_CLIENT_SECRET`; otherwise it asks you to run `gemini` again.

## Where data lives

`~/Library/Application Support/UsageBar/`

- `history.jsonl` — usage percentages over time (45-day rolling window) for the trend chart
- `activity-cache.json` — per-file token counts parsed from Claude Code / Codex session logs
- `analysis-cache.json` — numerical turn usage and model/effort metadata; no prompt or response text
- `model-prices.json` — the last LiteLLM price list downloaded from GitHub (optional; the app ships with a snapshot)

## Sleep control

The control reads `SleepDisabled` from `pmset -g` on launch, every 15 seconds, and when opened or refreshed. By default, changes use the macOS administrator prompt; UsageBar never collects or stores a password. The displayed state is read back after success, cancellation, or failure. macOS reports `disablesleep` as system-wide even with `-b`; it persists after UsageBar quits. The former coffee/idle-sleep assertion preference is no longer applied.

To approve administrator access once, turn on **Settings → Change sleep without a password**. UsageBar installs a root-owned, validated `/etc/sudoers.d/usagebar-<uid>` rule for your account's numeric user ID. The rule permits only `/usr/bin/pmset -b disablesleep 0` and `1`; later changes use `sudo -n`. **Confirm with Touch ID or password** is on by default. Authentication must succeed before UsageBar changes sleep; cancelling or unavailable authentication leaves the setting unchanged. You can turn confirmation off for one-click changes.

This permission also lets other apps running as your account use those two commands. Confirmation protects UsageBar's button only. Turning passwordless access off removes the rule after administrator approval. To remove it manually, run `sudo rm /etc/sudoers.d/usagebar-$(id -u)`. If the rule is rejected, UsageBar falls back to the administrator prompt and explains how to repair access.

## Usage & effort analysis

Click the chart button in the popup, or **Settings → Analyze usage & effort**. Select a preset or any 1–120 day range. Claude streaming records and repeated Codex counters are deduplicated; Codex input/cache/output tokens are counted once. Unknown reasoning effort stays unknown.

The **Estimated API cost per turn** plot follows the range, provider and model filters. Select a model to compare its effort levels over time. **Daily average** (hourly for a 24-hour range) shows total estimated cost divided by turns in each local calendar period; **Each turn** plots every priced response, including outliers. Hover for cost, observation count, uncached input, output and cache share. Larger average markers represent more observations; missing or incompletely priced periods break the line. The first and last periods can be partial, and the whole-range table remains weighted by turns, not by daily averages.

To render this view with local usage and saved rates: `.build/debug/UsageBar --render-analysis build/preview-analysis.png --analysis-model codex/gpt-6-astra --analysis-days 7`. Optional `--analysis-each-turn` selects the scatter plot; `--analysis-height 2400 --analysis-show-prices` renders a taller page with the pricing editor open; `--analysis-at 2026-09-15T17:49:59Z` fixes the range end for comparison with an earlier snapshot.

API list prices come from [LiteLLM's public price list](https://github.com/BerriAI/litellm/blob/main/model_prices_and_context_window.json): a snapshot ships inside the app, and **Pricing → Refresh list prices** (or an automatic weekly check when the analysis window is open) downloads the current file from GitHub into `model-prices.json`. Logged model names are matched after stripping provider prefixes and date suffixes (`claude-sonnet-4-5-20250929` → `claude-sonnet-4-5`). Any rate you type overrides the list price for that field; blank keeps the list price, and models without a match stay unpriced until you enter rates. `make prices` regenerates the bundled snapshot. Monthly plan prices give a prorated subscription cost per recorded turn. Missing costs are not treated as zero. The API comparison requires pricing and at least five observations for every compared group. The estimates apply the entered rates across the entire selected range; they do not reconstruct historical invoices or measure task quality, success, retries, or cost per completed task. Local history may be incomplete, and different workloads are not a controlled medium-vs-high benchmark.

Run `make test` for standalone regression checks (full Xcode/XCTest is not required).

## Releasing

Bump the default `VERSION` in `scripts/build-app.sh`, commit, then run the **Build** workflow from the Actions tab (`.github/workflows/build.yml`). Choose a version higher than the latest release and enable **publish**. The workflow runs the regression suite, builds the arm64 app and checksummed DMG, signs a Sparkle ZIP and appcast, tests an actual update on a disposable runner copy, and publishes all assets together. See [release signing and update verification](docs/updates.md) for key management and details.

Delete the folder to reset.

## Not included (yet)

- Multiple accounts per provider
- iOS widgets
- Grok / xAI (no local CLI on this machine to build against)
