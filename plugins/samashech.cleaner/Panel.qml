import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Cleaner: lists caches that are safe to delete, with their size, and clears
// the ones you tick. Scans only when the panel opens.
Panel {
  id: root
  moduleName: "samashech.cleaner"
  ipcTarget: "samashech.cleaner"

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  readonly property string helper: Qt.resolvedUrl("sweep").toString().replace(/^file:\/\//, "")
  readonly property color fg: root.barForeground
  readonly property string fontFamily: root.bar ? root.bar.fontFamily : Style.font.family

  // Display order and grouping. Items not found by the scan are hidden.
  readonly property var userOrder: ["uv", "mise", "brave", "vscode", "npm", "pip", "spotify", "aur",
                                    "devtools", "cargo", "chromium", "thumbs", "models", "trash"]
  readonly property var systemOrder: ["pacman", "coredumps", "journal"]
  // Off by default: these cost real time or data to get back.
  readonly property var optIn: ["models", "trash"]

  property var items: ({})        // id -> {bytes, running}
  property var picked: ({})       // id -> bool (user overrides)
  property var freed: ({})        // id -> bytes freed in the last clean
  property bool scanning: false
  property bool cleaning: false
  property real lastFreed: -1

  function isPicked(id) {
    if (!items[id] || items[id].running) return false
    return picked[id] !== undefined ? picked[id] : optIn.indexOf(id) < 0
  }
  function flip(id) {
    if (!items[id] || items[id].running || cleaning) return
    var p = Object.assign({}, picked); p[id] = !isPicked(id); picked = p
  }
  function present(order) { return order.filter(function(id) { return items[id] !== undefined }) }

  readonly property real selectedBytes: {
    var t = 0
    for (var id in items) if (isPicked(id)) t += items[id].bytes
    return t
  }
  readonly property real totalBytes: {
    var t = 0
    for (var id in items) t += items[id].bytes
    return t
  }

  function bytes(b) {
    if (b >= 1073741824) return strings.t("gb").arg(Commons.I18n.formatNumber(b / 1073741824, 1))
    return strings.t("mb").arg(Commons.I18n.formatNumber(Math.max(1, Math.round(b / 1048576)), 0))
  }

  function scan() {
    if (scanProc.running || cleaning) return
    scanning = true
    scanProc.running = true
  }

  function clean() {
    if (cleaning || scanning) return
    var ids = []
    for (var id in items) if (isPicked(id)) ids.push(id)
    if (ids.length === 0) return
    cleaning = true
    freed = ({})
    cleanProc.command = ["/usr/bin/python3", "-I", root.helper, "clean"].concat(ids)
    cleanProc.running = true
  }

  // sweep output is the only data source; accept known ids and bounded numbers.
  readonly property var knownIds: userOrder.concat(systemOrder)
  function parseScan(raw) {
    var next = {}
    var lines = String(raw || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var p = lines[i].split("\t")
      if (p.length === 4 && p[0] === "item" && knownIds.indexOf(p[1]) >= 0 && /^\d{1,15}$/.test(p[2]))
        next[p[1]] = { bytes: parseFloat(p[2]), running: p[3] === "running" }
    }
    items = next
    scanning = false
  }
  function parseClean(raw) {
    var f = {}, total = 0
    var lines = String(raw || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var p = lines[i].split("\t")
      if (p.length !== 3 || knownIds.indexOf(p[1]) < 0) continue
      if (p[0] === "done" && /^\d{1,15}$/.test(p[2])) { f[p[1]] = parseFloat(p[2]); total += f[p[1]] }
      else if (p[0] === "fail") f[p[1]] = -1
    }
    freed = f
    lastFreed = total
    // feed the bar pet, if it's installed (harmless no-op otherwise)
    if (total > 0) Quickshell.execDetached(["omarchy-shell", "samashech.pet", "feed", String(Math.round(total))])
    cleaning = false
    scan()
  }

  Process {
    id: scanProc
    command: ["/usr/bin/python3", "-I", root.helper, "scan"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.parseScan(text) }
  }
  Process {
    id: cleanProc
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.parseClean(text) }
  }

  onOpenedChanged: if (opened) { lastFreed = -1; freed = ({}); scan() }

  // ---------------------------------------------------------------- bar button
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰃢"
    tooltipText: ""
    onPressed: function(b) { root.toggle() }
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
        spacing: Style.space(10)

        // headline
        PlainText {
          width: parent.width
          font.pixelSize: Style.font.title
          font.bold: true
          text: root.cleaning ? strings.t("cleaning")
              : root.lastFreed >= 0 ? strings.t("freed").arg(root.bytes(root.lastFreed))
              : root.scanning && Object.keys(root.items).length === 0 ? strings.t("scanning")
              : root.totalBytes > 0 ? strings.t("canFree").arg(root.bytes(root.totalBytes))
              : strings.t("allClean")
        }
        PlainText {
          width: parent.width
          wrapMode: Text.WordWrap
          opacity: 0.6
          font.pixelSize: Style.font.caption
          text: strings.t("safeNote")
        }

        Flickable {
          id: flick
          width: parent.width
          height: Math.min(list.implicitHeight, Style.space(470))
          contentHeight: list.implicitHeight
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          interactive: contentHeight > height

          Column {
            id: list
            width: flick.width
            spacing: Style.space(2)

            PanelSectionHeader {
              visible: root.present(root.userOrder).length > 0
              text: strings.t("section.user")
              foreground: root.fg
              fontFamily: root.fontFamily
              bottomPadding: Style.space(4)
            }
            Repeater {
              model: root.present(root.userOrder)
              ItemRow { required property string modelData; itemId: modelData }
            }

            Item { width: 1; height: Style.space(8); visible: root.present(root.systemOrder).length > 0 }
            PanelSectionHeader {
              visible: root.present(root.systemOrder).length > 0
              text: strings.t("section.system")
              foreground: root.fg
              fontFamily: root.fontFamily
              bottomPadding: Style.space(4)
            }
            Repeater {
              model: root.present(root.systemOrder)
              ItemRow { required property string modelData; itemId: modelData }
            }
          }
        }

        PanelSeparator { foreground: root.fg }

        Button {
          width: parent.width
          text: root.cleaning ? strings.t("cleaning")
              : root.selectedBytes > 0 ? strings.t("cleanButton").arg(root.bytes(root.selectedBytes))
              : strings.t("nothingPicked")
          iconText: "󰃢"
          iconSpinning: root.cleaning
          bordered: true
          enabled: !root.cleaning && !root.scanning && root.selectedBytes > 0
          foreground: root.fg
          fontFamily: root.fontFamily
          onClicked: root.clean()
        }
      }
    }
  }

  // One tickable row: check, name + what it is, size (or what was freed).
  component ItemRow: Item {
    id: row
    property string itemId: ""
    readonly property var info: root.items[itemId] || ({ bytes: 0, running: false })
    readonly property bool on: root.isPicked(itemId)
    readonly property bool blocked: info.running
    readonly property var result: root.freed[itemId]

    width: list.width
    height: Math.max(Style.space(42), texts.implicitHeight + Style.space(10))
    opacity: blocked ? 0.5 : 1

    Rectangle {
      anchors.fill: parent
      radius: Style.space(6)
      color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, mouse.containsMouse && !row.blocked ? 0.08 : 0)
      Behavior on color { ColorAnimation { duration: Style.duration(100) } }
    }
    PlainText {
      id: check
      anchors.left: parent.left
      anchors.leftMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      font.pixelSize: Style.font.icon
      text: row.on ? "󰄲" : "󰄱"
      color: row.on ? Commons.Color.accent : root.fg
      opacity: row.on ? 1 : 0.5
    }
    Column {
      id: texts
      anchors.left: check.right
      anchors.leftMargin: Style.space(10)
      anchors.right: sizeLabel.left
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      PlainText {
        width: parent.width
        elide: Text.ElideRight
        text: strings.t("item." + row.itemId)
      }
      PlainText {
        width: parent.width
        elide: Text.ElideRight
        opacity: 0.55
        font.pixelSize: Style.font.caption
        text: row.blocked ? strings.t("closeFirst").arg(strings.t("app." + row.itemId))
            : row.result === -1 ? strings.t("failed." + (row.itemId === "pacman" || row.itemId === "coredumps" || row.itemId === "journal" ? "auth" : "busy"))
            : strings.t("desc." + row.itemId)
      }
    }
    PlainText {
      id: sizeLabel
      anchors.right: parent.right
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      font.bold: true
      text: root.bytes(row.info.bytes)
    }
    MouseArea {
      id: mouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: row.blocked ? Qt.ArrowCursor : Qt.PointingHandCursor
      onClicked: root.flip(row.itemId)
    }
  }

  component PlainText: Text {
    textFormat: Text.PlainText
    color: root.fg
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
  }
}
