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
- Direct Settings button and a fixed-size popup with scrolling content
- Usage & effort analysis across a custom 1–120 day range: tokens per assistant turn, model/effort groups, editable API cost estimates and monthly subscription allocation
- Launch at login and configurable refresh interval
- Everything stays on your Mac: no accounts, no telemetry, no servers of ours

## Install a release

Download the latest DMG from [Releases](https://github.com/kubilayege/UsageBar/releases), open it and drag UsageBar to Applications. Builds are ad-hoc signed and not notarized: on first launch right-click → Open, or run `xattr -d com.apple.quarantine /Applications/UsageBar.app`.

UsageBar checks GitHub releases once a day (toggle in **Settings → Updates**) and shows an **Update** chip in the popup when a newer version exists. If GitHub's anonymous API quota is exhausted, it reads the public release page and download links instead, respecting the API's retry time. **Download and open…** saves the DMG to Downloads, verifies its SHA-256 against the matching published checksum, and mounts it. Only a published release with a higher version triggers an update; workflow artifacts alone do not.

## Requirements

- macOS 14 Sonoma or newer
- Xcode Command Line Tools (`xcode-select --install`) — full Xcode is not required

## Build & run

```sh
make app        # builds build/UsageBar.app (release, ad-hoc signed)
make install    # copies it to /Applications and launches it
```

For development:

```sh
swift build && .build/debug/UsageBar          # run without a bundle (no notifications / launch-at-login)
.build/debug/UsageBar --probe                 # fetch every provider once and print the result
.build/debug/UsageBar --probe --no-activity   # same, skipping the local log scan
make preview                                  # render the popover and dashboard to PNG with demo data
```

The shared app artwork is [`Sources/UsageBar/Resources/AppLogo.png`](Sources/UsageBar/Resources/AppLogo.png). SwiftPM includes it for development; `make app` embeds it in the bundle and generates the full macOS `AppIcon.icns` size set. The popup, dashboard, and Settings use the same logo, with a simplified white mark in the menu bar. The generation prompt is recorded in [`docs/branding/app-logo.md`](docs/branding/app-logo.md).

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

The control reads `SleepDisabled` from `pmset -g` on launch, every 15 seconds, and when opened or refreshed. Changes use the macOS administrator prompt; UsageBar never collects a password. The displayed state is read back after success, cancellation, or failure. macOS reports `disablesleep` as system-wide even with `-b`; it persists after UsageBar quits. The former coffee/idle-sleep assertion preference is no longer applied.

## Usage & effort analysis

Click the chart button in the popup, or **Settings → Analyze usage & effort**. Select a preset or any 1–120 day range. Claude streaming records and repeated Codex counters are deduplicated; Codex input/cache/output tokens are counted once. Unknown reasoning effort stays unknown.

The **Estimated API cost per turn** plot follows the range, provider and model filters. Select a model to compare its effort levels over time. **Daily average** (hourly for a 24-hour range) shows total estimated cost divided by turns in each local calendar period; **Each turn** plots every priced response, including outliers. Hover for cost, observation count, uncached input, output and cache share. Larger average markers represent more observations; missing or incompletely priced periods break the line. The first and last periods can be partial, and the whole-range table remains weighted by turns, not by daily averages.

To render this view with local usage and saved rates: `.build/debug/UsageBar --render-analysis build/preview-analysis.png --analysis-model codex/gpt-6-astra --analysis-days 7`. Optional `--analysis-each-turn` selects the scatter plot; `--analysis-height 2400 --analysis-show-prices` renders a taller page with the pricing editor open; `--analysis-at 2026-09-15T17:49:59Z` fixes the range end for comparison with an earlier snapshot.

API list prices come from [LiteLLM's public price list](https://github.com/BerriAI/litellm/blob/main/model_prices_and_context_window.json): a snapshot ships inside the app, and **Pricing → Refresh list prices** (or an automatic weekly check when the analysis window is open) downloads the current file from GitHub into `model-prices.json`. This is the only network request that is not to a vendor you use. Logged model names are matched after stripping provider prefixes and date suffixes (`claude-sonnet-4-5-20250929` → `claude-sonnet-4-5`). Any rate you type overrides the list price for that field; blank keeps the list price, and models without a match stay unpriced until you enter rates. `make prices` regenerates the bundled snapshot. Monthly plan prices give a prorated subscription cost per recorded turn. Missing costs are not treated as zero. The API comparison requires pricing and at least five observations for every compared group. The estimates apply the entered rates across the entire selected range; they do not reconstruct historical invoices or measure task quality, success, retries, or cost per completed task. Local history may be incomplete, and different workloads are not a controlled medium-vs-high benchmark.

Run `make test` for standalone regression checks (full Xcode/XCTest is not required).

## Releasing

Bump the default `VERSION` in `scripts/build-app.sh`, commit, then run the **Build** workflow from the Actions tab (`.github/workflows/build.yml`). It runs `make test`, builds the arm64 app bundle and a checksummed DMG with `scripts/build-dmg.sh`, uploads them as an artifact, and, with **publish** enabled, creates or updates the `v<version>` GitHub release that the in-app updater reads. Locally, `make app && scripts/build-dmg.sh` produces the same DMG under `build/`.

Delete the folder to reset.

## Not included (yet)

- Multiple accounts per provider
- iOS widgets
- Grok / xAI (no local CLI on this machine to build against)
