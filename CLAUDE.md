# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

macOS LaunchDaemon that enables Low Power Mode when the Mac runs off a USB-C power bank
and restores the previous setting otherwise. Pure bash; no build step.

```
bin/powerbank-lpm   # watch loop, identify, status, doctor — all logic lives here
launchd/*.plist     # LaunchDaemon definition
install.sh          # root LaunchDaemon install; gates on `doctor` (FORCE=1 overrides)
install-agent.sh    # user LaunchAgent under $HOME + scoped sudoers rule; run as the user
tests/run.sh        # 42 assertions, no hardware, no root
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

`classify` precedence: `WALL_DEVICES` → `BANK_DEVICES` → `WALL_FINGERPRINTS` →
`BANK_FINGERPRINTS` → PD bits (opt-in) → wattage. Explicit lists must always beat inferred
bits — this is not theoretical, the test bank misreports Unconstrained Power.

**State**: `/var/db/powerbank-lpm.state` holds the Low Power Mode value seen *before* the
tool first overrode it. Disconnect restores that, never a hardcoded `0`.

**Testing**: sourcing `bin/powerbank-lpm` with `POWERBANK_LPM_LIB=1` returns before command
dispatch, exposing pure functions. Keep new logic in functions taking input as arguments;
hardware access belongs only in `adapter_raw`, `pd_port_line`, `on_ac`, `lpm_current`.

## Platform facts (verified on macOS 26.5.2, Apple Silicon)

Detection:
- **The source's vid:pid IS available** — from its USB-PD Discover Identity response, at
  `ioreg -rc IOPortTransportComponentCCUSBPDSOP` → `Metadata`. Read only the `SOP` node
  (the attached source); `SOP'` is the cable's e-marker, a different device. This node is
  absent when nothing is attached, so it does not go stale. The vendor ID is the **PD
  controller chip vendor**, not the brand (a 100 W Anker bank reports `04b4:f665`, Cypress).
- A charger does not enumerate as a USB data device — `system_profiler SPUSBDataType` is
  empty with one attached. Discover Identity is the only identity path.
- **`system_profiler SPPowerDataType` is useless here**: `AC Charger Information` reports
  only `Connected` and `Charging` — no wattage, no ID, no manufacturer. Guides saying to
  grep wattage from it describe older hardware/macOS.
- `ioreg -rn AppleSmartBattery` → `PortControllerInfo` → `PortControllerPortPDO` holds raw
  USB-PD Source Capability PDOs. Bit 27 of the first Fixed Supply PDO is **Unconstrained
  Power**, spec-defined as 0 for a battery-backed source. **Measured: a real 100 W Anker
  power bank reports 1**, identical to a wall charger. The bit is opt-in
  (`USE_PD_UNCONSTRAINED`) and off by default — do not re-promote it to primary.
- **Dual-Role Power (bit 29) is inverted in practice**: measured `1` on a mains-powered
  USB-C hub and `0` on the battery-powered bank. `REQUIRE_DUAL_ROLE` is kept but must not
  be assumed to point the way the spec implies.
- ID Header VDO product types are also useless: the bank reports `ufp_product_type=3` (PSD)
  and `dfp_product_type=3` (Power Brick). The spec has no "power bank" type.
- Measured devices: Anker 100 W bank `04b4:f665`, USB-C hub on wall power `2109:0108`.
  vid:pid separates them; the identity node refreshes on swap (verified, not assumed).
- **`PortControllerPortPDO` is not cleared on unplug.** It persists from the last
  negotiation. Select the port by live contract (`PortControllerMaxPower > 0`). Selecting
  "the port whose PDO array is non-zero" reports unplugged chargers as attached.
- Observed 60 W wall charger: 5/9/12/15/20 V @ 3 A + PPS 4.5–21 V, `unconstrained_power=1`,
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

- `pmset` writes require root. **`pmset` exits 0 even when the write is refused** — as a
  non-root user it prints "LowPowerMode not supported on <source>" and changes nothing.
  Never trust its exit code; `lpm_set` verifies by reading the value back.
- Two install paths: root daemon (`install.sh`) and user agent + sudoers (`install-agent.sh`).
  The sudoers rule lists two exact argument vectors; never widen it to `/usr/bin/pmset`.
- Detection is **enrolment-based by design**: the user lists their devices' vid:pid. No
  inferred signal found so far reliably separates a bank from a charger; treat any new
  candidate as suspect until measured against both.
- Wattage cannot distinguish a power bank from an equal-rated wall charger. It stays off by
  default and must not be re-promoted.
- Use `launchctl bootout` + `bootstrap`, not deprecated `load -w` (silently keeps stale config).
