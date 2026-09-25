# OmaSync

OmaSync is a native Omarchy bar widget for [Syncthing](https://syncthing.net/): folder and
device status at a glance, live transfer rates, incoming share invites, and
full control of the `syncthing` user service without leaving the bar.

![The OmaSync panel](preview.png)

## Features

**Service control**

- Start and stop the `syncthing.service` user unit from the switch in the panel
  header, or by right-clicking the bar icon
- Restart the service
- Toggle "start at login" (`systemctl --user enable` / `disable`) — this changes
  only what happens at the *next* login, never the currently running daemon
- Everything runs through `systemctl --user`, so there is no `sudo` and no
  polkit prompt, ever

**Folders**

- Every folder with its label, state, size, type and live progress bar
- Rescan a single folder, or all of them at once
- Pause and resume individual folders
- Revert local changes on a receive-only folder that has diverged
- Click a folder to open it in your file manager

**Devices**

- Every remote device, connected first, with a connection pip, address,
  transport and per-device completion
- Pause and resume a device
- Copy a device ID to the clipboard

**Invites**

- Incoming device invites can be accepted or dismissed in place
- Folders that another device has offered to share can be accepted (creating
  the folder under `~/Sync/<label>`) or dismissed

**Everything else**

- Syncthing's own errors, shown in the panel with a clear button
- Copy this machine's device ID
- Open the Syncthing Web GUI
- Optional desktop notifications for devices connecting and disconnecting,
  folders finishing or failing, and new invites
- Optional bar label showing transfer rate, overall completion, or connected
  device count

## Requirements

- `syncthing` — `omarchy pkg add syncthing`
- `/usr/bin/python3` — part of a base Arch install
- `wl-copy` (wl-clipboard) for the copy actions
- `xdg-open` for opening folders and the Web GUI

Syncthing does not need to be running, configured, or even started once: the
panel renders a useful first-run state and the header switch will start it.

## Install

```bash
omarchy plugin add https://github.com/ninepointlabs/omasync --enable
```

Or, from a clone:

```bash
git clone https://github.com/ninepointlabs/omasync \
  ~/.config/omarchy/plugins/ninepointlabs.omasync
omarchy plugin enable ninepointlabs.omasync --section right
```

## Mouse

| Action | Result |
|--------|--------|
| Left click the bar icon | Open the panel |
| Right click the bar icon | Start or stop the Syncthing service |
| Middle click the bar icon | Rescan all folders |
| Click a folder row | Open that folder in your file manager |

## Keyboard

Inside the panel:

| Key | Action |
|-----|--------|
| `j` / `k`, arrows | Move the cursor |
| `enter` / `space` | Activate the current row |
| `t` | Start or stop the Syncthing service |
| `r` | Rescan the selected folder, or all folders |
| `p` | Pause or resume the selected folder or device |
| `o` | Open the selected folder |
| `v` | Revert local changes in the selected receive-only folder |
| `c` | Copy the selected device's ID, the selected folder's path, or this machine's ID |
| `g` | Open the Web GUI |
| `x` | Clear Syncthing's error list |
| `tab` | Move to the next bar panel |
| `esc` | Close |

## Settings

Set these on the widget's entry in `~/.config/omarchy/shell.json`, or through
the bar's widget settings:

| Key | Default | Meaning |
|-----|---------|---------|
| `refreshIntervalSec` | `10` | Backstop poll interval. Syncthing's event stream already pushes changes as they happen, so this only matters when the stream is down. |
| `notify` | `true` | Desktop notifications for connections, completions, failures and invites. |
| `barLabel` | `"none"` | `none`, `rate`, `percent`, or `devices`. Always hidden on a vertical bar. |

## IPC

```bash
omarchy-shell ninepointlabs.omasync open
omarchy-shell ninepointlabs.omasync toggle
omarchy-shell ninepointlabs.omasync start
omarchy-shell ninepointlabs.omasync stop
omarchy-shell ninepointlabs.omasync restart
omarchy-shell ninepointlabs.omasync rescan
omarchy-shell ninepointlabs.omasync status      # "Up to date", "Syncing 2 folders", …
omarchy-shell ninepointlabs.omasync deviceId
```

## How it works

`bin/omasync-bridge` is the only program the plugin starts. It finds the
local Syncthing config, reads the API key out of the `<gui>` block, and does
all the REST and `systemctl` work; every subcommand prints one JSON object, so
a failure is data the panel can render rather than an exception. It is invoked
by absolute path under `/usr/bin/python3 -I -S`, never through a `PATH` lookup,
so a `mise` or `conda` Python on `PATH` cannot change what handles your API key.

The panel stays current through Syncthing's own `/rest/events` long-poll rather
than by polling hard: the bridge blocks until the daemon has something to say,
and the panel then re-reads a full snapshot. The bar instantiates a widget per
monitor, so the plugin also declares the `service` kind — the shell mounts the
service once and shares it across screens, which keeps a multi-monitor setup
from polling and notifying once per display.

Transfer rates are computed from successive samples of Syncthing's cumulative
byte counters, the same way its own Web GUI does it, because the API reports no
rate of its own.

## Development

```bash
./tests/run
```

That runs the manifest validator, the bridge's Python tests, the model's node
tests, and a QML syntax check.

The repository lives in `~/Projects/omasync`; the copy Omarchy loads
lives in `~/.config/omarchy/plugins/ninepointlabs.omasync`. Saving a file
under the plugin directory hot-reloads it.

## License

MIT — see [LICENSE](LICENSE).
