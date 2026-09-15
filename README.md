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

### Measured devices

| Source | vid:pid | Watts | `unconstrained_power` | `dual_role_power` | ufp/dfp product type |
| --- | --- | --- | --- | --- | --- |
| Anker power bank | `04b4:f665` (Cypress) | 100 | **1** | 0 | 3 / 3 |
| USB-C hub + wall power | `2109:0108` (VIA Labs) | 50 | 1 | **1** | 2 / 0 |
| 60 W PD wall charger | not captured | 60 | 1 | 0 | — |

vid:pid separates them cleanly, and the identity node refreshes on swap rather than
reporting the previous source. Every inferred signal fails on this sample:
`unconstrained_power` is 1 for all three, and `dual_role_power` is **backwards** — the
mains-powered hub sets it, the battery-powered bank does not.

### What does not work

- **Wattage.** A 100 W bank and a 100 W wall charger are identical on that axis.
- **`system_profiler SPPowerDataType`.** Its `AC Charger Information` reports only
  `Connected` and `Charging` — no wattage, no ID, no manufacturer.
- **The USB-PD "Unconstrained Power" bit**, tempting as it looks. The spec defines bit 27
  of the first Fixed PDO as *cleared* when the source runs off a limited internal supply,
  i.e. a battery. A real 100 W Anker power bank sets it to **1**, exactly like mains. The bit is available as opt-in `USE_PD_UNCONSTRAINED` but is **off by default**
  because it is demonstrably unreliable on real hardware.
- **Dual-Role Power** (bit 29), offered here as `REQUIRE_DUAL_ROLE`. It is inverted in
  practice: the mains-powered hub advertises it, the power bank does not. Kept only
  because a different pair of devices might behave as the spec suggests.
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

## Where it installs: user agent vs root daemon

Detection needs **no privileges at all** — `ioreg` and `pmset -g` run fine as your user.
Only the write does, and it cannot be avoided: `pmset -a lowpowermode` requires root.

Worse, it fails *quietly*. Run as a normal user it prints
`LowPowerMode not supported on AC Power`, changes nothing, and **exits 0**. A user agent
trusting that exit code looks like it is working while doing nothing. This tool verifies
every write by reading the value back.

So there are two installs:

**`./install-agent.sh`** — everything under `$HOME`:

```
~/.local/bin/powerbank-lpm
~/.config/powerbank-lpm.conf
~/Library/LaunchAgents/com.ondrasek.powerbank-low-power-mode.plist
~/Library/Logs/powerbank-lpm.log
```

plus one privileged file, `/etc/sudoers.d/powerbank-lpm`, containing exactly:

```
<you> ALL=(root) NOPASSWD: /usr/bin/pmset -a lowpowermode 0, /usr/bin/pmset -a lowpowermode 1
```

sudoers matches the full argument vector, so this grants those two commands and nothing
else — importantly *not* `pmset` in general, which can also schedule wakes and change
hibernation, i.e. persistence primitives. The installer validates the file with
`visudo -c` before installing it. Run it **as yourself**, not with sudo.

**`./install.sh`** — root LaunchDaemon in `/Library/LaunchDaemons`, no sudoers rule.

Neither is fully unprivileged. The agent confines the *running* code to your account and
needs root once at install; the daemon keeps the running code as root but leaves no
standing grant to your user account. Pick based on which you would rather audit.

## Commands

| Command | Purpose |
| --- | --- |
| `powerbank-lpm identify` | Decode the attached source's PD capabilities and verdict |
| `powerbank-lpm status` | Power source, PD contract, Low Power Mode, daemon state |
| `powerbank-lpm doctor` | Pre-install checks |
| `./install-agent.sh` | User-level LaunchAgent + scoped sudoers rule (run as yourself) |
| `./uninstall-agent.sh` | Remove the agent and its sudoers rule |
| `sudo ./install.sh` | Root LaunchDaemon install |
| `sudo ./uninstall.sh` | Remove it, restore the saved Low Power Mode value |
| `./tests/run.sh` | Unit tests — no hardware or root needed |

Logs: `~/Library/Logs/powerbank-lpm.log` (agent) or `/var/log/powerbank-lpm.log` (daemon).

## Caveat: stale PD data

`PortControllerPortPDO` is **not cleared when a charger is unplugged** — it persists from
the last negotiation. Port selection therefore keys on a live contract
(`PortControllerMaxPower > 0`), and `identify` refuses to run on battery. Any code reading
these fields must do the same or it will report an unplugged charger as still attached.
