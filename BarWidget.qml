import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// The bar icon. Owns no data: everything (fetching, merging, freshness) lives
// in the panel it hosts, which stays loaded for the shell session once it has
// been built.
//
// It is the /dev/null mark itself, two slashes, drawn as bar text in the
// bar's own font and slot: the brand survives at icon scale without an SVG
// illustration or a count beside it, so it reads as one more status icon.
// New commits tint it with the accent, a refresh that could not be read with
// the urgent colour, and the count and the reason stay in the tooltip and in
// the panel.
BarWidget {
  id: root
  moduleName: "io.github.ivozzz.devnull"

  // The two slashes of the dev-null.sh mark, in the font every other bar icon
  // is drawn with. JetBrains Mono has no single glyph with that shape, and the
  // brand rules out recolouring the SVG, so the mark here is type.
  readonly property string iconGlyph: "//"

  readonly property var panelItem: panelLoader.item
  readonly property bool opened: panelItem ? panelItem.opened === true : false
  readonly property bool popoutSwitchClosing: panelItem ? panelItem.popoutSwitchClosing === true : false

  // Accent for something new, urgent for a feed that could not be read at
  // all: without the old count, colour is what still tells an empty feed from
  // a failed one. A refresh that lost one user out of four keeps the plain
  // foreground; the panel's status line is where that belongs.
  readonly property bool failed: panelItem ? panelItem.hasFailures === true : false
  readonly property bool iconActive: panelItem
    ? (panelItem.hasFresh === true || ((panelItem.entries || []).length === 0 && failed))
    : false

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

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.iconGlyph
    slotSize: Style.bar.statusSlot
    activeColor: root.failed ? Commons.Color.urgent : Commons.Color.accent
    active: root.iconActive
    tooltipText: panelItem ? panelItem.tooltipText : "…"
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.MiddleButton) root.refresh()
      else root.togglePanel()
    }
  }
}
