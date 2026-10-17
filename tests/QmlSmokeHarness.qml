import Quickshell
import QtQuick
import "DevNull" as DevNull
import "DevNull/Model.js" as Model

// Load-time smoke test: both plugin entry points are compiled and
// instantiated for real, and the display strings they derive from a hostile
// response are checked for the one thing that must never survive into a Text
// or a tooltip.
//
// Run with tests/qml-smoke.test.sh, which supplies the import path.
ShellRoot {
  id: shell

  property int failures: 0

  function expect(name, ok, detail) {
    if (ok) {
      console.log("ok - " + name)
      return
    }
    failures++
    console.warn("DEVNULL_SMOKE_FAIL " + name + (detail ? " :: " + detail : ""))
  }

  // Enough of the bar host for a widget and its panel to construct: the panel
  // reads foreground, font, and position off it, and offers it the popout
  // handoff callbacks.
  QtObject {
    id: fakeBar
    property color foreground: "#ffffff"
    property color barForeground: "#ffffff"
    property color urgent: "#ff0000"
    property bool vertical: false
    property int barSize: 26
    property string fontFamily: "monospace"
    property string position: "top"
    property var activePopout: null
    property bool foregroundAnimationEnabled: true

    function run(command) {}
    function moduleWidgets(id) { return [] }
    function switchPanelFrom(key, direction) { return false }
    function setCenterHoverRevealSuppressed(value) {}
    function requestPopout(key) {}
    function releasePopout(key) {}
    function hideTooltip(target) {}
  }

  Item {
    id: holder
    width: 10
    height: 10

    DevNull.BarWidget {
      id: widget
      moduleName: "io.github.ivozzz.devnull"
      bar: fakeBar
    }

    // Same widget with the watchlist explicitly emptied.
    DevNull.BarWidget {
      id: emptyWidget
      moduleName: "io.github.ivozzz.devnull"
      bar: fakeBar
      settings: ({ watch: "" })
    }
  }

  Timer {
    interval: 2500
    running: true
    onTriggered: {
      console.log("DEVNULL_SMOKE_TIMEOUT")
      Qt.quit()
    }
  }

  Component.onCompleted: Qt.callLater(run)

  function run() {
    var panel = widget.panelItem
    var emptyPanel = emptyWidget.panelItem
    shell.expect("panel loads", !!panel)
    if (!panel) {
      finish()
      return
    }

    // A bar entry written by `omarchy plugin enable` has no settings block, so
    // the defaults have to come from the code too.
    shell.expect("default watchlist", panel.watchList.length === 4, String(panel.watchList.length))
    shell.expect("explicit empty watchlist", emptyPanel.watchList.length === 0, String(emptyPanel.watchList.length))

    // With no feed yet the pill shows a placeholder, never a stale count; the
    // timer may already have a request in flight, hence the two.
    shell.expect("idle bar text", panel.barText === "–" || panel.barText === "…", panel.barText)
    shell.expect("nothing fresh at rest", panel.hasFresh === false)
    shell.expect("refresh minute clamped", panel.refreshMinutes >= 1 && panel.refreshMinutes <= 60, String(panel.refreshMinutes))

    // Markup-shaped input must not reach a Text or a tooltip, whatever sink
    // it lands in.
    var hostile = '<img src="https://tracker.invalid/pixel">hi <b>there</b>'
    shell.expect("excerpt is plain", panel.excerpt({ body: hostile }).indexOf("<") === -1, panel.excerpt({ body: hostile }))
    shell.expect("tooltip is plain", panel.tooltipText.indexOf("<") === -1, panel.tooltipText)
    shell.expect("summary is plain", panel.summaryText.indexOf("<") === -1, panel.summaryText)

    var parsed = Model.parseCommits(JSON.stringify({ data: [{
      id: "01a149c1-f76d-703d-ae60-e82d7960889a",
      short_hash: "960889a",
      body: hostile,
      created_at: "2026-10-17T12:06:50Z",
      stars_count: 3,
      replies_count: 1,
      author: { username: "nunomaduro", name: "nunomaduro", avatar_url: "https://avatars.githubusercontent.com/u/1?v=4" }
    }] }))

    shell.expect("hostile commit parses", parsed.length === 1, String(parsed.length))
    shell.expect("body is plain", parsed.length === 1 && parsed[0].body.indexOf("<") === -1)
    shell.expect("commit url is rebuilt", parsed.length === 1 && parsed[0].url === "https://dev-null.sh/@nunomaduro/commits/01a149c1-f76d-703d-ae60-e82d7960889a", parsed.length ? parsed[0].url : "")
    shell.expect("age renders", panel.ageLabel("2026-10-17T12:06:50Z").length > 0)
    shell.expect("foreign url refused", Model.fetchArgs("https://evil.example/api/v1/users/x/commits").length === 0)

    // ---- Views ---------------------------------------------------------
    shell.expect("default view", panel.view === "following", panel.view)
    shell.expect("three views", panel.views.length === 3, String(panel.views.length))
    shell.expect("following has no log page", Model.logUrl("following") === "")
    shell.expect("log urls", Model.logUrl("latest") === "https://dev-null.sh/log/latest"
      && Model.logUrl("trending") === "https://dev-null.sh/log/trending")
    shell.expect("foreign log page refused", Model.pageFetchArgs("https://evil.example/log/latest").length === 0)
    shell.expect("view tooltip names the feed", panel.tooltipText.length > 0, panel.tooltipText)

    // A log page as the site serves it: the feed inside an Inertia payload,
    // with the author under `user` rather than `author`.
    var page = Model.parseLogPage("<html><body><script type=\"application/json\">" +
      JSON.stringify({ component: "log/show", props: { commits: { data: [{
        id: "01a14a51-db13-7104-ba00-88e5315a0267",
        body: hostile,
        created_at: "2026-10-17T12:06:50Z",
        stars_count: 7,
        replies_count: 3,
        user: { username: "brendt", name: "Brent Roose", avatar_url: "https://avatars.githubusercontent.com/u/2?v=4" }
      }] } } }) + "</script></body></html>")

    shell.expect("log page parses", page.length === 1, String(page.length))
    shell.expect("log page author read", page.length === 1 && page[0].authorUsername === "brendt")
    shell.expect("log page body is plain", page.length === 1 && page[0].body.indexOf("<") === -1)
    shell.expect("log page url rebuilt", page.length === 1
      && page[0].url === "https://dev-null.sh/@brendt/commits/01a14a51-db13-7104-ba00-88e5315a0267")
    shell.expect("unreadable page is empty", Model.parseLogPage("<html>login</html>").length === 0)

    // The panel builds its content lazily on first open, and the row delegates
    // only exist once it has: open it, then feed it commits and check the rows
    // actually took up space. An empty model would leave the riskiest layout
    // math untested.
    panel.open()
    Qt.callLater(function() {
      var before = shell.contentHeight(panel)
      shell.expect("content built on open", before > 0, String(before))

      panel.entries = parsed.concat(Model.parseCommits(JSON.stringify({ data: [{
        id: "01a149c2-f76d-703d-ae60-e82d7960889a",
        short_hash: "cef7611",
        body: "a second commit, to prove the rows stack",
        created_at: "2026-10-17T11:00:00Z",
        stars_count: 0,
        replies_count: 24,
        author: { username: "brendt", name: "Brent Roose", avatar_url: "https://avatars.githubusercontent.com/u/2?v=4" }
      }] })))

      Qt.callLater(function() {
        var after = shell.contentHeight(panel)
        shell.expect("rows laid out", after > before + 80, before + " -> " + after)
        shell.expect("bar text counts the feed", panel.barText === "2", panel.barText)

        // The three tab labels are in the built content. Their text depends on
        // the shell's language, so they are matched by name in both
        // catalogs rather than compared literally.
        var labels = shell.texts(shell.keyboardPanel(panel).loadedContent).filter(function(value) {
          return /^(following|latest|trending|seguiti|recenti|di tendenza)$/i.test(String(value).trim())
        })
        shell.expect("three feed tabs", labels.length === 3, labels.join("|"))

        finish()
      })
    })
  }

  function keyboardPanel(item) {
    var kids = item.data || []
    for (var i = 0; i < kids.length; i++) {
      if (kids[i] && typeof kids[i].loadedContentHeight === "number") return kids[i]
    }
    return null
  }

  // Every Text bound in a subtree, so the harness can assert on what the panel
  // actually renders without reaching into ids it does not own.
  function texts(item, out) {
    var found = out || []
    if (!item) return found
    if (typeof item.text === "string") found.push(item.text)
    var kids = item.children || []
    for (var i = 0; i < kids.length; i++) texts(kids[i], found)
    return found
  }

  // The KeyboardPanel is one of the panel root's data children (a window, so
  // not in `children`); it owns the lazily built content.
  function contentHeight(item) {
    var kids = item.data || []
    for (var i = 0; i < kids.length; i++) {
      if (kids[i] && typeof kids[i].loadedContentHeight === "number") return kids[i].loadedContentHeight
    }
    return -1
  }

  function finish() {
    console.log(failures === 0 ? "DEVNULL_SMOKE_OK" : "DEVNULL_SMOKE_FAIL count=" + failures)
    Qt.quit()
  }
}