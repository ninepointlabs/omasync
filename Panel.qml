import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

Panel {
  id: root
  moduleName: "ninepointlabs.omasync"
  ipcTarget: "ninepointlabs.omasync"
  manageIpc: false

  // Keyboard navigation uses one flat list of rows rather than a cursor per
  // section. Sections appear and disappear as folders sync, devices connect
  // and invites arrive, and a single index over a rebuilt list cannot drift
  // out of step with what is actually on screen the way parallel indices do.
  property int cursor: 0
  property bool cursorActive: false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  // The bar exposes foreground and urgent but has no accent of its own; the
  // accent is a theme-level colour, read straight off the Color singleton.
  readonly property color accent: Color.accent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // The bar instantiates a widget per monitor, so a service living inside the
  // widget would poll, long-poll and notify once per screen. Declaring the
  // `service` kind makes the shell mount Service.qml exactly once and hand it
  // to every screen's widget; `localService` is only a fallback for a host
  // that does not offer serviceFor().
  readonly property var sharedService: bar && bar.shell && typeof bar.shell.serviceFor === "function"
    ? bar.shell.serviceFor(moduleName)
    : null
  readonly property var syncthing: sharedService || localService

  function pushSettings() { if (syncthing) syncthing.settings = settings }
  onSettingsChanged: pushSettings()
  onSyncthingChanged: pushSettings()

  readonly property bool showFolders: root.syncthing.folders.length > 0
  readonly property bool showDevices: root.syncthing.devices.length > 0
  readonly property bool showPending: root.syncthing.pendingCount > 0
  readonly property bool showErrors: root.syncthing.errors.length > 0

  readonly property bool syncing: root.syncthing.stateKey === "syncing"
  readonly property bool problem: root.syncthing.stateKey === "error"

  readonly property color iconColor: !root.syncthing.serviceRunning
    ? dim
    : (problem ? urgent : foreground)
  readonly property color barIconColor: !root.syncthing.serviceRunning
    ? Qt.darker(barForeground, 1.55)
    : (problem ? (bar ? bar.urgent : Color.urgent) : barForeground)

  readonly property string barLabelMode: setting("barLabel", "none")
  readonly property string barLabelText: (bar && bar.vertical)
    ? ""
    : Model.barLabelText(barLabelMode, root.syncthing.snapshot, root.syncthing.inRate, root.syncthing.outRate)

  readonly property string toggleHint: root.syncthing.externallyManaged
    ? "Stop Syncthing (started outside systemd)"
    : (root.syncthing.serviceRunning ? "Stop the Syncthing service" : "Start the Syncthing service")

  // ------------------------------------------------------------- cursor

  // Flat, ordered list of everything the cursor can land on. Rebuilt whenever
  // the underlying lists change; `index` is the position within that section.
  readonly property var rows: buildRows()

  function buildRows() {
    var list = [{ section: "header", index: 0 }]
    var i
    for (i = 0; i < root.syncthing.pendingDevices.length; i++) list.push({ section: "pendingDevice", index: i })
    for (i = 0; i < root.syncthing.pendingFolders.length; i++) list.push({ section: "pendingFolder", index: i })
    for (i = 0; i < root.syncthing.folders.length; i++) list.push({ section: "folder", index: i })
    for (i = 0; i < root.syncthing.devices.length; i++) list.push({ section: "device", index: i })
    if (root.syncthing.errors.length > 0) list.push({ section: "errors", index: 0 })
    for (i = 0; i < footerActions.length; i++) list.push({ section: "action", index: i })
    return list
  }

  readonly property var footerActions: buildFooterActions()

  function buildFooterActions() {
    var actions = []
    if (root.syncthing.apiReachable) {
      actions.push({ key: "gui", icon: "󰖟", label: "Open Web GUI" })
      actions.push({ key: "rescan", icon: "󰑐", label: "Rescan all folders" })
      actions.push({ key: "copyId", icon: "󰆏", label: "Copy my device ID" })
    }
    if (root.syncthing.unitExists) {
      actions.push({
        key: "autostart",
        icon: root.syncthing.autostart ? "󰄬" : "󰅖",
        label: root.syncthing.autostart ? "Start at login: on" : "Start at login: off"
      })
      if (root.syncthing.externallyManaged) actions.push({ key: "restart", icon: "󰜉", label: "Hand over to systemd" })
      else if (root.syncthing.serviceRunning) actions.push({ key: "restart", icon: "󰜉", label: "Restart Syncthing" })
    }
    return actions
  }

  readonly property var cursorRow: rows.length === 0
    ? { section: "", index: -1 }
    : rows[Math.max(0, Math.min(cursor, rows.length - 1))]

  function isCursor(section, index) {
    return cursorActive && cursorRow.section === section && cursorRow.index === index
  }

  function setCursor(section, index) {
    for (var i = 0; i < rows.length; i++) {
      if (rows[i].section === section && rows[i].index === index) {
        cursor = i
        cursorActive = true
        return
      }
    }
  }

  function moveCursor(dx, dy) {
    if (rows.length === 0) return
    cursorActive = true
    var step = dy !== 0 ? dy : dx
    if (step === 0) return
    cursor = Math.max(0, Math.min(rows.length - 1, cursor + (step > 0 ? 1 : -1)))
    scrollCursorIntoView()
  }

  function clampCursor() {
    if (cursor > rows.length - 1) cursor = Math.max(0, rows.length - 1)
  }

  function scrollCursorIntoView() {
    if (!panelFlick) return
    var item = cursorItem()
    if (!item) return
    var top = item.mapToItem(column, 0, 0).y
    var bottom = top + item.height
    if (top < panelFlick.contentY) panelFlick.contentY = Math.max(0, top - Style.space(8))
    else if (bottom > panelFlick.contentY + panelFlick.height)
      panelFlick.contentY = Math.min(Math.max(0, column.implicitHeight - panelFlick.height),
                                     bottom - panelFlick.height + Style.space(8))
  }

  // The cursor's visual item, looked up by the (section, index) it carries.
  // Repeater children register themselves here as they are created.
  property var cursorRegistry: ({})

  function registerRow(section, index, item) {
    cursorRegistry[section + ":" + index] = item
  }

  function cursorItem() {
    return cursorRegistry[cursorRow.section + ":" + cursorRow.index] || null
  }

  function selectedFolder() {
    return cursorRow.section === "folder" ? root.syncthing.folders[cursorRow.index] : null
  }

  function selectedDevice() {
    return cursorRow.section === "device" ? root.syncthing.devices[cursorRow.index] : null
  }

  function activateCursor() {
    var row = cursorRow
    if (row.section === "header") root.syncthing.toggleService()
    else if (row.section === "folder") root.syncthing.toggleFolder(root.syncthing.folders[row.index])
    else if (row.section === "device") root.syncthing.toggleDevice(root.syncthing.devices[row.index])
    else if (row.section === "pendingDevice") root.syncthing.acceptDevice(root.syncthing.pendingDevices[row.index])
    else if (row.section === "pendingFolder") root.syncthing.acceptFolder(root.syncthing.pendingFolders[row.index])
    else if (row.section === "errors") root.syncthing.clearErrors()
    else if (row.section === "action") runFooterAction(footerActions[row.index])
  }

  function runFooterAction(action) {
    if (!action) return
    if (action.key === "gui") { root.syncthing.openGui(); close() }
    else if (action.key === "rescan") root.syncthing.rescanAll()
    else if (action.key === "copyId") root.syncthing.copyMyId()
    else if (action.key === "autostart") root.syncthing.setAutostart(!root.syncthing.autostart)
    else if (action.key === "restart") root.syncthing.restartService()
  }

  // Letter shortcuts act on whatever the cursor is sitting on, falling back to
  // the whole installation when the row does not have its own meaning.
  function handleTextKey(key) {
    var lower = String(key || "").toLowerCase()
    var folder = selectedFolder()
    var device = selectedDevice()
    if (lower === "t") root.syncthing.toggleService()
    else if (lower === "r") folder ? root.syncthing.rescanFolder(folder) : root.syncthing.rescanAll()
    else if (lower === "p") {
      if (folder) root.syncthing.toggleFolder(folder)
      else if (device) root.syncthing.toggleDevice(device)
    }
    else if (lower === "o") { if (folder) root.syncthing.openFolder(folder) }
    else if (lower === "v") { if (folder && Model.folderCanRevert(folder)) root.syncthing.revertFolder(folder) }
    else if (lower === "c") {
      if (device) root.syncthing.copyToClipboard(device.deviceID)
      else if (folder) root.syncthing.copyToClipboard(folder.path)
      else root.syncthing.copyMyId()
    }
    else if (lower === "g") { root.syncthing.openGui(); close() }
    else if (lower === "x") root.syncthing.clearErrors()
  }

  // ---------------------------------------------------------------- shell

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: if (opened) {
    cursorActive = false
    cursor = 0
    if (panelFlick) panelFlick.contentY = 0
    root.syncthing.refresh()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  onRowsChanged: clampCursor()

  Service {
    id: localService
    // Only the fallback instance does any work; when the shell mounted the
    // service plugin, this one stays completely idle.
    active: root.sharedService === null
    settings: root.settings
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { root.syncthing.refresh(); return "ok" }
    function start(): string { root.syncthing.startService(); return "ok" }
    function stop(): string { root.syncthing.stopService(); return "ok" }
    function restart(): string { root.syncthing.restartService(); return "ok" }
    function rescan(): string { root.syncthing.rescanAll(); return "ok" }
    function status(): string { return root.syncthing.stateLabel }
    function deviceId(): string { return root.syncthing.myId }
  }

  // ------------------------------------------------------------------ bar

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    labelVisible: false
    hasVisualContent: true
    // Matches the fixed icon slot when there is no label, and grows only as
    // far as the label needs so the bar does not jitter as rates change.
    fixedWidth: (bar && bar.vertical)
      ? -1
      : Math.round(barContent.implicitWidth + Style.spaceReal(horizontalMargin) * 2)
    tooltipText: "OmaSyncthing · " + root.syncthing.stateLabel
      + (root.syncthing.pendingCount > 0
        ? " · " + root.syncthing.pendingCount + (root.syncthing.pendingCount === 1 ? " invite" : " invites")
        : "")

    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) root.syncthing.toggleService()
      else if (buttonCode === Qt.MiddleButton) root.syncthing.rescanAll()
      else root.toggle()
    }

    Row {
      id: barContent
      anchors.centerIn: parent
      spacing: Style.space(5)

      SyncthingIcon {
        anchors.verticalCenter: parent.verticalCenter
        iconSize: Style.bar.iconCanvas * 0.72
        color: root.barIconColor
        crossed: !root.syncthing.serviceRunning && root.syncthing.installed
        spinning: root.syncing
        badge: root.syncthing.pendingCount > 0
        badgeColor: root.bar ? root.bar.urgent : Color.urgent
      }

      Text {
        textFormat: Text.PlainText
        visible: root.barLabelText !== ""
        anchors.verticalCenter: parent.verticalCenter
        text: root.barLabelText
        color: root.barIconColor
        font.family: root.fontFamily
        font.pixelSize: Style.bar.iconFont
        renderType: Text.NativeRendering
      }
    }
  }

  // ---------------------------------------------------------------- panel

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(400))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(620))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        root.moveCursor(dx, dy)
      }
      onActivateRequested: if (root.cursorActive) root.activateCursor()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(text) { root.handleTextKey(text) }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          // ------------------------------------------------------- hero

          Item {
            id: header
            width: parent.width
            implicitHeight: hero.implicitHeight
            // The hero's trailingControl resolves `root` to PanelHero, so
            // panel state is reached through this wrapper instead.
            readonly property bool ringVisible: root.isCursor("header", 0)
            readonly property bool canToggle: root.syncthing.unitExists || root.syncthing.externallyManaged
            function focusHero() { root.setCursor("header", 0) }
            function toggle() { root.syncthing.toggleService() }

            Component.onCompleted: root.registerRow("header", 0, header)

            PanelHero {
              id: hero
              width: parent.width
              title: root.syncthing.snapshot.myName || "OmaSyncthing"
              meta: Model.heroMeta(root.syncthing.snapshot, root.syncthing.inRate, root.syncthing.outRate)
              detail: root.syncthing.snapshot.version || ""
              foreground: root.foreground
              fontFamily: root.fontFamily
              iconOpacity: root.syncthing.serviceRunning ? 1.0 : 0.5

              iconComponent: Component {
                SyncthingIcon {
                  iconSize: Style.font.display
                  color: root.iconColor
                  crossed: !root.syncthing.serviceRunning && root.syncthing.installed
                  spinning: root.syncing
                }
              }

              trailingControl: Component {
                ToggleSwitch {
                  id: powerSwitch
                  visible: header.canToggle
                  checked: root.syncthing.serviceRunning
                  busy: root.syncthing.busy
                  hasCursor: header.ringVisible
                  foreground: hero.foreground
                  onHovered: function(on) { if (on) header.focusHero() }
                  onToggled: header.toggle()

                  PanelToolTip {
                    visible: powerSwitch.containsMouse
                    text: root.toggleHint
                    fontFamily: hero.fontFamily
                  }
                }
              }
            }
          }

          Text {
            id: statusLine
            textFormat: Text.PlainText
            width: parent.width
            visible: text !== ""
            text: root.syncthing.actionStatus !== ""
              ? root.syncthing.actionStatus
              : (root.syncthing.lastError !== "" ? root.syncthing.lastError : root.syncthing.stateLabel)
            color: root.syncthing.lastError !== "" && root.syncthing.actionStatus === "" ? root.urgent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          // -------------------------------------------------- empty states

          NoticeRow {
            visible: !root.syncthing.installed && root.syncthing.ready
            width: parent.width
            message: "Syncthing is not installed. Install it with `omarchy pkg add syncthing`."
          }

          NoticeRow {
            visible: root.syncthing.installed && !root.syncthing.unitExists && root.syncthing.ready
            width: parent.width
            message: "The root.syncthing.service user unit is missing, so this panel cannot start or stop it."
          }

          NoticeRow {
            visible: root.syncthing.installed && root.syncthing.unitExists && !root.syncthing.serviceRunning
            width: parent.width
            message: "Syncthing is stopped. Turn it on to see folders and devices."
          }

          NoticeRow {
            visible: root.syncthing.externallyManaged && root.syncthing.unitExists
            width: parent.width
            message: "Syncthing is running, but it was started outside systemd (from a terminal, say), so systemd will not restart it if it crashes. Use Hand over to systemd below to fix that."
          }

          NoticeRow {
            visible: root.syncthing.serviceRunning && !root.syncthing.apiReachable
            width: parent.width
            message: "Waiting for the Syncthing API to come up…"
          }

          NoticeRow {
            visible: root.syncthing.apiReachable && !root.showFolders && !root.showPending
            width: parent.width
            message: "No folders yet. Add one in the Web GUI to start syncing."
          }

          // ------------------------------------------------------ pending

          PanelSeparator { visible: root.showPending; foreground: root.foreground }

          Column {
            visible: root.showPending
            width: parent.width
            spacing: Style.space(8)

            PanelSectionHeader {
              text: "WAITING FOR YOU"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Repeater {
              model: root.syncthing.pendingDevices
              PendingRow {
                required property var modelData
                required property int index
                width: parent.width
                rowSection: "pendingDevice"
                rowIndex: index
                title: modelData.name || Model.shortDeviceId(modelData.deviceID)
                subtitle: "Wants to connect · " + Model.shortDeviceId(modelData.deviceID)
                onAccepted: root.syncthing.acceptDevice(modelData)
                onRejected: root.syncthing.rejectDevice(modelData)
              }
            }

            Repeater {
              model: root.syncthing.pendingFolders
              PendingRow {
                required property var modelData
                required property int index
                width: parent.width
                rowSection: "pendingFolder"
                rowIndex: index
                title: modelData.label || modelData.folderID
                subtitle: "Shared by " + (modelData.deviceName || Model.shortDeviceId(modelData.deviceID))
                onAccepted: root.syncthing.acceptFolder(modelData)
                onRejected: root.syncthing.rejectFolder(modelData)
              }
            }
          }

          // ------------------------------------------------------ folders

          PanelSeparator { visible: root.showFolders; foreground: root.foreground }

          Column {
            visible: root.showFolders
            width: parent.width
            spacing: Style.space(6)

            PanelSectionHeader {
              text: "FOLDERS"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Repeater {
              model: root.syncthing.folders
              FolderRow {
                required property var modelData
                required property int index
                width: parent.width
                folder: modelData
                rowIndex: index
              }
            }
          }

          // ------------------------------------------------------ devices

          PanelSeparator { visible: root.showDevices; foreground: root.foreground }

          Column {
            visible: root.showDevices
            width: parent.width
            spacing: Style.space(6)

            PanelSectionHeader {
              text: "REMOTE DEVICES"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Repeater {
              model: root.syncthing.devices
              DeviceRow {
                required property var modelData
                required property int index
                width: parent.width
                device: modelData
                rowIndex: index
              }
            }
          }

          // ------------------------------------------------------- errors

          PanelSeparator { visible: root.showErrors; foreground: root.foreground }

          Column {
            visible: root.showErrors
            width: parent.width
            spacing: Style.space(6)

            PanelSectionHeader {
              text: "ERRORS"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            ErrorsRow { width: parent.width }
          }

          // ------------------------------------------------------ actions

          PanelSeparator { visible: root.footerActions.length > 0; foreground: root.foreground }

          Column {
            visible: root.footerActions.length > 0
            width: parent.width
            spacing: Style.space(4)

            Repeater {
              model: root.footerActions
              ActionRow {
                required property var modelData
                required property int index
                width: parent.width
                action: modelData
                rowIndex: index
              }
            }
          }
        }
      }
    }
  }

  // ------------------------------------------------------------ row types

  component NoticeRow: Item {
    property string message: ""
    implicitHeight: visible ? noticeText.implicitHeight + Style.space(6) : 0

    Text {
      id: noticeText
      textFormat: Text.PlainText
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      text: parent.message
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      wrapMode: Text.WordWrap
    }
  }

  component FolderRow: CursorSurface {
    id: folderRow
    property var folder: null
    property int rowIndex: 0

    readonly property bool busy: Model.folderIsBusy(folder)
    readonly property bool trouble: Model.folderHasProblem(folder)
    readonly property real completion: folder ? Number(folder.completion) : 100

    hasCursor: root.isCursor("folder", rowIndex)
    foreground: root.foreground
    accent: root.accent
    implicitHeight: folderLayout.implicitHeight + Style.spacing.controlPaddingY * 2

    Component.onCompleted: root.registerRow("folder", rowIndex, folderRow)

    HoverHandler {
      onHoveredChanged: if (hovered) root.setCursor("folder", folderRow.rowIndex)
    }

    TapHandler {
      onTapped: root.syncthing.openFolder(folderRow.folder)
    }

    ColumnLayout {
      id: folderLayout
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.spacing.rowPaddingX
      anchors.rightMargin: Style.spacing.rowPaddingX
      spacing: Style.space(4)

      RowLayout {
        Layout.fillWidth: true
        spacing: Style.space(8)

        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          text: folderRow.folder ? folderRow.folder.label : ""
          color: folderRow.folder && folderRow.folder.paused ? root.dim : root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          font.bold: true
          elide: Text.ElideRight
        }

        Text {
          textFormat: Text.PlainText
          text: Model.folderStateLabel(folderRow.folder)
          color: folderRow.trouble ? root.urgent : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
        }

        PanelActionButton {
          iconText: "󰑐"
          tooltipText: "Rescan"
          enabled: folderRow.folder && !folderRow.folder.paused
          foreground: root.foreground
          fontFamily: root.fontFamily
          onHovered: function(on) { if (on) root.setCursor("folder", folderRow.rowIndex) }
          onClicked: root.syncthing.rescanFolder(folderRow.folder)
        }

        PanelActionButton {
          iconText: "󰕌"
          tooltipText: "Revert local changes"
          visible: Model.folderCanRevert(folderRow.folder)
          foreground: root.foreground
          hoverColor: root.urgent
          fontFamily: root.fontFamily
          onHovered: function(on) { if (on) root.setCursor("folder", folderRow.rowIndex) }
          onClicked: root.syncthing.revertFolder(folderRow.folder)
        }

        PanelActionButton {
          iconText: folderRow.folder && folderRow.folder.paused ? "󰐊" : "󰏤"
          tooltipText: folderRow.folder && folderRow.folder.paused ? "Resume" : "Pause"
          foreground: root.foreground
          fontFamily: root.fontFamily
          onHovered: function(on) { if (on) root.setCursor("folder", folderRow.rowIndex) }
          onClicked: root.syncthing.toggleFolder(folderRow.folder)
        }
      }

      Text {
        textFormat: Text.PlainText
        Layout.fillWidth: true
        text: Model.folderDetail(folderRow.folder)
          + " · " + Model.folderTypeLabel(folderRow.folder ? folderRow.folder.type : "")
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }

      // Progress track, shown only while there is progress worth watching.
      Rectangle {
        Layout.fillWidth: true
        Layout.preferredHeight: Math.max(2, Style.space(3))
        visible: folderRow.busy || folderRow.completion < 100
        radius: height / 2
        color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.12)

        Rectangle {
          height: parent.height
          radius: parent.radius
          width: Math.max(0, Math.min(1, folderRow.completion / 100)) * parent.width
          color: folderRow.trouble ? root.urgent : root.accent

          Behavior on width {
            NumberAnimation { duration: 240; easing.type: Easing.OutCubic }
          }
        }
      }
    }
  }

  component DeviceRow: CursorSurface {
    id: deviceRow
    property var device: null
    property int rowIndex: 0

    hasCursor: root.isCursor("device", rowIndex)
    foreground: root.foreground
    accent: root.accent
    implicitHeight: deviceLayout.implicitHeight + Style.spacing.controlPaddingY * 2

    Component.onCompleted: root.registerRow("device", rowIndex, deviceRow)

    HoverHandler {
      onHoveredChanged: if (hovered) root.setCursor("device", deviceRow.rowIndex)
    }

    ColumnLayout {
      id: deviceLayout
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.spacing.rowPaddingX
      anchors.rightMargin: Style.spacing.rowPaddingX
      spacing: Style.space(2)

      RowLayout {
        Layout.fillWidth: true
        spacing: Style.space(8)

        // Connection pip: the fastest read of whether this device is there.
        Rectangle {
          Layout.alignment: Qt.AlignVCenter
          width: Style.space(7)
          height: width
          radius: width / 2
          color: deviceRow.device && deviceRow.device.paused
            ? root.dim
            : (deviceRow.device && deviceRow.device.connected ? root.accent : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.25))
        }

        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          text: deviceRow.device ? deviceRow.device.name : ""
          color: deviceRow.device && (deviceRow.device.paused || !deviceRow.device.connected) ? root.dim : root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }

        Text {
          textFormat: Text.PlainText
          text: Model.deviceStatusLabel(deviceRow.device)
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
        }

        PanelActionButton {
          iconText: "󰆏"
          tooltipText: "Copy device ID"
          foreground: root.foreground
          fontFamily: root.fontFamily
          onHovered: function(on) { if (on) root.setCursor("device", deviceRow.rowIndex) }
          onClicked: root.syncthing.copyToClipboard(deviceRow.device ? deviceRow.device.deviceID : "")
        }

        PanelActionButton {
          iconText: deviceRow.device && deviceRow.device.paused ? "󰐊" : "󰏤"
          tooltipText: deviceRow.device && deviceRow.device.paused ? "Resume" : "Pause"
          foreground: root.foreground
          fontFamily: root.fontFamily
          onHovered: function(on) { if (on) root.setCursor("device", deviceRow.rowIndex) }
          onClicked: root.syncthing.toggleDevice(deviceRow.device)
        }
      }

      Text {
        textFormat: Text.PlainText
        Layout.fillWidth: true
        visible: text !== ""
        text: Model.deviceDetail(deviceRow.device)
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }
    }
  }

  component PendingRow: CursorSurface {
    id: pendingRow
    property string rowSection: "pendingDevice"
    property int rowIndex: 0
    property string title: ""
    property string subtitle: ""

    signal accepted()
    signal rejected()

    hasCursor: root.isCursor(rowSection, rowIndex)
    foreground: root.foreground
    accent: root.accent
    bordered: true
    implicitHeight: pendingLayout.implicitHeight + Style.spacing.controlPaddingY * 2

    Component.onCompleted: root.registerRow(rowSection, rowIndex, pendingRow)

    HoverHandler {
      onHoveredChanged: if (hovered) root.setCursor(pendingRow.rowSection, pendingRow.rowIndex)
    }

    RowLayout {
      id: pendingLayout
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.spacing.rowPaddingX
      anchors.rightMargin: Style.spacing.rowPaddingX
      spacing: Style.space(8)

      ColumnLayout {
        Layout.fillWidth: true
        spacing: Style.space(2)

        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          text: pendingRow.title
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          font.bold: true
          elide: Text.ElideRight
        }

        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          text: pendingRow.subtitle
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      PanelActionButton {
        iconText: "󰄬"
        tooltipText: "Accept"
        foreground: root.foreground
        hoverColor: root.accent
        fontFamily: root.fontFamily
        onHovered: function(on) { if (on) root.setCursor(pendingRow.rowSection, pendingRow.rowIndex) }
        onClicked: pendingRow.accepted()
      }

      PanelActionButton {
        iconText: "󰅖"
        tooltipText: "Dismiss"
        foreground: root.foreground
        hoverColor: root.urgent
        fontFamily: root.fontFamily
        onHovered: function(on) { if (on) root.setCursor(pendingRow.rowSection, pendingRow.rowIndex) }
        onClicked: pendingRow.rejected()
      }
    }
  }

  component ErrorsRow: CursorSurface {
    id: errorsRow

    hasCursor: root.isCursor("errors", 0)
    foreground: root.foreground
    accent: root.accent
    implicitHeight: errorsLayout.implicitHeight + Style.spacing.controlPaddingY * 2

    Component.onCompleted: root.registerRow("errors", 0, errorsRow)

    HoverHandler {
      onHoveredChanged: if (hovered) root.setCursor("errors", 0)
    }

    RowLayout {
      id: errorsLayout
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.spacing.rowPaddingX
      anchors.rightMargin: Style.spacing.rowPaddingX
      spacing: Style.space(8)

      ColumnLayout {
        Layout.fillWidth: true
        spacing: Style.space(3)

        Repeater {
          model: root.syncthing.errors
          Text {
            required property var modelData
            textFormat: Text.PlainText
            Layout.fillWidth: true
            text: String(modelData.message || modelData)
            color: root.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
            maximumLineCount: 3
            elide: Text.ElideRight
          }
        }
      }

      PanelActionButton {
        iconText: "󰩹"
        tooltipText: "Clear errors"
        foreground: root.foreground
        fontFamily: root.fontFamily
        onHovered: function(on) { if (on) root.setCursor("errors", 0) }
        onClicked: root.syncthing.clearErrors()
      }
    }
  }

  component ActionRow: CursorSurface {
    id: actionRow
    property var action: null
    property int rowIndex: 0

    hasCursor: root.isCursor("action", rowIndex)
    foreground: root.foreground
    accent: root.accent
    implicitHeight: Style.spacing.popupRowHeight

    Component.onCompleted: root.registerRow("action", rowIndex, actionRow)

    HoverHandler {
      onHoveredChanged: if (hovered) root.setCursor("action", actionRow.rowIndex)
    }

    TapHandler {
      onTapped: root.runFooterAction(actionRow.action)
    }

    RowLayout {
      anchors.fill: parent
      anchors.leftMargin: Style.spacing.rowPaddingX
      anchors.rightMargin: Style.spacing.rowPaddingX
      spacing: Style.space(10)

      Text {
        textFormat: Text.PlainText
        text: actionRow.action ? actionRow.action.icon : ""
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.iconSmall
      }

      Text {
        textFormat: Text.PlainText
        Layout.fillWidth: true
        text: actionRow.action ? actionRow.action.label : ""
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        elide: Text.ElideRight
      }
    }
  }
}
