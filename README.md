# MSI Power — Omarchy bar widget

Full MControlCenter coverage for MSI laptops plus a system monitor in one
`bar-widget` plugin (`tanmay.msi-power`):

- **Power mode** (user scenario): Super Battery / Balanced / High Performance
  (`eco` / `comfort` / `sport` on the EC)
- **Fan** — 3 one-tap manual presets (Quiet / Balanced / Performance: fixed
  speed tables via the MControlCenter Advanced registers
  `0x6A/0x72/0x82/0x8A`, applied with `scripts/msi-fan-curve.sh`, auto-flips
  the EC to Advanced) plus **Advanced** for the current EC curve, and a
  **Cooler Boost** toggle. The active preset is detected from the EC's live
  tables and ticked. On ECs without curve tables the raw EC fan modes
  (Auto / Silent / Advanced) are shown instead. Single-fan boards (no GPU
  fan speed exposed, e.g. iGPU-only Modern 15) write and match the CPU/fan1
  table only; dual-fan boards use both tables.
- **Heat alert**: the bar icon turns red when the CPU or GPU temperature
  reaches `tempAlertAt` (default 80 °C, configurable in the plugin settings)
- **Sensors**: read-only text rows in the network-panel style — CPU usage, EC
  temperature and fan %, RAM and swap, and a per-disk storage line with disk
  temperature. EC sensor rows come from sysfs; system stats from the bundled
  `bin/omarchy-msi-stats` sampler (same pipeline as the sysmon plugin).

Only hardware features the embedded controller actually reports are shown —
the EC sensor rows disappear automatically on models that lack them.

> **Fan reading**: the widget shows the **real fan RPM**, read the same way
> MControlCenter does — the EC keeps a 2-byte tick counter at `0xCC/0xCD`
> (fallback register pair MControlCenter picks for this board) and
> `RPM = 480000 / ticks` (`src/operate.cpp:getFan1Speed`). It reads the raw
> EC file **read-only**; when the fan is off it shows `OFF`. The number the
> `msi-ec` sysfs driver exports (`cpu/realtime_fan_speed`, the EC's thermal
> level at `0x71`) is *not* RPM and is not shown — note that Cooler Boost
> spins the fans up audibly without changing either value.

## How it works

Fully standalone — MControlCenter and its root D-Bus helper are **not**
required and never run. Reverse-engineering the helper
([src/helper/msi-ec.cpp][MControlCenter]) shows every setter it exposed is a
plain `write()` to one sysfs file; this widget does exactly that, in place:

- **Reads** come from sysfs (`/sys/devices/platform/msi-ec/…`). Everything is
  world-readable, so the widget never needs privileges just to report state,
  and it polls every `refreshMs` (default 2s).
- **Writes** go straight to the same sysfs attributes the helper used
  (`shift_mode`, `fan_mode`, `cooler_boost`, …). The kernel driver owns them
  as `root:root 0644`, so a one-shot udev setup makes them group-writable:
  a `msi-ec` group + a small rule — nothing runs in the background afterwards.
- **Fan RPM** is the one value sysfs doesn't expose; it comes from the raw EC
  interface (`ec_sys` debugfs) at register pair `0xCC/0xCD`, matching
  MControlCenter's tach decoding. The group gets **read-only** access (mode
  `0640`, no write bit), granted at boot by the same udev rule driving
  systemd-tmpfiles — so the widget can watch the tach but cannot poke other
  EC registers.

> **Features the EC doesn't support**: **USB Power Share** (charging USB
> devices while the laptop is off) targets the older GE/GP/GF gaming ECs —
> a raw EC bit the `msi-ec` driver doesn't export for this Gen-2 EC. That
> control is not shown — it'd be a no-op here.

It depends only on:

- the `msi-ec` kernel module (already loaded if MControlCenter worked), and
- the one-shot permission grant below.

If the msi-ec driver is absent, the widget hides itself (or shows an
explainer if you set `hideWhenUnsupported` to off).

## Setup (one time, not optional)

MControlCenter's helper side-stepped file permissions by running as root;
this widget replaces that with a udev-granted group. Run once, as root:

```bash
sudo ~/.config/omarchy/plugins/tanmay.msi-power/setup/grant-msi-ec-access.sh
# (+ optional second arg = the user to grant, defaults to $SUDO_USER)
```

This installs `setup/90-msi-ec.rules` to `/etc/udev/rules.d/`, creates the
`msi-ec` group, adds your user to it, and re-applies the permissions
immediately. It also loads and preloads the `msi_ec` driver and the `ec_sys`
raw interface at boot (the DKMS package does **not** auto-load them — without
this step the widget hides after the first reboot), and grants the group
read-only access to the raw EC file for the fan tachometer.
**Log out and back in** (or reboot) so your session joins the group, then
verify:

