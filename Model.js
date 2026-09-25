// Pure presentation logic for the Syncthing plugin.
//
// Everything here is a plain function over plain data so it can be exercised
// from node (`tests/model.test.js`) without a running shell. The QML side
// loads this with `import "Model.js" as Model`; nothing in here may touch a
// QML type, a singleton, or the filesystem.

var KIB = 1024
var UNITS = ["B", "KiB", "MiB", "GiB", "TiB", "PiB"]

// ------------------------------------------------------------ formatting

function formatBytes(bytes) {
  var n = Number(bytes)
  if (!isFinite(n) || n <= 0) return "0 B"
  var unit = 0
  while (n >= KIB && unit < UNITS.length - 1) {
    n = n / KIB
    unit++
  }
  // Bytes are always whole; larger units get one decimal until they are big
  // enough that the decimal is noise.
  var digits = unit === 0 ? 0 : (n < 10 ? 1 : 0)
  return n.toFixed(digits) + " " + UNITS[unit]
}

function formatRate(bytesPerSecond) {
  var n = Number(bytesPerSecond)
  if (!isFinite(n) || n < 1) return ""
  return formatBytes(n) + "/s"
}

function formatDuration(seconds) {
  var total = Math.floor(Number(seconds))
  if (!isFinite(total) || total <= 0) return ""
  var days = Math.floor(total / 86400)
  var hours = Math.floor((total % 86400) / 3600)
  var minutes = Math.floor((total % 3600) / 60)
  if (days > 0) return days + "d " + hours + "h"
  if (hours > 0) return hours + "h " + minutes + "m"
  if (minutes > 0) return minutes + "m"
  return total + "s"
}

function shortDeviceId(deviceId) {
  var id = String(deviceId || "")
  if (id === "") return ""
  // Syncthing itself abbreviates a device to its first dash-group.
  return id.split("-")[0]
}

function relativeTime(iso, nowMs) {
  var then = Date.parse(String(iso || ""))
  if (!isFinite(then)) return ""
  var now = isFinite(nowMs) ? nowMs : Date.now()
  var delta = Math.round((now - then) / 1000)
  if (delta < 0) delta = 0
  if (delta < 45) return "just now"
  return formatDuration(delta) + " ago"
}

// ----------------------------------------------------------------- rates

// Syncthing's API reports cumulative byte counters, never rates; the web GUI
// derives rates client-side from successive samples and so do we. Returns
// zeros whenever the counters cannot be compared -- a restart resets them, and
// a counter that went backwards would otherwise read as a huge negative rate.
function computeRates(previous, current) {
  var zero = { inRate: 0, outRate: 0 }
  if (!previous || !current) return zero
  var elapsed = (Number(current.atMs) - Number(previous.atMs)) / 1000
  if (!isFinite(elapsed) || elapsed <= 0.25) return zero
  var inDelta = Number(current.inBytesTotal) - Number(previous.inBytesTotal)
  var outDelta = Number(current.outBytesTotal) - Number(previous.outBytesTotal)
  if (!isFinite(inDelta) || !isFinite(outDelta) || inDelta < 0 || outDelta < 0) return zero
  return {
    inRate: Math.max(0, inDelta / elapsed),
    outRate: Math.max(0, outDelta / elapsed)
  }
}

// --------------------------------------------------------------- folders

function folderStateLabel(folder) {
  if (!folder) return "Unknown"
  if (folder.paused) return "Paused"
  if (Number(folder.errors) > 0 || Number(folder.pullErrors) > 0) return "Failed items"
  var state = String(folder.state || "unknown")
  if (state === "idle") return Number(folder.needBytes) > 0 ? "Out of sync" : "Up to date"
  if (state === "scanning") return "Scanning"
  if (state === "syncing") return "Syncing"
  if (state === "sync-preparing") return "Preparing"
  if (state === "cleaning") return "Cleaning"
  if (state === "error") return "Error"
  return state.charAt(0).toUpperCase() + state.slice(1)
}

function folderIsBusy(folder) {
  if (!folder || folder.paused) return false
  var state = String(folder.state || "")
  return state === "syncing" || state === "scanning" || state === "sync-preparing" || state === "cleaning"
}

function folderHasProblem(folder) {
  if (!folder) return false
  if (String(folder.state || "") === "error") return true
  return Number(folder.errors) > 0 || Number(folder.pullErrors) > 0
}

function folderDetail(folder) {
  if (!folder) return ""
  if (folder.paused) return "Paused"
  if (folderHasProblem(folder)) {
    var count = Number(folder.errors) + Number(folder.pullErrors)
    return count + (count === 1 ? " failed item" : " failed items")
  }
  if (Number(folder.needBytes) > 0) {
    return formatBytes(folder.needBytes) + " to sync"
  }
  return formatBytes(folder.globalBytes)
}

// "Receive only" and friends read better than the raw config values.
function folderTypeLabel(type) {
  var map = {
    sendreceive: "Send & receive",
    sendonly: "Send only",
    receiveonly: "Receive only",
    receiveencrypted: "Receive encrypted"
  }
  var key = String(type || "")
  return map[key] || key
}

