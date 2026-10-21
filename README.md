# MSI Center — bar summary

The [msi-center](https://github.com/tanmaypanda-14/msi-center-rust) app as a
single bar pill: the EC sensors and four of the app's settings, plus read-only
CPU/GPU clocks and memory. Every hardware interaction is the same sysfs write
the desktop app makes — no raw EC writes, no fan-curve editor, no root helper,
no daemon.

## What it shows

| Sensor | Source |
|---|---|
| CPU temperature | `msi-ec/cpu/realtime_temperature` |
| CPU clock | average of `cpu*/cpufreq/scaling_cur_freq` |
| GPU clock | `amdgpu` hwmon `freq1_input` |
| Memory | `/proc/meminfo` (`MemTotal - MemAvailable`) |
| Fan speed (RPM) | `0xCC/0xCD` ticks, `480000 / ticks` (same as the app) |
| Fan level | `msi-ec/cpu/realtime_fan_speed` |
| AC state | `ADP1/online` |

## What it controls

| Setting | Write | Values |
|---|---|---|
| Power mode | `msi-ec/shift_mode` | Super Battery / Balanced / High Performance |
| Fan mode | `msi-ec/fan_mode` | Auto / Silent / Advanced |
| Cooler Boost | `msi-ec/cooler_boost` | on / off |
| Charge limit | `BAT1/charge_control_end_threshold` | 60 / 80 / 100 |

The keyboard backlight, Fn/Win swap and webcam block controls were removed
from the pill; the desktop app still has them.

The EC readings match the app, and the four controls above are the same sysfs
writes. CPU/GPU clocks and memory are read-only host stats the app does not
show; disk usage and the MControlCenter fan-curve tables are still absent.

## Permissions

The `msi-ec` group gets write access to **exactly seven files** — `shift_mode`,
`fan_mode`, `cooler_boost`, `webcam_block`, `win_key`, the battery threshold
and the keyboard LED. The
raw EC image is `0640 root:msi-ec`, readable only for the tachometer; the
debugfs directories are `0710`, so the group can traverse to the image but
cannot list debugfs.

**Single source.** The msi-center package ships the udev rule, the tmpfiles
entry, the module-load list, the `ec_sys` modprobe hook and the
`msi-ec-perms.service` unit. The app's
[curl installer](https://github.com/tanmaypanda-14/msi-center-rust#install)
does this for you. If the app is already installed, run the bundled setup —
it detects the package, uses its integration and removes any old per-plugin
duplicates:

```sh
sudo setup/grant-msi-ec-access.sh
# log out and back in so your session joins the msi-ec group
```

The grant is re-applied automatically after every boot and after any
`modprobe -r ec_sys; modprobe ec_sys` cycle, so nothing has to be re-run
manually. Standalone (no package), the same command installs the plugin's
own copies under distinct `msi-power` names.

`setup/install.sh` and `setup/uninstall.sh` are the lifecycle hooks used by
`omarchy plugin add/remove`. Uninstalling the widget leaves the app's
integration alone when msi-center is installed.

## Install

One command installs the app, the matching `msi-ec` DKMS driver, the
permissions, and this widget (on Omarchy):

```sh
curl -fsSL https://github.com/tanmaypanda-14/msi-center-rust/releases/latest/download/install.sh | sudo bash
```

It verifies the release checksums, removes old `/etc` duplicates, and leaves
the widget in `~/.config/omarchy/plugins/tanmay.msi-power`; use
`--no-widget` on the app installer if you only want the app.

If the app is already set up, install just the widget:

```sh
omarchy plugin add https://github.com/tanmaypanda-14/omarchy-msi-power.git --enable
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
