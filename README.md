# MSI Power — Omarchy bar widget

Full MControlCenter coverage for MSI laptops plus a system monitor in one
`bar-widget` plugin (`tanmay.msi-power`):

- **Power mode** (user scenario): Super Battery / Balanced / High Performance
  (`eco` / `comfort` / `sport` on the EC)
- **Fan** profile (Auto / Silent / Advanced), **Cooler Boost** toggle, and
  **USB Power Share** (charge devices while the laptop is off)
- **Sensors**: read-only text rows in the network-panel style — CPU usage, EC
  temperature and fan %, RAM and swap, and a per-disk storage line with disk
  temperature. EC sensor rows come from sysfs; system stats from the bundled
  `bin/omarchy-msi-stats` sampler (same pipeline as the sysmon plugin).

Only hardware features the embedded controller actually reports are shown —
the EC sensor rows disappear automatically on models that lack them.

> **Fan reading units**: the `msi-ec` driver exposes fan speed only as a
> 0–100 % value (raw EC byte at `0x71`). It does not map a tachometer/RPM
> register, and this laptop exposes no `fan[0-9]_input` hwmon device, so the
> widget shows **fan percent** rather than RPM.

## How it works

Fully standalone — MControlCenter and its root D-Bus helper are **not**
required and never run. Reverse-engineering the helper
([src/helper/msi-ec.cpp][MControlCenter]) shows every setter it exposed is a
plain `write()` to one sysfs file; this widget does exactly that, in place:

- **Reads** come from sysfs (`/sys/devices/platform/msi-ec/…`, battery,
  LED). Everything is world-readable, so the widget never needs privileges
  just to report state, and it polls every `refreshMs` (default 2s).
- **Writes** go straight to the same sysfs attributes the helper used
  (`shift_mode`, `fan_mode`, `cooler_boost`, …). The kernel driver owns them
  as `root:root 0644`, so a one-shot udev setup makes them group-writable:
  a `msi-ec` group + a small rule — nothing runs in the background afterwards.
- **USB Power Share** is the one feature the `msi-ec` driver does not export,
  so the widget reads/writes raw EC byte `0xbf` through the `ec_sys` debugfs
  interface — exactly what MControlCenter's helper does (`operate.cpp`,
  `0x28` on / `0x08` off). The one-shot setup preloads `ec_sys
  write_support=1` and grants the group read/write on the debugfs file via
  tmpfiles. Byte-for-byte parity with MControlCenter, and the toggle only
  appears when the byte actually holds a known power-share state, so an EC
  that uses `0xbf` for something else is never written to.

> **Features the EC doesn't support**: MControlCenter's "fan configurations"
> (custom fan curves) and per-preset fan speeds target the older GE/GP/GF
> gaming ECs and write legacy registers (`0x72`/`0x6a`/`0x8a`/`0x82`). This
> Modern 15's Gen-2 EC exposes neither a curve interface nor a basic fan
> speed (`fan_mode` is `auto/silent/advanced` only), so those controls are
> not shown — and would be no-ops here anyway.

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
immediately. It also enables the raw EC interface for USB Power Share (loads
`ec_sys` with `write_support`, installs the boot config under
`/etc/modprobe.d/`, `/etc/modules-load.d/` and `/etc/tmpfiles.d/`).
**Log out and back in** (or reboot) so your session joins the group, then
verify:

```bash
id msi-ec
```

That's it — no daemon, no helper package, no re-run on reboot (the udev rule
re-enforces the perms every time the device appears). To undo it later,
remove the rule and group (`rm /etc/udev/rules.d/90-msi-ec.rules`, re-login,
then `groupdel msi-ec`).

## Install

The driver must be loaded (built in, DKMS `msi-ec`, or whatever the distro
ships); no `mcontrolcenter` package is needed anymore. Then add and enable
the plugin:

```bash
omarchy plugin add https://github.com/<you>/omarchy-msi-power.git --enable
omarchy bar move omarchy.power --section right   # optional, position in right section
```

For a local checkout, enable directly:

```bash
omarchy plugin enable tanmay.msi-power right
omarchy plugin validate ~/.config/omarchy/plugins/tanmay.msi-power
```

Saved edits under `~/.config/omarchy/plugins/` hot-reload. Force a reload with
`omarchy-shell shell rescanPlugins`.

## Usage

- **Left-click** the bolt icon — open the panel.
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
│   └── msi-set.sh      # apply a setting by writing the sysfs attribute directly
└── setup/
    ├── 90-msi-ec.rules              # udev rule: make msi-ec sysfs group-writable
    ├── grant-msi-ec-access.sh       # one-shot root grant (group + rules + apply)
    ├── msi-ec-tmpfiles.conf         # boot-time perms on the ec_sys debugfs file
    ├── ec_sys-modprobe.conf         # ec_sys write_support=1 module option
    └── ec_sys-load.conf             # preload ec_sys at boot
```

## Uninstall

```bash
omarchy plugin remove tanmay.msi-power
sudo rm /etc/udev/rules.d/90-msi-ec.rules          # undo the sysfs grant (optional)
sudo rm /etc/tmpfiles.d/msi-ec.conf \
        /etc/modprobe.d/msi-ec.conf \
        /etc/modules-load.d/msi-ec.conf            # undo the ec_sys grant (optional)
```

The EC holds any changes you made across reboots.

[MControlCenter]: https://github.com/dmitry-s93/MControlCenter