// Reverting is only meaningful where local edits are not supposed to exist.
function folderCanRevert(folder) {
  if (!folder || folder.paused) return false
  return String(folder.type || "") === "receiveonly" && Number(folder.needBytes) > 0
}

// --------------------------------------------------------------- devices

function deviceStatusLabel(device) {
  if (!device) return "Unknown"
  if (device.paused) return "Paused"
  if (!device.connected) return "Disconnected"
  // A device that shares no folder with us has nothing to be a percentage of;
  // Syncthing reports 0% for it, which would read as a sync stuck at zero.
  if (device.sharesFolders === false) return "Connected"
  if (Number(device.completion) < 100) return "Syncing " + Math.floor(Number(device.completion)) + "%"
  return "Up to date"
}

function deviceDetail(device) {
  if (!device) return ""
  if (device.paused) return "Paused"
  if (!device.connected) return "Disconnected"
  var parts = []
  if (device.address) parts.push(String(device.address))
  if (device.type) parts.push(String(device.type).replace(/([a-z])([A-Z])/g, "$1 $2"))
  return parts.join(" · ")
}

// ------------------------------------------------------------- aggregate

// The single state the bar icon and the hero headline agree on. Order matters:
// the worst true thing wins, so an error is never hidden behind "syncing".
function overallState(snapshot) {
  var s = snapshot || {}
  if (!s.installed) return { key: "missing", label: "Syncthing is not installed" }
  var service = s.service || {}
  if (!s.configured && !service.running) return { key: "stopped", label: "Not set up yet" }
  if (!service.running) return { key: "stopped", label: "Stopped" }
  var api = s.api || {}
  if (!api.reachable) return { key: "starting", label: "Starting…" }
  if ((s.errors || []).length > 0) return { key: "error", label: "Syncthing reported an error" }

  var folders = s.folders || []
  var problem = 0
  var busy = 0
  var paused = 0
  var behind = 0
  for (var i = 0; i < folders.length; i++) {
    var folder = folders[i]
    if (folder.paused) { paused++; continue }
    if (folderHasProblem(folder)) problem++
    else if (folderIsBusy(folder)) busy++
    else if (Number(folder.needBytes) > 0) behind++
  }
  if (problem > 0) return { key: "error", label: problem + (problem === 1 ? " folder has failed items" : " folders have failed items") }
  if (busy > 0) return { key: "syncing", label: busy === 1 ? "Syncing 1 folder" : "Syncing " + busy + " folders" }
  if (behind > 0) return { key: "behind", label: behind === 1 ? "1 folder out of sync" : behind + " folders out of sync" }
  if (folders.length === 0) return { key: "idle", label: "No folders yet" }
  if (paused === folders.length) return { key: "paused", label: "All folders paused" }
  return { key: "idle", label: "Up to date" }
}

// Overall local completion across every active folder, weighted by size so a
// big folder does not count the same as a tiny one.
function overallCompletion(folders) {
  var list = folders || []
  var global = 0
  var need = 0
  for (var i = 0; i < list.length; i++) {
    if (list[i].paused) continue
    global += Number(list[i].globalBytes) || 0
    need += Number(list[i].needBytes) || 0
  }
  if (global <= 0) return 100
  return Math.max(0, Math.min(100, (global - need) * 100 / global))
}

function connectedDeviceCount(devices) {
  var list = devices || []
  var count = 0
  for (var i = 0; i < list.length; i++) if (list[i].connected) count++
  return count
}

function pendingCount(snapshot) {
  var s = snapshot || {}
  return (s.pendingDevices || []).length + (s.pendingFolders || []).length
}

// Second line of the hero: who we are connected to, and how fast.
function heroMeta(snapshot, inRate, outRate) {
  var s = snapshot || {}
  var service = s.service || {}
  if (!service.running) return s.configured ? "Service stopped" : "Syncthing has never been started"
  var parts = []
  var devices = s.devices || []
  if (devices.length > 0) {
    parts.push(connectedDeviceCount(devices) + "/" + devices.length + " devices")
  }
  var folders = (s.folders || []).length
  if (folders > 0) parts.push(folders === 1 ? "1 folder" : folders + " folders")
  var down = formatRate(inRate)
  var up = formatRate(outRate)
  if (down !== "") parts.push("↓ " + down)
  if (up !== "") parts.push("↑ " + up)
  if (parts.length === 0) parts.push("Running")
  return parts.join(" · ")
}

// What the bar shows next to the icon, per the `barLabel` setting.
function barLabelText(mode, snapshot, inRate, outRate) {
  var s = snapshot || {}
  var service = s.service || {}
  if (mode === "none" || !service.running) return ""
  if (mode === "rate") {
    var down = formatRate(inRate)
    var up = formatRate(outRate)
    if (down === "" && up === "") return ""
    // A single arrow for whichever direction is actually moving keeps the bar
    // from jittering between one and two readings.
    if (up === "") return "↓" + down
    if (down === "") return "↑" + up
    return "↓" + down + " ↑" + up
  }
  if (mode === "percent") {
    var completion = overallCompletion(s.folders)
    return completion >= 100 ? "" : Math.floor(completion) + "%"
  }
  if (mode === "devices") {
    var devices = s.devices || []
    if (devices.length === 0) return ""
    return connectedDeviceCount(devices) + "/" + devices.length
  }
  return ""
}

