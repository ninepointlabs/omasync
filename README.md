# OmaSync

A native [Omarchy](https://omarchy.org/) bar widget for
[Syncthing](https://syncthing.net/). Folder and device status at a glance, live
transfer rates, incoming share invites — and full control of the `syncthing`
user service without ever leaving the bar, or seeing a password prompt.

<img src="preview.png" alt="The OmaSync panel, showing a pending device invite, two folders and a connected remote device" width="440">

## Why

The Syncthing Web GUI is a browser tab you have to remember to open. OmaSync
puts the parts you actually check — is it running, is everything in sync, who
is connected, is anything waiting on me — into the bar, and gives you the
handful of controls worth having a shortcut for.

It also starts and stops the daemon, which the Web GUI cannot do.

## Features

**Service control**

- Start and stop `syncthing.service` from the switch in the panel header, or by
  right-clicking the bar icon
- Restart the service, or restart Syncthing itself
- Toggle start-at-login, which changes only what happens at the *next* login
  and never disturbs a daemon that is currently running
- Everything goes through `systemctl --user`, so there is no `sudo` and no
  polkit prompt, ever

**Folders**

- Every folder with its label, state, size, type and a live progress bar
- Rescan one folder or all of them
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
- Folders another device has offered to share can be accepted — creating the
  folder under `~/Sync/<label>` — or dismissed

**Everything else**

- Syncthing's own error list, with a clear button
- Copy this machine's device ID; open the Web GUI
- Optional desktop notifications for devices connecting and disconnecting,
  folders finishing or failing, and new invites
- Optional bar label showing transfer rate, overall completion, or connected
  device count

## In the bar

<img src="preview-bar.png" alt="The OmaSync icon in the Omarchy bar with a badge for a pending invite" width="300">

The Syncthing mark is drawn natively rather than loaded from an SVG, so it
takes your theme's foreground colour exactly, stays crisp at bar size, spins
while a sync is running, and picks up a badge when something is waiting for
you. When the service is stopped it is struck through:

<img src="preview-stopped.png" alt="The OmaSync panel with the Syncthing service stopped" width="440">

## Requirements

- `syncthing` — `omarchy pkg add syncthing`
- `/usr/bin/python3` — part of a base Arch install
- `wl-clipboard` for the copy actions, `xdg-open` for opening folders and the
  Web GUI

Syncthing does not need to be running, configured, or ever started: the panel
renders a sensible first-run state, and the header switch will start it.

## Install

```bash
omarchy plugin add https://github.com/ninepointlabs/omasync --enable
```

Or from a clone:

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
| `refreshIntervalSec` | `10` | Backstop poll interval. Syncthing's event stream already pushes changes as they happen, so this only matters while the stream is down. |
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

`bin/omasync-bridge` is the only program the plugin starts. It finds the local
Syncthing config, reads the API key out of the `<gui>` block, and does all the
REST and `systemctl` work. Every subcommand prints one JSON object and exits 0,
so a failure arrives as data the panel can render rather than as an exception
in a signal handler. It is invoked by absolute path under
`/usr/bin/python3 -I -S`, never through a `PATH` lookup, so a `mise` or `conda`
Python on `PATH` cannot end up handling your API key.

The panel stays current through Syncthing's own `/rest/events` long-poll rather
than by polling hard: the bridge blocks until the daemon has something to say,
and the panel then re-reads a full snapshot. Applying a snapshot is cheap and
far easier to reason about than replaying event deltas by hand.

The bar instantiates a widget per monitor, so the plugin also declares the
`service` kind. The shell mounts that service once and shares it across
screens, which keeps a multi-monitor setup from polling — and notifying — once
per display.

Transfer rates are computed from successive samples of Syncthing's cumulative
byte counters, the same way its own Web GUI does it, because the API reports no
rate of its own.

## Development

```bash
./tests/run
```

That runs the Omarchy manifest validator, the bridge's Python tests, the
model's node tests, and a QML syntax check.

`Model.js` holds all the presentation logic as plain functions over plain data,
so it can be exercised from node without a running shell.

Saving a `.qml` file under `~/.config/omarchy/plugins/ninepointlabs.omasync`
hot-reloads it. `Model.js` is different: the QML engine caches imported
JavaScript, so a change there needs `omarchy restart shell` — neither saving
the file nor `omarchy-shell shell rescanPlugins` is enough, and the panel will
keep rendering the old logic against new data until you restart.

## License

MIT — see [LICENSE](LICENSE).