```bash
id   # → groups, gid=1000(msi-ec), msi-ec should be listed
getent group msi-ec   # → msi-ec:x:958:<your user>
```

That's it — no daemon, no helper package, no re-run on reboot (the udev rule
re-enforces the sysfs perms and the boot configs reload the drivers and
re-apply the read-only raw-EC grant every boot). To undo it later, remove
the rule and group:
`rm /etc/udev/rules.d/90-msi-ec.rules`, re-login, then `groupdel msi-ec`.

## Install

The driver must be loaded (built in, DKMS `msi-ec`, or whatever the distro
ships); no `mcontrolcenter` package is needed anymore. Then add and enable
the plugin — the grant is applied automatically during `plugin add`:

```bash
omarchy plugin add https://github.com/tanmaypanda-14/omarchy-msi-power.git --enable
omarchy bar move omarchy.power --section right   # optional, position in right section
```

The plugin ships a lifecycle (automation) layer so the omarchy plugin manager
runs the root-side setup for you:

```bash
omarchy plugin add      tanmay.msi-power   # runs setup/install.sh   → grant via sudo
omarchy plugin update   tanmay.msi-power   # re-runs setup/install.sh (idempotent)
omarchy plugin remove   tanmay.msi-power   # runs setup/uninstall.sh → revoke via sudo
```

omarchy's CLI has no hook mechanism, so one script adds the hooks to
`/usr/bin/omarchy-plugin-{add,update,remove}`. They are replaced whenever omarchy
is updated — re-apply after such an update:

```bash
sudo setup/cli-hooks.sh install    # or: sudo <plugin>/setup/cli-hooks.sh install
sudo setup/cli-hooks.sh remove     # revert later
```

If a grant/revoke runs in a non-interactive terminal, the hook prints how to
run the script manually instead of blocking; the plugin itself still
installs/uninstalls.

For a local checkout, enable directly:

```bash
omarchy plugin enable tanmay.msi-power right
omarchy plugin validate ~/.config/omarchy/plugins/tanmay.msi-power
```

Saved edits under `~/.config/omarchy/plugins/` hot-reload the panel, but the
bar icon only picks up `Panel.qml` changes after a shell restart
(`omarchy-restart-shell`). Force a plugin rescan with
`omarchy-shell shell rescanPlugins`.

## Usage

- **Left-click** the gauge icon — open the panel.
- **Right-click** — cycle power mode (Super Battery → Balanced → High).

## Layout

```
MSI Power/
├── manifest.json       # bar-widget manifest + settings schema
├── Panel.qml           # bar icon, keyboard panel, sensor + control rows
├── Service.qml         # sysfs polling, write dispatch, auto mode
├── Model.js            # mode labels, snapshot parsing
├── bin/
│   └── omarchy-msi-stats  # CPU/RAM/storage sampler (bundled, polled by Panel)
├── scripts/
│   ├── msi-read.sh     # one-line JSON snapshot of the EC state (reads)
│   ├── msi-set.sh      # apply a setting by writing the sysfs attribute directly
│   └── msi-fan-curve.sh # MCC-style fan-curve read/apply (raw EC, root for apply)
└── setup/
     ├── 90-msi-ec.rules              # udev rule: sysfs group-writable + raw-EC read grant
     ├── grant-msi-ec-access.sh       # one-shot root grant (group + rules + apply)
     ├── msi-ec-tmpfiles.conf         # boot perms: debugfs traversal + io read-only (0640)
     ├── ec-sys-write.conf            # modprobe: ec_sys write_support=1 (root curve writes)
     ├── msi-fan-curve.sudoers        # sudoers: msi-ec group NOPASSWD for curve `apply` only
     └── modules-load.conf            # preload msi_ec + ec_sys at boot
```

## Uninstall

```bash
omarchy plugin remove tanmay.msi-power   # also revokes the grants (setup/uninstall.sh)
```

The lifecycle hook runs `setup/uninstall.sh` before the plugin folder is
deleted: it removes the udev rule, the modules-load/tmpfiles configs, resets
the debugfs permissions, and deletes the `msi-ec` group (best-effort — the
group stays if a session still holds it, and vanishes after everyone logs
out). Manual fallback if the hook couldn't prompt for sudo:

```bash
sudo ~/.config/omarchy/plugins/tanmay.msi-power/setup/uninstall.sh
```

The EC holds any changes you made across reboots.

[MControlCenter]: https://github.com/dmitry-s93/MControlCenter