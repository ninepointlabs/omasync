import QtQuick
import qs.Commons

// The Syncthing mark drawn natively rather than loaded from SVG: three nodes
// on a broken ring. Drawing it means it takes the theme foreground exactly,
// stays crisp at the ~11px the bar asks for (where a scaled-down SVG goes
// muddy), and can spin while a sync is actually running.
Item {
  id: root

  property real iconSize: Style.font.icon
  property color color: Color.foreground
  // Drawn over the mark when the service is stopped.
  property bool crossed: false
  // A small filled dot in the top-right corner, for pending invites or errors.
  property bool badge: false
  property color badgeColor: Color.urgent
  // Rotates the ring continuously; used while folders are syncing.
  property bool spinning: false

  implicitWidth: iconSize
  implicitHeight: iconSize
  width: iconSize
  height: iconSize

  property real _spin: 0

  NumberAnimation on _spin {
    running: root.spinning
    from: 0
    to: 360
    duration: 2600
    loops: Animation.Infinite
    // Leaving the ring where it stopped avoids a visible jump back to zero
    // when a sync finishes.
    alwaysRunToEnd: false
  }

  onColorChanged: canvas.requestPaint()
  onCrossedChanged: canvas.requestPaint()
  on_SpinChanged: canvas.requestPaint()
  onIconSizeChanged: canvas.requestPaint()

  Canvas {
    id: canvas
    anchors.fill: parent
    antialiasing: true

    onPaint: {
      var ctx = getContext("2d")
      var w = width
      var h = height
      ctx.reset()
      ctx.clearRect(0, 0, w, h)

      var cx = w / 2
      var cy = h / 2
      // The ring sits inside the box with room for the node dots, which
      // straddle it, plus a hair of padding so nothing clips.
      var nodeRadius = Math.max(1.1, w * 0.13)
      var ringRadius = w / 2 - nodeRadius - Math.max(0.5, w * 0.04)
      if (ringRadius <= 0) return

      var stroke = Math.max(1, w * 0.085)
      ctx.strokeStyle = root.color
      ctx.fillStyle = root.color
      ctx.lineWidth = stroke
      ctx.lineCap = "round"

      var spin = root._spin * Math.PI / 180
      // Nodes at the top and the two lower corners, the mark's own posture.
      var nodes = [-Math.PI / 2, Math.PI / 6, Math.PI * 5 / 6]
      // Each arc runs between two nodes, stopping short of both so the dots
      // read as separate nodes rather than beads on a solid ring.
      var gap = 0.42

      for (var i = 0; i < nodes.length; i++) {
        var from = nodes[i] + gap + spin
        var to = nodes[(i + 1) % nodes.length] - gap + spin
        if (to < from) to += Math.PI * 2
        ctx.beginPath()
        ctx.arc(cx, cy, ringRadius, from, to, false)
        ctx.stroke()
      }

      for (var j = 0; j < nodes.length; j++) {
        var angle = nodes[j] + spin
        ctx.beginPath()
        ctx.arc(cx + Math.cos(angle) * ringRadius, cy + Math.sin(angle) * ringRadius,
                nodeRadius, 0, Math.PI * 2, false)
        ctx.fill()
      }

      if (root.crossed) {
        // A slash across the mark, cut out of the artwork underneath so the
        // stroke stays legible whatever the ring is doing behind it.
        var inset = w * 0.1
        ctx.globalCompositeOperation = "destination-out"
        ctx.lineWidth = stroke * 2.6
        ctx.beginPath()
        ctx.moveTo(inset, h - inset)
        ctx.lineTo(w - inset, inset)
        ctx.stroke()

        ctx.globalCompositeOperation = "source-over"
        ctx.strokeStyle = root.color
        ctx.lineWidth = stroke
        ctx.beginPath()
        ctx.moveTo(inset, h - inset)
        ctx.lineTo(w - inset, inset)
        ctx.stroke()
      }
    }
  }

  Rectangle {
    visible: root.badge
    width: Math.max(3, root.iconSize * 0.3)
    height: width
    radius: width / 2
    color: root.badgeColor
    anchors.right: parent.right
    anchors.top: parent.top
    anchors.rightMargin: -width * 0.15
    anchors.topMargin: -width * 0.15
  }
}
