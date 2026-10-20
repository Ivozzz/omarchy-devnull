import QtQuick
import qs.Commons

// The /dev/null mark — the two slashes from https://dev-null.sh/brand. The
// brand ships one file per background and forbids recolouring the mark, so
// both variants live in assets/ and the one drawn follows the colour of the
// label the mark sits next to.
Item {
  id: root

  // Square box the SVG is drawn in. The slashes fill about 39/45 of it, so an
  // 18px box paints the mark at just over the brand's 16px floor.
  property real size: Style.bar.iconCanvas
  // Colour of the text beside the mark. Read for its luminance only.
  property color surroundingColor: Commons.Color.bar.text

  readonly property real luminance: 0.2126 * surroundingColor.r
    + 0.7152 * surroundingColor.g
    + 0.0722 * surroundingColor.b
  readonly property bool onDarkBackground: luminance > 0.5
  readonly property url source: Qt.resolvedUrl(onDarkBackground
    ? "assets/dev-null-mark-on-dark.svg"
    : "assets/dev-null-mark-on-light.svg")

  implicitWidth: Math.max(1, Math.round(size))
  implicitHeight: implicitWidth

  Image {
    anchors.fill: parent
    source: root.source
    fillMode: Image.PreserveAspectFit
    smooth: true
    // Rasterise at the pixel size it is painted at, so the outlined slash
    // keeps its edge on HiDPI instead of being upscaled from 45px.
    sourceSize.width: Math.max(1, Math.ceil(width * Screen.devicePixelRatio))
    sourceSize.height: Math.max(1, Math.ceil(height * Screen.devicePixelRatio))
    asynchronous: false
  }
}
