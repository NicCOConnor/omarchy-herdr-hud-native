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
  // Touchpads emit many tiny wheel events and the terminal turns each one into
  // a full scroll step. Accumulate them and forward one step per this many
  // pixels of finger travel; a mouse wheel still scrolls one step per notch.
  property real touchpadStepPixels: 48
  property real wheelRemainder: 0
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
      if (wheel.pixelDelta.y !== 0)
        root.wheelRemainder += wheel.pixelDelta.y * 120 / root.touchpadStepPixels
      else
        root.wheelRemainder += wheel.angleDelta.y
      while (Math.abs(root.wheelRemainder) >= 120) {
        var step = root.wheelRemainder > 0 ? 120 : -120
        terminal.simulateWheel(wheel.x, wheel.y, 0, wheel.modifiers, Qt.point(0, step))
        root.wheelRemainder -= step
      }
      wheel.accepted = true
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
