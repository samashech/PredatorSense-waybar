import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Tasks: a minimal task manager. Top 5 apps by CPU %, RAM and GPU % + VRAM.
// Sampling only happens while the panel is open.
Panel {
  id: root
  moduleName: "samashech.tasks"
  ipcTarget: "samashech.tasks"

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  readonly property string helper: Qt.resolvedUrl("topproc").toString().replace(/^file:\/\//, "")
  readonly property color fg: root.barForeground
  readonly property string fontFamily: root.bar ? root.bar.fontFamily : Style.font.family

  property string tab: "cpu"
  property var cpuRows: []     // [{name, count, value}]
  property var memRows: []
  property var gpuRows: []     // [{name, count, value, vram, dev}]
  property real cpuTotal: 0
  property real memUsed: 0
  property real memTotal: 0
  property string nvidia: ""   // "" unknown, "sleep", or "util|used|total"
  property bool loaded: false

  readonly property var rows: tab === "cpu" ? cpuRows : (tab === "mem" ? memRows : gpuRows)
  readonly property real maxValue: {
    var m = 0
    for (var i = 0; i < rows.length; i++) m = Math.max(m, rows[i].value)
    return m
  }

  function num(v, d) { return Commons.I18n.formatNumber(v, d) }
  function bytes(b) {
    if (b >= 1073741824) return strings.t("gb").arg(num(b / 1073741824, 1))
    return strings.t("mb").arg(num(Math.round(b / 1048576), 0))
  }
  function mib(m) {
    if (m >= 1024) return strings.t("gb").arg(num(m / 1024, 1))
    return strings.t("mb").arg(num(Math.round(m), 0))
  }
  function pct(v) { return strings.t("pct").arg(num(v, v < 10 ? 1 : 0)) }

  function valueText(r) {
    if (tab === "mem") return bytes(r.value)
    if (tab === "gpu") return pct(r.value) + "  ·  " + mib(r.vram)
    return pct(r.value)
  }

  // topproc output is the only data source; accept known shapes with bounded values.
  function parse(raw) {
    var lines = String(raw || "").split("\n")
    var c = [], m = [], g = [], nv = ""
    for (var i = 0; i < lines.length; i++) {
      var p = lines[i].split("\t")
      var name = p.length > 1 ? p[1].slice(0, 32) : ""
      if (p[0] === "sys") {
        if (p[1] === "cpu" && /^[\d.]{1,6}$/.test(p[2])) cpuTotal = parseFloat(p[2])
        else if (p[1] === "mem" && /^\d{1,16}$/.test(p[2]) && /^\d{1,16}$/.test(p[3])) { memUsed = parseFloat(p[2]); memTotal = parseFloat(p[3]) }
        else if (p[1] === "nvidia" && p[2] === "sleep") nv = "sleep"
        else if (p[1] === "nvidia" && p.length === 5 && /^\d{1,6}$/.test(p[2] + p[3] + p[4])) nv = p[2] + "|" + p[3] + "|" + p[4]
      } else if (p[0] === "cpu" && p.length === 4 && /^\d{1,5}$/.test(p[2]) && /^[\d.]{1,6}$/.test(p[3])) {
        c.push({ name: name, count: parseInt(p[2]), value: parseFloat(p[3]) })
      } else if (p[0] === "mem" && p.length === 4 && /^\d{1,5}$/.test(p[2]) && /^\d{1,16}$/.test(p[3])) {
        m.push({ name: name, count: parseInt(p[2]), value: parseFloat(p[3]) })
      } else if (p[0] === "gpu" && p.length === 6 && /^\d{1,5}$/.test(p[2]) && /^[\d.]{1,6}$/.test(p[3])
                 && /^\d{1,8}$/.test(p[4]) && (p[5] === "nvidia" || p[5] === "intel")) {
        g.push({ name: name, count: parseInt(p[2]), value: parseFloat(p[3]), vram: parseInt(p[4]), dev: p[5] })
      }
    }
    cpuRows = c.slice(0, 5); memRows = m.slice(0, 5); gpuRows = g.slice(0, 5)
    nvidia = nv
    loaded = true
  }

  function summary() {
    if (tab === "cpu") return strings.t("cpuTotal").arg(pct(cpuTotal))
    if (tab === "mem") return strings.t("memTotal").arg(bytes(memUsed)).arg(bytes(memTotal))
    if (nvidia === "sleep") return strings.t("nvidiaSleep")
    if (nvidia !== "") {
      var p = nvidia.split("|")
      return strings.t("nvidiaTotal").arg(pct(parseFloat(p[0]))).arg(mib(parseFloat(p[1]))).arg(mib(parseFloat(p[2])))
    }
    return ""
  }

  Process {
    id: sampler
    command: ["/usr/bin/python3", "-I", root.helper]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.parse(text) }
  }
  Timer {
    interval: 2000
    repeat: true
    running: root.opened
    triggeredOnStart: true
    onTriggered: if (!sampler.running) sampler.running = true
  }

  // ---------------------------------------------------------------- bar button
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰍛"
    tooltipText: ""
    onPressed: function(b) {
      if (b === Qt.RightButton) Quickshell.execDetached(["omarchy-launch-or-focus-tui", "btop"])
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
    contentWidth: panel.fittedContentWidth(Style.space(360))
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
        spacing: Style.space(12)

        ButtonGroup {
          id: tabs
          width: parent.width
          options: [
            { value: "cpu", label: strings.t("tab.cpu"), icon: "󰻠" },
            { value: "mem", label: strings.t("tab.mem"), icon: "󰘚" },
            { value: "gpu", label: strings.t("tab.gpu"), icon: "󰢮" }
          ]
          value: root.tab
          foreground: root.fg
          fontFamily: root.fontFamily
          fontSize: Style.font.bodySmall
          onChanged: function(v) { root.tab = v }
        }

        PlainText {
          visible: !root.loaded || root.rows.length === 0
          width: parent.width
          horizontalAlignment: Text.AlignHCenter
          opacity: 0.6
          topPadding: Style.space(8)
          bottomPadding: Style.space(8)
          text: !root.loaded ? strings.t("measuring") : strings.t("idle")
        }

        Repeater {
          model: root.rows
          Item {
            required property var modelData
            width: column.width
            height: Style.space(30)
            // usage bar behind the row
            Rectangle {
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              height: parent.height
              radius: Style.space(6)
              width: root.maxValue > 0 ? Math.max(Style.space(4), parent.width * modelData.value / root.maxValue) : 0
              color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.08)
              Behavior on width { NumberAnimation { duration: Style.duration(180); easing.type: Easing.OutCubic } }
            }
            Row {
              anchors.left: parent.left
              anchors.leftMargin: Style.space(8)
              anchors.right: valueLabel.left
              anchors.rightMargin: Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(6)
              PlainText {
                id: nameLabel
                text: modelData.name
                elide: Text.ElideRight
                width: Math.min(implicitWidth, parent.width - countLabel.width - tag.width - parent.spacing * 2)
              }
              PlainText {
                id: countLabel
                visible: modelData.count > 1
                width: visible ? implicitWidth : 0
                text: strings.t("count").arg(Commons.I18n.formatNumber(modelData.count))
                opacity: 0.45
                font.pixelSize: Style.font.caption
                anchors.verticalCenter: parent.verticalCenter
              }
              PlainText {
                id: tag
                visible: root.tab === "gpu"
                width: visible ? implicitWidth : 0
                text: modelData.dev === "nvidia" ? "RTX" : "iGPU"
                opacity: 0.45
                font.pixelSize: Style.font.caption
                anchors.verticalCenter: parent.verticalCenter
              }
            }
            PlainText {
              id: valueLabel
              anchors.right: parent.right
              anchors.rightMargin: Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
              text: root.valueText(modelData)
              font.bold: true
            }
          }
        }

        PanelSeparator { foreground: root.fg; visible: root.summary() !== "" }
        PlainText {
          visible: text !== ""
          width: parent.width
          wrapMode: Text.WordWrap
          opacity: 0.6
          font.pixelSize: Style.font.caption
          text: root.summary()
        }
      }
    }
  }

  component PlainText: Text {
    textFormat: Text.PlainText
    color: root.fg
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
  }
}
