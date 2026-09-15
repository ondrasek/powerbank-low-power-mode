# powerbank-low-power-mode

Enables macOS Low Power Mode when the Mac is running off a USB-C **power bank**, and
restores your previous setting on wall power.

Event-driven via `pmset -g pslog` — no polling, no menu bar app.

## How a power bank is detected

**Primary: the source's USB-PD Discover Identity (vid:pid).** A PD source does not
enumerate as a USB data device — `system_profiler SPUSBDataType` is empty with one
attached — but it does answer a Discover Identity request, and macOS keeps the result in
the IORegistry:

```bash
ioreg -rc IOPortTransportComponentCCUSBPDSOP -w 0 | grep Metadata
# "Metadata" = {"Product ID"=63077,"Vendor ID"=1204,"VDO Count"=4, ...}
```

`SOP` is the attached source; `SOP'` would be the cable's e-marker, a different device —
this tool reads only SOP. Unlike the PD capability arrays, this node exists only while a
source is attached, so it does not go stale.

Note the vendor ID identifies the **PD controller chip**, not the brand: a 100 W Anker
bank reports `04b4:f665`, and `0x04B4` is Cypress/Infineon. So treat vid:pid as a device
identity to enrol once, not as a brand test. Enrol with `BANK_DEVICES` / `WALL_DEVICES`.

**Fallback: capability fingerprint.** For sources answering no Discover Identity,
`identify` prints a hash of the full advertised rail set plus PPS range — far more
discriminating than wattage, since two 100 W sources with different rails differ.

### What does not work

- **Wattage.** A 100 W bank and a 100 W wall charger are identical on that axis.
- **`system_profiler SPPowerDataType`.** Its `AC Charger Information` reports only
  `Connected` and `Charging` — no wattage, no ID, no manufacturer.
- **The USB-PD "Unconstrained Power" bit**, tempting as it looks. The spec defines bit 27
  of the first Fixed PDO as *cleared* when the source runs off a limited internal supply,
  i.e. a battery. A real 100 W Anker power bank sets it to **1**, exactly like a wall
  charger. The bit is available as opt-in `USE_PD_UNCONSTRAINED` but is **off by default**
  because it is demonstrably unreliable on real hardware.
- **PD product-type fields.** The ID Header VDO reports `ufp_product_type=3` (PSD) and
  `dfp_product_type=3` (Power Brick) for the bank. There is no "power bank" product type
  in the spec.

## Install

```bash
git clone https://github.com/ondrasek/powerbank-low-power-mode.git
cd powerbank-low-power-mode
sudo ./install.sh
```

Then plug in the power bank and read its identity:

```bash
powerbank-lpm identify
```

Copy the printed `vid:pid` into `BANK_DEVICES` in `/usr/local/etc/powerbank-lpm.conf`
(sources without a Discover Identity response use `BANK_FINGERPRINTS` instead), then reload:

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
