import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import "Model.js" as Model

// Owns every conversation with Syncthing: the periodic snapshot, the event
// long-poll that makes the panel feel live, the systemd user unit, and the
// one-shot actions the panel fires. The panel reads state from here and never
// starts a process itself.
Item {
  id: root

  property var settings: ({})

  // False on the per-widget fallback instance whenever the shell has mounted
  // the shared one. An inactive service starts no timers and no processes, so
  // a two-monitor bar still polls, long-polls and notifies exactly once.
  property bool active: true

  // The bridge is addressed by absolute path under a fixed interpreter. Both
  // halves are deliberate: a PATH lookup could pick up a mise/conda python
  // whose standard library differs, and -I -S keeps user site-packages and
  // PYTHON* environment out of a script that talks to a local API key.
  readonly property string pluginDirectory: Model.fileUrlPath(Qt.resolvedUrl("."))
  readonly property string bridgePath: pluginDirectory + "/bin/omasync-bridge"
  readonly property var bridgePrefix: ["/usr/bin/python3", "-I", "-S", "-B", bridgePath]

  // ------------------------------------------------------------ published

  property var snapshot: emptySnapshot()
  property bool ready: false
  property bool refreshing: false
  property string lastError: ""
  property string actionStatus: ""
  property real inRate: 0
  property real outRate: 0

  readonly property var overall: Model.overallState(snapshot)
  readonly property string stateKey: overall.key
  readonly property string stateLabel: overall.label
  readonly property bool installed: snapshot.installed === true
  readonly property bool configured: snapshot.configured === true
  readonly property bool apiReachable: snapshot.api && snapshot.api.reachable === true
  readonly property bool unitExists: snapshot.service && snapshot.service.exists === true
  readonly property bool autostart: snapshot.service && snapshot.service.enabled === "enabled"
  readonly property var folders: snapshot.folders || []
  readonly property var devices: snapshot.devices || []
  readonly property var pendingDevices: snapshot.pendingDevices || []
  readonly property var pendingFolders: snapshot.pendingFolders || []
  readonly property var errors: snapshot.errors || []
  readonly property int pendingCount: Model.pendingCount(snapshot)
  readonly property string guiUrl: snapshot.api ? String(snapshot.api.url || "") : ""
  readonly property string myId: String(snapshot.myID || "")

  // Optimistic service state so the hero switch throws the instant it is
  // clicked instead of waiting for the next snapshot. -1 means "just follow
  // whatever the snapshot says".
  property int _desiredRunning: -1
  readonly property bool serviceRunning: _desiredRunning === -1
    ? (snapshot.service ? snapshot.service.running === true : false)
    : (_desiredRunning === 1)

  readonly property bool busy: snapshotProcess.running || actionProcess.running

  readonly property int refreshIntervalSec: intSetting("refreshIntervalSec", 10, 2, 600)
  readonly property bool notifyEnabled: setting("notify", true) === true

  // -------------------------------------------------------------- private

  property var _rateSample: null
  property var _previousSnapshot: null
  property var _notified: ({})
  property int _eventCursor: 0
  property int _eventFailures: 0
  property bool _firstSnapshotDone: false

  function emptySnapshot() {
    return {
      ok: false,
      installed: false,
      configured: false,
      service: { exists: false, active: "unknown", enabled: "unknown", running: false },
      api: { reachable: false, url: "" },
      folders: [],
      devices: [],
      pendingDevices: [],
      pendingFolders: [],
      errors: []
    }
  }

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function intSetting(name, fallback, min, max) {
    var n = parseInt(String(setting(name, fallback)), 10)
    if (!isFinite(n)) n = fallback
    return Math.max(min, Math.min(max, n))
  }

  // ------------------------------------------------------------- snapshot

  function refresh() {
    if (!active || snapshotProcess.running) return
    refreshing = true
    snapshotProcess.command = bridgePrefix.concat(["snapshot"])
    snapshotProcess.running = true
  }

  function applySnapshot(text) {
    var parsed = Model.parseBridge(text)
    if (parsed.ok === false && parsed.installed === undefined) {
      // A bridge-level failure (bad interpreter, missing script) rather than a
      // Syncthing one; keep the last good snapshot and surface the reason.
      lastError = String(parsed.error || "Could not reach the Syncthing bridge")
      ready = true
      return
    }

    var previous = snapshot
    var totals = parsed.totals || {}
    var sample = {
      atMs: Date.now(),
      inBytesTotal: Number(totals.inBytesTotal) || 0,
      outBytesTotal: Number(totals.outBytesTotal) || 0
    }
    var rates = Model.computeRates(_rateSample, sample)
    inRate = rates.inRate
    outRate = rates.outRate
    _rateSample = sample

    snapshot = parsed
    ready = true
    // A refused connection is the expected answer while the daemon is stopped
    // or still binding its API, and the panel already says so in words. Only
    // report an API error once the unit is up and settled, where it means
    // something real -- a rejected key, a wedged daemon.
    var apiError = parsed.api ? String(parsed.api.error || "") : ""
    var apiErrorMatters = apiError !== "" &&
      parsed.service && parsed.service.running === true && !startupRamp.running
    lastError = apiErrorMatters ? apiError : String(parsed.error || "")

    // The snapshot has caught up with the toggle, so stop overriding it.
    if (_desiredRunning !== -1 && parsed.service &&
        (parsed.service.running === true) === (_desiredRunning === 1)) {
      _desiredRunning = -1
    }

    if (notifyEnabled && _firstSnapshotDone) announce(Model.notifiableChanges(previous, parsed))
    _firstSnapshotDone = true

    syncEventStream()
  }

  // --------------------------------------------------------------- events

  // One long-poll against /rest/events. It returns as soon as Syncthing has
  // anything to say, which is what makes folder state and transfer figures
  // move in near real time without polling hard.
  function syncEventStream() {
    var wanted = active && serviceRunning && apiReachable
    if (!wanted) {
      eventProcess.running = false
      return
    }
    if (eventProcess.running) return
    eventProcess.command = bridgePrefix.concat(["events", String(_eventCursor)])
    eventProcess.running = true
  }

  function applyEvents(text) {
    var parsed = Model.parseBridge(text)
    if (parsed.ok === true) {
      _eventFailures = 0
      _eventCursor = Number(parsed.since) || _eventCursor
      // Any event at all means the snapshot is stale; re-read rather than try
      // to apply deltas by hand.
      if (Number(parsed.count) > 0) refresh()
      Qt.callLater(syncEventStream)
      return
    }
    // Back off on repeated failure so a stopped daemon does not spin the
    // bridge. The periodic refresh still restarts the stream once it recovers.
    _eventFailures = Math.min(_eventFailures + 1, 6)
    eventRetry.interval = 1000 * Math.pow(2, _eventFailures)
    eventRetry.restart()
  }

  // -------------------------------------------------------------- actions

  function runAction(args, statusText) {
    if (!active || actionProcess.running) return
    actionStatus = statusText || ""
    actionProcess.command = bridgePrefix.concat(args)
    actionProcess.running = true
  }

  function startService() {
    _desiredRunning = 1
    // The daemon needs a moment to bind its API after systemd returns, so the
    // ramp timer polls quickly until the API answers.
    startupRamp.ticks = 0
    startupRamp.start()
    runAction(["service", "start"], "Starting Syncthing…")
  }

  function stopService() {
    _desiredRunning = 0
    runAction(["service", "stop"], "Stopping Syncthing…")
  }

  function toggleService() {
    if (serviceRunning) stopService()
    else startService()
  }

  function restartService() {
    _desiredRunning = 1
    startupRamp.ticks = 0
    startupRamp.start()
    runAction(["service", "restart"], "Restarting Syncthing…")
  }

  function setAutostart(enabled) {
    _desiredRunning = enabled ? 1 : _desiredRunning
    runAction(["service", enabled ? "enable" : "disable"],
              enabled ? "Enabling autostart…" : "Disabling autostart…")
  }

  function rescanAll() { runAction(["rescan"], "Rescanning all folders…") }
  function rescanFolder(folder) {
    if (!folder) return
    runAction(["rescan", String(folder.id)], "Rescanning " + folder.label + "…")
  }

  function toggleFolder(folder) {
    if (!folder) return
    var pausing = !folder.paused
    runAction([pausing ? "folder-pause" : "folder-resume", String(folder.id)],
              (pausing ? "Pausing " : "Resuming ") + folder.label + "…")
  }

  function revertFolder(folder) {
    if (!folder) return
    runAction(["folder-revert", String(folder.id)], "Reverting local changes in " + folder.label + "…")
  }

  function toggleDevice(device) {
    if (!device) return
    var pausing = !device.paused
    runAction([pausing ? "device-pause" : "device-resume", String(device.deviceID)],
              (pausing ? "Pausing " : "Resuming ") + device.name + "…")
  }

  function acceptDevice(pending) {
    if (!pending) return
    runAction(["accept-device", String(pending.deviceID), String(pending.name || "")],
              "Adding " + (pending.name || Model.shortDeviceId(pending.deviceID)) + "…")
  }

  function rejectDevice(pending) {
    if (!pending) return
    runAction(["reject-device", String(pending.deviceID)], "Dismissed")
  }

  function acceptFolder(pending) {
    if (!pending) return
    runAction(["accept-folder", String(pending.folderID), String(pending.label || ""), String(pending.deviceID)],
              "Accepting " + (pending.label || pending.folderID) + "…")
  }

  function rejectFolder(pending) {
    if (!pending) return
    runAction(["reject-folder", String(pending.folderID), String(pending.deviceID)], "Dismissed")
  }

  function clearErrors() { runAction(["clear-errors"], "Cleared") }

  function restartSyncthing() {
    runAction(["syncthing-restart"], "Restarting Syncthing…")
  }

  // ------------------------------------------------------------ utilities

  function copyToClipboard(value) {
    var text = String(value || "")
    if (text === "") return
    Quickshell.execDetached(["wl-copy", "--", text])
    actionStatus = "Copied"
    statusClear.restart()
  }

  function copyMyId() {
    if (myId === "") return
    copyToClipboard(myId)
  }

  function openGui() {
    if (guiUrl === "") return
    Quickshell.execDetached(["xdg-open", guiUrl])
  }

  function openFolder(folder) {
    if (!folder || !folder.path) return
    Quickshell.execDetached(["xdg-open", String(folder.path)])
  }

  function announce(events) {
    for (var i = 0; i < events.length; i++) {
      var event = events[i]
      if (_notified[event.key]) continue
      _notified[event.key] = true
      Quickshell.execDetached([
        "omarchy-notification-send",
        "--app-name", "OmaSync",
        "-g", "󰓦",
        "-u", event.urgent ? "normal" : "low",
        String(event.title || "OmaSync"),
        String(event.body || "")
      ])
    }
    // The de-dup map only needs to outlive the condition that produced it;
    // clearing it wholesale once it grows keeps it from leaking across a long
    // uptime while still suppressing the repeats that matter.
    var keys = Object.keys(_notified)
    if (keys.length > 200) _notified = ({})
  }

  // -------------------------------------------------------------- plumbing

  Process {
    id: snapshotProcess
    running: false
    command: []
    stdout: StdioCollector { id: snapshotOut; waitForEnd: true }
    stderr: StdioCollector { id: snapshotErr; waitForEnd: true }
    onExited: function(exitCode) {
      root.refreshing = false
      if (exitCode === 0) root.applySnapshot(snapshotOut.text)
      else {
        root.ready = true
        root.lastError = String(snapshotErr.text || "").trim() || "OmaSync bridge failed"
      }
    }
  }

  Process {
    id: actionProcess
    running: false
    command: []
    stdout: StdioCollector { id: actionOut; waitForEnd: true }
    stderr: StdioCollector { id: actionErr; waitForEnd: true }
    onExited: function(exitCode) {
      var parsed = Model.parseBridge(actionOut.text)
      if (exitCode !== 0 || parsed.ok === false) {
        root.actionStatus = ""
        root.lastError = String(parsed.error || actionErr.text || "Action failed").trim()
        // A failed toggle must not leave the switch lying about the state.
        root._desiredRunning = -1
      } else {
        root.lastError = ""
        statusClear.restart()
      }
      root.refresh()
    }
  }

  Process {
    id: eventProcess
    running: false
    command: []
    stdout: StdioCollector { id: eventOut; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode === 0) root.applyEvents(eventOut.text)
      else {
        root._eventFailures = Math.min(root._eventFailures + 1, 6)
        eventRetry.interval = 1000 * Math.pow(2, root._eventFailures)
        eventRetry.restart()
      }
    }
  }

  Timer {
    id: refreshTimer
    interval: root.refreshIntervalSec * 1000
    repeat: true
    running: root.active
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  Timer {
    // While the daemon is coming up, systemd reports the unit active well
    // before the REST API binds. Poll fast until the API answers, then stop.
    id: startupRamp
    property int ticks: 0
    interval: 1000
    repeat: true
    running: false
    onTriggered: {
      ticks += 1
      root.refresh()
      if (root.apiReachable || ticks > 20) stop()
    }
  }

  Timer {
    id: eventRetry
    interval: 2000
    repeat: false
    onTriggered: root.syncEventStream()
  }

  Timer {
    id: statusClear
    interval: 2500
    repeat: false
    onTriggered: root.actionStatus = ""
  }

  Component.onDestruction: {
    // Long-poll processes outlive a plugin hot-reload unless they are stopped.
    eventProcess.running = false
  }
}
