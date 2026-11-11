import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Keyboard Sync: Acer Predator 4-zone keyboard lighting. Three layers, any mix:
// audio sync, a ripple as you type, and a flash when a notification arrives.
// All device work happens in the `kbsync` helper; this widget starts/stops it,
// edits its settings, forwards notifications, and shows the live zone colors.
Panel {
  id: root
  moduleName: "samashech.audio-sync"
  ipcTarget: "samashech.audio-sync"
  manageIpc: false

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  readonly property string python: "/usr/bin/python3"
  readonly property string helper: Qt.resolvedUrl("kbsync").toString().replace(/^file:\/\//, "")
  readonly property var modes: ["pulse", "spectrum", "wave", "theme"]
  readonly property var idles: ["theme", "white", "off"]
  readonly property var ripples: ["theme", "rainbow", "white"]
  readonly property var soundKinds: ["blue", "brown", "typewriter"]
  readonly property string soundHelper: Qt.resolvedUrl("keysound").toString().replace(/^file:\/\//, "")

  property bool loaded: false
  property bool hasDevice: true
  property bool keyboardReadable: true
  property bool enabled: false        // audio sync
  property bool typing: false         // typing ripple
  property bool notify: false         // notification flash
  property string mode: "pulse"
  property int sensitivity: 100
  property int brightness: 100
  property string idle: "theme"
  property string ripple: "theme"
  property string savedAccent: ""
  property bool sounds: false        // mechanical key sounds (separate `keysound` process)
  property string sound: "blue"
  property int volume: 60

  readonly property bool anyOn: enabled || typing || notify

  // Live state from the daemon.
  property var zones: ["#000000", "#000000", "#000000", "#000000"]
  property real level: 0
  readonly property bool running: daemon.running

  readonly property string themeAccent: String(Commons.Color.accent).slice(0, 7).toLowerCase()

  // ---------------------------------------------------------------- settings
  property var queue: []
  function setOption(key, value) {
    queue = queue.concat([[key, String(value)]])
    pump()
  }
  function pump() {
    if (setProc.running || queue.length === 0) return
    var next = queue[0]
    queue = queue.slice(1)
    setProc.command = [python, "-I", helper, "set", next[0], next[1]]
    setProc.running = true
  }

  function setLayer(key, on) {
    if (!hasDevice && on) return
    if (key === "enabled") enabled = on
    else if (key === "typing") typing = on
    else if (key === "notify") notify = on
    else if (key === "sounds") { sounds = on; setOption(key, on ? "true" : "false"); return }
    else return
    setOption(key, on ? "true" : "false")
  }
  function toggleSync() { setLayer("enabled", !enabled) }
  function setMode(m) { if (modes.indexOf(m) >= 0) { mode = m; setOption("mode", m) } }
  function setSound(v) {
    if (soundKinds.indexOf(v) < 0) return
    sound = v
    setOption("sound", v)
    demoProc.running = false
    demoProc.command = [python, "-I", soundHelper, "demo", v]
    demoProc.running = true
  }
  function setRipple(v) { if (ripples.indexOf(v) >= 0) { ripple = v; setOption("ripple", v) } }
  function setIdle(v) {
    if (idles.indexOf(v) < 0) return
    idle = v
    setOption("idle", v)
    if (!running) restoreProc.running = true
  }

  function syncAccent() {
    if (!loaded || !/^#[0-9a-f]{6}$/.test(themeAccent) || themeAccent === savedAccent) return
    savedAccent = themeAccent
    setOption("accent", themeAccent)
    if (!running && idle === "theme") restoreProc.running = true
  }
  onThemeAccentChanged: syncAccent()

  // Flash on demand (IPC `flash`). Real notifications are picked up by the
  // daemon itself from the session bus. urgency: 0 low, 1 normal, 2 critical.
  function flash(urgency) {
    if (!notify || !daemon.running) return
    var u = Math.max(0, Math.min(2, parseInt(urgency) || 0))
    daemon.write("notify " + u + "\n")
  }

  // kbsync output is the only data source; accept known keys with bounded values.
  function parseConfig(raw) {
    var lines = String(raw || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var p = lines[i].split("\t")
      if (p.length !== 2) continue
      var k = p[0], v = p[1].trim()
      if ((k === "enabled" || k === "typing" || k === "notify" || k === "sounds") && (v === "true" || v === "false")) root[k] = v === "true"
      else if (k === "sound" && soundKinds.indexOf(v) >= 0) sound = v
      else if (k === "volume" && /^\d{1,3}$/.test(v)) volume = parseInt(v)
      else if (k === "mode" && modes.indexOf(v) >= 0) mode = v
      else if (k === "idle" && idles.indexOf(v) >= 0) idle = v
      else if (k === "ripple" && ripples.indexOf(v) >= 0) ripple = v
      else if (k === "sensitivity" && /^\d{1,3}$/.test(v)) sensitivity = parseInt(v)
      else if (k === "brightness" && /^\d{1,3}$/.test(v)) brightness = parseInt(v)
      else if (k === "accent" && /^#[0-9a-f]{6}$/.test(v)) savedAccent = v
    }
    loaded = true
    syncAccent()
  }

  function parseProbe(raw) {
    var t = String(raw || "")
    hasDevice = t.indexOf("device\tok") >= 0
    keyboardReadable = t.indexOf("keyboard\tok") >= 0
  }

  function parseLine(line) {
    var p = String(line).split("\t")
    if (p.length === 3 && p[0] === "s" && p[1] === "typing") {
      keyboardReadable = p[2] === "ok"
      return
    }
    if (p.length !== 6 || p[0] !== "f" || !/^\d{1,3}$/.test(p[1])) return
    var next = []
    for (var i = 2; i < 6; i++) {
      if (!/^#[0-9a-f]{6}$/.test(p[i])) return
      next.push(p[i])
    }
    zones = next
    level = Math.min(100, parseInt(p[1])) / 100
  }

  // Brightest zone, pushed to full value so the bar icon stays vivid; level drives its opacity.
  function iconColor() {
    var best = null, bestV = -1
    for (var i = 0; i < zones.length; i++) {
      var c = Qt.color(zones[i])
      var v = Math.max(c.r, c.g, c.b)
      if (v > bestV) { bestV = v; best = c }
    }
    if (!best || bestV < 0.02) return root.barForeground
    return Qt.rgba(best.r / bestV, best.g / bestV, best.b / bestV, 0.45 + 0.55 * level)
  }

  function modeIcon(m) {
    if (m === "spectrum") return "󰺢"
    if (m === "wave") return "󰖧"
    if (m === "theme") return "󰏘"
    return "󰝚"
  }

  function statusText() {
    if (!running) return strings.t("off")
    if (enabled) return strings.t("listening")
    return strings.t("active")
  }

  // ---------------------------------------------------------------- processes
  Process {
    id: probeProc
    running: true
    command: [root.python, "-I", root.helper, "probe"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.parseProbe(text) }
  }
  Process {
    id: configProc
    running: true
    command: [root.python, "-I", root.helper, "config"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.parseConfig(text) }
  }
  Process { id: setProc; onExited: root.pump() }
  Process { id: restoreProc; command: [root.python, "-I", root.helper, "restore"] }

  Process {
    id: daemon
    command: [root.python, "-I", root.helper, "run"]
    running: root.loaded && root.hasDevice && root.anyOn
    stdinEnabled: true
    stdout: SplitParser { onRead: function(line) { root.parseLine(line) } }
    onRunningChanged: {
      if (running) return
      root.level = 0
      root.zones = ["#000000", "#000000", "#000000", "#000000"]
      // The daemon restores the idle color itself; this covers a hard kill.
      if (!root.anyOn) restoreProc.running = true
      else retry.restart()
    }
  }
  // Key sounds run on their own so they work with any keyboard and without the RGB device.
  Process {
    id: soundProc
    command: [root.python, "-I", root.soundHelper, "run"]
    running: root.loaded && root.sounds
    onRunningChanged: if (!running && root.sounds) soundRetry.restart()
  }
  Timer {
    id: soundRetry
    interval: 3000
    onTriggered: if (root.sounds && !soundProc.running) soundProc.running = true
  }
  Process { id: demoProc }

  // If the daemon dies while a layer is on (audio server restart, etc.), try again.
  Timer {
    id: retry
    interval: 3000
    onTriggered: if (root.anyOn && root.hasDevice && !daemon.running) daemon.running = true
  }

  ShellIpc {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function toggleSync(): void { root.toggleSync() }
    function on(): void { root.setLayer("enabled", true) }
    function off(): void { root.setLayer("enabled", false) }
    function setMode(mode: string): void { root.setMode(mode) }
    function toggleTyping(): void { root.setLayer("typing", !root.typing) }
    function toggleNotify(): void { root.setLayer("notify", !root.notify) }
    function flash(urgency: string): void { root.flash(urgency) }
    function toggleSounds(): void { root.setLayer("sounds", !root.sounds) }
    function setSound(kind: string): void { root.setSound(kind) }
  }

  // ---------------------------------------------------------------- bar button
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰌌"
    foreground: root.running ? root.iconColor() : root.barForeground
    dimmed: !root.hasDevice
    tooltipText: ""
    onPressed: function(b) {
      if (b === Qt.RightButton || b === Qt.MiddleButton) root.toggleSync()
      else root.toggle()
    }
  }

  // ---------------------------------------------------------------- panel
  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: panel.loadedContent
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(panel.loadedContentHeight)

    content: PanelKeyCatcher {
      anchors.fill: parent
      implicitHeight: column.implicitHeight
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(14)

        Item {
          width: parent.width
          implicitHeight: headerRow.implicitHeight
          Row {
            id: headerRow
            spacing: Style.space(12)
            PlainText { text: "󰌌"; font.pixelSize: Style.font.display }
            PlainText {
              text: strings.t("title")
              font.pixelSize: Style.font.title
              font.bold: true
              anchors.verticalCenter: parent.verticalCenter
            }
          }
          PlainText {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            opacity: 0.7
            text: root.statusText()
          }
        }

        PlainText {
          visible: !root.hasDevice
          width: parent.width
          wrapMode: Text.WordWrap
          opacity: 0.8
          text: strings.t("noDevice")
        }

        // Live keyboard: one tile per zone, left to right, exactly what the keys show.
        Row {
          id: zoneRow
          visible: root.hasDevice
          width: parent.width
          spacing: Style.space(6)
          readonly property real cell: (width - spacing * 3) / 4
          Repeater {
            model: 4
            Rectangle {
              required property int index
              width: zoneRow.cell
              height: Style.space(26)
              radius: Style.cornerRadius > 0 ? Style.space(4) : 0
              color: root.running ? root.zones[index] : Qt.rgba(1, 1, 1, 0.04)
              border.width: 1
              border.color: Qt.rgba(root.barForeground.r, root.barForeground.g, root.barForeground.b, 0.18)
            }
          }
        }

        Toggle {
          visible: root.hasDevice
          width: parent.width
          label: strings.t("syncToAudio")
          description: strings.t("syncDescription")
          checked: root.enabled
          foreground: root.barForeground
          fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
          onClicked: root.setLayer("enabled", !root.enabled)
        }
        Toggle {
          visible: root.hasDevice
          width: parent.width
          label: strings.t("typingRipple")
          description: root.keyboardReadable ? strings.t("typingDescription") : strings.t("typingNoAccess")
          checked: root.typing
          foreground: root.barForeground
          fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
          onClicked: root.setLayer("typing", !root.typing)
        }
        Toggle {
          visible: root.hasDevice
          width: parent.width
          label: strings.t("notifyFlash")
          description: strings.t("notifyDescription")
          checked: root.notify
          foreground: root.barForeground
          fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
          onClicked: root.setLayer("notify", !root.notify)
        }
        Toggle {
          width: parent.width
          label: strings.t("keySounds")
          description: strings.t("keySoundsDescription")
          checked: root.sounds
          foreground: root.barForeground
          fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
          onClicked: root.setLayer("sounds", !root.sounds)
        }

        PanelSeparator { foreground: root.barForeground; visible: root.hasDevice }
        PanelSectionHeader {
          visible: root.hasDevice
          text: strings.t("mode"); foreground: root.barForeground
          fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
        }
        Row {
          id: modeRow
          visible: root.hasDevice
          width: parent.width
          spacing: Style.space(6)
          readonly property real cell: (width - spacing * (root.modes.length - 1)) / root.modes.length
          Repeater {
            model: root.modes
            Button {
              required property var modelData
              width: modeRow.cell
              iconText: root.modeIcon(String(modelData))
              text: strings.t("mode." + modelData)
              tooltipText: strings.t("mode." + modelData + ".tip")
              fontSize: Style.font.bodySmall
              foreground: root.barForeground
              fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
              bordered: true
              active: root.mode === modelData
              onClicked: root.setMode(String(modelData))
            }
          }
        }

        Repeater {
          model: root.hasDevice ? [
            { key: "sensitivity", min: 25, max: 200, step: 5 },
            { key: "brightness", min: 10, max: 100, step: 5 }
          ] : []
          Column {
            required property var modelData
            width: column.width
            spacing: Style.space(6)
            Item {
              width: parent.width
              implicitHeight: sliderLabel.implicitHeight
              PlainText { id: sliderLabel; text: strings.t(modelData.key); font.bold: true }
              PlainText {
                anchors.right: parent.right
                opacity: 0.7
                text: strings.t("percent").arg(Commons.I18n.formatNumber(slider.liveValue))
              }
            }
            PanelSlider {
              id: slider
              width: parent.width
              bar: root.bar
              minimum: modelData.min; maximum: modelData.max; step: modelData.step; integer: true
              value: modelData.key === "sensitivity" ? root.sensitivity : root.brightness
              onReleased: function(v) {
                var n = Math.round(v)
                if (modelData.key === "sensitivity") root.sensitivity = n
                else root.brightness = n
                root.setOption(modelData.key, n)
              }
            }
          }
        }

        PanelSeparator { foreground: root.barForeground; visible: root.hasDevice }
        Chips {
          visible: root.hasDevice
          title: strings.t("rippleColor")
          options: root.ripples
          prefix: "ripple."
          value: root.ripple
          onPicked: function(v) { root.setRipple(v) }
        }
        Chips {
          visible: root.hasDevice
          title: strings.t("idle")
          options: root.idles
          prefix: "idle."
          value: root.idle
          onPicked: function(v) { root.setIdle(v) }
        }

        PanelSeparator { foreground: root.barForeground; visible: root.sounds }
        Chips {
          visible: root.sounds
          title: strings.t("soundKind")
          options: root.soundKinds
          prefix: "sound."
          value: root.sound
          onPicked: function(v) { root.setSound(v) }
        }
        Column {
          visible: root.sounds
          width: column.width
          spacing: Style.space(6)
          Item {
            width: parent.width
            implicitHeight: volLabel.implicitHeight
            PlainText { id: volLabel; text: strings.t("volume"); font.bold: true }
            PlainText {
              anchors.right: parent.right
              opacity: 0.7
              text: strings.t("percent").arg(Commons.I18n.formatNumber(volSlider.liveValue))
            }
          }
          PanelSlider {
            id: volSlider
            width: parent.width
            bar: root.bar
            minimum: 5; maximum: 100; step: 5; integer: true
            value: root.volume
            onReleased: function(v) { root.volume = Math.round(v); root.setOption("volume", root.volume) }
          }
        }
      }
    }
  }

  // A titled row of pick-one buttons.
  component Chips: Column {
    id: chips
    property string title: ""
    property var options: []
    property string prefix: ""
    property string value: ""
    signal picked(string value)
    width: parent ? parent.width : 0
    spacing: Style.space(8)
    PanelSectionHeader {
      text: chips.title; foreground: root.barForeground
      fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
    }
    Row {
      id: chipRow
      width: parent.width
      spacing: Style.space(6)
      readonly property real cell: (width - spacing * (chips.options.length - 1)) / Math.max(1, chips.options.length)
      Repeater {
        model: chips.options
        Button {
          required property var modelData
          width: chipRow.cell
          text: strings.t(chips.prefix + modelData)
          fontSize: Style.font.bodySmall
          foreground: root.barForeground
          fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
          bordered: true
          active: chips.value === modelData
          onClicked: chips.picked(String(modelData))
        }
      }
    }
  }

  component PlainText: Text {
    textFormat: Text.PlainText
    color: root.barForeground
    font.family: root.bar ? root.bar.fontFamily : Style.font.family
    font.pixelSize: Style.font.bodySmall
  }
}
