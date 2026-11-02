import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

BarWidget {
  id: root
  moduleName: "sbdbar"

  readonly property string configuredUrl: String(setting("url", ""))
  readonly property string configuredPassword: String(setting("password", ""))
  readonly property int configuredInterval: Math.max(1, Number(setting("refreshIntervalSec", 2)))

  property string effectiveUrl: configuredUrl
  property string effectivePassword: configuredPassword

  property bool online: false
  property string errorText: ""
  property int httpStatus: 0
  property string apiType: "daemon-grpc"
  property string version: ""
  property string activeNode: ""
  property string currentMode: "Rule"
  property var modeList: ["Rule", "Direct", "Global"]
  property real uploadRate: 0
  property real downloadRate: 0
  property real uploadTotal: 0
  property real downloadTotal: 0
  property int connCount: 0
  property real memory: 0
  property int goroutines: 0
  property string uptime: ""
  property int connectionsIn: 0
  property int connectionsOut: 0
  property var uplinkHistory: []
  property var downlinkHistory: []
  property var groupsData: []
  property bool busy: false

  readonly property var configuredShowTraffic: setting("showTraffic", null)
  property bool showTraffic: configuredShowTraffic !== null ? Boolean(configuredShowTraffic) : true
  // UI preferences saved in the plugin config through set-pref
  property string groupsView: "card"
  property string ipProvider: "ip.sb"
  property string stunServer: "stun.miwifi.com:3478"

  // Public IP over HTTP (proxy egress) and the latest STUN result
  property var publicIp: ({})
  property bool publicIpBusy: false
  property double publicIpFetchedAt: 0
  property var stunResult: ({})
  property bool stunBusy: false

  // sbdbar-agent is the only backend: it streams from the sing-box daemon
  // gRPC API and handles actions and config (see docs/grpc-agent.md).
  readonly property string agentPath: Qt.resolvedUrl("bin/sbdbar-agent").toString().replace(/^file:\/\//, "")
  property bool agentAvailable: false

  function procEnv() {
    return {
      "BOX_API_URL": root.effectiveUrl || "",
      "BOX_API_SECRET": root.effectivePassword || ""
    }
  }

  function setShowTraffic(enabled) {
    root.showTraffic = enabled
    persistTrafficProc.command = [root.agentPath, "set-traffic", enabled ? "true" : "false"]
    persistTrafficProc.running = false
    persistTrafficProc.running = true
  }

  Process {
    id: persistTrafficProc
  }

  function setGroupsView(view) {
    if (view !== "card" && view !== "list") return
    root.setPref("groupsView", view)
  }

  function setPref(key, value) {
    if (["groupsView", "ipProvider", "stunServer"].indexOf(key) === -1) return
    root[key] = value
    persistPrefProc.command = [root.agentPath, "set-pref", key, value]
    persistPrefProc.running = false
    persistPrefProc.running = true
    if (key === "ipProvider") root.fetchPublicIp()
  }

  Process {
    id: persistPrefProc
  }

  function fetchPublicIp() {
    if (!root.agentAvailable) return
    root.publicIpBusy = true
    ipProc.running = false
    ipProc.command = [root.agentPath, "ip", "--provider", root.ipProvider]
    ipProc.running = true
  }

  Process {
    id: ipProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.publicIpBusy = false
        root.publicIpFetchedAt = Date.now()
        try {
          root.publicIp = JSON.parse(String(text || "").trim())
        } catch (e) {
          root.publicIp = { "success": false, "error": "Invalid response" }
        }
      }
    }
  }

  function runStun() {
    if (!root.agentAvailable || root.stunBusy) return
    root.stunBusy = true
    root.stunResult = {}
    stunProc.environment = root.procEnv()
    stunProc.command = [root.agentPath, "stun", "--server", root.stunServer, "--outbound", "direct"]
    stunProc.running = true
  }

  Process {
    id: stunProc
    stdout: SplitParser {
      onRead: function(line) {
        try {
          root.stunResult = JSON.parse(line)
        } catch (e) {}
      }
    }
    onExited: root.stunBusy = false
  }

  // Auto-refresh Real IP: run once when no result yet, then every 5 minutes
  Timer {
    id: stunAutoTimer
    interval: 300000
    repeat: true
    running: root.agentAvailable
    triggeredOnStart: false
    onTriggered: root.runStun()
  }

  // The egress IP changes when the selected node or mode does; refetch once it settles
  onActiveNodeChanged: if (root.publicIpFetchedAt > 0) ipRefetchDebounce.restart()
  onCurrentModeChanged: if (root.publicIpFetchedAt > 0) ipRefetchDebounce.restart()

  Timer {
    id: ipRefetchDebounce
    interval: 2500
    onTriggered: root.fetchPublicIp()
  }

  Process {
    id: agentProbeProc
    command: ["test", "-x", root.agentPath]
    onExited: function(exitCode) {
      root.agentAvailable = exitCode === 0
      if (root.agentAvailable) {
        initConfigProc.running = true
      } else {
        root.online = false
        root.errorText = "sbdbar-agent not found; build it with scripts/build_agent.sh"
      }
    }
  }

  Process {
    id: initConfigProc
    command: [root.agentPath, "get-config"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var raw = String(text || "").trim()
        try {
          var cfg = JSON.parse(raw)
          if (cfg.url && !root.configuredUrl) root.effectiveUrl = cfg.url
          if (cfg.password && !root.configuredPassword) root.effectivePassword = cfg.password
          if (cfg.showTraffic !== undefined && root.configuredShowTraffic === null) {
            root.showTraffic = Boolean(cfg.showTraffic)
          }
          if (cfg.groupsView === "card" || cfg.groupsView === "list") root.groupsView = cfg.groupsView
          if (cfg.ipProvider) root.ipProvider = cfg.ipProvider
          if (cfg.stunServer) root.stunServer = cfg.stunServer
        } catch (e) {}
        root.restartAgent()
        if (Object.keys(root.stunResult).length === 0) root.runStun()
      }
    }
  }

  Component.onCompleted: {
    agentProbeProc.running = true
  }

  readonly property color foreground: bar ? bar.barForeground : Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.5)
  readonly property color statusColor: online ? Color.accent : (bar ? bar.urgent : Color.urgent)

  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function open() {
    if (panelLoader.item) panelLoader.item.open()
  }

  function close() {
    if (panelLoader.item) panelLoader.item.close()
  }

  function openTab(tab) {
    var item = panelLoader.item
    if (!item || ["overview", "groups", "connections", "logs", "settings"].indexOf(tab) === -1) return
    if (!item.opened) item.open()
    item.currentTab = tab
  }

  function togglePanel() {
    if (panelLoader.item) panelLoader.item.toggle()
  }

  function toggle() {
    togglePanel()
  }

  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  function injectPanel() {
    var item = panelLoader.item
    if (!item) return
    if ("bar" in item) item.bar = root.bar
    if ("settings" in item) item.settings = root.settings
    if ("anchorItem" in item) item.anchorItem = button
    if ("hostWidget" in item) item.hostWidget = root
    if ("parentWidget" in item) item.parentWidget = root
  }

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  function applyStats(res) {
    root.uploadRate = Number(res.uploadRate) || 0
    root.downloadRate = Number(res.downloadRate) || 0
    root.uploadTotal = Number(res.uploadTotal) || 0
    root.downloadTotal = Number(res.downloadTotal) || 0
    root.connCount = Number(res.connectionsCount) || 0
    root.connectionsIn = Number(res.connectionsIn) || 0
    root.connectionsOut = Number(res.connectionsOut) || 0
    root.memory = Number(res.memory) || 0
    root.goroutines = Number(res.goroutines) || 0
    root.uptime = String(res.uptime || "")

    var upHist = root.uplinkHistory.slice()
    upHist.push(root.uploadRate)
    if (upHist.length > 30) upHist.shift()
    root.uplinkHistory = upHist

    var downHist = root.downlinkHistory.slice()
    downHist.push(root.downloadRate)
    if (downHist.length > 30) downHist.shift()
    root.downlinkHistory = downHist
  }

  function restartAgent() {
    if (!root.agentAvailable) return
    agentProc.running = false
    agentProc.environment = root.procEnv()
    agentProc.command = [root.agentPath, "watch", "--interval", root.configuredInterval + "s"]
    agentProc.running = true
  }

  // The streams update on their own; a manual refresh reconnects.
  function refreshNow() {
    root.restartAgent()
  }

  onEffectiveUrlChanged: agentRestartDebounce.restart()
  onEffectivePasswordChanged: agentRestartDebounce.restart()
  onConfiguredIntervalChanged: agentRestartDebounce.restart()

  Timer {
    id: agentRestartDebounce
    interval: 300
    onTriggered: root.restartAgent()
  }

  Process {
    id: agentProc
    stdout: SplitParser {
      onRead: function(line) {
        var msg
        try {
          msg = JSON.parse(line)
        } catch (e) {
          return
        }
        if (msg.type === "hello") {
          root.version = String(msg.version || "")
        } else if (msg.type === "status") {
          root.online = true
          root.httpStatus = 200
          root.errorText = ""
          root.applyStats(msg)
        } else if (msg.type === "groups") {
          root.groupsData = msg.groups || []
          root.activeNode = String(msg.activeNode || "")
        } else if (msg.type === "mode") {
          root.currentMode = Model.normalizeMode(msg.mode)
          if (msg.modeList && msg.modeList.length > 0) root.modeList = msg.modeList
        } else if (msg.type === "offline") {
          root.online = false
          root.httpStatus = Number(msg.status) || 0
          root.errorText = String(msg.error || "")
        }
      }
    }
    onExited: function(exitCode) {
      // Exit code 2 is a config error (e.g. cleartext to a remote host); wait for a config change
      if (root.agentAvailable && exitCode !== 2) agentRespawnTimer.restart()
    }
  }

  Timer {
    id: agentRespawnTimer
    interval: 5000
    onTriggered: if (!agentProc.running) root.restartAgent()
  }

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  readonly property string trafficLabel: {
    if (root.vertical || !root.showTraffic) {
      if (root.httpStatus === 401) return "Auth Required"
      return ""
    }
    if (root.online) {
      return "↑ " + Model.formatRate(root.uploadRate) + "  ↓ " + Model.formatRate(root.downloadRate)
    }
    if (root.httpStatus === 401) {
      return "Auth Required"
    }
    return "sing-box"
  }

  readonly property real openPanelIndicatorWidth: Math.max(Style.space(16), contentRow.implicitWidth)
  readonly property real openPanelIndicatorHeight: Math.max(Style.space(10), Math.round(Style.bar.iconSlot * 0.55))

  implicitWidth: root.vertical ? root.barSize : Math.max(root.barSize, contentRow.implicitWidth + Style.space(17))
  implicitHeight: root.barSize

  IpcHandler {
    target: "sbdbar"

    function refresh() { root.refreshNow() }
    function open() { root.open() }
    function close() { root.close() }
    function show() { root.open() }
    function hide() { root.close() }
    function toggle() { root.togglePanel() }
    function toggleTraffic() { root.setShowTraffic(!root.showTraffic) }
    // Open the panel on a tab: overview, groups, connections, logs or settings
    function openTab(tab: string): void { root.openTab(tab) }
    function setGroupsView(view: string): void { root.setGroupsView(view) }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: " "
    labelVisible: false
    fixedWidth: root.implicitWidth
    fixedHeight: root.implicitHeight
    active: root.opened
    useActiveColor: false
    activeColor: root.foreground
    Component.onCompleted: root.injectPanel()
    tooltipText: root.online
      ? ("sing-box [" + root.currentMode + "]\n" +
         (root.activeNode ? "Node: " + root.activeNode + "\n" : "") +
         "↑ " + Model.formatRate(root.uploadRate) + "  ↓ " + Model.formatRate(root.downloadRate) + "\n" +
         "Click to open sing-box panel")
      : (root.httpStatus === 401
          ? "sing-box: 401 Unauthorized\nClick to configure API password"
          : "sing-box: Offline\nClick to check connection")
    onPressed: function(b) {
      if (b === Qt.RightButton) root.refreshNow()
      else root.togglePanel()
    }

    Row {
      id: contentRow
      anchors.centerIn: parent
      spacing: Style.space(6)

      SingBoxIcon {
        id: boxIcon
        width: Style.space(16)
        height: Style.space(16)
        iconSize: Style.space(16)
        color: root.foreground
        anchors.verticalCenter: parent.verticalCenter
      }

      Text {
        id: labelText
        visible: root.trafficLabel !== ""
        text: root.trafficLabel
        font.family: button.fontFamily
        font.pixelSize: button.fontSize
        color: root.foreground
        anchors.verticalCenter: parent.verticalCenter
        renderType: Text.NativeRendering
      }
    }
  }
}
