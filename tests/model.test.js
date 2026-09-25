const test = require("node:test")
const assert = require("node:assert/strict")

const Model = require("../Model.js")

function folder(overrides = {}) {
  return {
    id: "docs",
    label: "Documents",
    path: "/home/tim/Documents",
    type: "sendreceive",
    paused: false,
    state: "idle",
    stateChanged: "2026-09-25T09:00:00Z",
    globalBytes: 1000,
    localBytes: 1000,
    needBytes: 0,
    needItems: 0,
    errors: 0,
    pullErrors: 0,
    completion: 100,
    ...overrides
  }
}

function device(overrides = {}) {
  return {
    deviceID: "AAAAAAA-BBBBBBB-CCCCCCC",
    name: "Laptop",
    paused: false,
    connected: true,
    address: "192.168.1.5:22000",
    type: "tcpClient",
    completion: 100,
    ...overrides
  }
}

function snapshot(overrides = {}) {
  return {
    installed: true,
    configured: true,
    service: { exists: true, active: "active", enabled: "enabled", running: true },
    api: { reachable: true, url: "http://127.0.0.1:8384" },
    folders: [],
    devices: [],
    pendingDevices: [],
    pendingFolders: [],
    errors: [],
    ...overrides
  }
}

test("formatBytes uses binary units and drops noisy decimals", () => {
  assert.equal(Model.formatBytes(0), "0 B")
  assert.equal(Model.formatBytes(-5), "0 B")
  assert.equal(Model.formatBytes(512), "512 B")
  assert.equal(Model.formatBytes(1536), "1.5 KiB")
  assert.equal(Model.formatBytes(1024 * 1024 * 20), "20 MiB")
  assert.equal(Model.formatBytes("not a number"), "0 B")
})

test("formatRate stays empty below one byte per second", () => {
  assert.equal(Model.formatRate(0), "")
  assert.equal(Model.formatRate(0.4), "")
  assert.equal(Model.formatRate(2048), "2.0 KiB/s")
})

test("formatDuration reports the two most significant units", () => {
  assert.equal(Model.formatDuration(0), "")
  assert.equal(Model.formatDuration(42), "42s")
  assert.equal(Model.formatDuration(3600 + 720), "1h 12m")
  assert.equal(Model.formatDuration(86400 * 2 + 3600 * 3), "2d 3h")
})

test("computeRates derives speeds from counter deltas", () => {
  const previous = { atMs: 1000, inBytesTotal: 0, outBytesTotal: 0 }
  const current = { atMs: 3000, inBytesTotal: 2000, outBytesTotal: 1000 }
  const rates = Model.computeRates(previous, current)
  assert.equal(rates.inRate, 1000)
  assert.equal(rates.outRate, 500)
})

test("computeRates refuses samples it cannot trust", () => {
  // A daemon restart resets the counters; a negative delta must not become a
  // huge negative rate on screen.
  const reset = Model.computeRates(
    { atMs: 1000, inBytesTotal: 9000, outBytesTotal: 9000 },
    { atMs: 3000, inBytesTotal: 10, outBytesTotal: 10 }
  )
  assert.deepEqual(reset, { inRate: 0, outRate: 0 })

  // Two samples from effectively the same instant divide by ~nothing.
  const instant = Model.computeRates(
    { atMs: 1000, inBytesTotal: 0, outBytesTotal: 0 },
    { atMs: 1100, inBytesTotal: 500, outBytesTotal: 0 }
  )
  assert.deepEqual(instant, { inRate: 0, outRate: 0 })

  assert.deepEqual(Model.computeRates(null, null), { inRate: 0, outRate: 0 })
})

test("folderStateLabel distinguishes idle-and-complete from idle-and-behind", () => {
  assert.equal(Model.folderStateLabel(folder()), "Up to date")
  assert.equal(Model.folderStateLabel(folder({ needBytes: 400 })), "Out of sync")
  assert.equal(Model.folderStateLabel(folder({ state: "syncing" })), "Syncing")
  assert.equal(Model.folderStateLabel(folder({ paused: true })), "Paused")
  assert.equal(Model.folderStateLabel(folder({ pullErrors: 2 })), "Failed items")
})

test("a paused folder is never reported as busy or problematic", () => {
  assert.equal(Model.folderIsBusy(folder({ paused: true, state: "syncing" })), false)
  assert.equal(Model.folderIsBusy(folder({ state: "scanning" })), true)
  assert.equal(Model.folderHasProblem(folder({ state: "error" })), true)
  assert.equal(Model.folderHasProblem(folder()), false)
})

test("revert is offered only for a receive-only folder with local divergence", () => {
  assert.equal(Model.folderCanRevert(folder({ type: "receiveonly", needBytes: 10 })), true)
  assert.equal(Model.folderCanRevert(folder({ type: "receiveonly", needBytes: 0 })), false)
  assert.equal(Model.folderCanRevert(folder({ type: "sendreceive", needBytes: 10 })), false)
  assert.equal(Model.folderCanRevert(folder({ type: "receiveonly", needBytes: 10, paused: true })), false)
})

