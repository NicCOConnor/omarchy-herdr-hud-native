import QtQuick
import QMLTermWidget 2.0

Item {
  id: root
  required property string terminalTarget
  property color foreground: "#eeeeee"
  property color background: "#101010"
  property bool clientRunning: false
  property bool stopping: false
  property bool started: false
  property bool inputEnabled: true
  property bool selecting: false
  property bool clearingSelection: false
  property bool endedSent: false
  property alias terminalItem: terminal
  // macOS-style touchpad scrolling. The terminal turns every wheel event into
  // a full scroll step (one line: herdr-attach gives the HUD's client
  // mouse_scroll_lines = 1), and touchpads
  // emit many tiny events, so translate finger travel into steps ourselves:
  // distance follows the fingers, fast flicks accelerate, and lifting off
  // mid-flick glides with friction. A mouse wheel stays one step per notch.
  property real touchpadStepPixels: 8       // finger travel per line at slow speed
  property int wheelNotchLines: 3          // mouse wheel lines per notch
  property real accelerationGain: 1.6      // extra speed per px/ms above the threshold
  property real accelerationThreshold: 0.25
  property real maxAcceleration: 4
  property real momentumFriction: 0.96     // velocity kept per 16ms frame
  property real momentumMinVelocity: 0.02  // px/ms below which gliding stops
  property real momentumStartVelocity: 0.08 // px/ms at lift-off needed to glide
  property int flickWindowMs: 100          // finger travel window used at lift-off
  property var recentScroll: []            // [{t, px}] finger events in that window
  property real wheelRemainder: 0
  property real scrollVelocity: 0          // px/ms, smoothed
  property double lastWheelTime: 0
  property int lastWheelX: 0
  property int lastWheelY: 0

  function accelerated(pixels, velocity) {
    var speed = Math.abs(velocity)
    var factor = 1 + Math.max(0, speed - accelerationThreshold) * accelerationGain
    return pixels * Math.min(maxAcceleration, factor)
  }

  function emitSteps() {
    var sent = 0
    while (Math.abs(wheelRemainder) >= 1 && sent < 24) {
      var step = wheelRemainder > 0 ? 1 : -1
      terminal.simulateWheel(lastWheelX, lastWheelY, 0, 0, Qt.point(0, step * 120))
      wheelRemainder -= step
      sent++
    }
    if (Math.abs(wheelRemainder) >= 1) wheelRemainder = wheelRemainder > 0 ? 0.99 : -0.99
  }
  property alias terminalSession: session
  signal ended()

  function finish() {
    if (endedSent) return
    endedSent = true
    clientRunning = false
    stopTimeout.stop()
    abandonTimeout.stop()
    ended()
  }

  function copyAndClearSelection() {
    if (selecting || stopping) return
    terminal.copyClipboard()
    selectionReset.restart()
  }

  function clearSelection() {
    if (selecting || stopping) return
    clearingSelection = true
    try {
      terminal.simulateMousePress(1, 1, Qt.LeftButton, Qt.LeftButton, Qt.ShiftModifier)
      terminal.simulateMouseRelease(1, 1, Qt.LeftButton, Qt.NoButton, Qt.ShiftModifier)
    } finally {
      clearingSelection = false
    }
  }

  function focusTerminal() {
    if (!stopping && clientRunning) terminal.forceActiveFocus()
  }

  function stop() {
    if (stopping) return
    stopping = true
    startup.stop()
    if (clientRunning) {
      session.sendSignal(15)
      stopTimeout.start()
    } else finish()
  }

  function applyPalette() {
    terminal.setBackgroundColor(background)
    terminal.setForegroundColor(foreground)
  }

  onForegroundChanged: applyPalette()
  onBackgroundChanged: applyPalette()
  Component.onCompleted: applyPalette()

  Shortcut {
    sequences: ["Ctrl+Shift+V", "Shift+Insert"]
    enabled: terminal.activeFocus && root.clientRunning && !root.stopping && root.inputEnabled
    onActivated: terminal.pasteClipboard()
  }

  QMLTermWidget {
    id: terminal
    anchors.fill: parent
    enabled: root.clientRunning && !root.stopping && root.inputEnabled
    font.family: "monospace"
    font.pointSize: 10
    colorScheme: "cool-retro-term"
    onIsBusySelecting: busy => {
      if (root.clearingSelection) return
      root.selecting = busy
      if (busy) selectionReset.stop()
      if (!busy) Qt.callLater(root.copyAndClearSelection)
    }
    session: QMLTermSession {
      id: session
      shellProgram: "/usr/bin/env"
      shellProgramArgs: ["python3", decodeURIComponent(Qt.resolvedUrl("bin/herdr-attach").toString().replace(/^file:\/\//, "")), root.terminalTarget]
      initialWorkingDirectory: "/"
      onStarted: {
        root.clientRunning = true
        root.focusTerminal()
      }
      onFinished: root.finish()
    }
  }

  MouseArea {
    anchors.fill: terminal
    z: 1
    acceptedButtons: Qt.NoButton
    enabled: terminal.enabled
    onWheel: function(wheel) {
      root.lastWheelX = wheel.x
      root.lastWheelY = wheel.y
      if (wheel.pixelDelta.y === 0) {
        // Mouse wheel: one step per notch, no momentum.
        momentum.stop()
        root.scrollVelocity = 0
        root.wheelRemainder += wheel.angleDelta.y / 120 * root.wheelNotchLines
        root.emitSteps()
        wheel.accepted = true
        return
      }
      momentum.stop()
      var now = Date.now()
      var dt = Math.max(4, Math.min(100, now - root.lastWheelTime))
      if (now - root.lastWheelTime > 120) root.scrollVelocity = 0
      root.lastWheelTime = now
      root.scrollVelocity = root.scrollVelocity * 0.5 + (wheel.pixelDelta.y / dt) * 0.5
      var recent = root.recentScroll.filter(function(sample) { return now - sample.t <= root.flickWindowMs })
      recent.push({ t: now, px: wheel.pixelDelta.y })
      root.recentScroll = recent
      root.wheelRemainder += root.accelerated(wheel.pixelDelta.y, root.scrollVelocity) / root.touchpadStepPixels
      root.emitSteps()
      // No explicit lift event is guaranteed, so treat a short pause in
      // finger events as the fingers leaving the touchpad.
      if (wheel.phase === Qt.ScrollEnd) liftDetector.fire()
      else liftDetector.restart()
      wheel.accepted = true
    }
  }

  Timer {
    id: liftDetector
    interval: 60
    function fire() { stop(); triggered() }
    onTriggered: {
      // Fingers slow down as they lift, so the last events understate the
      // flick; use the average speed over the recent window, as macOS does.
      var samples = root.recentScroll
      root.recentScroll = []
      var travel = 0
      for (var i = 0; i < samples.length; i++) travel += samples[i].px
      var span = samples.length > 1 ? samples[samples.length - 1].t - samples[0].t : 0
      var velocity = samples.length > 1 ? travel / Math.max(16, span) : root.scrollVelocity
      if (Math.abs(velocity) > root.momentumStartVelocity) {
        root.scrollVelocity = velocity
        momentum.start()
      } else root.scrollVelocity = 0
    }
  }

  Timer {
    id: momentum
    interval: 16
    repeat: true
    onTriggered: {
      root.scrollVelocity *= root.momentumFriction
      if (Math.abs(root.scrollVelocity) < root.momentumMinVelocity) {
        root.scrollVelocity = 0
        stop()
        return
      }
      root.wheelRemainder += root.accelerated(root.scrollVelocity * interval, root.scrollVelocity) / root.touchpadStepPixels
      root.emitSteps()
    }
  }

  Timer {
    id: selectionReset
    interval: Qt.styleHints.mouseDoubleClickInterval + 1
    onTriggered: root.clearSelection()
  }

  Timer {
    id: startup
    interval: 50
    running: root.width > 100 && root.height > 60 && !root.stopping && !root.started
    onTriggered: {
      root.started = true
      session.startShellProgram()
    }
  }

  Timer {
    id: stopTimeout
    interval: 1500
    onTriggered: {
      if (root.clientRunning) session.sendSignal(9)
      abandonTimeout.start()
    }
  }

  // If the session never reports finishing (the client already died, or
  // the signal was lost), stop waiting so switching agents can't wedge on
  // "Disconnecting…".
  Timer {
    id: abandonTimeout
    interval: 1500
    onTriggered: if (root.stopping) root.finish()
  }
}
