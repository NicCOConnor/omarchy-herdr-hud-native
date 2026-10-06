import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui as Ui
import "Roster.js" as Roster
import "Alerts.js" as Alerts
import "."

Item {
  id: root

  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property var shell: null
  property var manifest: null
  property bool monitorEnabled: true
  readonly property alias terminalView: terminalPane

  readonly property string pluginId: (manifest && manifest.id) || "indie.herdr-hud"
  readonly property string pluginDir: (manifest && manifest.__sourceDir) || ""
  readonly property string bridgePath: decodeURIComponent(String(Qt.resolvedUrl("bin/herdr-monitor")).replace(/^file:\/\//, ""))
  readonly property string homeDir: Quickshell.env("HOME")
  readonly property string configDir: homeDir + "/.config/herdr-hud-native"
  readonly property string statePath: configDir + "/state.json"

  property bool opened: false
  onOpenedChanged: if (opened) clearAlerts()
  property bool overlayVisible: true
  property bool openingRequested: false
  property bool demoMode: false
  property bool focusPrimed: false
  property string panelScreenName: ""
  property var agents: []
  property string selectedPane: ""
  property var unread: ({})
  readonly property var sortedAgents: Roster.sorted(agents, unread)
  property var lastSequence: ({})
  property var alertQueue: []
  property bool alertsEnabled: true
  onAlertsEnabledChanged: if (!alertsEnabled) clearAlerts()
  property var activeAlert: null
  readonly property bool activeAlertNeedsInput: !!activeAlert && activeAlert.agent_status === "blocked"
  property string alertPreview: ""
  property bool alertHovered: false
  property bool alertBaseline: false
  property var workingSince: ({})
  property double activityNow: Date.now()
  readonly property bool selectedWorking: connected
    && String(agentForPane(selectedPane)?.agent_status || "") === "working"
  property int dataRevision: 0
  property bool connected: false
  property string errorText: "Connecting to Herdr…"
  property string noticeText: ""
  property int rosterWidth: 196
  property int panelWidth: 800
  property int panelHeight: 590
  readonly property int minPanelWidth: 560
  readonly property int minPanelHeight: 380
  property var positions: ({})
  property int stateRevision: 0
  property bool stateReady: false

  property string uiMode: "omarchy"
  readonly property bool wowMode: uiMode === "wow"
  readonly property int cornerRadius: wowMode ? 4 : 0
  readonly property string chromeFont: wowMode ? "Georgia" : Style.font.family

  function toggleUiMode() {
    uiMode = wowMode ? "omarchy" : "wow"
    saveState()
  }

  function toggleAlerts() {
    alertsEnabled = !alertsEnabled
    saveState()
  }

  // Bind to shell roles so theme changes update existing surfaces and HTML.
  readonly property color foreground: wowMode ? "#e8dfca" : Color.popups.text
  readonly property color background: wowMode ? "#17110c" : Color.popups.background
  readonly property color accent: wowMode ? "#d5ad55" : Color.accent
  readonly property color urgent: wowMode ? "#db6555" : Color.urgent
  readonly property color success: wowMode ? "#66bd69" : accent
  readonly property color working: wowMode ? "#d5ad55" : accent
  // Herdr's semantic agent states, so the roster marks read like Herdr's own
  // status glyphs instead of collapsing blocked/done/idle into one color.
  readonly property color statusBlocked: wowMode ? "#db6555" : "#c9543f"
  readonly property color statusWorking: wowMode ? "#d5ad55" : "#c29327"
  readonly property color statusDone: wowMode ? "#5fb3a1" : "#3f9e8c"
  readonly property color statusIdle: wowMode ? "#66bd69" : "#5aa05e"
  readonly property color muted: Qt.tint(alpha(background, 1), alpha(foreground, 0.62))
  readonly property color panelFill: background
  readonly property var panelBorderSpec: wowMode ? Border.flat("#80613a", 2) : Border.surfaceSpec("popups", "border", accent, 2)
  readonly property color panelBorder: Border.color(panelBorderSpec)
  // A subtle foreground tint works on both light and dark popup backgrounds.
  readonly property color terminalFill: wowMode ? "#100d09" : Qt.tint(background, alpha(foreground, 0.035))
  readonly property color accentText: contrastColor(accent, foreground, background)

  function contrastColor(fill, light, dark) {
    function linear(v) { return v <= 0.04045 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4) }
    function luminance(c) { return 0.2126 * linear(c.r) + 0.7152 * linear(c.g) + 0.0722 * linear(c.b) }
    function contrast(c) {
      var a = luminance(fill), b = luminance(c)
      return (Math.max(a, b) + 0.05) / (Math.min(a, b) + 0.05)
    }
    return contrast(light) >= contrast(dark) ? light : dark
  }
  readonly property int edgeGap: 16
  property int launcherStyle: 0
  readonly property color launcherAccent: launcherStyle === 5 ? "#d5ad55" : Color.accent
  readonly property color launcherBackground: launcherStyle === 5 ? "#17110c" : Color.popups.background
  readonly property color launcherText: contrastColor(launcherAccent, launcherStyle === 5 ? "#e8dfca" : Color.popups.text, launcherBackground)
  readonly property color launcherSuccess: launcherStyle === 5 ? "#66bd69" : launcherAccent
  readonly property int bubbleWidth: launcherStyle === 4 ? 96 : (launcherStyle === 2 || launcherStyle === 3 ? 32 : 54)
  readonly property int bubbleHeight: launcherStyle === 4 ? 28 : (launcherStyle === 2 || launcherStyle === 3 ? 32 : 54)
  readonly property real bubbleRadius: launcherStyle === 0 || launcherStyle === 2 ? bubbleWidth / 2 : 0

  function cycleLauncherStyle() {
    launcherStyle = (launcherStyle + 1) % 6
    stateRevision++
    // Re-clamp after size changes, including launchers that were dragged.
    for (var i = 0; i < screenViews.instances.length; i++) {
      var view = screenViews.instances[i]
      var position = positionFor(view.screenName, view.width, view.height)
      view.bubbleX = position.x
      view.bubbleY = position.y
    }
    saveState()
  }

  function alpha(color, value) {
    return Qt.rgba(color.r, color.g, color.b, value)
  }

  function cloneObject(source) {
    var target = ({})
    for (var key in source) target[key] = source[key]
    return target
  }

  function screenByName(name) {
    var screens = Quickshell.screens || []
    for (var i = 0; i < screens.length; i++)
      if (screens[i].name === name) return screens[i]
    return screens.length > 0 ? screens[0] : null
  }

  function defaultScreenName() {
    var screen = screenByName(panelScreenName)
    return screen ? screen.name : ""
  }

  function positionFor(name, width, height) {
    stateRevision
    var saved = positions[name] || {}
    return {
      x: clamp(Number(saved.x === undefined ? width - bubbleWidth - edgeGap : saved.x),
               edgeGap, Math.max(edgeGap, width - bubbleWidth - edgeGap)),
      y: clamp(Number(saved.y === undefined ? 150 : saved.y),
               edgeGap, Math.max(edgeGap, height - bubbleHeight - edgeGap))
    }
  }

  function clamp(value, lower, upper) {
    return Math.max(lower, Math.min(upper, value))
  }

  function savePosition(name, x, y) {
    var next = cloneObject(positions)
    next[name] = { x: Math.round(x), y: Math.round(y) }
    positions = next
    stateRevision++
    saveState()
  }

  function loadState(raw) {
    try {
      var parsed = JSON.parse(String(raw || ""))
      if (parsed && typeof parsed === "object") {
        if (Number.isInteger(parsed.launcherStyle) && parsed.launcherStyle >= 0 && parsed.launcherStyle < 6) launcherStyle = parsed.launcherStyle
        if (parsed.uiMode === "wow" || parsed.uiMode === "omarchy") uiMode = parsed.uiMode
        if (typeof parsed.alertsEnabled === "boolean") alertsEnabled = parsed.alertsEnabled
        if (typeof parsed.overlayVisible === "boolean") overlayVisible = parsed.overlayVisible
        if (parsed.positions && typeof parsed.positions === "object") positions = parsed.positions
        if (Number(parsed.rosterWidth) > 0) rosterWidth = clamp(Number(parsed.rosterWidth), 150, 330)
        if (Number(parsed.panelWidth) > 0) panelWidth = Math.max(minPanelWidth, Number(parsed.panelWidth))
        if (Number(parsed.panelHeight) > 0) panelHeight = Math.max(minPanelHeight, Number(parsed.panelHeight))
      }
    } catch (error) {
      positions = ({})
    }
    stateReady = true
    stateRevision++
  }

  function saveState() {
    if (!stateReady) return
    stateFile.setText(JSON.stringify({
      version: 1,
      uiMode: uiMode,
      alertsEnabled: alertsEnabled,
      launcherStyle: launcherStyle,
      overlayVisible: overlayVisible,
      positions: positions,
      rosterWidth: Math.round(rosterWidth),
      panelWidth: Math.round(panelWidth),
      panelHeight: Math.round(panelHeight)
    }, null, 2) + "\n")
  }

  function open(payloadJson) {
    overlayVisible = true
    saveState()
    noticeText = ""
    var payload = ({})
    try { payload = JSON.parse(String(payloadJson || "{}")) } catch (error) { payload = ({}) }
    demoMode = payload.demo === true
    if (demoMode) applyDemoData()
    if (focusedScreenProc.running) focusedScreenProc.running = false
    openingRequested = true
    focusedScreenProc.exec(["python3", bridgePath, "focused-screen"])
  }

  function toggleVisibility(_arg) {
    if (overlayVisible) {
      requestClose()
      close()
      overlayVisible = false
      clearAlerts()
      alertBaseline = false
      workingSince = ({})
    } else {
      overlayVisible = true
      refreshRoster()
    }
    saveState()
  }

  function applyDemoData() {
    agents = [
      {
        agent: "hermes", agent_status: "idle", pane_id: "demo:p1",
        terminal_id: "demo-1", workspace_id: "demo-1", workspace_label: "Raid planner"
      },
      {
        agent: "codex", agent_status: "working", pane_id: "demo:p2",
        terminal_id: "demo-2", workspace_id: "demo-2", workspace_label: "Combat AI"
      },
      {
        agent: "codex", agent_status: "idle", pane_id: "demo:p3",
        terminal_id: "demo-3", workspace_id: "demo-3", workspace_label: "Addon UI"
      },
      {
        agent: "hermes", agent_status: "blocked", pane_id: "demo:p4",
        terminal_id: "demo-4", workspace_id: "demo-4", workspace_label: "Quest research"
      }
    ]
    selectedPane = "demo:p1"
    unread = ({ "demo:p1": true })
    connected = true
    errorText = ""
    dataRevision++
  }

  function state(_arg) {
    var activeView = viewForScreen(panelScreenName || defaultScreenName())
    return JSON.stringify({
      opened: opened,
      overlayVisible: overlayVisible,
      panelScreenName: panelScreenName,
      bridgePath: bridgePath,
      uiMode: uiMode,
      launcherStyle: launcherStyle,
      theme: {
        background: String(background),
        foreground: String(foreground),
        accent: String(accent),
        border: String(panelBorder),
        borderGradient: panelBorderSpec.gradient.enabled
      },
      screens: screenViews.instances.length,
      agents: agents.length,
      demoMode: demoMode,
      connected: connected,
      selectedPane: selectedPane,
      selectedWorking: selectedWorking,
      workingElapsed: selectedWorking ? workingElapsed() : "",
      bubbleX: activeView ? Math.round(activeView.bubbleCurrentX) : null,
      bubbleY: activeView ? Math.round(activeView.bubbleCurrentY) : null,
      view: "terminal",
      alertsEnabled: alertsEnabled,
      alertVisible: alertsEnabled && !!activeAlert && overlayVisible && !opened,
      alertPane: activeAlert ? activeAlert.pane_id : "",
      rosterOrder: sortedAgents.map(function(agent) { return String(agent.pane_id || "") }),
      notice: noticeText,
      error: errorText
    })
  }

  function openOnScreen(name) {
    overlayVisible = true
    panelScreenName = name || defaultScreenName()
    opened = true
    var nextUnread = cloneObject(unread)
    delete nextUnread[selectedPane]
    unread = nextUnread
    dataRevision++
    focusPrimed = false
    focusPrimeTimer.restart()
    refreshRoster()
    Qt.callLater(function() {
      var view = viewForScreen(panelScreenName)
      if (view) view.focusTerminal()
    })
  }

  function close() {
    openingRequested = false
    opened = false
    focusPrimed = false
    if (demoMode) {
      demoMode = false
      Qt.callLater(root.refreshRoster)
    }
  }

  function requestClose() {
    if (shell && typeof shell.hide === "function") shell.hide(pluginId)
    else close()
  }

  function toggleOnScreen(name) {
    if (opened && panelScreenName === name) requestClose()
    else openOnScreen(name)
  }

  function viewForScreen(name) {
    for (var i = 0; i < screenViews.instances.length; i++) {
      var item = screenViews.instances[i]
      if (item && item.screenName === name) return item
    }
    return screenViews.instances.length ? screenViews.instances[0] : null
  }

  function agentForPane(pane) {
    for (var i = 0; i < agents.length; i++)
      if (String(agents[i].pane_id || "") === pane) return agents[i]
    return null
  }

  function selectAgent(pane) {
    if (demoMode) return
    selectedPane = pane
    var nextUnread = cloneObject(unread)
    delete nextUnread[pane]
    unread = nextUnread
    dataRevision++
    noticeText = ""
    Qt.callLater(function() {
      var activeView = viewForScreen(panelScreenName)
      if (activeView) activeView.focusTerminal()
    })
  }

  function isReady(agent) {
    var status = String(agent ? agent.agent_status || "" : "")
    return status === "idle" || status === "done"
  }

  function statusLabel(agent) {
    var status = String(agent ? agent.agent_status || "" : "")
    if (status === "blocked") return "Needs your input"
    if (status === "idle" || status === "done") return "Ready for prompt"
    if (status === "working") return "Working"
    return "Status unknown"
  }

  // Herdr serializes state_change_seq as 0 when a terminal has no recorded state
  // change yet. Treat 0/absent as "no sequence" instead of falling back to the
  // churning revision counter, which would keep re-flagging unread forever.
  function stateSequence(row) {
    var value = Number(row ? row.state_change_seq : NaN)
    return isFinite(value) && value > 0 ? value : null
  }

  function isUnreadTransition(previous, row, previousSequence, sequence) {
    if (!previous || previous.terminal_id !== row.terminal_id) return false
    var status = String(row.agent_status || "")
    var previousStatus = String(previous.agent_status || "")
    if (previousStatus === "working" && status !== "working") return true
    if (status === "blocked" && previousStatus !== "blocked") return true
    if (status === previousStatus) return false
    if (sequence === null || previousSequence === undefined || sequence <= previousSequence) return false
    // Ignore Herdr's idle/done seen-state bookkeeping so reading an agent
    // elsewhere does not resurrect the unread badge.
    if ((status === "idle" || status === "done") && (previousStatus === "idle" || previousStatus === "done")) return false
    return true
  }

  function workingElapsed() {
    var agent = agentForPane(selectedPane)
    var started = agent ? workingSince[String(agent.terminal_id || agent.pane_id)] : undefined
    var seconds = Math.max(0, Math.floor((activityNow - (started || activityNow)) / 1000))
    return (seconds < 60 ? seconds + "s" : Math.floor(seconds / 60) + "m " + seconds % 60 + "s") + "+"
  }

  function statusKey(agent) {
    if (!agent) return "unknown"
    var status = String(agent.agent_status || "")
    if (status === "blocked") return "blocked"
    if (status === "working") return "working"
    if (isReady(agent)) return unread[String(agent.pane_id || "")] ? "done" : "idle"
    return "unknown"
  }

  // Mirrors Herdr's distinct "symbols" indicator style (src/ui/status.rs):
  // blocked ×, working ◐, done ✓, idle ○, unknown ·.
  function statusSymbol(agent) {
    var key = statusKey(agent)
    if (key === "blocked") return "\u00d7"
    if (key === "working") return "\u25d0"
    if (key === "done") return "\u2713"
    if (key === "idle") return "\u25cb"
    return "\u00b7"
  }

  function statusColor(agent) {
    var key = statusKey(agent)
    if (key === "blocked") return statusBlocked
    if (key === "working") return statusWorking
    if (key === "done") return statusDone
    if (key === "idle") return statusIdle
    return muted
  }

  function agentName(agent) {
    if (!agent) return "Agent"
    var type = String(agent.agent || "agent")
    return type.charAt(0).toUpperCase() + type.slice(1)
  }

  function attentionCount() {
    dataRevision
    var count = 0
    for (var i = 0; i < agents.length; i++) {
      var agent = agents[i]
      var pane = String(agent.pane_id || "")
      if (String(agent.agent_status || "") === "blocked" || unread[pane]) count++
    }
    return count
  }

  function refreshRoster() {
    if (!monitorEnabled || !overlayVisible || demoMode || rosterProc.running || bridgePath === "") return
    rosterProc.exec(["python3", bridgePath, "roster"])
  }

  function clearAlerts() {
    alertQueue = []
    activeAlert = null
    alertHovered = false
  }

  function queueAlert(agent) {
    if (!alertsEnabled || opened || !overlayVisible) return
    var next = alertQueue.slice()
    next.push(agent)
    alertQueue = next.slice(-5)
    if (!activeAlert) showNextAlert()
  }

  function showNextAlert() {
    activeAlert = null
    if (!alertsEnabled || !alertQueue.length || opened || !overlayVisible) return
    var next = alertQueue.slice()
    var agent = next.shift()
    alertQueue = next
    var live = agentForPane(String(agent.pane_id))
    if (!live || live.terminal_id !== agent.terminal_id || live.agent_status !== agent.agent_status) {
      showNextAlert()
      return
    }
    activeAlert = agent
    alertHovered = false
    completionTimer.restart()
    if (activeAlertNeedsInput) completionTimer.stop()
    alertPreview = agent.agent_status === "blocked" ? "Open the agent to see what needs your input."
      : "Open the agent to read its latest reply."
    if (!alertPreviewProc.running && agent.agent_status !== "blocked") {
      previewIdentity = String(agent.terminal_id)
      alertPreviewProc.exec(["python3", bridgePath, "preview", String(agent.pane_id), previewIdentity])
    }

  }

  function openAlert(screenName) {
    var agent = activeAlert
    if (!agent) return
    var live = agentForPane(String(agent.pane_id))
    if (!live || live.terminal_id !== agent.terminal_id) { showNextAlert(); return }
    clearAlerts()
    selectAgent(String(agent.pane_id))
    openOnScreen(screenName)
  }

  function previewAlert(_arg) {
    var agent = agents.find(function(row) { return row.agent_status === "idle" || row.agent_status === "done" })
    if (!agent) return
    requestClose()
    Qt.callLater(function() { root.queueAlert(agent) })
  }

  function applyRoster(raw, error, exitCode) {
    if (demoMode) return
    if (exitCode !== 0) {
      alertBaseline = false
      clearAlerts()
      connected = false
      workingSince = ({})
      errorText = String(error || "Herdr is unavailable").trim()
      return
    }
    try {
      var parsed = JSON.parse(String(raw || "{}"))
      var rows = Array.isArray(parsed.agents) ? parsed.agents : []
      var completed = alertBaseline ? Alerts.events(agents, rows) : []
      alertBaseline = true
      var nextUnread = cloneObject(unread)
      var nextSequence = ({})
      var nextWorkingSince = ({})
      var live = ({})
      var previousByPane = ({})
      for (var p = 0; p < agents.length; p++) previousByPane[String(agents[p].pane_id || "")] = agents[p]
      for (var i = 0; i < rows.length; i++) {
        var row = rows[i]
        var pane = String(row.pane_id || "")
        var status = String(row.agent_status || "")
        var sequence = stateSequence(row)
        var previousSequence = lastSequence[pane]
        if (status === "working") {
          var identity = String(row.terminal_id || pane)
          nextWorkingSince[identity] = workingSince[identity] || Date.now()
        }
        live[pane] = true
        nextSequence[pane] = sequence === null ? (previousSequence === undefined ? 0 : previousSequence) : sequence
        if (status === "working" || (opened && pane === selectedPane)) delete nextUnread[pane]
        else if (isUnreadTransition(previousByPane[pane], row, previousSequence, sequence)) nextUnread[pane] = true
      }
      for (var unreadPane in nextUnread) if (!live[unreadPane]) delete nextUnread[unreadPane]
      var previousAgent = agentForPane(selectedPane)
      agents = rows
      workingSince = nextWorkingSince
      activityNow = Date.now()
      var currentAgent = agentForPane(selectedPane)
      if (previousAgent && currentAgent && previousAgent.terminal_id !== currentAgent.terminal_id)
        noticeText = "The agent in this pane changed."
      unread = nextUnread
      lastSequence = nextSequence
      connected = true
      if (activeAlert) {
        var alertAgent = agentForPane(String(activeAlert.pane_id))
        if (!alertAgent || alertAgent.terminal_id !== activeAlert.terminal_id || alertAgent.agent_status !== activeAlert.agent_status) showNextAlert()
      }
      completed.forEach(function(agent) { root.queueAlert(agent) })
      errorText = ""
      if (!agentForPane(selectedPane)) selectAgent(rows.length ? String(rows[0].pane_id || "") : "")
      dataRevision++
    } catch (parseError) {
      alertBaseline = false
      clearAlerts()
      connected = false
      workingSince = ({})
      errorText = "Herdr returned an unreadable response."
    }
  }

  Component.onCompleted: {
    mkdirProc.running = true
    Qt.callLater(root.refreshRoster)
  }

  TerminalPane {
    id: terminalPane
    parent: root.viewForScreen(root.panelScreenName)
      ? root.viewForScreen(root.panelScreenName).terminalContainer : root
    anchors.fill: parent
    visible: root.opened && root.overlayVisible
    target: root.opened && root.overlayVisible && !root.demoMode
      ? String(root.agentForPane(root.selectedPane)?.terminal_id || "") : ""
    foreground: root.foreground
    muted: root.muted
    accent: root.accent
    background: root.terminalFill
    chromeFont: root.chromeFont
    wowMode: root.wowMode
  }

  Process {
    id: mkdirProc
    command: ["mkdir", "-p", root.configDir]
    onExited: function() { stateFile.reload() }
  }

  FileView {
    id: stateFile
    path: root.statePath
    atomicWrites: true
    watchChanges: false
    printErrors: false
    onLoaded: root.loadState(text())
    onLoadFailed: {
      root.loadState("")
    }
  }

  Process {
    id: focusedScreenProc
    stdout: StdioCollector { id: focusedScreenOut; waitForEnd: true }
    stderr: StdioCollector { id: focusedScreenErr; waitForEnd: true }
    onExited: function(exitCode) {
      if (!root.openingRequested) return
      root.openingRequested = false
      var name = ""
      if (exitCode === 0) {
        try { name = String(JSON.parse(focusedScreenOut.text).screen || "") }
        catch (error) { name = "" }
      }
      root.openOnScreen(name || root.defaultScreenName())
    }
  }

  Process {
    id: rosterProc
    stdout: StdioCollector { id: rosterOut; waitForEnd: true }
    stderr: StdioCollector { id: rosterErr; waitForEnd: true }
    onExited: function(exitCode) { root.applyRoster(rosterOut.text, rosterErr.text, exitCode) }
  }

  property string previewIdentity: ""
  Process {
    id: alertPreviewProc
    stdout: StdioCollector { id: alertPreviewOut; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0 || !root.activeAlert || root.activeAlert.agent_status === "blocked"
          || String(root.activeAlert.terminal_id) !== root.previewIdentity) return
      try {
        var preview = String(JSON.parse(alertPreviewOut.text).preview || "")
        if (preview) root.alertPreview = preview
      } catch (error) {}
    }
  }

  Timer {
    id: completionTimer
    interval: 8000
    running: !!root.activeAlert && !root.activeAlertNeedsInput && !root.alertHovered
    onTriggered: root.showNextAlert()
  }

  Timer {
    interval: 1000
    repeat: true
    running: root.opened && root.selectedWorking
    onTriggered: root.activityNow = Date.now()
  }

  Timer {
    interval: 2000
    repeat: true
    running: root.overlayVisible
    onTriggered: root.refreshRoster()
  }

  Timer {
    id: focusPrimeTimer
    interval: 100
    onTriggered: root.focusPrimed = true
  }

  Variants {
    id: screenViews
    model: Quickshell.screens

    PanelWindow {
      id: overlayWindow
      required property var modelData
      readonly property string screenName: modelData.name
      readonly property bool panelVisible: root.overlayVisible && root.opened && root.panelScreenName === screenName
      property bool draggingBubble: false
      property real bubbleX: root.positionFor(screenName, width, height).x
      property real bubbleY: root.positionFor(screenName, width, height).y
      readonly property real bubbleCurrentX: bubble.x
      readonly property real bubbleCurrentY: bubble.y
      readonly property real panelRoomLeft: Math.max(1, bubble.x - root.edgeGap - 12)
      readonly property real panelRoomRight: Math.max(1, width - root.edgeGap - bubble.x - bubble.width - 12)
      readonly property bool panelOnRight: panelRoomRight >= root.panelWidth
        || (panelRoomLeft < root.panelWidth && panelRoomRight >= panelRoomLeft)
      property real rosterDragStart: 0
      property real rosterWidthStart: 0
      property point resizeStart: Qt.point(0, 0)
      property size resizeStartSize: Qt.size(0, 0)

      // The HUD is a layer-shell overlay, so Hyprland's window resizing does
      // not apply; these handles resize it from its outer edge and bottom.
      function beginResize(area, mouse) {
        resizeStart = area.mapToItem(contentItem, mouse.x, mouse.y)
        resizeStartSize = Qt.size(panelCard.width, panelCard.height)
      }

      function updateResize(area, mouse, horizontal, vertical) {
        var point = area.mapToItem(contentItem, mouse.x, mouse.y)
        if (horizontal) {
          var dx = (point.x - resizeStart.x) * (panelOnRight ? 1 : -1)
          root.panelWidth = root.clamp(resizeStartSize.width + dx, root.minPanelWidth,
            Math.max(root.minPanelWidth, panelOnRight ? panelRoomRight : panelRoomLeft))
        }
        if (vertical)
          root.panelHeight = root.clamp(resizeStartSize.height + point.y - resizeStart.y,
            root.minPanelHeight, Math.max(root.minPanelHeight, height - 32))
      }

      function focusTerminal() {
        if (panelVisible) terminalPane.focusTerminal()
      }

      readonly property alias terminalContainer: terminalSlot
      readonly property alias panelSurface: panelCard
      readonly property alias alertSurface: completionAlert

      screen: modelData
      visible: root.overlayVisible
      color: "transparent"
      anchors { top: true; bottom: true; left: true; right: true }
      exclusionMode: ExclusionMode.Ignore
      WlrLayershell.namespace: "herdr-hud"
      WlrLayershell.layer: WlrLayer.Overlay
      WlrLayershell.keyboardFocus: panelVisible
        ? (root.focusPrimed ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.Exclusive)
        : WlrKeyboardFocus.None

      mask: Region {
        Region {
          x: bubble.x
          y: bubble.y
          width: bubble.visible ? bubble.width : 0
          height: bubble.visible ? bubble.height : 0
          radius: root.bubbleRadius
        }
        Region {
          x: panelCard.x
          y: panelCard.y
          width: overlayWindow.panelVisible ? panelCard.width : 0
          height: overlayWindow.panelVisible ? panelCard.height : 0
          radius: root.cornerRadius
        }
        Region {
          x: completionAlert.x
          y: completionAlert.y
          width: completionAlert.visible ? completionAlert.width : 0
          height: completionAlert.visible ? completionAlert.height : 0
          radius: root.cornerRadius
        }
      }

      Rectangle {
        visible: overlayWindow.panelVisible
        x: overlayWindow.panelOnRight ? bubble.x + bubble.width : panelCard.x + panelCard.width
        y: bubble.y + bubble.height / 2 - 1
        width: 12
        height: 2
        color: root.panelBorder
      }

      Ui.BorderSurface {
        id: panelCard
        visible: overlayWindow.panelVisible
        width: Math.min(root.panelWidth, overlayWindow.panelOnRight
          ? overlayWindow.panelRoomRight : overlayWindow.panelRoomLeft)
        height: Math.max(1, Math.min(parent.height - 32, root.panelHeight))
        x: overlayWindow.panelOnRight ? bubble.x + bubble.width + 12 : bubble.x - width - 12
        y: root.clamp(bubble.y + bubble.height / 2 - 41,
          root.edgeGap, Math.max(root.edgeGap, parent.height - height - root.edgeGap))
        color: root.wowMode ? "transparent" : root.panelFill
        radius: root.cornerRadius
        borderSpec: root.wowMode ? Border.none() : root.panelBorderSpec
        clip: true

        WowFrame {
          anchors.fill: parent
          visible: root.wowMode
          fillColor: root.panelFill
        }

        Repeater {
          // Outer edge, bottom edge, and the outer bottom corner.
          model: [
            { horizontal: true, vertical: false },
            { horizontal: false, vertical: true },
            { horizontal: true, vertical: true }
          ]
          MouseArea {
            id: resizeHandle
            required property var modelData
            readonly property bool corner: modelData.horizontal && modelData.vertical
            z: 10
            x: modelData.horizontal ? (overlayWindow.panelOnRight ? parent.width - width : 0) : 18
            y: modelData.vertical ? parent.height - height : 18
            width: corner ? 22 : modelData.horizontal ? 7 : parent.width - 36
            height: corner ? 22 : modelData.vertical ? 7 : parent.height - 36
            hoverEnabled: true
            cursorShape: corner ? (overlayWindow.panelOnRight ? Qt.SizeFDiagCursor : Qt.SizeBDiagCursor)
              : modelData.horizontal ? Qt.SizeHorCursor : Qt.SizeVerCursor
            onPressed: function(mouse) { overlayWindow.beginResize(resizeHandle, mouse) }
            onPositionChanged: function(mouse) {
              if (pressed) overlayWindow.updateResize(resizeHandle, mouse,
                resizeHandle.modelData.horizontal, resizeHandle.modelData.vertical)
            }
            onReleased: root.saveState()

            Canvas {
              id: grip
              // A small grip so the corner handle is discoverable.
              visible: resizeHandle.corner
              anchors.fill: parent
              opacity: resizeHandle.containsMouse || resizeHandle.pressed ? 0.9 : 0.4
              onPaint: {
                var ctx = getContext("2d")
                ctx.reset()
                ctx.strokeStyle = root.accent
                ctx.lineWidth = 1.5
                for (var i = 1; i <= 2; i++) {
                  var o = 6 * i
                  ctx.beginPath()
                  if (overlayWindow.panelOnRight) { ctx.moveTo(width - 5, height - 5 - o); ctx.lineTo(width - 5 - o, height - 5) }
                  else { ctx.moveTo(5, height - 5 - o); ctx.lineTo(5 + o, height - 5) }
                  ctx.stroke()
                }
              }
              Connections {
                target: overlayWindow
                function onPanelOnRightChanged() { grip.requestPaint() }
              }
            }
          }
        }

        ColumnLayout {
          anchors.fill: parent
          anchors.margins: 18
          spacing: 12

          Item {
            Layout.fillWidth: true
            Layout.preferredHeight: 36

            RowLayout {
              anchors.fill: parent
              anchors.margins: 4
              spacing: 12

              Button {
                id: modeButton
                text: root.wowMode ? "UI: WoW" : "UI: Omarchy"
                Layout.preferredWidth: 132
                Layout.fillHeight: true
                hoverEnabled: true
                onClicked: root.toggleUiMode()
                background: Rectangle {
                  radius: root.cornerRadius
                  color: modeButton.down ? root.alpha(root.accent, 0.28)
                    : root.alpha(root.accent, modeButton.hovered ? 0.18 : 0.08)
                  border.width: 1
                  border.color: modeButton.activeFocus || modeButton.hovered ? root.accent : root.alpha(root.accent, 0.5)
                }
                contentItem: Text {
                  text: modeButton.text + "  ⇄"
                  color: root.accent
                  font.family: root.chromeFont
                  font.pixelSize: 12
                  font.bold: true
                  horizontalAlignment: Text.AlignHCenter
                  verticalAlignment: Text.AlignVCenter
                }
              }
              Button {
                id: alertsButton
                text: root.alertsEnabled ? "Alerts: On" : "Alerts: Off"
                Layout.preferredWidth: 112
                Layout.fillHeight: true
                hoverEnabled: true
                checkable: true
                checked: root.alertsEnabled
                onClicked: root.toggleAlerts()
                background: Rectangle {
                  radius: root.cornerRadius
                  color: alertsButton.down ? root.alpha(root.accent, 0.28)
                    : root.alpha(root.accent, alertsButton.hovered ? 0.18 : 0.08)
                  border.width: 1
                  border.color: alertsButton.activeFocus || alertsButton.hovered ? root.accent : root.alpha(root.accent, 0.5)
                }
                contentItem: Text {
                  text: alertsButton.text
                  color: root.accent
                  font.family: root.chromeFont
                  font.pixelSize: 12
                  font.bold: true
                  horizontalAlignment: Text.AlignHCenter
                  verticalAlignment: Text.AlignVCenter
                }
              }
              Item { Layout.fillWidth: true }
              Text {
                visible: root.wowMode
                text: "HERDR · Agent Command"
                color: root.accent
                font.family: root.chromeFont
                font.pixelSize: 13
                font.bold: true
                Layout.fillWidth: false
                Layout.maximumWidth: 160
                elide: Text.ElideRight
              }
              Button {
                id: disconnectTerminalButton
                text: terminalPane.clientRunning ? "Disconnect" : "Reconnect"
                enabled: !!terminalPane.target && !terminalPane.stopping
                focusPolicy: Qt.NoFocus
                Layout.preferredWidth: 104
                Layout.fillHeight: true
                hoverEnabled: true
                onClicked: terminalPane.toggleConnection()
                background: Rectangle {
                  radius: root.cornerRadius
                  color: root.alpha(root.accent, disconnectTerminalButton.hovered ? 0.18 : 0.08)
                  border.width: 1
                  border.color: root.alpha(root.accent, 0.5)
                }
                contentItem: Text {
                  text: disconnectTerminalButton.text
                  color: root.accent
                  font.family: root.chromeFont
                  font.pixelSize: 12
                  horizontalAlignment: Text.AlignHCenter
                  verticalAlignment: Text.AlignVCenter
                }
              }
            }
          }

          Item {
            Layout.fillWidth: true
            Layout.fillHeight: true

            RowLayout {
              anchors.fill: parent
              spacing: 0

              Rectangle {
                Layout.preferredWidth: root.rosterWidth
                Layout.fillHeight: true
                color: root.alpha(root.foreground, 0.035)
                radius: root.cornerRadius
                border.width: 1
                border.color: root.wowMode ? "#614a2f" : root.alpha(root.foreground, 0.12)

                ColumnLayout {
                  anchors.fill: parent
                  anchors.margins: 8
                  spacing: 8

                  Text {
                    Layout.fillWidth: true
                    text: root.demoMode ? "HERDR · PREVIEW" : root.connected
                      ? "HERDR · " + root.agents.length + " AGENTS" : "HERDR · OFFLINE"
                    color: root.muted
                    font.family: root.chromeFont
                    font.pixelSize: 11
                    font.bold: true
                    leftPadding: 5
                  }

                  ListView {
                    id: rosterList
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    clip: true
                    spacing: 7
                    model: root.sortedAgents
                    boundsBehavior: Flickable.StopAtBounds

                    delegate: Rectangle {
                      id: agentRow
                      required property var modelData

                      width: ListView.view.width
                      height: 86
                      radius: root.cornerRadius
                      color: String(modelData.pane_id || "") === root.selectedPane
                        ? root.alpha(root.accent, 0.15)
                        : (agentMouse.containsMouse ? root.alpha(root.foreground, 0.08) : "transparent")
                      border.width: root.wowMode ? 0 : 1
                      border.color: String(modelData.pane_id || "") === root.selectedPane
                        ? root.alpha(root.accent, 0.72)
                        : root.alpha(root.foreground, 0.12)

                      WowFrame {
                        anchors.fill: parent
                        visible: root.wowMode
                        z: 1
                      }

                      MouseArea {
                        id: agentMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        onClicked: root.selectAgent(String(agentRow.modelData.pane_id || ""))
                      }

                      RowLayout {
                        anchors.fill: parent
                        anchors.margins: 10
                        spacing: 9

                        Text {
                          Layout.alignment: Qt.AlignTop
                          Layout.topMargin: 2
                          Layout.preferredWidth: 12
                          horizontalAlignment: Text.AlignHCenter
                          text: root.statusSymbol(agentRow.modelData)
                          color: root.statusColor(agentRow.modelData)
                          font.family: root.chromeFont
                          font.pixelSize: 14
                          font.bold: root.wowMode
                        }

                        ColumnLayout {
                          Layout.fillWidth: true
                          spacing: 3

                          Text {
                            Layout.fillWidth: true
                            text: String(agentRow.modelData.workspace_label || "Untitled space")
                            color: root.accent
                            font.family: root.chromeFont
                            font.pixelSize: 15
                            font.bold: true
                            elide: Text.ElideRight
                          }
                          Text {
                            Layout.fillWidth: true
                            text: root.agentName(agentRow.modelData)
                            color: root.muted
                            font.family: root.chromeFont
                            font.pixelSize: 12
                            elide: Text.ElideRight
                          }
                          Text {
                            Layout.fillWidth: true
                            text: (root.unread[String(agentRow.modelData.pane_id || "")] ? "Unseen update · " : "")
                              + root.statusLabel(agentRow.modelData)
                            color: root.unread[String(agentRow.modelData.pane_id || "")] ? root.success : root.muted
                            font.family: root.chromeFont
                            font.pixelSize: 11
                            elide: Text.ElideRight
                          }
                        }
                      }
                    }

                    ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
                  }
                }
              }

              Item {
                id: rosterDivider
                Layout.preferredWidth: 10
                Layout.fillHeight: true

                MouseArea {
                  id: dividerMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.SplitHCursor
                  onPressed: function(mouse) {
                    overlayWindow.rosterDragStart = mapToItem(overlayWindow.contentItem, mouse.x, mouse.y).x
                    overlayWindow.rosterWidthStart = root.rosterWidth
                  }
                  onPositionChanged: function(mouse) {
                    if (pressed) root.rosterWidth = root.clamp(
                      overlayWindow.rosterWidthStart + mapToItem(overlayWindow.contentItem, mouse.x, mouse.y).x - overlayWindow.rosterDragStart,
                      150, 330)
                  }
                  onReleased: root.saveState()
                }
              }

              ColumnLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                Layout.leftMargin: 4
                spacing: 8

                Rectangle {
                  visible: root.selectedWorking
                  Layout.fillWidth: true
                  Layout.preferredHeight: 42
                  color: root.alpha(root.working, 0.12)
                  border.width: 1
                  border.color: root.alpha(root.working, 0.35)
                  radius: root.cornerRadius
                  RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: 12
                    anchors.rightMargin: 12
                    spacing: 10
                    Row {
                      spacing: 4
                      Repeater {
                        model: 3
                        Rectangle {
                          required property int index
                          width: 5
                          height: 5
                          radius: root.wowMode ? 3 : 0
                          color: root.accent
                          SequentialAnimation on opacity {
                            running: overlayWindow.panelVisible && (root.selectedWorking)
                            loops: Animation.Infinite
                            PauseAnimation { duration: index * 130 }
                            NumberAnimation { from: 0.25; to: 1; duration: 350; easing.type: Easing.InOutSine }
                            NumberAnimation { from: 1; to: 0.25; duration: 350; easing.type: Easing.InOutSine }
                          }
                        }
                      }
                    }
                    Text {
                      Layout.fillWidth: true
                      text: root.agentName(root.agentForPane(root.selectedPane)) + " is working…"
                      color: root.accent
                      font.family: root.chromeFont
                      font.pixelSize: 13
                      font.bold: true
                      elide: Text.ElideRight
                    }
                    Text {
                      visible: root.selectedWorking
                      text: root.workingElapsed()
                      color: root.muted
                      font.family: root.chromeFont
                      font.pixelSize: 11
                    }
                  }
                }

                Rectangle {
                  Layout.fillWidth: true
                  Layout.fillHeight: true
                  color: root.terminalFill
                  radius: root.cornerRadius
                  border.width: 1
                  border.color: root.alpha(root.foreground, 0.1)
                  clip: true

                  Item {
                    id: terminalSlot
                    anchors.fill: parent
                    anchors.margins: 6
                  }
                }

                Rectangle {
                  visible: !root.connected
                  Layout.fillWidth: true
                  Layout.preferredHeight: visible ? 108 : 0
                  color: root.alpha(root.urgent, 0.08)
                  radius: root.cornerRadius
                  border.width: 1
                  border.color: root.alpha(root.urgent, 0.35)

                  ColumnLayout {
                    anchors.fill: parent
                    anchors.margins: 12
                    spacing: 5
                    Text {
                      Layout.fillWidth: true
                      text: "Herdr is not connected"
                      color: root.foreground
                      font.family: root.chromeFont
                      font.pixelSize: 14
                      font.bold: true
                    }
                    Text {
                      Layout.fillWidth: true
                      text: root.errorText + "\nInstall or start Herdr. Reconnecting automatically."
                      color: root.muted
                      wrapMode: Text.Wrap
                      font.family: root.chromeFont
                      font.pixelSize: 12
                    }
                  }
                }

                Text {
                  Layout.fillWidth: true
                  Layout.preferredHeight: 20
                  visible: text.length > 0
                  text: root.noticeText || (root.agentForPane(root.selectedPane)?.agent_status === "blocked"
                    ? "Approval needed — respond directly in the terminal." : "")
                  color: root.noticeText ? root.accent : root.muted
                  font.family: root.chromeFont
                  font.pixelSize: 12
                  elide: Text.ElideRight
                }
              }
            }
          }
        }
      }

      Ui.BorderSurface {
        id: completionAlert
        z: 5
        visible: root.alertsEnabled && root.overlayVisible && !root.opened && !!root.activeAlert
          && overlayWindow.screenName === (root.panelScreenName || root.defaultScreenName())
        readonly property color statusColor: root.activeAlertNeedsInput ? root.urgent : root.success
        width: Math.min(380, overlayWindow.width - root.edgeGap * 2)
        height: alertColumn.implicitHeight + 24
        x: root.clamp(overlayWindow.panelRoomLeft >= width ? bubble.x - width - 12 : bubble.x + bubble.width + 12,
          root.edgeGap, overlayWindow.width - width - root.edgeGap)
        y: root.clamp(bubble.y + bubble.height / 2 - height / 2, root.edgeGap, overlayWindow.height - height - root.edgeGap)
        radius: root.cornerRadius
        color: root.wowMode ? "transparent" : root.panelFill
        borderSpec: root.wowMode ? Border.none() : root.panelBorderSpec

        WowFrame {
          anchors.fill: parent
          visible: root.wowMode
          fillColor: root.panelFill
          z: 0
        }
        MouseArea {
          z: 1
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onEntered: root.alertHovered = true
          onExited: root.alertHovered = false
          onClicked: root.openAlert(overlayWindow.screenName)
        }
        Column {
          id: alertColumn
          z: 1
          anchors.top: parent.top
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.margins: 12
          spacing: 8
          Text {
            width: parent.width - 24
            text: (root.activeAlertNeedsInput ? "Needs input · " : "Done · ")
              + (root.activeAlert ? String(root.activeAlert.workspace_label || "Agent") : "")
            textFormat: Text.PlainText
            font.family: root.chromeFont
            font.pixelSize: 12
            font.bold: true
            color: completionAlert.statusColor
            elide: Text.ElideRight
          }
          Text {
            width: parent.width
            text: root.alertPreview
            textFormat: Text.PlainText
            font.family: root.chromeFont
            font.pixelSize: 12
            color: root.foreground
            wrapMode: Text.Wrap
            maximumLineCount: 8
            elide: Text.ElideRight
          }
        }
        Button {
          z: 2
          anchors.top: parent.top
          anchors.right: parent.right
          anchors.margins: 5
          implicitWidth: 28
          implicitHeight: 28
          text: "×"
          onClicked: { root.alertHovered = false; root.showNextAlert() }
          background: Rectangle { color: "transparent" }
          contentItem: Text {
            text: parent.text
            color: root.muted
            font.pixelSize: 18
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
          }
        }
      }

      Item {
        id: bubble
        z: 1
        width: root.bubbleWidth
        height: root.bubbleHeight
        x: overlayWindow.bubbleX
        y: overlayWindow.bubbleY

        Rectangle {
          anchors.fill: parent
          visible: root.launcherStyle !== 5
          radius: root.bubbleRadius
          color: bubbleHover.hovered ? Qt.tint(root.launcherAccent, root.alpha(root.launcherText, 0.08)) : root.launcherAccent
          border.width: 2
          border.color: root.attentionCount() > 0 ? root.launcherSuccess : root.alpha(root.launcherBackground, 0.55)

          Text {
            anchors.centerIn: parent
            text: root.launcherStyle === 4 ? "herdr" : "H"
            color: root.launcherText
            font.family: root.chromeFont
            font.pixelSize: root.bubbleHeight <= 32 ? 16 : 25
            font.bold: true
          }
        }

        WowLauncher {
          anchors.fill: parent
          visible: root.launcherStyle === 5
          hovered: bubbleHover.hovered
        }

        Rectangle {
          visible: root.attentionCount() > 0
          width: Math.max(19, badgeText.implicitWidth + 8)
          height: 19
          radius: root.cornerRadius
          anchors.right: parent.right
          anchors.top: parent.top
          color: root.launcherSuccess
          border.width: 2
          border.color: root.launcherBackground

          Text {
            id: badgeText
            anchors.centerIn: parent
            text: root.attentionCount() > 99 ? "99+" : String(root.attentionCount())
            color: root.launcherText
            font.family: root.chromeFont
            font.pixelSize: 10
            font.bold: true
          }
        }

        HoverHandler {
          id: bubbleHover
          cursorShape: bubbleDrag.active ? Qt.ClosedHandCursor : Qt.PointingHandCursor
        }

        TapHandler {
          acceptedButtons: Qt.LeftButton
          onTapped: root.toggleOnScreen(overlayWindow.screenName)
        }

        TapHandler {
          acceptedButtons: Qt.RightButton
          onTapped: root.cycleLauncherStyle()
        }

        DragHandler {
          id: bubbleDrag
          target: bubble
          acceptedButtons: Qt.LeftButton
          xAxis.minimum: root.edgeGap
          xAxis.maximum: Math.max(root.edgeGap, overlayWindow.width - bubble.width - root.edgeGap)
          yAxis.minimum: root.edgeGap
          yAxis.maximum: Math.max(root.edgeGap, overlayWindow.height - bubble.height - root.edgeGap)

          onActiveChanged: {
            if (active) {
              overlayWindow.draggingBubble = true
            } else if (overlayWindow.draggingBubble) {
              overlayWindow.bubbleX = bubble.x
              overlayWindow.bubbleY = bubble.y
              root.savePosition(overlayWindow.screenName, bubble.x, bubble.y)
              overlayWindow.draggingBubble = false
            }
          }
        }
      }
    }
  }


}
