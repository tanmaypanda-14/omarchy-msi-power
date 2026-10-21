# MSI Center — bar summary

The [msi-center](https://github.com/tanmaypanda-14/msi-center-rust) app as a
single bar pill: the same four sensors and the same seven settings, nothing
else. Every hardware interaction is the same sysfs write the desktop app
makes — no raw EC writes, no fan-curve editor, no root helper, no daemon.

## What it shows

| Sensor | Source |
|---|---|
| CPU temperature | `msi-ec/cpu/realtime_temperature` |
| Fan speed (RPM) | `0xCC/0xCD` ticks, `480000 / ticks` (same as the app) |
| Fan level | `msi-ec/cpu/realtime_fan_speed` |
| Battery + AC | `BAT1/capacity`, `ADP1/online` |

## What it controls

| Setting | Write | Values |
|---|---|---|
| Power mode | `msi-ec/shift_mode` | Super Battery / Balanced / High Performance |
| Fan mode | `msi-ec/fan_mode` | Auto / Silent / Advanced |
| Cooler Boost | `msi-ec/cooler_boost` | on / off |
| Charge limit | `BAT1/charge_control_end_threshold` | 60 / 80 / 100 |
| Keyboard backlight | `LEDs/…::kbd_backlight/brightness` | cycles 0…max |
| Swap Fn / Win | `msi-ec/win_key` | left / right |
| Block webcam | `msi-ec/webcam_block` | on / off |

This is the full feature set of the app. GPU, CPU usage, RAM, disks and the
MControlCenter fan-curve tables were removed: the app does not have them.

## Permissions

The `msi-ec` group gets write access to **exactly seven files** — the five
`msi-ec` attributes above, the battery threshold and the keyboard LED. The
raw EC image is `0640 root:msi-ec`, readable only for the tachometer.

The simplest setup is the msi-center package, which installs the same udev
rule system-wide:

```sh
sudo pacman -U msi-center-0.2.3-1-x86_64.pkg.tar.zst
```

Standalone (no package), run the bundled setup once:

```sh
sudo setup/grant-msi-ec-access.sh
# log out and back in so your session joins the msi-ec group
```

`setup/install.sh` and `setup/uninstall.sh` are the lifecycle hooks used by
`omarchy plugin add/remove`.

## Install

```sh
omarchy plugin add tanmay.msi-power
```

or symlink/copy this directory to
`~/.config/omarchy/plugins/tanmay.msi-power`.

## Bar interaction

- Left click: open the panel
- Right click: cycle power mode
- `j`/`k`: move the cursor, `Enter`: activate, `r`: refresh, `m`: power mode,
  `f`: fan mode
- IPC: `qs ipc call tanmay.msi-power status|open|close|toggle|refresh|cycleShift`

## Requirements

- `msi-ec` kernel driver loaded (DKMS)
- `ec_sys` for RPM only; it can stay read-only (`write_support=0`)
- Wayland + Quickshell (Omarchy)