test("overallState reports the worst true condition first", () => {
  assert.equal(Model.overallState(snapshot({ installed: false })).key, "missing")
  assert.equal(
    Model.overallState(snapshot({ service: { exists: true, running: false }, api: { reachable: false } })).key,
    "stopped"
  )
  assert.equal(
    Model.overallState(snapshot({ api: { reachable: false } })).key,
    "starting"
  )
  // An error outranks a concurrent sync rather than being hidden behind it.
  assert.equal(
    Model.overallState(snapshot({
      folders: [folder({ state: "syncing" }), folder({ id: "b", pullErrors: 1 })]
    })).key,
    "error"
  )
  assert.equal(
    Model.overallState(snapshot({ folders: [folder({ state: "syncing" })] })).key,
    "syncing"
  )
  assert.equal(
    Model.overallState(snapshot({ folders: [folder({ needBytes: 5 })] })).key,
    "behind"
  )
  assert.equal(Model.overallState(snapshot({ folders: [folder()] })).key, "idle")
  assert.equal(
    Model.overallState(snapshot({ folders: [folder({ paused: true })] })).key,
    "paused"
  )
})

test("a daemon-level error outranks healthy folders", () => {
  const state = Model.overallState(snapshot({
    errors: [{ message: "disk full" }],
    folders: [folder()]
  }))
  assert.equal(state.key, "error")
})

test("overallCompletion weights folders by size and skips paused ones", () => {
  assert.equal(Model.overallCompletion([]), 100)
  assert.equal(
    Model.overallCompletion([
      folder({ globalBytes: 1000, needBytes: 500 }),
      folder({ id: "b", globalBytes: 1000, needBytes: 0 })
    ]),
    75
  )
  // The paused folder's outstanding bytes do not drag the figure down.
  assert.equal(
    Model.overallCompletion([
      folder({ globalBytes: 1000, needBytes: 0 }),
      folder({ id: "b", globalBytes: 1000, needBytes: 1000, paused: true })
    ]),
    100
  )
})

test("barLabelText honours the mode and hides itself when there is nothing to say", () => {
  const running = snapshot({ folders: [folder({ globalBytes: 100, needBytes: 50 })] })
  assert.equal(Model.barLabelText("none", running, 1000, 1000), "")
  assert.equal(Model.barLabelText("percent", running, 0, 0), "50%")
  // Nothing outstanding means no percentage worth the bar space.
  assert.equal(Model.barLabelText("percent", snapshot({ folders: [folder()] }), 0, 0), "")
  assert.equal(Model.barLabelText("rate", running, 2048, 0), "↓2.0 KiB/s")
  assert.equal(Model.barLabelText("rate", running, 0, 2048), "↑2.0 KiB/s")
  assert.equal(Model.barLabelText("rate", running, 0, 0), "")
  assert.equal(
    Model.barLabelText("devices", snapshot({ devices: [device(), device({ deviceID: "x", connected: false })] }), 0, 0),
    "1/2"
  )
})

test("barLabelText is empty whenever the service is not running", () => {
  const stopped = snapshot({ service: { exists: true, running: false }, api: { reachable: false } })
  assert.equal(Model.barLabelText("rate", stopped, 5000, 5000), "")
  assert.equal(Model.barLabelText("percent", stopped, 0, 0), "")
})

test("notifiableChanges reports connection transitions once each", () => {
  const before = snapshot({ devices: [device({ connected: false })] })
  const after = snapshot({ devices: [device({ connected: true })] })
  const events = Model.notifiableChanges(before, after)
  assert.equal(events.length, 1)
  assert.equal(events[0].key, "device-up:AAAAAAA-BBBBBBB-CCCCCCC")
  assert.equal(events[0].body, "Connected")

  // Steady state produces nothing at all.
  assert.deepEqual(Model.notifiableChanges(after, after), [])
})

test("notifiableChanges stays quiet when a device is paused rather than lost", () => {
  const before = snapshot({ devices: [device({ connected: true })] })
  const after = snapshot({ devices: [device({ connected: false, paused: true })] })
  assert.deepEqual(Model.notifiableChanges(before, after), [])
})

test("notifiableChanges announces a folder finishing and a folder failing", () => {
  const finished = Model.notifiableChanges(
    snapshot({ folders: [folder({ needBytes: 500 })] }),
    snapshot({ folders: [folder({ needBytes: 0 })] })
  )
  assert.equal(finished.length, 1)
  assert.equal(finished[0].body, "Finished syncing")
  assert.equal(finished[0].urgent, false)

  const failed = Model.notifiableChanges(
    snapshot({ folders: [folder()] }),
    snapshot({ folders: [folder({ pullErrors: 3 })] })
  )
  assert.equal(failed.length, 1)
  assert.equal(failed[0].urgent, true)
  assert.match(failed[0].body, /3 failed items/)
})

