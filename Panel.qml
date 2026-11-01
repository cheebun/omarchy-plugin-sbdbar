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
  moduleName: "sbdbar"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  property var parentWidget: null

  // Every color derives from the Omarchy theme, so the panel follows theme switches
  readonly property color foreground: bar ? bar.barForeground : Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property color faint: Qt.darker(foreground, 2.05)
  readonly property color accent: Color.accent
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property var delayPalette: ({ "accent": accent, "foreground": foreground, "urgent": urgent, "faint": faint })
  readonly property var logPalette: ({
    "foreground": String(foreground), "dim": String(dim), "faint": String(faint),
    "accent": String(accent), "urgent": String(urgent)
  })

  function tint(c, alpha) {
    return Qt.rgba(c.r, c.g, c.b, alpha)
  }
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property string agentPath: Qt.resolvedUrl("bin/sbdbar-agent").toString().replace(/^file:\/\//, "")

  property string currentTab: "overview"
  property var expandedGroups: ({})
  property string searchConnection: ""
  property string selectedLogLevel: "info"
  property string searchLog: ""
  property bool logsPaused: false
  property var connectionsList: []
  property var logsList: []

  readonly property real availableTabHeight: Math.max(Style.space(200), (panel.availableCardHeight > 0 ? Math.min(panel.availableCardHeight, Style.space(680)) : Style.space(680)) - Style.space(210))

  readonly property var displayedLogs: {
    var list = root.logsList || []
    var q = (root.searchLog || "").trim().toLowerCase()
    if (!q) return list
    return list.filter(function(item) {
      var plain = ((item.level || "") + " " + (item.seq || "") + " " + (item.message || "")).toLowerCase()
      return plain.indexOf(q) !== -1
    })
  }


  property string inputUrl: parentWidget && parentWidget.effectiveUrl ? parentWidget.effectiveUrl : "http://127.0.0.1:9999"
  property string inputPassword: parentWidget && parentWidget.effectivePassword ? parentWidget.effectivePassword : ""
  property bool showPassword: false
  property bool showTrafficSetting: parentWidget ? parentWidget.showTraffic : true
  property string actionMessage: ""
  property bool actionIsError: false

  function isGroupExpanded(expandedMap, groupName, index) {
    if (expandedMap && expandedMap[groupName] !== undefined) {
      return expandedMap[groupName] === true
    }
    return index === 0
  }

  function toggleGroupExpand(groupName, index) {
    var cur = isGroupExpanded(expandedGroups, groupName, index)
    var next = Object.assign({}, expandedGroups)
    next[groupName] = !cur
    expandedGroups = next
  }

  // Groups render from a ListModel updated in place. The daemon pushes groups
  // every 250ms during a URL test; replacing the whole array would rebuild
  // every card on each push and make the tab flicker.
  ListModel {
    id: groupsModel
  }

  function groupsShape(groups) {
    return (groups || []).map(function(g) {
      return g.name + ":" + (g.items || []).map(function(it) { return it.name }).join(",")
    }).join("|")
  }

  property string groupsModelShape: ""
  readonly property string groupsView: parentWidget ? parentWidget.groupsView : "card"
  // Short transitions so delay and selection updates ease in instead of jumping
  readonly property int transitionMs: 180

  function syncGroupsModel() {
    var groups = root.parentWidget ? (root.parentWidget.groupsData || []) : []
    var shape = root.groupsShape(groups)
    if (shape !== root.groupsModelShape) {
      groupsModel.clear()
      for (var i = 0; i < groups.length; i++) {
        groupsModel.append({
          "name": String(groups[i].name || ""),
          "type": String(groups[i].type || ""),
          "selected": String(groups[i].selected || ""),
          "items": (groups[i].items || []).map(function(it) {
            return { "name": String(it.name || ""), "type": String(it.type || ""), "delay": Number(it.delay) || 0 }
          })
        })
      }
      root.groupsModelShape = shape
      return
    }
    for (var g = 0; g < groups.length; g++) {
      var row = groupsModel.get(g)
      if (row.type !== String(groups[g].type || "")) groupsModel.setProperty(g, "type", String(groups[g].type || ""))
      if (row.selected !== String(groups[g].selected || "")) groupsModel.setProperty(g, "selected", String(groups[g].selected || ""))
      var items = groups[g].items || []
      for (var j = 0; j < items.length; j++) {
        var item = row.items.get(j)
        var delay = Number(items[j].delay) || 0
        if (item.delay !== delay) row.items.setProperty(j, "delay", delay)
        if (item.type !== String(items[j].type || "")) row.items.setProperty(j, "type", String(items[j].type || ""))
      }
    }
  }

  Connections {
    target: root.parentWidget
    function onGroupsDataChanged() { root.syncGroupsModel() }
  }

  onParentWidgetChanged: root.syncGroupsModel()

  function open() {
    if (parentWidget) {
      inputUrl = parentWidget.effectiveUrl || "http://127.0.0.1:9999"
      inputPassword = parentWidget.effectivePassword || ""
    }
    currentTab = "overview"
    root.controller.show()
  }

  function close() {
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.open()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function") {
      return root.bar.switchPanelFrom(root.hostWidget || root, direction)
    }
    return false
  }

  function currentProcEnv() {
    return parentWidget ? parentWidget.procEnv() : {
      "BOX_API_URL": inputUrl || "",
      "BOX_API_SECRET": inputPassword || ""
    }
  }

  function runAction(args) {
    actionProc.running = false
    actionProc.environment = root.currentProcEnv()
    actionProc.command = [root.agentPath].concat(args)
    actionProc.running = true
  }

  function setMode(modeName) {
    if (!parentWidget) return
    root.runAction(["set-mode", modeName])
    parentWidget.currentMode = modeName
  }

  function selectNode(groupName, nodeName) {
    root.runAction(["select", groupName, nodeName])
  }

  function testGroup(groupName) {
    root.runAction(["urltest", groupName])
  }

  function testAll() {
    root.runAction(["urltest"])
  }

  function closeConn(connId) {
    root.runAction(["close", connId])
    root.connectionsList = (root.connectionsList || []).filter(function(c) { return c.id !== connId })
  }

  function closeAllConns() {
    root.runAction(["close-all"])
    root.connectionsList = []
  }

  // Connections and logs stream only while their tab is visible.
  // Setting running = false does not flip it until the process exits, so a
  // restart sets it back to true right away instead of checking it.
  function syncStream(proc, want, restart, command) {
    if (!want) {
      proc.running = false
      return
    }
    if (proc.running && !restart) return
    proc.running = false
    proc.environment = root.currentProcEnv()
    proc.command = command
    proc.running = true
  }

  function syncConnections(restart) {
    root.syncStream(connectionsProc, root.opened && root.currentTab === "connections", restart,
      [root.agentPath, "connections", "--interval", "1s"])
  }

  function syncLogs(restart) {
    root.syncStream(logsProc, root.opened && root.currentTab === "logs" && !root.logsPaused, restart,
      [root.agentPath, "logs", "--level", root.selectedLogLevel])
  }

  function refreshAll() {
    if (parentWidget) parentWidget.refreshNow()
    root.syncConnections(true)
    root.syncLogs(true)
  }

  onOpenedChanged: {
    root.syncConnections(false)
    root.syncLogs(false)
  }
  onCurrentTabChanged: {
    root.syncConnections(false)
    root.syncLogs(false)
  }
  onLogsPausedChanged: root.syncLogs(false)
  onSelectedLogLevelChanged: root.syncLogs(true)

  function saveConfig(newUrl, newPass) {
    var trafficStr = (root.parentWidget ? root.parentWidget.showTraffic : root.showTrafficSetting) ? "true" : "false"
    // The secret goes through the environment so it never shows up in ps
    saveProc.environment = ({ "BOX_API_SECRET": newPass || "" })
    saveProc.command = [root.agentPath, "save-config", "--url", newUrl, "--traffic", trafficStr]
    saveProc.running = true
  }

  function setTrafficDisplay(enabled) {
    root.showTrafficSetting = enabled
    if (root.parentWidget) {
      root.parentWidget.setShowTraffic(enabled)
    } else {
      setTrafficProc.command = [root.agentPath, "set-traffic", enabled ? "true" : "false"]
      setTrafficProc.running = false
      setTrafficProc.running = true
    }
  }

  Process {
    id: setTrafficProc
  }

  Process {
    id: saveProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.actionMessage = "Config saved"
        root.actionIsError = false
        if (parentWidget) {
          parentWidget.effectiveUrl = root.inputUrl
          parentWidget.effectivePassword = root.inputPassword
        }
        root.syncConnections(true)
        root.syncLogs(true)
      }
    }
  }

  Process {
    id: actionProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        // Groups, mode and connections update through their streams; after a
        // failure, reconnect so optimistic UI changes snap back to the real state.
        try {
          var res = JSON.parse(String(text || "").trim())
          root.actionMessage = res.success ? "" : String(res.error || "Action failed")
          root.actionIsError = !res.success
          if (!res.success && parentWidget) parentWidget.refreshNow()
        } catch (e) {}
      }
    }
  }

  Process {
    id: connectionsProc
    stdout: SplitParser {
      onRead: function(line) {
        try {
          var res = JSON.parse(line)
          if (res.type === "connections") root.connectionsList = res.connections || []
        } catch (e) {}
      }
    }
  }

  Process {
    id: logsProc
    stdout: SplitParser {
      onRead: function(line) {
        var res
        try {
          res = JSON.parse(line)
        } catch (e) {
          return
        }
        if (res.type !== "logs") return
        var list = res.reset ? [] : (root.logsList || []).slice()
        list = list.concat(res.entries || [])
        if (list.length > 500) list = list.slice(list.length - 500)
        root.logsList = list
      }
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.hostWidget || root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(540))
    contentHeight: panel.fittedContentHeight(contentCol.implicitHeight, Style.space(680))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: contentCol
        width: parent.width
        spacing: Style.space(12)

        // -----------------------------------------------------------
        // Top Bar: Dynamic Title & Quick Actions
        // -----------------------------------------------------------
        RowLayout {
          width: parent.width
          spacing: Style.space(8)

          Item {
            width: Style.space(22)
            height: Style.space(22)
            Layout.alignment: Qt.AlignVCenter

            SingBoxIcon {
              anchors.fill: parent
              iconSize: Style.space(22)
              color: root.foreground
            }

            Rectangle {
              width: Style.space(7)
              height: Style.space(7)
              radius: width / 2
              anchors.right: parent.right
              anchors.bottom: parent.bottom
              color: root.parentWidget && root.parentWidget.online ? root.accent : root.urgent
              border.width: 1
              border.color: Color.background
            }
          }

          Text {
            text: root.currentTab === "groups" ? "Groups" : (root.currentTab === "connections" ? "Connections" : (root.currentTab === "logs" ? "Logs" : (root.currentTab === "settings" ? "Settings" : "Overview")))
            font.family: root.fontFamily
            font.pixelSize: Style.font.title
            font.bold: true
            color: root.foreground
            Layout.fillWidth: true
          }

          // Refresh button
          Button {
            radius: 0
            iconText: "󰑐"
            tooltipText: "Refresh sing-box status"
            iconSpinning: root.parentWidget ? root.parentWidget.busy : false
            onClicked: {
              root.refreshAll()
            }
          }

          // Settings shortcut button
          Button {
            radius: 0
            iconText: "󰒓"
            tooltipText: "Configure API settings"
            selected: root.currentTab === "settings"
            onClicked: root.currentTab = (root.currentTab === "settings" ? "overview" : "settings")
          }
        }

        // Navigation Tabs Row
        RowLayout {
          width: parent.width
          spacing: Style.space(4)

          Button {
            radius: 0
            text: "Overview"
            iconText: "󰕮"
            selected: root.currentTab === "overview"
            bordered: true
            Layout.fillWidth: true
            onClicked: root.currentTab = "overview"
          }

          Button {
            radius: 0
            text: "Groups"
            iconText: "󰒍"
            selected: root.currentTab === "groups"
            bordered: true
            Layout.fillWidth: true
            onClicked: root.currentTab = "groups"
          }

          Button {
            radius: 0
            text: "Connections"
            iconText: "󰌘"
            selected: root.currentTab === "connections"
            bordered: true
            Layout.fillWidth: true
            onClicked: root.currentTab = "connections"
          }

          Button {
            radius: 0
            text: "Logs"
            iconText: "󰌱"
            selected: root.currentTab === "logs"
            bordered: true
            Layout.fillWidth: true
            onClicked: root.currentTab = "logs"
          }
        }

        PanelSeparator {
          width: parent.width
          foreground: root.foreground
        }

        // -----------------------------------------------------------
        // TAB 1: OVERVIEW (EXACTLY MATCHING OFFICIAL sing-box dashboard)
        // -----------------------------------------------------------
        Column {
          id: overviewTabCol
          width: parent.width
          spacing: Style.space(12)
          visible: root.currentTab === "overview"

          // 2x2 Grid of Cards: Upload, Download, Status, Connections
          Grid {
            id: cardsGrid
            columns: 2
            spacing: Style.space(12)
            width: parent.width

            // 1. Upload Traffic Card
            Rectangle {
              id: uploadCard
              width: (parent.width - Style.space(12)) / 2
              implicitHeight: uploadCol.implicitHeight + Style.space(24)
              height: implicitHeight
              color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.05)
              radius: 0
              border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.1)
              border.width: 1

              Column {
                id: uploadCol
                x: Style.space(14)
                y: Style.space(12)
                width: parent.width - Style.space(28)
                spacing: Style.space(4)

                // Header
                Row {
                  spacing: Style.space(6)
                  Text {
                    text: "󰕒"
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption * 1.1
                    color: root.accent
                  }
                  Text {
                    text: "Upload"
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption * 1.05
                    font.bold: true
                    color: root.foreground
                  }
                }

                // Primary Metric
                Text {
                  text: (root.parentWidget ? Model.formatBytes(root.parentWidget.uploadRate) : "0 B") + "/s"
                  font.family: root.fontFamily
                  font.pixelSize: Style.space(24)
                  font.bold: true
                  color: root.accent
                }

                // Subtitle Metric
                Text {
                  text: root.parentWidget ? Model.formatBytes(root.parentWidget.uploadTotal) : "0 B"
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  color: root.dim
                }

                Item { width: 1; height: Style.space(4) }

                // Sparkline
                Canvas {
                  id: uploadSparkline
                  width: parent.width
                  height: Style.space(46)

                  property var history: root.parentWidget ? root.parentWidget.uplinkHistory : []
                  property color lineColor: root.accent
                  onLineColorChanged: requestPaint()
                  onHistoryChanged: requestPaint()
                  onWidthChanged: requestPaint()
                  Component.onCompleted: requestPaint()

                  onPaint: {
                    var ctx = getContext("2d")
                    ctx.reset()
                    var w = width
                    var h = height
                    var pts = history || []
                    if (w <= 0 || h <= 0) return

                    if (pts.length < 2) {
                      ctx.beginPath()
                      ctx.moveTo(0, h - 3)
                      ctx.lineTo(w, h - 3)
                      ctx.strokeStyle = lineColor
                      ctx.lineWidth = 2.0
                      ctx.stroke()
                      return
                    }

                    var maxVal = 1
                    for (var i = 0; i < pts.length; i++) {
                      if (pts[i] > maxVal) maxVal = pts[i]
                    }
                    maxVal = maxVal * 1.25

                    var step = w / Math.max(pts.length - 1, 1)

                    ctx.beginPath()
                    ctx.moveTo(0, h)
                    for (var j = 0; j < pts.length; j++) {
                      var x = j * step
                      var y = h - 3 - (pts[j] / maxVal) * (h - 8)
                      ctx.lineTo(x, y)
                    }
                    ctx.lineTo((pts.length - 1) * step, h)
                    ctx.closePath()
                    ctx.fillStyle = root.tint(lineColor, 0.15)
                    ctx.fill()

                    ctx.beginPath()
                    for (var k = 0; k < pts.length; k++) {
                      var px = k * step
                      var py = h - 3 - (pts[k] / maxVal) * (h - 8)
                      if (k === 0) ctx.moveTo(px, py)
                      else ctx.lineTo(px, py)
                    }
                    ctx.strokeStyle = lineColor
                    ctx.lineWidth = 2.0
                    ctx.lineJoin = "round"
                    ctx.lineCap = "round"
                    ctx.stroke()
                  }
                }
              }
            }

            // 2. Download Traffic Card
            Rectangle {
              id: downloadCard
              width: (parent.width - Style.space(12)) / 2
              implicitHeight: downloadCol.implicitHeight + Style.space(24)
              height: implicitHeight
              color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.05)
              radius: 0
              border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.1)
              border.width: 1

              Column {
                id: downloadCol
                x: Style.space(14)
                y: Style.space(12)
                width: parent.width - Style.space(28)
                spacing: Style.space(4)

                // Header
                Row {
                  spacing: Style.space(6)
                  Text {
                    text: "󰇚"
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption * 1.1
                    color: root.dim
                  }
                  Text {
                    text: "Download"
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption * 1.05
                    font.bold: true
                    color: root.foreground
                  }
                }

                // Primary Metric
                Text {
                  text: (root.parentWidget ? Model.formatBytes(root.parentWidget.downloadRate) : "0 B") + "/s"
                  font.family: root.fontFamily
                  font.pixelSize: Style.space(24)
                  font.bold: true
                  color: root.foreground
                }

                // Subtitle Metric
                Text {
                  text: root.parentWidget ? Model.formatBytes(root.parentWidget.downloadTotal) : "0 B"
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  color: root.dim
                }

                Item { width: 1; height: Style.space(4) }

                // Sparkline
                Canvas {
                  id: downloadSparkline
                  width: parent.width
                  height: Style.space(46)

                  property var history: root.parentWidget ? root.parentWidget.downlinkHistory : []
                  property color lineColor: root.foreground
                  onLineColorChanged: requestPaint()
                  onHistoryChanged: requestPaint()
                  onWidthChanged: requestPaint()
                  Component.onCompleted: requestPaint()

                  onPaint: {
                    var ctx = getContext("2d")
                    ctx.reset()
                    var w = width
                    var h = height
                    var pts = history || []
                    if (w <= 0 || h <= 0) return

                    if (pts.length < 2) {
                      ctx.beginPath()
                      ctx.moveTo(0, h - 3)
                      ctx.lineTo(w, h - 3)
                      ctx.strokeStyle = lineColor
                      ctx.lineWidth = 2.0
                      ctx.stroke()
                      return
                    }

                    var maxVal = 1
                    for (var i = 0; i < pts.length; i++) {
                      if (pts[i] > maxVal) maxVal = pts[i]
                    }
                    maxVal = maxVal * 1.25

                    var step = w / Math.max(pts.length - 1, 1)

                    ctx.beginPath()
                    ctx.moveTo(0, h)
                    for (var j = 0; j < pts.length; j++) {
                      var x = j * step
                      var y = h - 3 - (pts[j] / maxVal) * (h - 8)
                      ctx.lineTo(x, y)
                    }
                    ctx.lineTo((pts.length - 1) * step, h)
                    ctx.closePath()
                    ctx.fillStyle = root.tint(lineColor, 0.15)
                    ctx.fill()

                    ctx.beginPath()
                    for (var k = 0; k < pts.length; k++) {
                      var px = k * step
                      var py = h - 3 - (pts[k] / maxVal) * (h - 8)
                      if (k === 0) ctx.moveTo(px, py)
                      else ctx.lineTo(px, py)
                    }
                    ctx.strokeStyle = lineColor
                    ctx.lineWidth = 2.0
                    ctx.lineJoin = "round"
                    ctx.lineCap = "round"
                    ctx.stroke()
                  }
                }
              }
            }

            // 3. Status Card (Memory, Goroutines)
            Rectangle {
              id: statusCard
              width: (parent.width - Style.space(12)) / 2
              implicitHeight: statusCol.implicitHeight + Style.space(24)
              height: implicitHeight
              color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.05)
              radius: 0
              border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.1)
              border.width: 1

              Column {
                id: statusCol
                x: Style.space(14)
                y: Style.space(12)
                width: parent.width - Style.space(28)
                spacing: Style.space(10)

                // Header
                Row {
                  spacing: Style.space(6)
                  Text {
                    text: "󰍛"
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption * 1.1
                    color: root.dim
                  }
                  Text {
                    text: "Status"
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption * 1.05
                    font.bold: true
                    color: root.foreground
                  }
                }

                // Line 1: Memory
                Item {
                  width: parent.width
                  height: Style.space(20)
                  Text {
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    text: "Memory"
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption * 1.05
                    color: root.dim
                  }
                  Text {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    text: Model.formatBytes(root.parentWidget ? root.parentWidget.memory : 0)
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption * 1.05
                    font.bold: true
                    color: root.foreground
                  }
                }

                // Line 2: Goroutines
                Item {
                  width: parent.width
                  height: Style.space(20)
                  Text {
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    text: "Goroutines"
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption * 1.05
                    color: root.dim
                  }
                  Text {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    text: String(root.parentWidget ? root.parentWidget.goroutines : 0)
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption * 1.05
                    font.bold: true
                    color: root.foreground
                  }
                }
              }
            }

            // 4. Connections Card (Inbound, Outbound)
            Rectangle {
              id: connCard
              width: (parent.width - Style.space(12)) / 2
              implicitHeight: connCol.implicitHeight + Style.space(24)
              height: implicitHeight
              color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.05)
              radius: 0
              border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.1)
              border.width: 1

              Column {
                id: connCol
                x: Style.space(14)
                y: Style.space(12)
                width: parent.width - Style.space(28)
                spacing: Style.space(10)

                // Header
                Row {
                  spacing: Style.space(6)
                  Text {
                    text: "󰛳"
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption * 1.1
                    color: root.dim
                  }
                  Text {
                    text: "Connections"
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption * 1.05
                    font.bold: true
                    color: root.foreground
                  }
                }

                // Line 1: Inbound
                Item {
                  width: parent.width
                  height: Style.space(20)
                  Text {
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    text: "Inbound"
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption * 1.05
                    color: root.dim
                  }
                  Text {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    text: String(root.parentWidget ? root.parentWidget.connectionsIn : 0)
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption * 1.05
                    font.bold: true
                    color: root.foreground
                  }
                }

                // Line 2: Outbound
                Item {
                  width: parent.width
                  height: Style.space(20)
                  Text {
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    text: "Outbound"
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption * 1.05
                    color: root.dim
                  }
                  Text {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    text: String(root.parentWidget ? root.parentWidget.connectionsOut : 0)
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption * 1.05
                    font.bold: true
                    color: root.foreground
                  }
                }
              }
            }
          }

          // 5. Mode Card (Wide Card matching screenshot)
          Rectangle {
            id: modeCard
            width: parent.width
            implicitHeight: modeCol.implicitHeight + Style.space(24)
            height: implicitHeight
            color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.05)
            radius: 0
            border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.1)
            border.width: 1

            Column {
              id: modeCol
              x: Style.space(14)
              y: Style.space(12)
              width: parent.width - Style.space(28)
              spacing: Style.space(10)

              // Header
              Row {
                spacing: Style.space(6)
                Text {
                  text: "󰑮"
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption * 1.1
                  color: root.dim
                }
                Text {
                  text: "Mode"
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption * 1.05
                  font.bold: true
                  color: root.foreground
                }
              }

              // Segmented Container
              Rectangle {
                width: parent.width
                height: Style.space(38)
                color: root.tint(root.foreground, 0.055)
                border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.08)
                border.width: 1
                radius: 0

                Row {
                  id: modeRow
                  anchors.fill: parent
                  anchors.margins: Style.space(3)
                  spacing: Style.space(2)

                  property var modes: root.parentWidget && root.parentWidget.modeList && root.parentWidget.modeList.length
                    ? root.parentWidget.modeList.map(function(m) { return String(m).toLowerCase() })
                    : ["rule", "direct", "global"]
                  property real itemWidth: (width - (modes.length - 1) * spacing) / modes.length

                  Repeater {
                    model: modeRow.modes

                    Rectangle {
                      id: modeBtn
                      width: modeRow.itemWidth
                      height: modeRow.height
                      radius: 0
                      property bool isSelected: root.parentWidget && root.parentWidget.currentMode.toLowerCase() === modelData.toLowerCase()

                      color: isSelected ? root.tint(root.accent, 0.14) : (modeMouse.containsMouse ? root.tint(root.foreground, 0.06) : "transparent")
                      border.color: isSelected ? root.accent : "transparent"
                      border.width: isSelected ? 1 : 0

                      Text {
                        anchors.centerIn: parent
                        text: modelData
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption * 1.05
                        font.bold: modeBtn.isSelected
                        color: modeBtn.isSelected ? root.accent : root.dim
                      }

                      MouseArea {
                        id: modeMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.setMode(modelData)
                      }
                    }
                  }
                }
              }
            }
          }
        }

        // -----------------------------------------------------------
        // TAB 2: GROUPS (MATCHING OFFICIAL sing-box dashboard GroupsView)
        // -----------------------------------------------------------
        Column {
          id: groupsTabCol
          width: parent.width
          spacing: Style.space(12)
          visible: root.currentTab === "groups"

          // Card / list view switch
          RowLayout {
            id: groupsViewSwitch
            width: parent.width
            spacing: Style.space(4)

            Item { Layout.fillWidth: true }

            // Test every group; lives here since it only applies to this tab
            Button {
              radius: 0
              iconText: "󰓅"
              tooltipText: "Test latency on groups"
              bordered: true
              onClicked: root.testAll()
            }

            Button {
              radius: 0
              iconText: "󰕰"
              tooltipText: "Card view"
              bordered: true
              selected: root.groupsView === "card"
              onClicked: if (root.parentWidget) root.parentWidget.setGroupsView("card")
            }

            Button {
              radius: 0
              iconText: "󰕲"
              tooltipText: "List view"
              bordered: true
              selected: root.groupsView === "list"
              onClicked: if (root.parentWidget) root.parentWidget.setGroupsView("list")
            }
          }

          Flickable {
            id: groupsFlickable
            width: parent.width
            height: Math.min(groupsCol.implicitHeight, root.availableTabHeight - groupsViewSwitch.height - groupsTabCol.spacing)
            implicitHeight: height
            contentWidth: width
            contentHeight: groupsCol.implicitHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            flickableDirection: Flickable.VerticalFlick
            interactive: contentHeight > height
            ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

            Column {
              id: groupsCol
              width: parent.width - (groupsFlickable.interactive ? Style.space(8) : 0)
              spacing: Style.space(14)

              Repeater {
                model: groupsModel

                Rectangle {
                  id: groupCardSurface
                  width: parent.width
                  implicitHeight: groupCardInner.implicitHeight + Style.space(24)
                  height: implicitHeight
                  color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.05)
                  radius: 0
                  border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.1)
                  border.width: 1

                  property var groupInfo: model
                  property bool isExpanded: root.isGroupExpanded(root.expandedGroups, groupInfo.name, index)
                  property bool isSelectable: String(groupInfo.type || "").toLowerCase() === "selector"

                  Column {
                    id: groupCardInner
                    x: Style.space(14)
                    y: Style.space(12)
                    width: parent.width - Style.space(28)
                    spacing: Style.space(12)

                    // 1. Group Header Row
                    RowLayout {
                      width: parent.width
                      spacing: Style.space(8)

                      Item {
                        Layout.fillWidth: true
                        implicitHeight: groupTitleRow.implicitHeight

                        Row {
                          id: groupTitleRow
                          anchors.verticalCenter: parent.verticalCenter
                          spacing: Style.space(6)

                          Text {
                            text: groupCardSurface.groupInfo.name || "group"
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.title * 0.95
                            font.bold: true
                            color: root.foreground
                          }

                          Text {
                            text: Model.proxyDisplayType(groupCardSurface.groupInfo.type)
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.caption * 1.05
                            color: root.dim
                          }
                        }

                        MouseArea {
                          anchors.fill: parent
                          cursorShape: Qt.PointingHandCursor
                          onClicked: root.toggleGroupExpand(groupCardSurface.groupInfo.name, index)
                        }
                      }

                      // Node count badge
                      Rectangle {
                        width: countBadgeText.implicitWidth + Style.space(14)
                        height: Style.space(22)
                        radius: 0
                        color: root.tint(root.foreground, 0.1)

                        Text {
                          id: countBadgeText
                          anchors.centerIn: parent
                          text: groupCardSurface.groupInfo.items ? String(groupCardSurface.groupInfo.items.count) : "0"
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.caption
                          font.bold: true
                          color: root.dim
                        }
                      }

                      // Test Group Button
                      Button {
                        radius: 0
                        iconText: "󰓅"
                        tooltipText: "Test latency on this group"
                        onClicked: root.testGroup(groupCardSurface.groupInfo.name)
                      }

                      // Expand / Collapse Chevron Button
                      Button {
                        radius: 0
                        iconText: groupCardSurface.isExpanded ? "󰅃" : "󰅀"
                        tooltipText: groupCardSurface.isExpanded ? "Collapse group" : "Expand group"
                        onClicked: root.toggleGroupExpand(groupCardSurface.groupInfo.name, index)
                      }
                    }

                    // 2. Node Cards Grid (When Expanded)
                    Grid {
                      id: nodesGrid
                      visible: groupCardSurface.isExpanded && root.groupsView === "card"
                      width: parent.width
                      columns: width >= Style.space(460) ? 4 : 3
                      spacing: Style.space(8)

                      property real cardWidth: Math.floor((width - (columns - 1) * spacing) / columns)

                      Repeater {
                        model: groupCardSurface.groupInfo.items

                        Rectangle {
                          id: nodeCardItem
                          width: nodesGrid.cardWidth
                          height: Style.space(58)
                          radius: 0

                          property var itemData: model
                          property bool isSelected: groupCardSurface.groupInfo.selected === itemData.name
                          property int delayVal: Number(itemData.delay) || 0

                          color: isSelected ? root.tint(root.accent, 0.14) : (nodeHoverArea.containsMouse ? root.tint(root.foreground, 0.09) : root.tint(root.foreground, 0.055))
                          border.color: isSelected ? root.accent : (nodeHoverArea.containsMouse ? root.tint(root.foreground, 0.3) : root.tint(root.foreground, 0.12))
                          border.width: isSelected ? 1.5 : 1

                          Behavior on color { ColorAnimation { duration: root.transitionMs } }
                          Behavior on border.color { ColorAnimation { duration: root.transitionMs } }

                          Column {
                            anchors.fill: parent
                            anchors.margins: Style.space(8)
                            spacing: Style.space(4)

                            // Node Tag Name
                            Text {
                              width: parent.width
                              text: nodeCardItem.itemData.name || ""
                              font.family: root.fontFamily
                              font.pixelSize: Style.font.caption * 1.05
                              font.bold: true
                              color: nodeCardItem.isSelected ? root.accent : root.foreground
                              elide: Text.ElideRight
                            }

                            // Protocol Type & Delay Text
                            Item {
                              width: parent.width
                              height: Style.space(16)

                              Text {
                                anchors.left: parent.left
                                anchors.verticalCenter: parent.verticalCenter
                                text: Model.proxyDisplayType(nodeCardItem.itemData.type)
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.caption * 0.9
                                color: root.dim
                              }

                              Text {
                                id: delayLabel
                                anchors.right: parent.right
                                anchors.verticalCenter: parent.verticalCenter
                                text: Model.delayText(nodeCardItem.delayVal)
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.caption * 0.95
                                font.bold: true
                                color: Model.delayColor(nodeCardItem.delayVal, root.delayPalette)

                                Behavior on color { ColorAnimation { duration: root.transitionMs } }

                                // Fade the new value in so a fresh test result is noticeable
                                NumberAnimation {
                                  id: delayFadeIn
                                  target: delayLabel
                                  property: "opacity"
                                  from: 0.25
                                  to: 1
                                  duration: root.transitionMs * 2
                                  easing.type: Easing.OutQuad
                                }
                              }

                              Connections {
                                target: nodeCardItem
                                function onDelayValChanged() { delayFadeIn.restart() }
                              }
                            }
                          }

                          ToolTip.visible: nodeHoverArea.containsMouse && nodeCardItem.itemData.name.length > 12
                          ToolTip.text: nodeCardItem.itemData.name + (nodeCardItem.delayVal > 0 ? " (" + nodeCardItem.delayVal + "ms)" : "")

                          MouseArea {
                            id: nodeHoverArea
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: groupCardSurface.isSelectable ? Qt.PointingHandCursor : Qt.ArrowCursor
                            onClicked: {
                              if (groupCardSurface.isSelectable) {
                                root.selectNode(groupCardSurface.groupInfo.name, nodeCardItem.itemData.name)
                                groupCardSurface.groupInfo.selected = nodeCardItem.itemData.name
                              }
                            }
                          }
                        }
                      }
                    }

                    // 2b. Node List Rows (When Expanded, list view)
                    Column {
                      id: nodesList
                      visible: groupCardSurface.isExpanded && root.groupsView === "list"
                      width: parent.width
                      spacing: Style.space(4)

                      Repeater {
                        model: groupCardSurface.groupInfo.items

                        Rectangle {
                          id: nodeRowItem
                          width: nodesList.width
                          height: Style.space(36)
                          radius: 0

                          property var itemData: model
                          property bool isSelected: groupCardSurface.groupInfo.selected === itemData.name
                          property int delayVal: Number(itemData.delay) || 0
                          property color delayTone: Model.delayColor(delayVal, root.delayPalette)

                          color: isSelected ? root.tint(root.accent, 0.14) : (rowHoverArea.containsMouse ? root.tint(root.foreground, 0.09) : root.tint(root.foreground, 0.055))
                          border.color: isSelected ? root.accent : (rowHoverArea.containsMouse ? root.tint(root.foreground, 0.3) : root.tint(root.foreground, 0.12))
                          border.width: isSelected ? 1.5 : 1

                          Behavior on color { ColorAnimation { duration: root.transitionMs } }
                          Behavior on border.color { ColorAnimation { duration: root.transitionMs } }

                          RowLayout {
                            anchors.fill: parent
                            anchors.leftMargin: Style.space(12)
                            anchors.rightMargin: Style.space(8)
                            spacing: Style.space(10)

                            Text {
                              text: nodeRowItem.itemData.name || ""
                              font.family: root.fontFamily
                              font.pixelSize: Style.font.caption * 1.05
                              font.bold: true
                              color: nodeRowItem.isSelected ? root.accent : root.foreground
                              elide: Text.ElideRight
                              Layout.fillWidth: true
                              Layout.minimumWidth: 0
                            }

                            Text {
                              text: Model.proxyDisplayType(nodeRowItem.itemData.type).toUpperCase()
                              font.family: root.fontFamily
                              font.pixelSize: Style.font.caption * 0.85
                              color: root.dim
                            }

                            // Delay badge with a tone-colored underline
                            Rectangle {
                              Layout.preferredWidth: Style.space(46)
                              Layout.preferredHeight: Style.space(22)
                              radius: 0
                              color: nodeRowItem.delayVal > 0 ? root.tint(nodeRowItem.delayTone, 0.14) : root.tint(root.foreground, 0.08)

                              Behavior on color { ColorAnimation { duration: root.transitionMs } }

                              Text {
                                id: rowDelayLabel
                                anchors.centerIn: parent
                                text: nodeRowItem.delayVal > 0 ? String(nodeRowItem.delayVal) : "—"
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.caption * 0.9
                                font.bold: true
                                color: nodeRowItem.delayVal > 0 ? nodeRowItem.delayTone : root.faint

                                Behavior on color { ColorAnimation { duration: root.transitionMs } }

                                NumberAnimation {
                                  id: rowDelayFadeIn
                                  target: rowDelayLabel
                                  property: "opacity"
                                  from: 0.25
                                  to: 1
                                  duration: root.transitionMs * 2
                                  easing.type: Easing.OutQuad
                                }
                              }

                              Rectangle {
                                visible: nodeRowItem.delayVal > 0
                                anchors.left: parent.left
                                anchors.right: parent.right
                                anchors.bottom: parent.bottom
                                height: 2
                                color: nodeRowItem.delayTone

                                Behavior on color { ColorAnimation { duration: root.transitionMs } }
                              }
                            }
                          }

                          Connections {
                            target: nodeRowItem
                            function onDelayValChanged() { rowDelayFadeIn.restart() }
                          }

                          ToolTip.visible: rowHoverArea.containsMouse && nodeRowItem.delayVal > 0
                          ToolTip.text: nodeRowItem.itemData.name + " (" + nodeRowItem.delayVal + "ms)"

                          MouseArea {
                            id: rowHoverArea
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: groupCardSurface.isSelectable ? Qt.PointingHandCursor : Qt.ArrowCursor
                            onClicked: {
                              if (groupCardSurface.isSelectable) {
                                root.selectNode(groupCardSurface.groupInfo.name, nodeRowItem.itemData.name)
                                groupCardSurface.groupInfo.selected = nodeRowItem.itemData.name
                              }
                            }
                          }
                        }
                      }
                    }

                    // 3. Horizontal Latency Dots (When Collapsed)
                    Flow {
                      id: dotsFlow
                      visible: !groupCardSurface.isExpanded
                      width: parent.width
                      spacing: Style.space(4)

                      Repeater {
                        model: groupCardSurface.groupInfo.items

                        Rectangle {
                          id: dotItem
                          width: 11
                          height: 11
                          radius: 0

                          property var itemData: model
                          property int delayVal: Number(itemData.delay) || 0
                          property bool isSelected: groupCardSurface.groupInfo.selected === itemData.name

                          color: Model.delayColor(delayVal, root.delayPalette)

                          Behavior on color { ColorAnimation { duration: root.transitionMs } }

                          // Inner white circle for selected node
                          Rectangle {
                            visible: dotItem.isSelected
                            anchors.centerIn: parent
                            width: 4
                            height: 4
                            radius: 2
                            color: Color.background
                          }

                          ToolTip.visible: dotMouse.containsMouse
                          ToolTip.text: dotItem.itemData.name + (dotItem.delayVal > 0 ? " (" + dotItem.delayVal + "ms)" : "")

                          MouseArea {
                            id: dotMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: groupCardSurface.isSelectable ? Qt.PointingHandCursor : Qt.ArrowCursor
                            onClicked: {
                              if (groupCardSurface.isSelectable) {
                                root.selectNode(groupCardSurface.groupInfo.name, dotItem.itemData.name)
                                groupCardSurface.groupInfo.selected = dotItem.itemData.name
                              }
                            }
                          }
                        }
                      }
                    }
                  }
                }
              }

              // Empty groups fallback
              Text {
                visible: groupsModel.count === 0
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                topPadding: Style.space(40)
                text: "No outbound groups found. Click refresh to query sing-box API."
                font.family: root.fontFamily
                color: root.dim
              }
            }
          }
        }

        // -----------------------------------------------------------
        // TAB 3: CONNECTIONS
        // -----------------------------------------------------------
        Column {
          width: parent.width
          spacing: Style.space(8)
          visible: root.currentTab === "connections"

          // Filter & Actions Row
          RowLayout {
            width: parent.width
            spacing: Style.space(8)

            TextField {
              Component.onCompleted: if (background) background.radius = 0
              id: connSearchField
              placeholderText: "Search"
              Layout.fillWidth: true
              text: root.searchConnection
              onTextChanged: root.searchConnection = text
            }

            Button {
              radius: 0
              text: "Close All"
              iconText: "󰅙"
              tooltipText: "Terminate all active connections"
              onClicked: root.closeAllConns()
            }

            Button {
              radius: 0
              iconText: "󰑐"
              tooltipText: "Refresh active connections"
              onClicked: root.syncConnections(true)
            }
          }

          // Connections Count Summary
          Text {
            text: "Active: " + (root.connectionsList ? root.connectionsList.length : 0) + " tracked connections"
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            color: root.dim
          }

          // Connections Scrollable List
          Flickable {
            id: connFlickable
            width: parent.width
            height: Math.min(connsCol.implicitHeight, root.availableTabHeight)
            implicitHeight: height
            contentWidth: width
            contentHeight: connsCol.implicitHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            flickableDirection: Flickable.VerticalFlick
            interactive: contentHeight > height
            ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

            Column {
              id: connsCol
              width: parent.width - (connFlickable.interactive ? Style.space(8) : 0)
              spacing: Style.space(8)

              Repeater {
                model: {
                  if (!root.connectionsList) return []
                  if (!root.searchConnection) return root.connectionsList
                  var q = root.searchConnection.trim().toLowerCase()
                  return root.connectionsList.filter(function(c) {
                    return (c.host && c.host.toLowerCase().indexOf(q) !== -1) ||
                           (c.destination && c.destination.toLowerCase().indexOf(q) !== -1) ||
                           (c.route && c.route.toLowerCase().indexOf(q) !== -1) ||
                           (c.outbound && c.outbound.toLowerCase().indexOf(q) !== -1) ||
                           (c.inbound && c.inbound.toLowerCase().indexOf(q) !== -1) ||
                           (c.network && c.network.toLowerCase().indexOf(q) !== -1)
                  })
                }

                Rectangle {
                  id: connCardItem
                  width: parent.width
                  implicitHeight: connCardInner.implicitHeight + Style.space(20)
                  height: implicitHeight
                  color: connHoverArea.containsMouse ? root.tint(root.foreground, 0.09) : root.tint(root.foreground, 0.055)
                  radius: 0
                  border.color: connHoverArea.containsMouse ? root.tint(root.foreground, 0.3) : root.tint(root.foreground, 0.12)
                  border.width: 1
                  clip: true

                  property var cData: modelData

                  Column {
                    id: connCardInner
                    x: Style.space(14)
                    y: Style.space(10)
                    width: parent.width - Style.space(28)
                    spacing: Style.space(8)

                    // Line 1: Header (TCP Badge, Destination Host, Active Badge / Close Button)
                    RowLayout {
                      width: parent.width
                      spacing: Style.space(8)

                      // Network pill (e.g. TCP, UDP)
                      Rectangle {
                        width: netText.implicitWidth + Style.space(12)
                        height: Style.space(20)
                        radius: 0
                        color: root.tint(root.foreground, 0.1)

                        Text {
                          id: netText
                          anchors.centerIn: parent
                          text: (connCardItem.cData.network || "TCP").toUpperCase()
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.caption * 0.85
                          font.bold: true
                          color: root.dim
                        }
                      }

                      // Host / Destination (Monospace white text)
                      Text {
                        text: connCardItem.cData.host || connCardItem.cData.destination || "Unknown"
                        font.family: "monospace"
                        font.pixelSize: Style.font.caption * 1.05
                        font.bold: true
                        color: root.foreground
                        elide: Text.ElideRight
                        Layout.fillWidth: true
                        Layout.minimumWidth: 0
                      }

                      // Close button (visible when hovering)
                      Button {
                        radius: 0
                        id: closeBtn
                        visible: connHoverArea.containsMouse
                        iconText: "󰅙"
                        tooltipText: "Close this connection"
                        onClicked: root.closeConn(connCardItem.cData.id)
                      }

                      // Active status badge (green pill)
                      Rectangle {
                        visible: !closeBtn.visible
                        width: activeText.implicitWidth + Style.space(16)
                        height: Style.space(20)
                        radius: 0
                        color: root.tint(root.accent, 0.14)

                        Text {
                          id: activeText
                          anchors.centerIn: parent
                          text: "Active"
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.caption * 0.85
                          font.bold: true
                          color: root.accent
                        }
                      }
                    }

                    // Line 2: 3 Columns matching official dashboard
                    RowLayout {
                      width: parent.width
                      spacing: Style.space(6)

                      // Col 1: Transfer Rates (↑ 0 B/s, ↓ 1 KB/s)
                      Column {
                        Layout.preferredWidth: Style.space(90)
                        spacing: Style.space(2)

                        Text {
                          text: connCardItem.cData.upRate || "↑ 0 B/s"
                          font.family: "monospace"
                          font.pixelSize: Style.font.caption * 0.95
                          color: root.dim
                        }

                        Text {
                          text: connCardItem.cData.downRate || "↓ 0 B/s"
                          font.family: "monospace"
                          font.pixelSize: Style.font.caption * 0.95
                          color: root.dim
                        }
                      }

                      // Col 2: Total Transferred (↑ 2.1 KB, ↓ 5.5 KB)
                      Column {
                        Layout.preferredWidth: Style.space(90)
                        spacing: Style.space(2)

                        Text {
                          text: connCardItem.cData.upTotal || "↑ 0 B"
                          font.family: "monospace"
                          font.pixelSize: Style.font.caption * 0.95
                          color: root.dim
                        }

                        Text {
                          text: connCardItem.cData.downTotal || "↓ 0 B"
                          font.family: "monospace"
                          font.pixelSize: Style.font.caption * 0.95
                          color: root.dim
                        }
                      }

                      // Col 3: Inbound & Outbound / Route (tun/tun-in, select)
                      Column {
                        Layout.fillWidth: true
                        Layout.minimumWidth: 0
                        spacing: Style.space(2)

                        Text {
                          width: parent.width
                          horizontalAlignment: Text.AlignRight
                          text: connCardItem.cData.inbound || "tun/tun-in"
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.caption * 0.95
                          color: root.dim
                          elide: Text.ElideRight
                        }

                        Text {
                          width: parent.width
                          horizontalAlignment: Text.AlignRight
                          text: connCardItem.cData.route || connCardItem.cData.outbound || "select"
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.caption * 0.95
                          color: root.dim
                          elide: Text.ElideRight
                        }
                      }
                    }
                  }

                  MouseArea {
                    id: connHoverArea
                    anchors.fill: parent
                    hoverEnabled: true
                  }
                }
              }

              // Empty Connections State
              Text {
                visible: !root.connectionsList || root.connectionsList.length === 0
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                topPadding: Style.space(40)
                bottomPadding: Style.space(40)
                text: "No active connections"
                font.family: root.fontFamily
                color: root.dim
              }
            }
          }
        }

        // -----------------------------------------------------------
        // TAB 4: LOGS (BEAUTIFIED MONOSPACE MATCHING OFFICIAL DASHBOARD)
        // -----------------------------------------------------------
        Column {
          width: parent.width
          spacing: Style.space(8)
          visible: root.currentTab === "logs"

          // 1. Search Bar & Action Buttons (Pause, Clear, Reload)
          RowLayout {
            width: parent.width
            spacing: Style.space(8)

            // Search pill matching screenshot
            Rectangle {
              Layout.fillWidth: true
              height: Style.space(34)
              radius: 0
              color: root.tint(root.foreground, 0.055)
              border.color: searchLogInput.activeFocus ? root.accent : root.tint(root.foreground, 0.12)
              border.width: 1

              RowLayout {
                anchors.fill: parent
                anchors.leftMargin: Style.space(10)
                anchors.rightMargin: Style.space(10)
                spacing: Style.space(8)

                Text {
                  text: "󰍉"
                  font.family: Style.font.family
                  font.pixelSize: Style.font.body
                  color: root.dim
                }

                TextInput {
                  id: searchLogInput
                  Layout.fillWidth: true
                  text: root.searchLog
                  onTextChanged: root.searchLog = text
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  color: root.foreground
                  clip: true

                  Text {
                    visible: !searchLogInput.text && !searchLogInput.activeFocus
                    text: "Search"
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    color: root.dim
                    anchors.verticalCenter: parent.verticalCenter
                  }
                }

                Button {
                  radius: 0
                  visible: !!searchLogInput.text
                  iconText: "✕"
                  padding: 0
                  onClicked: {
                    searchLogInput.text = ""
                    root.searchLog = ""
                  }
                }
              }
            }

            // Pause / Resume Auto-scroll
            Button {
              radius: 0
              iconText: root.logsPaused ? "󰐊" : "󰏤"
              tooltipText: root.logsPaused ? "Resume auto-scroll" : "Pause auto-scroll"
              selected: root.logsPaused
              onClicked: root.logsPaused = !root.logsPaused
            }

            // Clear View
            Button {
              radius: 0
              iconText: "󰃢"
              tooltipText: "Clear logs view"
              onClicked: root.logsList = []
            }

            // Refresh
            Button {
              radius: 0
              iconText: "󰑐"
              tooltipText: "Reload service logs"
              onClicked: root.syncLogs(true)
            }
          }

          // 2. Logs Level Filter Row
          RowLayout {
            width: parent.width
            spacing: Style.space(6)

            Repeater {
              model: ["info", "warn", "error", "debug", "trace"]

              Button {
                radius: 0
                text: modelData.toUpperCase()
                selected: root.selectedLogLevel === modelData
                bordered: true
                Layout.fillWidth: true
                onClicked: root.selectedLogLevel = modelData
              }
            }
          }

          // 3. Log Console Card (Dark rounded terminal view matching screenshot)
          Rectangle {
            id: logsConsoleCard
            width: parent.width
            height: Style.space(360)
            color: root.tint(root.foreground, 0.035)
            radius: 0
            border.color: root.tint(root.foreground, 0.12)
            border.width: 1
            clip: true

            Flickable {
              id: logsFlickable
              anchors.fill: parent
              anchors.margins: Style.space(12)
              contentWidth: Math.max(width, logLinesCol.implicitWidth)
              contentHeight: logLinesCol.implicitHeight
              clip: true
              boundsBehavior: Flickable.StopAtBounds

              onContentHeightChanged: {
                if (!root.logsPaused && contentHeight > height) {
                  contentY = contentHeight - height
                }
              }

              Column {
                id: logLinesCol
                spacing: Style.space(3)

                Repeater {
                  model: root.displayedLogs

                  Text {
                    textFormat: Text.RichText
                    text: Model.formatLogLineHtml(modelData, root.logPalette)
                    font.family: "monospace"
                    font.pixelSize: Style.font.caption * 0.92
                    renderType: Text.NativeRendering
                  }
                }

                Text {
                  visible: !root.displayedLogs || root.displayedLogs.length === 0
                  width: logsFlickable.width
                  horizontalAlignment: Text.AlignHCenter
                  topPadding: Style.space(50)
                  text: root.searchLog ? ("No logs matching \"" + root.searchLog + "\"") : ("No log entries for level " + root.selectedLogLevel)
                  font.family: "monospace"
                  font.pixelSize: Style.font.caption
                  color: root.dim
                }
              }
            }
          }
        }

        // -----------------------------------------------------------
        // TAB 5: SETTINGS
        // -----------------------------------------------------------
        Column {
          width: parent.width
          spacing: Style.space(10)
          visible: root.currentTab === "settings"

          PanelSectionHeader {
            text: "SING-BOX API CONFIGURATION"
            foreground: root.foreground
          }

          Column {
            width: parent.width
            spacing: Style.space(4)

            Text {
              text: "Daemon API URL:"
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              color: root.foreground
            }

            TextField {
              Component.onCompleted: if (background) background.radius = 0
              id: urlInput
              width: parent.width
              text: root.inputUrl
              placeholderText: "http://127.0.0.1:9999"
              onTextChanged: root.inputUrl = text
            }
          }

          Column {
            width: parent.width
            spacing: Style.space(4)

            Text {
              text: "API Secret / Password:"
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              color: root.foreground
            }

            RowLayout {
              width: parent.width
              spacing: Style.space(6)

              TextField {
                Component.onCompleted: if (background) background.radius = 0
                id: passInput
                text: root.inputPassword
                password: !root.showPassword
                placeholderText: "Enter sing-box API secret"
                Layout.fillWidth: true
                onTextChanged: root.inputPassword = text
              }

              Button {
                radius: 0
                iconText: root.showPassword ? "󰈉" : "󰈈"
                tooltipText: root.showPassword ? "Hide password" : "Show password"
                onClicked: root.showPassword = !root.showPassword
              }
            }
          }

          RowLayout {
            width: parent.width
            spacing: Style.space(8)

            Button {
              radius: 0
              text: "Save & Connect"
              iconText: "󰆓"
              selected: true
              bordered: true
              Layout.fillWidth: true
              onClicked: root.saveConfig(root.inputUrl, root.inputPassword)
            }
          }

          Text {
            visible: Boolean(root.actionMessage)
            text: root.actionMessage
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            color: root.actionIsError ? root.urgent : root.accent
            horizontalAlignment: Text.AlignHCenter
            width: parent.width
          }

          PanelSeparator {
            width: parent.width
            foreground: root.foreground
          }

          PanelSectionHeader {
            text: "BAR DISPLAY"
            foreground: root.foreground
          }

          Toggle {
            radius: 0
            width: parent.width
            label: "Display Traffic in Bar"
            description: "Show real-time upload and download speeds on the top bar"
            foreground: root.foreground
            accent: root.accent
            fontFamily: root.fontFamily
            checked: root.parentWidget ? root.parentWidget.showTraffic : root.showTrafficSetting
            onClicked: {
              var current = root.parentWidget ? root.parentWidget.showTraffic : root.showTrafficSetting
              root.setTrafficDisplay(!current)
            }
          }

          PanelSeparator {
            width: parent.width
            foreground: root.foreground
          }

          // Service info banner
          BorderSurface {
            width: parent.width
            color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.05)
            radius: 0
            leftPadding: Style.space(10)
            rightPadding: Style.space(10)
            topPadding: Style.space(8)
            bottomPadding: Style.space(8)

            ColumnLayout {
              anchors.fill: parent
              spacing: Style.space(2)

              Text {
                text: "sing-box 1.14 Integration"
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                color: root.foreground
              }

              Text {
                text: "Streams from the sing-box daemon gRPC API (services type \"api\", port 9999). Saved credentials persist to ~/.config/sbdbar/config.json."
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption * 0.9
                color: root.dim
                wrapMode: Text.WordWrap
                Layout.fillWidth: true
              }
            }
          }
        }
      }
    }
  }
}
