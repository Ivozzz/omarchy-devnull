import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// The bar pill. Owns no data: everything (fetching, merging, freshness) lives
// in the panel it hosts, which stays loaded for the shell session once it has
// been built.
BarWidget {
  id: root
  moduleName: "Ivozzz.devnull"

  readonly property var panelItem: panelLoader.item
  readonly property bool opened: panelItem ? panelItem.opened === true : false
  readonly property bool popoutSwitchClosing: panelItem ? panelItem.popoutSwitchClosing === true : false

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  // Middle click asks for an unconditional refresh, past the quiet-path
  // rate guard the panel applies when it is merely opened.
  function refresh() {
    if (panelLoader.item && panelLoader.item.refresh) panelLoader.item.refresh(true)
  }

  function togglePanel() {
    if (panelLoader.item && panelLoader.item.toggle) panelLoader.item.toggle()
  }

  // Shape contract for shell.summon/hide/toggle routing (Bar.findPanelWidget
  // requires open/close/opened on the bar-widget root).
  function open() {
    if (panelLoader.item && panelLoader.item.openFromHotkey) panelLoader.item.openFromHotkey()
  }

  function close() {
    if (panelLoader.item && panelLoader.item.close) panelLoader.item.close()
  }

  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    // WidgetButton paints itself at opacity 0 unless `text` is non-empty;
    // labelVisible keeps its own label off, since the Row below draws the
    // glyph and the count itself.
    text: panelItem ? panelItem.barText : "–"
    labelVisible: false
    keepSpace: true
    fixedWidth: vertical ? barSize : horizontalContent.implicitWidth + Style.space(12)
    fixedHeight: vertical ? verticalContent.implicitHeight + Style.space(10) : barSize
    foreground: panelItem ? panelItem.barForeground : (root.bar ? root.bar.barForeground : Color.foreground)
    fontSize: Style.font.caption
    horizontalMargin: Style.space(6)
    // Accent only while something arrived since the last refresh: the number is
    // always the size of the merged feed, so a quiet panel and a busy one look
    // the same by accident otherwise.
    active: panelItem ? panelItem.hasFresh : false
    activeColor: Commons.Color.accent
    tooltipText: panelItem ? panelItem.tooltipText : "…"
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.MiddleButton) root.refresh()
      else root.togglePanel()
    }

    Row {
      id: horizontalContent
      visible: !button.vertical
      anchors.centerIn: parent
      spacing: Style.space(5)

      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: "\uf120"  // nf-fa-terminal
        textFormat: Text.PlainText
        color: button.active && button.useActiveColor ? button.activeColor : button.foreground
        font.family: button.fontFamily
        font.pixelSize: button.fontSize
        renderType: Text.NativeRendering
      }

      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: panelItem ? panelItem.barText : "–"
        textFormat: Text.PlainText
        color: button.active && button.useActiveColor ? button.activeColor : button.foreground
        font.family: button.fontFamily
        font.pixelSize: button.fontSize
        renderType: Text.NativeRendering
      }
    }

    Column {
      id: verticalContent
      visible: button.vertical
      anchors.centerIn: parent
      spacing: Style.space(2)

      Text {
        anchors.horizontalCenter: parent.horizontalCenter
        text: "\uf120"  // nf-fa-terminal
        textFormat: Text.PlainText
        color: button.active && button.useActiveColor ? button.activeColor : button.foreground
        font.family: button.fontFamily
        font.pixelSize: button.fontSize
        renderType: Text.NativeRendering
      }

      Text {
        anchors.horizontalCenter: parent.horizontalCenter
        text: panelItem ? panelItem.barText : "–"
        textFormat: Text.PlainText
        color: button.active && button.useActiveColor ? button.activeColor : button.foreground
        font.family: button.fontFamily
        font.pixelSize: button.fontSize
        renderType: Text.NativeRendering
      }
    }
  }
}