test("notifiableChanges surfaces pending invites as urgent", () => {
  const events = Model.notifiableChanges(
    snapshot(),
    snapshot({
      pendingDevices: [{ deviceID: "ZZZZZZZ-YYYYYYY", name: "Phone" }],
      pendingFolders: [{ folderID: "photos", label: "Photos", deviceID: "ZZZZZZZ-YYYYYYY", deviceName: "Phone" }]
    })
  )
  assert.equal(events.length, 2)
  assert.ok(events.every(event => event.urgent === true))
  assert.equal(events[0].key, "pending-device:ZZZZZZZ-YYYYYYY")
  assert.equal(events[1].key, "pending-folder:photos:ZZZZZZZ-YYYYYYY")
})

test("notifiableChanges ignores devices it has never seen before", () => {
  // A device present only in the new snapshot was just configured, not
  // reconnected, and announcing it would be noise on every fresh start.
  const events = Model.notifiableChanges(snapshot(), snapshot({ devices: [device()] }))
  assert.deepEqual(events, [])
})

test("parseBridge degrades instead of throwing", () => {
  assert.deepEqual(Model.parseBridge('{"ok":true}'), { ok: true })
  assert.equal(Model.parseBridge("").ok, false)
  assert.equal(Model.parseBridge("Traceback (most recent call last)").ok, false)
  assert.equal(Model.parseBridge("[1,2,3]").ok, undefined)
  assert.equal(Model.parseBridge("null").ok, false)
})

test("fileUrlPath turns a QML resolved url into a usable path", () => {
  assert.equal(Model.fileUrlPath("file:///home/tim/plugins/x/"), "/home/tim/plugins/x")
  assert.equal(Model.fileUrlPath("file:///home/tim/My%20Plugins/x"), "/home/tim/My Plugins/x")
  assert.equal(Model.fileUrlPath(""), "")
})

test("a connected device that shares nothing reads as Connected, not stuck at 0%", () => {
  // Syncthing reports 0% completion for a device with no shared folders.
  assert.equal(
    Model.deviceStatusLabel(device({ sharesFolders: false, completion: 0 })),
    "Connected"
  )
  assert.equal(
    Model.deviceStatusLabel(device({ sharesFolders: true, completion: 0 })),
    "Syncing 0%"
  )
})

test("deviceStatusLabel and deviceDetail describe the connection", () => {
  assert.equal(Model.deviceStatusLabel(device()), "Up to date")
  assert.equal(Model.deviceStatusLabel(device({ completion: 42.7 })), "Syncing 42%")
  assert.equal(Model.deviceStatusLabel(device({ connected: false })), "Disconnected")
  assert.equal(Model.deviceStatusLabel(device({ paused: true })), "Paused")
  assert.equal(Model.deviceDetail(device()), "192.168.1.5:22000 · tcp Client")
})

test("heroMeta summarises devices, folders and live rates", () => {
  const state = snapshot({
    devices: [device(), device({ deviceID: "b", connected: false })],
    folders: [folder()]
  })
  assert.equal(Model.heroMeta(state, 0, 0), "1/2 devices · 1 folder")
  assert.equal(Model.heroMeta(state, 2048, 1024), "1/2 devices · 1 folder · ↓ 2.0 KiB/s · ↑ 1.0 KiB/s")
  assert.equal(
    Model.heroMeta(snapshot({ service: { running: false }, api: { reachable: false }, configured: false }), 0, 0),
    "Syncthing has never been started"
  )
})

test("a daemon started outside systemd reads as running, not stopped", () => {
  // Started from a terminal: the unit is failed (it tripped over the lock)
  // but the API answers and folders are in sync.
  const outside = snapshot({
    service: { exists: true, active: "failed", enabled: "disabled", running: false },
    devices: [device()],
    folders: [folder({ globalBytes: 100, needBytes: 50 })]
  })
  assert.equal(Model.daemonRunning(outside), true)
  assert.equal(Model.runningOutsideSystemd(outside), true)
  assert.equal(Model.overallState(outside).key, "behind")
  assert.equal(Model.heroMeta(outside, 0, 0), "1/1 devices · 1 folder · outside systemd")
  assert.equal(Model.barLabelText("percent", outside, 0, 0), "50%")

  assert.equal(Model.heroMeta(snapshot({ service: { running: false } }), 0, 0), "Running · outside systemd")
  assert.equal(Model.runningOutsideSystemd(snapshot()), false)
  assert.equal(Model.runningOutsideSystemd(snapshot({ service: { running: false }, api: { reachable: false } })), false)
})

test("shortDeviceId and relativeTime stay readable", () => {
  assert.equal(Model.shortDeviceId("AAAAAAA-BBBBBBB-CCCCCCC"), "AAAAAAA")
  assert.equal(Model.shortDeviceId(""), "")
  const now = Date.parse("2026-09-25T10:00:00Z")
  assert.equal(Model.relativeTime("2026-09-25T09:59:50Z", now), "just now")
  assert.equal(Model.relativeTime("2026-09-25T09:30:00Z", now), "30m ago")
  assert.equal(Model.relativeTime("nonsense", now), "")
})
