# powerbank-low-power-mode

Enables macOS Low Power Mode when the Mac is running off a USB-C **power bank**, and
restores your previous setting on wall power.

Event-driven via `pmset -g pslog` — no polling, no menu bar app.

## How a power bank is detected

**There is no USB vendor/product ID to read.** A PD charger or power bank supplies power
only; it does not enumerate as a USB data device. `system_profiler SPUSBDataType` is
empty with one attached, and macOS does not expose the PD Discover Identity VDO
(vendor ID) anywhere in the IORegistry.

What macOS *does* expose is the source's advertised **USB-PD Source Capabilities** —
the raw Power Data Objects, in `ioreg -rn AppleSmartBattery` under
`PortControllerInfo` → `PortControllerPortPDO`. Those carry a spec-defined bit that
answers exactly the question we care about:

> **Unconstrained Power** (bit 27 of the first Fixed Supply PDO) — set when the source
> is backed by an effectively unlimited supply (mains), cleared when it is backed by a
> limited one (a battery).

A spec-compliant power bank clears it; a wall charger sets it. This is the default
mechanism (`DETECT_MODE="pd"`). A second bit, **Dual-Role Power** (bit 29, "I can also
sink, i.e. recharge myself"), is available as a stricter `REQUIRE_DUAL_ROLE` check.

**Confidence: moderate, not high.** The bit is spec-defined and semantic rather than a
heuristic, but it depends on the device's firmware being honest. Cheap power banks are
known to misreport PD fields. Verify yours with `powerbank-lpm identify` before trusting
it, and use the fingerprint lists to override if it lies.

### If the bits lie: fingerprints

`powerbank-lpm identify` prints a fingerprint combining wattage, serial (when present),
and a hash of the **full advertised capability set** — every voltage/current rail plus
the PPS range. That is far more discriminating than wattage: two 60 W sources with
different rail sets or PPS ranges produce different hashes.

`BANK_FINGERPRINTS` / `WALL_FINGERPRINTS` in the config override the PD bits entirely.

### Why not wattage

Wattage cannot work, and is off by default. A 60 W power bank and a 60 W wall charger
are identical on that axis. It remains available as `BANK_MAX_WATTS` in `list` mode only.

## Install

```bash
git clone https://github.com/ondrasek/powerbank-low-power-mode.git
cd powerbank-low-power-mode
sudo ./install.sh
```

Then plug in the power bank and check what it advertises:

```bash
powerbank-lpm identify
```

If the verdict is already `POWER BANK`, you are done. If not, copy the printed
fingerprint into `BANK_FINGERPRINTS` in `/usr/local/etc/powerbank-lpm.conf` and reload:

```bash
sudo launchctl kickstart -k system/com.ondrasek.powerbank-low-power-mode
```

## Low Power Mode on macOS 26

Verified on macOS 26.5.2 (Apple Silicon). Two asymmetries will bite anyone scripting this:

- The **write** key is `lowpowermode` (`sudo pmset -a lowpowermode 1`), but `pmset -g custom`
  reports it back as **`powermode`**. Grepping the read output for `lowpowermode` never matches.
- `pmset` **omits the key entirely when the mode is off.** Absent means `0`, not
  "unsupported". Treating absent as unknown makes every save/restore decision wrong.
- `lowpowermode` is not documented in `man pmset` on macOS 26, but it does work.

Before installing, set Low Power Mode to whatever you consider *normal* — the daemon saves
the value in force at first override and restores it on wall power. `doctor` warns if it is
currently on.

## Why a root LaunchDaemon, not a user LaunchAgent

`pmset` writes require root; a user LaunchAgent cannot set Low Power Mode and fails
silently in launchd's log. The alternative, a `NOPASSWD` sudoers rule, is wider than it
looks — `pmset` can schedule wakes and change hibernation, which are persistence
primitives. If you go that way, scope the rule to one exact command, not the binary.

## Commands

| Command | Purpose |
| --- | --- |
| `powerbank-lpm identify` | Decode the attached source's PD capabilities and verdict |
| `powerbank-lpm status` | Power source, PD contract, Low Power Mode, daemon state |
| `powerbank-lpm doctor` | Pre-install checks |
| `sudo ./install.sh` | Install binary, config and LaunchDaemon |
| `sudo ./uninstall.sh` | Remove them, restore the saved Low Power Mode value |
| `./tests/run.sh` | Unit tests — no hardware or root needed |

Logs: `/var/log/powerbank-lpm.log`.

## Caveat: stale PD data

`PortControllerPortPDO` is **not cleared when a charger is unplugged** — it persists from
the last negotiation. Port selection therefore keys on a live contract
(`PortControllerMaxPower > 0`), and `identify` refuses to run on battery. Any code reading
these fields must do the same or it will report an unplugged charger as still attached.
