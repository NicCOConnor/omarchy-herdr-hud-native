import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Item {
  id: root
  property string target: ""
  property color foreground: "#eeeeee"
  property color muted: "#aaaaaa"
  property color accent: "#88aaff"
  property color background: "#101010"
  property string chromeFont: "sans-serif"
  property bool wowMode: false
  property string currentTarget: ""
  property bool paused: false
  property bool stopping: false
  property string message: "Select an agent to view its terminal."
  readonly property alias terminal: terminalLoader.item
  readonly property bool clientRunning: !!terminal && terminal.clientRunning

  function toggleConnection() {
    if (clientRunning) {
      paused = true
      reconcile()
    } else reconnect()
  }

  function focusTerminal() {
    if (terminal) terminal.focusTerminal()
  }

  function reconcile() {
    if (stopping) return
    var desired = paused ? "" : target
    if (currentTarget === desired) {
      if (!desired) message = paused ? "Disconnected. Reconnect to enter terminal input." : "Select an agent to view its terminal."
      return
    }
    if (terminal) {
      stopping = true
      message = "Disconnecting…"
      terminal.stop()
      return
    }
    terminalLoader.source = ""
    currentTarget = ""
    if (!desired) {
      message = paused ? "Disconnected. Reconnect to enter terminal input." : "Select an agent to view its terminal."
      return
    }
    if (!/^term_[A-Za-z0-9_-]+$/.test(desired)) {
      message = "This agent has no valid terminal ID."
      return
    }
    currentTarget = desired
    message = "Starting terminal…"
    terminalLoader.setSource("NativeTerminal.qml", {terminalTarget: desired})
  }

  function reconnect() {
    paused = false
    if (terminal) {
      stopping = true
      terminal.stop()
    } else {
      currentTarget = ""
      reconcile()
    }
  }

  onTargetChanged: {
    paused = false
    Qt.callLater(reconcile)
  }
  Component.onCompleted: Qt.callLater(reconcile)

  ColumnLayout {
    anchors.fill: parent
    spacing: 4
    Item {
      Layout.fillWidth: true
      Layout.fillHeight: true
      Loader {
        id: terminalLoader
        anchors.fill: parent
        onStatusChanged: {
          if (status === Loader.Error) root.message = "Cannot load QMLTermWidget. Install qmltermwidget and restart Omarchy shell."
        }
      }
      Text {
        anchors.centerIn: parent
        width: Math.max(0, parent.width - 24)
        visible: !terminalLoader.item
        text: root.message
        color: root.foreground
        font.family: root.chromeFont
        wrapMode: Text.Wrap
        horizontalAlignment: Text.AlignHCenter
      }
    }
    RowLayout {
      Layout.fillWidth: true
      Text {
        Layout.fillWidth: true
        text: root.clientRunning && !root.stopping ? "Super+Ctrl+↑↓ switch agents · Ctrl+Shift+V to paste · Shift+drag to select & copy · Esc goes to agent" : root.message
        color: root.muted
        font.family: root.chromeFont
        font.pixelSize: 11
        elide: Text.ElideRight
      }
    }
  }

  Binding { target: terminalLoader.item; property: "foreground"; value: root.foreground; when: !!terminalLoader.item }
  Binding { target: terminalLoader.item; property: "background"; value: root.background; when: !!terminalLoader.item }
  Binding { target: terminalLoader.item; property: "inputEnabled"; value: root.currentTarget === root.target && !root.paused && !root.stopping; when: !!terminalLoader.item }
  Connections {
    target: terminalLoader.item
    function onEnded() {
      if (root.stopping) {
        Qt.callLater(function() {
          terminalLoader.source = ""
          root.currentTarget = ""
          root.stopping = false
          root.reconcile()
        })
      } else {
        root.paused = true
        root.message = "Attach ended. Check terminal output; another controller may own it. Reconnect manually."
      }
    }
  }
}
