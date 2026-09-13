# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

macOS LaunchDaemon that enables Low Power Mode when the Mac runs off a USB-C power bank
and restores the previous setting otherwise. Pure bash; no build step.

```
bin/powerbank-lpm   # watch loop, identify, status, doctor — all logic lives here
launchd/*.plist     # LaunchDaemon definition
install.sh          # sudo installer; gates on `doctor` (FORCE=1 overrides)
tests/run.sh        # 32 assertions, no hardware, no root
```

## Commands

```bash
./tests/run.sh                    # full suite (~1s)
./tests/run.sh 2>&1 | grep FAIL   # failures only; no single-test selector
./bin/powerbank-lpm identify      # decode attached source (requires AC)
./bin/powerbank-lpm doctor        # platform checks
sudo ./install.sh
sudo launchctl kickstart -k system/com.ondrasek.powerbank-low-power-mode   # reload after config edit
```

## Architecture

One decision function, `apply()`, called at startup and on every `pmset -g pslog` line
containing `Now drawing from`. Pipeline:
`adapter_raw`/`pd_port_line` → `pd_pdo_list` → `pd_flags` → `classify` → `lpm_set`.

`classify` precedence: `WALL_FINGERPRINTS` → `BANK_FINGERPRINTS` → PD bits → wattage.
Explicit lists must always beat inferred bits, because device firmware lies.

**State**: `/var/db/powerbank-lpm.state` holds the Low Power Mode value seen *before* the
tool first overrode it. Disconnect restores that, never a hardcoded `0`.

**Testing**: sourcing `bin/powerbank-lpm` with `POWERBANK_LPM_LIB=1` returns before command
dispatch, exposing pure functions. Keep new logic in functions taking input as arguments;
hardware access belongs only in `adapter_raw`, `pd_port_line`, `on_ac`, `lpm_current`.

## Platform facts (verified on macOS 26.5.2, Apple Silicon)

Detection:
- **No USB vendor/product ID exists for a charger.** It supplies power without enumerating
  as a data device — `system_profiler SPUSBDataType` is empty with one attached, and the PD
  Discover Identity VDO is not exposed in the IORegistry. Do not go looking for it again.
- **`system_profiler SPPowerDataType` is useless here**: `AC Charger Information` reports
  only `Connected` and `Charging` — no wattage, no ID, no manufacturer. Guides saying to
  grep wattage from it describe older hardware/macOS.
- The usable signal is `ioreg -rn AppleSmartBattery` → `PortControllerInfo` →
  `PortControllerPortPDO`: raw USB-PD Source Capability PDOs. Bit 27 of the first Fixed
  Supply PDO is **Unconstrained Power** (mains-backed = 1, battery-backed = 0); bit 29 is
  Dual-Role Power. This is the detection mechanism.
- **`PortControllerPortPDO` is not cleared on unplug.** It persists from the last
  negotiation. Select the port by live contract (`PortControllerMaxPower > 0`). Selecting
  "the port whose PDO array is non-zero" reports unplugged chargers as attached.
- Observed wall charger: 5/9/12/15/20 V @ 3 A + PPS 4.5–21 V, `unconstrained_power=1`,
  `dual_role_power=0`, `Watts=60`, no `Manufacturer`/`SerialString`.

Low Power Mode:
- **Write key is `lowpowermode`; read key is `powermode`.** `sudo pmset -a lowpowermode 1`
  works, but `pmset -g custom` prints `powermode 1`. Grepping read output for
  `lowpowermode` silently never matches.
- **`pmset` omits the key when the mode is off** — absent means `0`, not unsupported.
- Undocumented in `man pmset` on macOS 26, but confirmed working.

Shell:
- **BSD `sed` has no `\|` alternation.** A sed-based `AdapterDetails` parser fails *silently*
  and yields empty fields. `adapter_field` is awk for this reason — do not "simplify" it back.
- **`local a=$1 b=$((a+1))` does not work**: bash expands all words before assigning, so `a`
  is still unset inside the arithmetic. Split into separate `local` statements. This silently
  produced all-zero PDO decodes.

## Constraints

- `pmset` writes require root — a user LaunchAgent cannot do this. If revisiting the sudoers
  alternative, scope it to one exact command, never `/usr/bin/pmset`.
- Detection confidence is **moderate, not high**: the PD bit is spec-defined but firmware may
  misreport it. Never document it as guaranteed; keep the fingerprint override path working.
- Wattage cannot distinguish a power bank from an equal-rated wall charger. It stays off by
  default and must not be re-promoted.
- Use `launchctl bootout` + `bootstrap`, not deprecated `load -w` (silently keeps stale config).
