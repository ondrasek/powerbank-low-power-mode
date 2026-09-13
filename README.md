# powerbank-low-power-mode

Enables macOS Low Power Mode when the Mac is running off a USB-C **power bank**, and
restores your previous setting when you plug into a wall charger or unplug entirely.

Event-driven via `pmset -g pslog` — no polling, no menu bar app.

## Install

```bash
git clone https://github.com/ondrasek/powerbank-low-power-mode.git
cd powerbank-low-power-mode
sudo ./install.sh
```

Then enroll your power bank — plug it in and run:

```bash
powerbank-lpm identify
```

Copy the printed fingerprint into `BANK_FINGERPRINTS` in
`/usr/local/etc/powerbank-lpm.conf`, then reload:

```bash
sudo launchctl kickstart -k system/com.ondrasek.powerbank-low-power-mode
```

Until a fingerprint is enrolled the daemon runs but changes nothing.

## Why a root LaunchDaemon and not a user LaunchAgent

`pmset` writes power settings and requires root. A user-level LaunchAgent cannot set
Low Power Mode — the write fails and launchd logs the error without surfacing it.

The alternative is a LaunchAgent plus a `NOPASSWD` sudoers rule. That is a wider hole
than it looks: `pmset` can schedule wakes, change sleep behaviour and disable hibernation,
so a blanket `NOPASSWD: /usr/bin/pmset` hands an attacker with your user account durable
persistence primitives. If you go that route, scope the rule to the single exact command,
not the binary.

## Why identifying a power bank is the hard part

**There is no "this adapter is a battery pack" bit in IOKit.** A power bank negotiates
USB-C Power Delivery exactly like a wall charger does. Two things follow:

- `system_profiler SPPowerDataType` is not usable for this. On the machine this was
  developed against (macOS 26.5.2, Apple Silicon) its `AC Charger Information` section
  reports only `Connected` and `Charging` — **no wattage, no ID, no manufacturer**.
  Guides that tell you to grep wattage out of `system_profiler` are describing older
  hardware or older macOS. This tool reads `ioreg -rn AppleSmartBattery` instead.
- Detection is therefore an allowlist you curate, keyed on the adapter's
  `AdapterDetails` tuple: `Watts`, `AdapterID`, `FamilyCode`, and `SerialString`.
  Apple's own bricks report `Manufacturer` and `SerialString`; the third-party PD
  chargers tested here report neither, so their fingerprint is the electrical profile.

`BANK_MAX_WATTS` offers a wattage-threshold fallback. It is genuinely lossy — a 30 W
travel wall charger and a 30 W power bank are indistinguishable to it — so it is off
by default. Two power banks of the same wattage and family will also collide.

## Commands

| Command | Purpose |
| --- | --- |
| `powerbank-lpm identify` | Print the attached adapter's fingerprint |
| `powerbank-lpm status` | Power source, adapter, Low Power Mode, daemon state |
| `powerbank-lpm doctor` | Check platform support before installing |
| `sudo ./install.sh` | Install binary, config, and LaunchDaemon |
| `sudo ./uninstall.sh` | Remove them and restore the saved Low Power Mode value |
| `./tests/run.sh` | Unit tests — no hardware or root needed |

Logs go to `/var/log/powerbank-lpm.log`.

## Known caveat: `lowpowermode` on macOS 26

`lowpowermode` is **not documented in `man pmset` on macOS 26.5.2**, and on the
development machine the key is absent from both `pmset -g custom` and
`/Library/Preferences/com.apple.PowerManagement.plist` — consistent with it simply
never having been set, but not proof the flag still works. Recent macOS also exposes
an Energy Mode (low / automatic / high) on some hardware instead of a boolean.

`install.sh` runs `doctor`, which reports this and refuses to install (override with
`FORCE=1`). Confirm on your machine before relying on the tool:

```bash
sudo pmset -a lowpowermode 1
pmset -g custom | grep -i lowpower    # should now show lowpowermode 1
```

If that prints nothing, `pmset` is not the right lever on your hardware and this tool
will not work as written.

## Config

`/usr/local/etc/powerbank-lpm.conf` — see `powerbank-lpm.conf.sample`.

`ON_BATTERY` controls what happens with no adapter attached: `ignore` (default, restore
the pre-existing setting), `on`, or `off`.
