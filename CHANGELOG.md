# Changelog

## 0.1.7 - 2026-07-16

- Added synchronized auto-refresh status and refresh time to Mini mode.
- The Mini mode auto-refresh badge now controls the same setting as Full mode.
- Mini mode keeps the normal footer font size when only the weekly quota is
  available, and uses compact sizing only when the 5-hour quota is present.
- Aligned the Mini mode footer with the reset label and reset time above it.
## 0.1.6 - 2026-07-16

- Fixed Pro Lite account detection after the desktop app began emitting both
  account-wide and model-specific rate-limit records.
- Account-wide Codex quota data now takes priority over model-specific limits,
  keeping the plan label and weekly remaining percentage in sync.
- Remaining quota percentages use the same whole-percent presentation as the
  official app, including activity-aware handling near 100 percent.
- Centered the plan badge vertically and aligned the full-mode usage ring,
  reset label, and reset time within the left usage panel.
## 0.1.5 - 2026-07-13

- Added ChatGPT-compatible quota windows: CodexW recognizes weekly windows
  reported as the primary rate limit and handles a missing 5-hour window.
- The full panel no longer has a close button; compact square refresh controls
  provide refresh and full-mode actions directly from Mini mode.
- Updated documentation for current ChatGPT/Codex data-directory compatibility.
## 0.1.4 - 2026-07-11

- Fixed stale quota values after newer Codex versions append rate-limit events
  while the local session log is being scanned.
- CodexW now performs a lightweight final read of live Codex rate updates after
  token aggregation, so manual and scheduled refreshes use the newest 5-hour
  and 7-day quota record without repeating the full token calculation.
- Runtime package remains minimal: one root launcher, the WPF script, and the
  resources required to run the panel.
## 0.1.3 - 2026-07-07

- Prefer Codex's reported remaining quota percentage when available instead of
  always deriving it from `100 - used_percent`.
- This makes the 5-hour and weekly quota display match the official Codex menu
  more closely when the local log contains both values.

## 0.1.2 - 2026-07-07

- Fixed a release startup crash caused by the missing footer refresh text
  helper in the packaged WPF script.
- Added verification so release builds fail if the helper is missing again.

## 0.1.1 - 2026-07-07

- Fixed manual refresh so the panel redraws immediately after the background
  snapshot cache is updated.
- Added visible manual refresh feedback for refresh-in-progress and refresh
  complete states.
- Kept the low-memory refresh model: Codex session logs are scanned in a short
  hidden background PowerShell process, then released after the snapshot is
  written.
- Release zip now remains runtime-only.

## 0.1.0 - 2026-07-03

- Initial public Windows release as CodexW.
- Added a WPF desktop panel styled after codexU.
- Added local Codex usage parsing from `%USERPROFILE%\.codex`.
- Added tray icon, custom tray menu, show/hide, refresh, desktop-bottom mode,
  launch-at-login, and graceful quit.
- Added 5-minute low-cost auto-refresh when Codex is running.
- Added saved window placement under `%LOCALAPPDATA%\CodexW\settings.json`.

