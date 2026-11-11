import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Services.Mpris
import Quickshell.Services.UPower
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Bit: a tiny creature that lives in the bar and reacts to the machine.
//   sleeps when you're away, dances while music plays, sweats when the CPU
//   is hot, droops on low battery, eats the cache the Cleaner frees, and
//   loves being clicked. Everything is drawn in QML; nothing leaves the machine.
Panel {
  id: root
  moduleName: "samashech.pet"
  ipcTarget: "samashech.pet"
  manageIpc: false

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  readonly property color fg: root.barForeground
  readonly property color skin: Commons.Color.accent
  readonly property color hotSkin: "#ff4d3d"

  // ---------------------------------------------------------------- senses
  property int cpuTemp: 0
  readonly property bool playing: {
    var list = Mpris.players.values
    for (var i = 0; i < list.length; i++) if (list[i].isPlaying) return true
    return false
  }
  readonly property bool lowBattery: {
    var d = UPower.displayDevice
    return !!(d && d.isPresent && d.state === UPowerDeviceState.Discharging && d.percentage <= 0.2)
  }
  IdleMonitor { id: idle; timeout: 120; respectInhibitors: true }
  readonly property bool asleep: idle.isIdle && !playing

  // short-lived reactions
  property bool petted: false
  property bool eating: false
  property string floater: ""
  property int pets: 0
  property real eatenBytes: 0
  property real bornAt: 0
  property string petName: "Bit"

  readonly property string mood: eating ? "eating" : petted ? "happy" : asleep ? "sleeping"
    : cpuTemp >= 85 ? "hot" : playing ? "dancing" : lowBattery ? "tired" : cpuTemp >= 75 ? "warm" : "chill"

  function pet() {
    pets += 1
    petted = true
    floater = "♥"
    floatAnim.restart()
    pettedTimer.restart()
    save()
  }
  function feed(bytes) {
    var b = parseFloat(bytes)
    if (!(b > 0) || b > 1e13) return
    eatenBytes += b
    eating = true
    floater = b >= 1073741824 ? "+" + (b / 1073741824).toFixed(1) + "G" : "+" + Math.max(1, Math.round(b / 1048576)) + "M"
    floatAnim.restart()
    eatTimer.restart()
    save()
  }
  function rename(n) {
    var clean = String(n || "").replace(/[^\p{L}\p{N} _-]/gu, "").trim().slice(0, 16)
    if (clean) { petName = clean; save() }
  }

  Timer { id: pettedTimer; interval: 1600; onTriggered: root.petted = false }
  Timer { id: eatTimer; interval: 2200; onTriggered: root.eating = false }

  // ---------------------------------------------------------------- temperature
  property string tempPath: ""
  Process {
    running: true
    command: ["sh", "-c", "for h in /sys/class/hwmon/hwmon*; do n=$(cat $h/name); for l in $h/temp*_label; do [ -e \"$l\" ] || continue; case \"$n:$(cat $l)\" in coretemp:Package*|k10temp:Tctl) echo ${l%_label}_input; exit;; esac; done; done"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: { var p = text.trim(); if (/^\/sys\/class\/hwmon\/hwmon\d+\/temp\d+_input$/.test(p)) root.tempPath = p } }
  }
  FileView {
    id: tempFile
    path: root.tempPath
    printErrors: false
    onLoaded: { var t = parseInt(text()); if (t > 0 && t < 150000) root.cpuTemp = Math.round(t / 1000) }
  }
  Timer { interval: 3000; repeat: true; running: root.tempPath !== ""; triggeredOnStart: true; onTriggered: tempFile.reload() }

  // ---------------------------------------------------------------- memory
  readonly property string statePath: (Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") + "/.local/state")) + "/omarchy-pet/state.json"
  property bool stateLoaded: false
  Process { running: true; command: ["mkdir", "-p", root.statePath.replace(/\/[^\/]+$/, "")] }
  FileView {
    id: stateFile
    path: root.statePath
    printErrors: false
    onLoaded: {
      try {
        var s = JSON.parse(text())
        if (typeof s.name === "string") root.rename(s.name)
        if (s.pets >= 0) root.pets = Math.floor(s.pets)
        if (s.eaten >= 0) root.eatenBytes = s.eaten
        if (s.born > 0) root.bornAt = s.born
      } catch (e) {}
      root.stateLoaded = true
      if (!root.bornAt) { root.bornAt = Date.now(); root.save() }
    }
    onLoadFailed: { root.stateLoaded = true; root.bornAt = Date.now(); root.save() }
  }
  function save() {
    if (!stateLoaded) return
    stateFile.setText(JSON.stringify({ name: petName, pets: pets, eaten: eatenBytes, born: bornAt }))
  }

  function tooltip() {
    var days = bornAt ? Math.max(0, Math.floor((Date.now() - bornAt) / 86400000)) : 0
    var gb = eatenBytes / 1073741824
    return strings.t("tooltip").arg(petName).arg(strings.t("mood." + mood))
      .arg(Commons.I18n.formatNumber(days)).arg(Commons.I18n.formatNumber(gb, gb < 10 ? 1 : 0))
      .arg(Commons.I18n.formatNumber(pets))
  }

  ShellIpc {
    target: root.ipcTarget
    function pet(): void { root.pet() }
    function feed(bytes: string): void { root.feed(bytes) }
    function rename(name: string): void { root.rename(name) }
    function mood(): string { return root.mood }
  }

  // ---------------------------------------------------------------- the creature
  implicitWidth: Style.bar.iconSlot
  implicitHeight: Style.bar.iconSlot + Style.space(6)

  MouseArea {
    id: mouse
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    acceptedButtons: Qt.LeftButton
    onClicked: root.pet()
    onEntered: if (root.bar) root.bar.showTooltip(root, root.tooltip())
    onExited: if (root.bar) root.bar.hideTooltip(root)
  }

  Item {
    id: stage
    width: Style.space(20)
    height: Style.space(18)
    anchors.horizontalCenter: parent.horizontalCenter
    anchors.bottom: parent.bottom
    anchors.bottomMargin: Style.space(3)

    // dance / hop offset and tilt
    property real hop: 0
    property real tilt: 0
    transform: [
      Translate { y: stage.hop },
      Rotation { origin.x: stage.width / 2; origin.y: stage.height; angle: stage.tilt }
    ]

    SequentialAnimation {
      running: root.mood === "dancing"
      loops: Animation.Infinite
      onRunningChanged: if (!running) { stage.hop = 0; stage.tilt = 0 }
      ParallelAnimation {
        NumberAnimation { target: stage; property: "hop"; to: -Style.space(3); duration: 180; easing.type: Easing.OutQuad }
        NumberAnimation { target: stage; property: "tilt"; to: -8; duration: 180 }
      }
      NumberAnimation { target: stage; property: "hop"; to: 0; duration: 180; easing.type: Easing.InQuad }
      ParallelAnimation {
        NumberAnimation { target: stage; property: "hop"; to: -Style.space(3); duration: 180; easing.type: Easing.OutQuad }
        NumberAnimation { target: stage; property: "tilt"; to: 8; duration: 180 }
      }
      NumberAnimation { target: stage; property: "hop"; to: 0; duration: 180; easing.type: Easing.InQuad }
    }
    // a happy hop when petted or fed
    SequentialAnimation {
      id: happyHop
      NumberAnimation { target: stage; property: "hop"; to: -Style.space(5); duration: 140; easing.type: Easing.OutQuad }
      NumberAnimation { target: stage; property: "hop"; to: 0; duration: 220; easing.type: Easing.OutBounce }
    }
    Connections {
      target: root
      function onPettedChanged() { if (root.petted) happyHop.restart() }
      function onEatingChanged() { if (root.eating) happyHop.restart() }
    }

    // body
    Rectangle {
      id: body
      anchors.bottom: parent.bottom
      anchors.horizontalCenter: parent.horizontalCenter
      width: parent.width
      height: parent.height * breath
      radius: width * 0.42
      property real breath: 1
      color: root.mood === "hot" ? root.hotSkin
           : root.mood === "warm" ? Qt.tint(root.skin, Qt.rgba(1, 0.3, 0.2, 0.35))
           : root.skin
      opacity: root.mood === "tired" ? 0.7 : 1
      Behavior on color { ColorAnimation { duration: Style.duration(400) } }

      SequentialAnimation on breath {
        loops: Animation.Infinite
        NumberAnimation { to: 0.92; duration: root.asleep ? 1800 : 1100; easing.type: Easing.InOutSine }
        NumberAnimation { to: 1.0; duration: root.asleep ? 1800 : 1100; easing.type: Easing.InOutSine }
      }

      // little feet
      Repeater {
        model: 2
        Rectangle {
          required property int index
          width: body.width * 0.22; height: Style.space(3); radius: height / 2
          color: Qt.darker(body.color, 1.3)
          anchors.bottom: parent.bottom
          anchors.bottomMargin: -1
          x: index === 0 ? body.width * 0.16 : body.width * 0.62
        }
      }
    }

    // face
    Canvas {
      id: face
      anchors.fill: body
      property string mood: root.mood
      property real lid: 1          // 1 open, 0 closed (blinks)
      property real look: 0         // -1 left .. 1 right
      property real chew: 0
      onMoodChanged: requestPaint()
      onLidChanged: requestPaint()
      onLookChanged: requestPaint()
      onChewChanged: requestPaint()
      onWidthChanged: requestPaint()
      onHeightChanged: requestPaint()

      onPaint: {
        var c = getContext("2d")
        c.reset()
        var w = width, h = height
        var ink = Commons.Color.background
        c.strokeStyle = ink; c.fillStyle = ink
        c.lineWidth = Math.max(1.2, w * 0.08); c.lineCap = "round"
        var ey = h * 0.42, ex1 = w * 0.33 + look * w * 0.07, ex2 = w * 0.67 + look * w * 0.07
        var er = w * 0.085

        function eyeDot(x) { c.beginPath(); c.ellipse(x - er, ey - er * 1.25 * lid, er * 2, Math.max(0.6, er * 2.5 * lid)); c.fill() }
        function arcEye(x, up) { c.beginPath(); c.arc(x, ey + (up ? er : -er * 0.2), er * 1.2, up ? Math.PI * 1.15 : Math.PI * 0.15, up ? Math.PI * 1.85 : Math.PI * 0.85); c.stroke() }
        function line(x1, y1, x2, y2) { c.beginPath(); c.moveTo(x1, y1); c.lineTo(x2, y2); c.stroke() }

        if (mood === "sleeping") {
          line(ex1 - er, ey + er * 0.4, ex1 + er, ey + er * 0.4); line(ex2 - er, ey + er * 0.4, ex2 + er, ey + er * 0.4)
          c.beginPath(); c.ellipse(w * 0.46, h * 0.66, w * 0.08, h * 0.08); c.stroke()
        } else if (mood === "happy" || mood === "dancing") {
          arcEye(ex1, true); arcEye(ex2, true)
          c.beginPath(); c.arc(w * 0.5, h * 0.62, w * 0.13, Math.PI * 0.15, Math.PI * 0.85); c.stroke()
        } else if (mood === "eating") {
          arcEye(ex1, true); arcEye(ex2, true)
          var mh = h * (0.06 + 0.16 * chew)
          c.beginPath(); c.ellipse(w * 0.5 - w * 0.12, h * 0.66 - mh / 2, w * 0.24, mh); c.fill()
        } else if (mood === "hot") {
          eyeDot(ex1); eyeDot(ex2)
          c.beginPath(); c.ellipse(w * 0.42, h * 0.62, w * 0.16, h * 0.16); c.fill()   // panting
        } else if (mood === "tired") {
          line(ex1 - er, ey, ex1 + er, ey); line(ex2 - er, ey, ex2 + er, ey)
          eyeDot(ex1); eyeDot(ex2)
          line(w * 0.42, h * 0.68, w * 0.58, h * 0.68)
        } else {
          eyeDot(ex1); eyeDot(ex2)
          c.beginPath(); c.arc(w * 0.5, h * 0.6, w * 0.09, Math.PI * 0.2, Math.PI * 0.8); c.stroke()
        }
      }

      // blinking and glancing while awake
      Timer {
        interval: 2600 + Math.random() * 3000
        repeat: true
        running: root.mood === "chill" || root.mood === "warm" || root.mood === "tired" || root.mood === "hot"
        onTriggered: {
          interval = 2600 + Math.random() * 3000
          if (Math.random() < 0.35) face.look = Math.random() < 0.5 ? -1 : 1
          else if (Math.random() < 0.5) face.look = 0
          blink.restart()
        }
      }
      SequentialAnimation {
        id: blink
        NumberAnimation { target: face; property: "lid"; to: 0.1; duration: 70 }
        NumberAnimation { target: face; property: "lid"; to: 1; duration: 110 }
      }
      SequentialAnimation {
        running: root.mood === "eating"
        loops: Animation.Infinite
        onRunningChanged: if (!running) face.chew = 0
        NumberAnimation { target: face; property: "chew"; to: 1; duration: 130 }
        NumberAnimation { target: face; property: "chew"; to: 0; duration: 130 }
      }
      Behavior on look { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
    }

    // sweat drop
    Rectangle {
      id: sweat
      visible: root.mood === "hot"
      width: Style.space(3); height: Style.space(4); radius: width / 2
      color: "#7cc7ff"
      x: stage.width - width
      property real fall: 0
      y: Style.space(2) + fall
      opacity: 1 - fall / Style.space(10)
      NumberAnimation on fall { running: sweat.visible; loops: Animation.Infinite; from: 0; to: Style.space(10); duration: 900; easing.type: Easing.InQuad }
    }
  }

  // floating z / heart / "+1.2G"
  Text {
    id: zzz
    visible: root.mood === "sleeping"
    text: "z"
    textFormat: Text.PlainText
    color: root.fg
    font.family: root.bar ? root.bar.fontFamily : Style.font.family
    font.pixelSize: Style.font.caption
    font.bold: true
    x: parent.width - width - 1
    property real rise: 0
    y: Style.space(6) - rise
    opacity: 1 - rise / Style.space(8)
    NumberAnimation on rise { running: zzz.visible; loops: Animation.Infinite; from: 0; to: Style.space(8); duration: 1600 }
  }
  Text {
    id: float
    text: root.floater
    textFormat: Text.PlainText
    color: root.floater === "♥" ? "#ff5f8f" : root.fg
    font.family: root.bar ? root.bar.fontFamily : Style.font.family
    font.pixelSize: Style.font.caption
    font.bold: true
    anchors.horizontalCenter: parent.horizontalCenter
    property real rise: 0
    y: -rise
    opacity: 0
    ParallelAnimation {
      id: floatAnim
      NumberAnimation { target: float; property: "rise"; from: -Style.space(4); to: Style.space(6); duration: 1100; easing.type: Easing.OutCubic }
      SequentialAnimation {
        NumberAnimation { target: float; property: "opacity"; from: 0; to: 1; duration: 120 }
        PauseAnimation { duration: 600 }
        NumberAnimation { target: float; property: "opacity"; to: 0; duration: 380 }
      }
    }
  }
}