// --------------------------------------------------------- notifications

// Diff two snapshots into the things a person would want to be told about.
// Returns [{key, title, body, urgent}]; `key` de-duplicates repeats so a
// notification is not re-sent on every poll while the condition persists.
function notifiableChanges(previous, current) {
  var events = []
  if (!previous || !current) return events

  var before = indexBy(previous.devices, "deviceID")
  var after = current.devices || []
  for (var i = 0; i < after.length; i++) {
    var device = after[i]
    var was = before[device.deviceID]
    if (!was) continue
    if (device.connected && !was.connected) {
      events.push({
        key: "device-up:" + device.deviceID,
        title: device.name,
        body: "Connected",
        urgent: false
      })
    } else if (!device.connected && was.connected && !device.paused) {
      events.push({
        key: "device-down:" + device.deviceID,
        title: device.name,
        body: "Disconnected",
        urgent: false
      })
    }
  }

  var foldersBefore = indexBy(previous.folders, "id")
  var foldersAfter = current.folders || []
  for (var j = 0; j < foldersAfter.length; j++) {
    var folder = foldersAfter[j]
    var previousFolder = foldersBefore[folder.id]
    if (!previousFolder) continue
    if (folderHasProblem(folder) && !folderHasProblem(previousFolder)) {
      events.push({
        key: "folder-error:" + folder.id,
        title: folder.label,
        body: folderDetail(folder),
        urgent: true
      })
    } else if (
      Number(previousFolder.needBytes) > 0 &&
      Number(folder.needBytes) === 0 &&
      !folder.paused &&
      !folderHasProblem(folder)
    ) {
      events.push({
        key: "folder-synced:" + folder.id + ":" + folder.stateChanged,
        title: folder.label,
        body: "Finished syncing",
        urgent: false
      })
    }
  }

  var pendingDevices = current.pendingDevices || []
  for (var k = 0; k < pendingDevices.length; k++) {
    events.push({
      key: "pending-device:" + pendingDevices[k].deviceID,
      title: "New device wants to connect",
      body: (pendingDevices[k].name || shortDeviceId(pendingDevices[k].deviceID)),
      urgent: true
    })
  }

  var pendingFolders = current.pendingFolders || []
  for (var m = 0; m < pendingFolders.length; m++) {
    var offer = pendingFolders[m]
    events.push({
      key: "pending-folder:" + offer.folderID + ":" + offer.deviceID,
      title: "New folder shared with you",
      body: (offer.label || offer.folderID) + " from " + (offer.deviceName || shortDeviceId(offer.deviceID)),
      urgent: true
    })
  }

  return events
}

function indexBy(list, key) {
  var map = {}
  var items = list || []
  for (var i = 0; i < items.length; i++) {
    var item = items[i]
    if (item && item[key] !== undefined) map[item[key]] = item
  }
  return map
}

// Parse one line of bridge output. The bridge always prints a single JSON
// object, but a crashed interpreter or a truncated pipe would not, and the
// panel must degrade rather than throw inside a signal handler.
function parseBridge(text) {
  var raw = String(text || "").trim()
  if (raw === "") return { ok: false, error: "no response" }
  try {
    var parsed = JSON.parse(raw)
    if (!parsed || typeof parsed !== "object") return { ok: false, error: "unexpected response" }
    return parsed
  } catch (error) {
    return { ok: false, error: "unreadable response" }
  }
}

// Qt.resolvedUrl(".") hands back a file:// URL; the Process command needs a
// plain absolute path, and a plugin directory can contain percent-encoded
// characters once it lives under a themed or spaced path.
function fileUrlPath(url) {
  var text = String(url || "")
  if (text.indexOf("file://") === 0) text = text.slice(7)
  try {
    text = decodeURIComponent(text)
  } catch (error) {
    // Leave a malformed encoding alone rather than losing the path entirely.
  }
  return text.replace(/\/+$/, "")
}

if (typeof module !== "undefined" && module.exports) {
  module.exports = {
    formatBytes: formatBytes,
    formatRate: formatRate,
    formatDuration: formatDuration,
    shortDeviceId: shortDeviceId,
    relativeTime: relativeTime,
    computeRates: computeRates,
    folderStateLabel: folderStateLabel,
    folderIsBusy: folderIsBusy,
    folderHasProblem: folderHasProblem,
    folderDetail: folderDetail,
    folderTypeLabel: folderTypeLabel,
    folderCanRevert: folderCanRevert,
    deviceStatusLabel: deviceStatusLabel,
    deviceDetail: deviceDetail,
    overallState: overallState,
    overallCompletion: overallCompletion,
    connectedDeviceCount: connectedDeviceCount,
    pendingCount: pendingCount,
    heroMeta: heroMeta,
    barLabelText: barLabelText,
    notifiableChanges: notifiableChanges,
    parseBridge: parseBridge,
    fileUrlPath: fileUrlPath
  }
}
