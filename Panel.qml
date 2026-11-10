import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui

Panel {
  id: root
  moduleName: "samashech.fans"
  ipcTarget: "samashech.fans"

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  readonly property string helper: Qt.resolvedUrl("fanctl").toString().replace(/^file:\/\//, "")
  property var fans: ({})
  property var profiles: []
  property string activeProfile: ""

  readonly property bool hasDriver: fans.backend !== undefined && fans.backend !== "none"

  function num(key) { var v = parseInt(fans[key]); return isNaN(v) ? 0 : v }
  function isAuto(f) { return num("fan" + f + "_mode") !== 1 }
  function pct(f) { return num("fan" + f + "_pct") }
  function rpmText(f) {
    var key = "fan" + f + "_rpm"
    return fans[key] === undefined ? "—" : strings.t("rpm").arg(Commons.I18n.formatNumber(num(key)))
  }
  function tempText(which) {
    var t = fans[which + "_temp"]
    if (t === "sleep") return strings.t("gpuSleeping")
    if (t === undefined) return ""
    return strings.t("temp").arg(Commons.I18n.formatNumber(parseInt(t)))
  }
  function fanTitle(f) {
    var name = strings.t(f === "1" ? "cpu" : "gpu")
    var temp = tempText(f === "1" ? "cpu" : "gpu")
    return temp ? strings.t("fanWithTemp").arg(name).arg(temp) : name
  }

  // fanctl output is the only data source; accept known keys with bounded values.
  function parse(raw) {
    var next = {}
    var lines = String(raw || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var p = lines[i].split("\t")
      if (p.length !== 2) continue
      var k = p[0], v = p[1].trim()
      if (/^fan[12]_(rpm|mode|pct)$/.test(k) && /^\d{1,6}$/.test(v)) next[k] = v
      else if (k === "cpu_temp" && /^\d{1,3}$/.test(v)) next[k] = v
      else if (k === "gpu_temp" && (/^\d{1,3}$/.test(v) || v === "sleep")) next[k] = v
      else if (k === "backend" && /^(hwmon|linuwu|none)$/.test(v)) next[k] = v
    }
    if (Object.keys(next).length > 0) fans = next
  }

  function parseProfiles(raw) {
    var list = [], active = ""
    var lines = String(raw || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var p = lines[i].trim().split("\t")
      if (!/^[a-z-]{1,32}$/.test(p[0])) continue
      list.push(p[0])
      if (p[1] === "1") active = p[0]
    }
    if (list.length > 0) { profiles = list; activeProfile = active }
  }

  function refresh() {
    if (!statusProc.running) statusProc.running = true
    if (opened && !profilesProc.running) profilesProc.running = true
  }

  function setFan(which, mode, value) {
    if (!hasDriver || actionProc.running) return
    var w = (which === "1" || which === "2") ? which : "all"
    var cmd = ["bash", helper, "set", w, mode === "auto" ? "auto" : "manual"]
    if (mode !== "auto") cmd.push(String(Math.max(30, Math.min(100, Math.round(value)))))
    actionProc.command = cmd
    actionProc.running = true
  }

  function toggleMax() {
    if (!hasDriver || actionProc.running) return
    actionProc.command = ["bash", helper, "toggle"]
    actionProc.running = true
  }

  function setProfile(p) {
    if (profiles.indexOf(p) < 0 || profileProc.running) return
    profileProc.command = ["omarchy-powerprofiles-set", "autodetect", p]
    profileProc.running = true
  }

  function profileIcon(name) {
    if (name === "power-saver") return "󰌪"
    if (name === "balanced") return "󰊚"
    if (name === "performance") return "󰓅"
    return "󰂄"
  }

  onOpenedChanged: if (opened) refresh()

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Process {
    id: statusProc
    command: ["bash", root.helper, "status"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.parse(text) }
  }
  Process {
    id: profilesProc
    command: ["omarchy-powerprofiles-list", "--active-state"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.parseProfiles(text) }
  }
  Process { id: actionProc; onExited: root.refresh() }
  Process { id: profileProc; onExited: { profilesProc.running = true } }

  Timer { interval: root.opened ? 2000 : 15000; running: true; repeat: true; triggeredOnStart: true; onTriggered: root.refresh() }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: (root.isAuto(1) && root.isAuto(2)) ? "󰈐" : "󰠝"
    tooltipText: ""
    onPressed: function(b) {
      if (b === Qt.RightButton) root.toggleMax()
      else root.toggle()
    }
  }

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
        spacing: Style.space(14)

        Row {
          spacing: Style.space(12)
          PlainText { text: "󰈐"; font.pixelSize: Style.font.display }
          PlainText { text: strings.t("title"); font.pixelSize: Style.font.title; font.bold: true; anchors.verticalCenter: parent.verticalCenter }
        }

        PlainText {
          visible: root.fans.backend === "none"
          width: parent.width
          wrapMode: Text.WordWrap
          opacity: 0.8
          text: strings.t("noDriver")
        }

        Row {
          id: allRow
          visible: root.hasDriver
          width: parent.width
          spacing: Style.space(6)
          readonly property real cell: (width - spacing) / 2
          Button {
            width: allRow.cell; text: strings.t("auto"); iconText: "󰁪"; bordered: true
            foreground: root.bar.foreground; fontFamily: root.bar.fontFamily
            active: root.isAuto(1) && root.isAuto(2)
            onClicked: root.setFan("all", "auto", 0)
          }
          Button {
            width: allRow.cell; text: strings.t("max"); iconText: "󰓅"; bordered: true
            foreground: root.bar.foreground; fontFamily: root.bar.fontFamily
            active: !root.isAuto(1) && !root.isAuto(2) && root.pct(1) >= 99 && root.pct(2) >= 99
            onClicked: root.setFan("all", "manual", 100)
          }
        }

        Repeater {
          model: ["1", "2"]
          Column {
            required property string modelData
            width: column.width
            spacing: Style.space(6)
            Item {
              width: parent.width
              implicitHeight: fanLabel.implicitHeight
              PlainText { id: fanLabel; text: root.fanTitle(modelData); font.bold: true }
              PlainText {
                anchors.right: parent.right
                opacity: 0.7
                text: root.rpmText(modelData) + " · " + (root.isAuto(modelData) ? strings.t("auto") : Commons.I18n.formatNumber(root.pct(modelData)) + "%")
              }
            }
            PanelSlider {
              visible: root.hasDriver
              width: parent.width
              bar: root.bar
              minimum: 30; maximum: 100; step: 5; integer: true
              value: root.isAuto(modelData) ? 30 : root.pct(modelData)
              onReleased: function(v) { root.setFan(modelData, "manual", v) }
            }
          }
        }

        PanelSeparator { foreground: root.bar.foreground; visible: root.profiles.length > 0 }
        PanelSectionHeader {
          visible: root.profiles.length > 0
          text: strings.t("profile"); foreground: root.bar.foreground; fontFamily: root.bar.fontFamily
        }

        Row {
          id: profileRow
          visible: root.profiles.length > 0
          width: parent.width
          spacing: Style.space(6)
          readonly property real cell: root.profiles.length > 0 ? (width - spacing * (root.profiles.length - 1)) / root.profiles.length : 0
          Repeater {
            model: root.profiles
            Button {
              required property var modelData
              width: profileRow.cell
              iconText: root.profileIcon(String(modelData))
              text: String(modelData)
              fontSize: Style.font.bodySmall
              foreground: root.bar.foreground; fontFamily: root.bar.fontFamily
              bordered: true
              active: root.activeProfile === modelData
              onClicked: root.setProfile(String(modelData))
            }
          }
        }
      }
    }
  }

  component PlainText: Text {
    textFormat: Text.PlainText
    color: root.bar ? root.bar.foreground : Commons.Color.foreground
    font.family: root.bar ? root.bar.fontFamily : Style.font.family
    font.pixelSize: Style.font.bodySmall
  }
}
