import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Mpris
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Now Bar: a now-playing card. Playback comes from MPRIS (any player); the
// "next up" row and the save button come from Spotify's Web API via `nowq`.
Panel {
  id: root
  moduleName: "samashech.nowbar"
  ipcTarget: "samashech.nowbar"

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  readonly property string python: "/usr/bin/python3"
  readonly property string helper: Qt.resolvedUrl("nowq").toString().replace(/^file:\/\//, "")
  readonly property color fg: root.barForeground
  readonly property string fontFamily: root.bar ? root.bar.fontFamily : Style.font.family

  // ---------------------------------------------------------------- player
  readonly property var players: Mpris.players ? Mpris.players.values : []
  readonly property var player: {
    var list = players, fallback = null
    for (var i = 0; i < list.length; i++) if (list[i].isPlaying) return list[i]
    for (var j = 0; j < list.length; j++) {
      if (isSpotify(list[j])) return list[j]
      if (!fallback && list[j].trackTitle) fallback = list[j]
    }
    return fallback || (list.length > 0 ? list[0] : null)
  }
  readonly property bool hasTrack: !!(player && player.trackTitle)
  readonly property bool spotify: isSpotify(player)
  property real position: 0

  function isSpotify(p) {
    if (!p) return false
    return String(p.identity || "").toLowerCase().indexOf("spotify") >= 0
      || String(p.dbusName || "").indexOf("spotify") >= 0
  }

  // Track titles and device names go into shell-owned tooltips/buttons whose Text
  // may be AutoText; swap angle brackets so markup-shaped titles stay plain text.
  function safe(s) { return String(s || "").replace(/</g, "\u2039").replace(/>/g, "\u203a") }

  function fmt(sec) {
    var s = Math.max(0, Math.floor(sec || 0))
    var m = Math.floor(s / 60)
    var r = s % 60
    return m + ":" + (r < 10 ? "0" : "") + r
  }

  function sourceGlyph() {
    if (spotify) return ""
    var id = player ? String(player.identity || "").toLowerCase() : ""
    if (id.indexOf("brave") >= 0 || id.indexOf("chrom") >= 0) return ""
    if (id.indexOf("firefox") >= 0) return ""
    return "󰝚"
  }

  Timer {
    interval: 500
    repeat: true
    running: root.opened && !!root.player
    triggeredOnStart: true
    onTriggered: {
      root.player.positionChanged()
      root.position = root.player.position
    }
  }

  // ---------------------------------------------------------------- cover art
  // Spotify hands out https://i.scdn.co URLs; nowq caches them as local files.
  property string artPath: ""
  readonly property string artUrl: player ? String(player.trackArtUrl || "") : ""
  onArtUrlChanged: refreshArt()
  function refreshArt() {
    if (artUrl.indexOf("file://") === 0) { artPath = artUrl; return }
    if (!/^https:\/\/i\.scdn\.co\/image\/[0-9a-f]{16,64}$/.test(artUrl)) { artPath = ""; return }
    artProc.command = [python, "-I", helper, "art", artUrl]
    artProc.running = true
  }
  Process {
    id: artProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var p = text.trim()
        root.artPath = p.indexOf("/") === 0 && p.length < 512 ? "file://" + p : ""
      }
    }
  }

  // ---------------------------------------------------------------- queue (Spotify Web API)
  property string auth: "unknown"     // ok | nologin | noclient | busy | error
  property var queue: []              // [{uri, title, artist, art}]
  property string nowUri: ""
  property bool saved: false

  function parseQueue(raw) {
    var lines = String(raw || "").split("\n"), next = [], gotNow = false
    for (var i = 0; i < lines.length; i++) {
      var p = lines[i].split("\t")
      if (p[0] === "auth" && p.length === 2 && /^[a-z0-9]{1,12}$/.test(p[1])) auth = p[1]
      else if (p[0] === "now" && p.length === 2 && /^spotify:(track|episode):[A-Za-z0-9]{22}$/.test(p[1])) { nowUri = p[1]; gotNow = true }
      else if (p[0] === "saved" && p.length === 2) saved = p[1] === "true"
      else if (p[0] === "q" && p.length === 5 && /^spotify:(track|episode):[A-Za-z0-9]{22}$/.test(p[1]) && next.length < 4) {
        next.push({
          uri: p[1],
          title: p[2].slice(0, 160),
          artist: p[3].slice(0, 160),
          art: p[4].indexOf("/") === 0 && p[4].length < 512 ? "file://" + p[4] : ""
        })
      }
    }
    if (auth === "ok") {
      queue = next
      if (!gotNow) nowUri = ""
    } else if (auth === "nologin" || auth === "noclient") {
      queue = []
    }
  }

  function refreshQueue() {
    if (!spotify || queueProc.running) return
    queueProc.running = true
  }
  Process {
    id: queueProc
    command: [root.python, "-I", root.helper, "queue"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.parseQueue(text) }
  }

  // Spotify updates its queue a moment after the track changes.
  readonly property string trackKey: player ? String(player.trackTitle || "") + "|" + String(player.trackArtist || "") : ""
  onTrackKeyChanged: queueDelay.restart()
  Timer { id: queueDelay; interval: 1200; onTriggered: root.refreshQueue() }
  Timer { interval: 20000; repeat: true; running: root.opened && root.spotify; onTriggered: root.refreshQueue() }
  onOpenedChanged: if (opened) { refreshQueue(); refreshSinks() }

  // Jump to a queued song: skip forward that many times.
  property int skipsLeft: 0
  function playQueued(index) {
    if (!player || !player.canGoNext || index < 0 || index > 3) return
    skipsLeft = index + 1
    skipTimer.restart()
  }
  Timer {
    id: skipTimer
    interval: 280
    repeat: true
    onTriggered: {
      if (root.skipsLeft <= 0 || !root.player) { stop(); return }
      root.player.next()
      root.skipsLeft -= 1
      if (root.skipsLeft <= 0) { stop(); queueDelay.restart() }
    }
  }

  function toggleSaved() {
    if (!/^spotify:track:[A-Za-z0-9]{22}$/.test(nowUri) || libProc.running) return
    var next = !saved
    libProc.command = [python, "-I", helper, next ? "save" : "unsave", nowUri]
    saved = next
    libProc.running = true
  }
  Process {
    id: libProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (text.indexOf("result\tok") < 0) root.saved = !root.saved   // undo on failure
    }
  }

  Process { id: loginProc; command: [root.python, "-I", root.helper, "login"]; onExited: root.refreshQueue() }

  // ---------------------------------------------------------------- output device
  property var sinks: []           // [{name, description}]
  property string defaultSink: ""
  property bool showOutputs: false

  function refreshSinks() {
    if (!sinksProc.running) sinksProc.running = true
    if (!defaultSinkProc.running) defaultSinkProc.running = true
  }
  Process {
    id: sinksProc
    command: ["pactl", "-f", "json", "list", "sinks"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var list = []
        try {
          var data = JSON.parse(text)
          for (var i = 0; i < data.length && list.length < 12; i++) {
            var n = String(data[i].name || ""), d = String(data[i].description || n)
            if (/^[A-Za-z0-9._:-]{1,200}$/.test(n)) list.push({ name: n, description: d.slice(0, 80) })
          }
        } catch (e) {}
        root.sinks = list
      }
    }
  }
  Process {
    id: defaultSinkProc
    command: ["pactl", "get-default-sink"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.defaultSink = text.trim() }
  }
  Process { id: setSinkProc; onExited: root.refreshSinks() }
  function setSink(name) {
    if (!/^[A-Za-z0-9._:-]{1,200}$/.test(name)) return
    setSinkProc.command = ["pactl", "set-default-sink", name]
    setSinkProc.running = true
    defaultSink = name
  }
  function sinkGlyph(desc) {
    var d = String(desc).toLowerCase()
    if (d.indexOf("headphone") >= 0 || d.indexOf("headset") >= 0 || d.indexOf("buds") >= 0) return "󰋋"
    if (d.indexOf("hdmi") >= 0 || d.indexOf("displayport") >= 0) return "󰍹"
    if (d.indexOf("bluetooth") >= 0 || d.indexOf("bluez") >= 0) return "󰂯"
    return "󰓃"
  }
  readonly property string currentSinkDescription: {
    for (var i = 0; i < sinks.length; i++) if (sinks[i].name === defaultSink) return sinks[i].description
    return ""
  }

  // ---------------------------------------------------------------- bar button
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.player && root.player.isPlaying ? "󰎈" : "󰎊"
    dimmed: !root.hasTrack
    tooltipText: root.hasTrack ? root.safe(root.player.trackTitle) : ""
    onPressed: function(b) {
      if (b === Qt.MiddleButton && root.player && root.player.canTogglePlaying) root.player.togglePlaying()
      else if (b === Qt.RightButton && root.player && root.player.canGoNext) root.player.next()
      else root.toggle()
    }
  }

  // ---------------------------------------------------------------- card
  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: panel.loadedContent
    contentWidth: panel.fittedContentWidth(Style.space(400))
    contentHeight: panel.fittedContentHeight(panel.loadedContentHeight)

    content: PanelKeyCatcher {
      anchors.fill: parent
      implicitHeight: card.implicitHeight
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: card
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(14)

        PlainText {
          visible: !root.hasTrack
          width: parent.width
          horizontalAlignment: Text.AlignHCenter
          opacity: 0.7
          topPadding: Style.space(10)
          bottomPadding: Style.space(10)
          text: strings.t("nothingPlaying")
        }

        // Art + title, artist, seek bar
        Row {
          visible: root.hasTrack
          width: parent.width
          spacing: Style.space(14)

          Rectangle {
            id: artBox
            width: Style.space(104)
            height: width
            radius: Style.space(14)
            color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.08)
            clip: true
            Image {
              anchors.fill: parent
              source: root.artPath
              fillMode: Image.PreserveAspectCrop
              asynchronous: true
              sourceSize.width: 256
              sourceSize.height: 256
              visible: status === Image.Ready
              layer.enabled: true
              layer.smooth: true
            }
            PlainText {
              anchors.centerIn: parent
              visible: root.artPath === ""
              text: "󰝚"
              font.pixelSize: Style.font.display
              opacity: 0.4
            }
          }

          Column {
            width: parent.width - artBox.width - parent.spacing
            spacing: Style.space(4)
            anchors.verticalCenter: parent.verticalCenter

            Item {
              width: parent.width
              height: titleText.implicitHeight
              Marquee {
                id: titleText
                anchors.left: parent.left
                anchors.right: sourceIcon.left
                anchors.rightMargin: Style.space(8)
                text: root.player ? String(root.player.trackTitle || "") : ""
                pixelSize: Style.font.subtitle
                bold: true
              }
              PlainText {
                id: sourceIcon
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: root.sourceGlyph()
                font.pixelSize: Style.font.subtitle
                color: root.spotify ? "#1ed760" : root.fg
              }
            }
            Marquee {
              width: parent.width
              text: root.player ? String(root.player.trackArtist || "") : ""
              pixelSize: Style.font.bodySmall
              textOpacity: 0.7
            }
            Item { width: 1; height: Style.space(6) }
            PanelSlider {
              width: parent.width
              bar: root.bar
              enabled: !!root.player && root.player.canSeek && root.player.length > 0
              minimum: 0
              maximum: Math.max(1, root.player ? root.player.length : 1)
              step: 1
              value: root.position
              onReleased: function(v) {
                if (root.player && root.player.canSeek) { root.player.position = v; root.position = v }
              }
            }
            Item {
              width: parent.width
              height: posText.implicitHeight
              PlainText { id: posText; text: root.fmt(root.position); opacity: 0.6; font.pixelSize: Style.font.caption }
              PlainText {
                anchors.right: parent.right
                text: root.fmt(root.player ? root.player.length : 0)
                opacity: 0.6
                font.pixelSize: Style.font.caption
              }
            }
          }
        }

        // Controls: output, previous, play/pause, next, save
        Item {
          visible: root.hasTrack
          width: parent.width
          height: playButton.height
          Row {
            anchors.centerIn: parent
            spacing: Style.space(18)
            IconButton {
              glyph: root.sinkGlyph(root.currentSinkDescription)
              tip: root.safe(root.currentSinkDescription) || strings.t("output")
              highlighted: root.showOutputs
              onActivated: { root.showOutputs = !root.showOutputs; if (root.showOutputs) root.refreshSinks() }
            }
            IconButton {
              glyph: "󰒮"
              tip: strings.t("previous")
              enabled: !!root.player && root.player.canGoPrevious
              onActivated: root.player.previous()
            }
            Rectangle {
              id: playButton
              width: Style.space(52)
              height: width
              radius: width / 2
              color: root.fg
              scale: playMouse.pressed ? 0.95 : 1
              Behavior on scale { NumberAnimation { duration: Style.duration(120); easing.type: Easing.OutCubic } }
              Text {
                anchors.centerIn: parent
                textFormat: Text.PlainText
                text: root.player && root.player.isPlaying ? "󰏤" : "󰐊"
                color: Commons.Color.background
                font.family: root.fontFamily
                font.pixelSize: Style.font.title
              }
              MouseArea {
                id: playMouse
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: if (root.player && root.player.canTogglePlaying) root.player.togglePlaying()
              }
            }
            IconButton {
              glyph: "󰒭"
              tip: strings.t("next")
              enabled: !!root.player && root.player.canGoNext
              onActivated: root.player.next()
            }
            IconButton {
              glyph: root.saved ? "󰄬" : "󰐕"
              tip: root.saved ? strings.t("saved") : strings.t("save")
              enabled: root.spotify && root.auth === "ok" && root.nowUri.indexOf("spotify:track:") === 0
              highlighted: root.saved
              onActivated: root.toggleSaved()
            }
          }
        }

        // Output picker
        Column {
          visible: root.hasTrack && root.showOutputs
          width: parent.width
          spacing: Style.space(4)
          Repeater {
            model: root.sinks
            Button {
              required property var modelData
              width: card.width
              leftAlign: true
              iconText: root.sinkGlyph(modelData.description)
              text: root.safe(modelData.description)
              fontSize: Style.font.bodySmall
              foreground: root.fg
              fontFamily: root.fontFamily
              bordered: true
              active: modelData.name === root.defaultSink
              onClicked: root.setSink(modelData.name)
            }
          }
        }

        // Next up
        Row {
          id: queueRow
          visible: root.hasTrack && root.spotify && root.queue.length > 0
          width: parent.width
          spacing: Style.space(8)
          readonly property real cell: (width - spacing * 3) / 4
          Repeater {
            model: root.queue
            Column {
              required property var modelData
              required property int index
              width: queueRow.cell
              spacing: Style.space(4)
              Rectangle {
                width: parent.width
                height: width
                radius: Style.space(10)
                clip: true
                color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.08)
                scale: tileMouse.pressed ? 0.96 : 1
                Behavior on scale { NumberAnimation { duration: Style.duration(120); easing.type: Easing.OutCubic } }
                Image {
                  anchors.fill: parent
                  source: modelData.art
                  fillMode: Image.PreserveAspectCrop
                  asynchronous: true
                  sourceSize.width: 160
                  sourceSize.height: 160
                  visible: status === Image.Ready
                }
                Rectangle {
                  anchors.fill: parent
                  radius: parent.radius
                  color: "transparent"
                  border.width: tileMouse.containsMouse ? 2 : 0
                  border.color: root.fg
                }
                MouseArea {
                  id: tileMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.playQueued(index)
                }
              }
              PlainText {
                width: parent.width
                text: modelData.title
                elide: Text.ElideRight
                font.pixelSize: Style.font.caption
                opacity: 0.85
              }
              PlainText {
                width: parent.width
                text: modelData.artist
                elide: Text.ElideRight
                font.pixelSize: Style.font.caption
                opacity: 0.55
              }
            }
          }
        }

        // Not connected yet
        Column {
          visible: root.hasTrack && root.spotify && (root.auth === "nologin" || root.auth === "noclient")
          width: parent.width
          spacing: Style.space(6)
          PanelSeparator { foreground: root.fg }
          PlainText {
            width: parent.width
            wrapMode: Text.WordWrap
            opacity: 0.7
            text: root.auth === "noclient" ? strings.t("needsSetup") : strings.t("connectHint")
          }
          Button {
            visible: root.auth === "nologin"
            width: parent.width
            iconText: ""
            text: loginProc.running ? strings.t("waitingForBrowser") : strings.t("connect")
            foreground: root.fg
            fontFamily: root.fontFamily
            bordered: true
            onClicked: if (!loginProc.running) loginProc.running = true
          }
        }
      }
    }
  }

  // ---------------------------------------------------------------- pieces
  component PlainText: Text {
    textFormat: Text.PlainText
    color: root.fg
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
  }

  // Round, borderless control glyph.
  component IconButton: Item {
    id: ib
    property string glyph: ""
    property string tip: ""
    property bool highlighted: false
    signal activated()
    width: Style.space(36)
    height: Style.space(36)
    opacity: enabled ? 1 : 0.35
    Rectangle {
      anchors.fill: parent
      radius: width / 2
      color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, ib.highlighted ? 0.18 : (ibMouse.containsMouse ? 0.1 : 0))
    }
    Text {
      anchors.centerIn: parent
      textFormat: Text.PlainText
      text: ib.glyph
      color: root.fg
      font.family: root.fontFamily
      font.pixelSize: Style.font.title
      scale: ibMouse.pressed ? 0.92 : 1
      Behavior on scale { NumberAnimation { duration: Style.duration(120); easing.type: Easing.OutCubic } }
    }
    MouseArea {
      id: ibMouse
      anchors.fill: parent
      hoverEnabled: true
      enabled: ib.enabled
      cursorShape: Qt.PointingHandCursor
      onClicked: ib.activated()
      onContainsMouseChanged: {
        if (!root.bar || !ib.tip) return
        if (containsMouse) root.bar.showTooltip(ib, root.safe(ib.tip))
        else root.bar.hideTooltip(ib)
      }
    }
  }

  // Single line that scrolls when it doesn't fit, like the phone's Now Bar.
  component Marquee: Item {
    id: mq
    property string text: ""
    property real pixelSize: Style.font.body
    property bool bold: false
    property real textOpacity: 1
    readonly property real overflow: Math.max(0, label.implicitWidth - width)
    readonly property bool canAnimate: Style.duration(1000) > 0
    implicitHeight: label.implicitHeight
    clip: true
    onTextChanged: label.x = 0
    Text {
      id: label
      textFormat: Text.PlainText
      text: mq.text
      color: root.fg
      opacity: mq.textOpacity
      font.family: root.fontFamily
      font.pixelSize: mq.pixelSize
      font.bold: mq.bold
    }
    SequentialAnimation {
      running: root.opened && mq.overflow > 0 && mq.canAnimate
      loops: Animation.Infinite
      onRunningChanged: if (!running) label.x = 0
      PauseAnimation { duration: 1800 }
      NumberAnimation { target: label; property: "x"; to: -mq.overflow; duration: Math.max(600, mq.overflow * 28); easing.type: Easing.Linear }
      PauseAnimation { duration: 1400 }
      NumberAnimation { target: label; property: "x"; to: 0; duration: 220; easing.type: Easing.OutCubic }
    }
  }
}
