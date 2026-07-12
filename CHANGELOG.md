# Changelog

## 1.0 (unreleased)

- Claude + Codex rate limits (session 5h / weekly) as menu bar ring gauges
- Four menu bar styles: rings + %, rings, text, bars
- Liquid Glass popover (macOS 26) with countdown reset times
- Notifications at 70% / 90%, once per window cycle
- Reads Claude Code / Codex CLI logins automatically; browser OAuth Connect for everyone else
- HTTP 429 backoff with cached-data fallback
- First-run welcome with CLI detection and Keychain pre-prompt
- Settings: hide providers, refresh interval, launch at login, notification toggle

## 1.1 (unreleased)

- Burn-rate prediction: warns when usage is on pace to hit 100% before the window resets
- 24h sparklines per provider card
- "Connect in browser instead" option for Claude Code users who prefer no Keychain prompt
- Claude credentials cached in memory (Keychain read only on expiry)
