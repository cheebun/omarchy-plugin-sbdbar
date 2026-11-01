import QtQuick
import QtQuick.Shapes
import qs.Commons

Item {
  id: root

  property real iconSize: Style.font.icon
  property color color: Color.foreground
  property bool shaded: false

  width: iconSize
  height: iconSize
  implicitWidth: iconSize
  implicitHeight: iconSize

  readonly property real boxSize: Math.min(root.width, root.height)
  readonly property real s: boxSize / 100.0
  readonly property real ox: (root.width - 100.0 * s) / 2.0
  readonly property real oy: (root.height - 100.0 * s) / 2.0

  Shape {
    anchors.fill: parent
    antialiasing: true
    layer.enabled: true
    layer.samples: 4
    scale: 0.95

    // Top-Left Face
    ShapePath {
      fillColor: root.shaded ? Qt.rgba(root.color.r, root.color.g, root.color.b, 0.95) : root.color
      strokeWidth: 0
      startX: root.ox + 16.5 * root.s
      startY: root.oy + 30.0 * root.s
      PathLine { x: root.ox + 26.5 * root.s; y: root.oy + 24.5 * root.s }
      PathLine { x: root.ox + 59.5 * root.s; y: root.oy + 43.0 * root.s }
      PathLine { x: root.ox + 49.5 * root.s; y: root.oy + 48.5 * root.s }
      PathLine { x: root.ox + 16.5 * root.s; y: root.oy + 30.0 * root.s }
    }

    // Top-Right Face
    ShapePath {
      fillColor: root.shaded ? Qt.rgba(root.color.r, root.color.g, root.color.b, 0.95) : root.color
      strokeWidth: 0
      startX: root.ox + 50.5 * root.s
      startY: root.oy + 13.0 * root.s
      PathLine { x: root.ox + 83.5 * root.s; y: root.oy + 30.0 * root.s }
      PathLine { x: root.ox + 73.5 * root.s; y: root.oy + 35.8 * root.s }
      PathLine { x: root.ox + 40.5 * root.s; y: root.oy + 17.5 * root.s }
      PathLine { x: root.ox + 50.5 * root.s; y: root.oy + 13.0 * root.s }
    }

    // Left Face
    ShapePath {
      fillColor: root.shaded ? Qt.rgba(root.color.r, root.color.g, root.color.b, 0.55) : root.color
      strokeWidth: 0
      startX: root.ox + 16.0 * root.s
      startY: root.oy + 33.0 * root.s
      PathLine { x: root.ox + 48.8 * root.s; y: root.oy + 51.5 * root.s }
      PathLine { x: root.ox + 48.8 * root.s; y: root.oy + 87.0 * root.s }
      PathLine { x: root.ox + 16.0 * root.s; y: root.oy + 68.5 * root.s }
      PathLine { x: root.ox + 16.0 * root.s; y: root.oy + 33.0 * root.s }
    }

    // Right Face (with tape flap cutout)
    ShapePath {
      fillColor: root.shaded ? Qt.rgba(root.color.r, root.color.g, root.color.b, 0.78) : root.color
      strokeWidth: 0
      startX: root.ox + 51.2 * root.s
      startY: root.oy + 51.5 * root.s
      PathLine { x: root.ox + 60.5 * root.s; y: root.oy + 46.2 * root.s }
      PathLine { x: root.ox + 60.5 * root.s; y: root.oy + 63.5 * root.s }
      PathLine { x: root.ox + 73.5 * root.s; y: root.oy + 56.2 * root.s }
      PathLine { x: root.ox + 73.5 * root.s; y: root.oy + 39.0 * root.s }
      PathLine { x: root.ox + 84.0 * root.s; y: root.oy + 33.0 * root.s }
      PathLine { x: root.ox + 84.0 * root.s; y: root.oy + 68.5 * root.s }
      PathLine { x: root.ox + 51.2 * root.s; y: root.oy + 87.0 * root.s }
      PathLine { x: root.ox + 51.2 * root.s; y: root.oy + 51.5 * root.s }
    }
  }
}
