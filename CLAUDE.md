# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

macOS LaunchDaemon that enables Low Power Mode when the Mac runs off a USB-C **power bank** and restores the previous setting otherwise. Pure bash; no build step.

```
bin/powerbank-lpm   # everything: watch loop, identify, status, doctor
launchd/*.plist     # LaunchDaemon definition
install.sh          # sudo installer; runs `doctor` and refuses on failure (FORCE=1 overrides)
tests/run.sh        # unit tests — no hardware, no root
```

## Commands

```bash
./tests/run.sh                    # full test suite (~1s)
./tests/run.sh 2>&1 | grep FAIL   # failures only; there is no single-test selector
./bin/powerbank-lpm identify      # print attached adapter's fingerprint
./bin/powerbank-lpm doctor        # platform support check
sudo ./install.sh                 # install + bootstrap daemon
sudo launchctl kickstart -k system/com.ondrasek.powerbank-low-power-mode   # reload after config edit
```

## Architecture

Single decision function, `apply()`, called once at startup and again on every line
`pmset -g pslog` emits containing `Now drawing from`. Everything else is support:
`adapter_raw` → `adapter_field` → `adapter_fingerprint` → `is_power_bank` → `lpm_set`.

**State**: `/var/db/powerbank-lpm.state` holds the Low Power Mode value observed *before*
this tool first overrode it. Disconnect restores that, never a hardcoded `0`. Anything
touching `lpm_set` must preserve this — see `state_save`/`state_restore_value`.

**Testing**: sourcing `bin/powerbank-lpm` with `POWERBANK_LPM_LIB=1` set returns before
command dispatch, exposing the pure functions. Keep new logic in functions that take
their input as arguments so it stays reachable this way; hardware access belongs only in
`adapter_raw`, `on_ac`, and `lpm_current`.

## Platform facts (verified on macOS 26.5.2, Apple Silicon)

- **BSD `sed` has no `\|` alternation.** A `sed`-based `AdapterDetails` parser fails
  *silently* and yields an empty fingerprint, which then matches nothing. `adapter_field`
  is written in `awk` for this reason — do not "simplify" it back to `sed`.
- **`system_profiler SPPowerDataType` is useless for adapter identity here.** Its
  `AC Charger Information` section reports only `Connected` and `Charging` — no wattage,
  no ID, no manufacturer. Use `ioreg -rn AppleSmartBattery` → `AdapterDetails`.
- `pmset -g pslog` streams a line per AC↔battery transition; this is the event source.
  Adapter details settle ~1-2s after attach, hence the `sleep 2` before `apply`.
- **`lowpowermode` is undocumented in `man pmset` on macOS 26** and absent from both
  `pmset -g custom` and `com.apple.PowerManagement.plist` on the dev machine. `doctor`
  reports this. It is not confirmed that `pmset -a lowpowermode 1` still works — do not
  write docs or commit messages asserting it does.
- Observed third-party adapter: `Watts=60, AdapterID=0, Description="pd charger"`, with
  no `Manufacturer`/`SerialString`. Apple bricks do carry those.

## Constraints

- `pmset` writes require root — a user LaunchAgent cannot do this. Daemon runs as root.
  If revisiting the sudoers alternative, scope it to one exact command, never `/usr/bin/pmset`.
- **There is no IOKit flag for "this is a power bank."** Detection is a user-curated
  fingerprint allowlist, with a lossy wattage threshold as opt-in fallback. Never document
  it as reliable adapter-type detection.
- Use `launchctl bootout` + `bootstrap`, not deprecated `load -w` (silently keeps stale config).
