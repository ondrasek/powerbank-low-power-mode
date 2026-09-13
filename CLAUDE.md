# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

macOS launchd job that enables Low Power Mode when the Mac is running off a **power bank** (USB-C PD battery pack) and restores the previous state when it is not. Repository is currently empty — no code has been committed yet. Update this file as the implementation lands.

## Hard constraint: privilege

`pmset` writes power settings and **requires root**. A user-level LaunchAgent (`~/Library/LaunchAgents`) cannot set Low Power Mode by itself. Only three viable designs; pick one explicitly and document the choice here:

1. **LaunchDaemon** in `/Library/LaunchDaemons` running as root — simplest, but not user-level, needs an admin install step.
2. **LaunchAgent + sudoers drop-in** in `/etc/sudoers.d/` with `NOPASSWD` scoped to the exact `pmset` invocation — keeps the watcher in user space; the sudoers file still needs root to install and is a privilege-escalation surface, so scope it to a single fixed command path, never a wildcard.
3. **Split**: user LaunchAgent detects, privileged helper applies (LaunchDaemon + local socket/file trigger). Most work, cleanest separation.

Do not write code that assumes a plain LaunchAgent can call `pmset -a` — it will fail silently in launchd logs.

## Platform facts (verified on this machine, macOS 26.5.2 / Apple Silicon)

- `pmset -g custom` does **not** list `lowpowermode` here, and `/Library/Preferences/com.apple.PowerManagement.plist` has no such key — the setting is unset, and `lowpowermode` is **undocumented in `man pmset` on macOS 26**. Verify `sudo pmset -b lowpowermode 1` actually takes effect on the target machine before building on it; on recent hardware Apple exposes Energy Mode (low/automatic/high) instead of a single boolean. Re-check with `pmset -g custom` after writing.
- Power-source change events: `pmset -g pslog` streams a line on every AC↔Battery transition. This is the event source to drive the watcher (`KeepAlive` + read stdin loop), not `StartInterval` polling.
- Current source, one-shot: `pmset -g batt` → `Now drawing from 'AC Power'` | `'Battery Power'`.
- Adapter identity: `ioreg -rn AppleSmartBattery` → `AdapterDetails` dict, e.g. `{"Watts"=60,"AdapterVoltage"=20000,"FamilyCode"=...,"AdapterID"=0,"Description"="pd charger","IsWireless"=No}`. Apple first-party adapters additionally carry `Manufacturer`/`SerialString`; the third-party PD charger observed here carries neither.

## The actual hard problem: identifying a power bank

**There is no "this is a battery pack" bit in IOKit.** A power bank negotiates USB-C PD exactly like a wall charger. Workable discriminators, in descending reliability:

1. **Fingerprint allowlist** — match on the `AdapterDetails` tuple (`Watts` + `FamilyCode` + `AdapterID`, plus `SerialString` when present) for the user's known power banks. Requires a user-editable config file and a `--identify` mode that prints the currently connected adapter's fingerprint so a bank can be enrolled.
2. **Wattage threshold** — e.g. treat < 65 W as a bank. Cheap, but misclassifies low-wattage wall chargers and high-output banks. Only acceptable as a fallback with the threshold configurable.

Never claim in docs or commit messages that detection is reliable by adapter type alone.

## Conventions once code exists

- Reverse-DNS label matching the plist filename, e.g. `com.ondrasek.powerbank-low-power-mode`.
- Restore semantics: persist the pre-existing Low Power Mode value before overriding, and restore it on disconnect — do not hardcode "off".
- Log to `~/Library/Logs/` (agent) or `/var/log/` (daemon) via the plist's `StandardOutPath`/`StandardErrorPath`; `launchctl print gui/$(id -u)/<label>` (or `system/<label>` for a daemon) is the primary debugging command.
- Reloading after a plist edit: `launchctl bootout` then `bootstrap` — `launchctl load -w` is deprecated and silently keeps stale config.
