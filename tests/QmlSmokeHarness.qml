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

    // Same widget with the watchlist emptied and the booleans written the way
    // `omarchy bar set` writes them: as strings.
    DevNull.BarWidget {
      id: emptyWidget
      moduleName: "io.github.ivozzz.devnull"
      bar: fakeBar
      settings: ({ watch: "", notifyNewPosts: "false", notifySound: "false", showAvatars: "0", includeReplies: "off" })
    }

    // The brand mark carries one file per background. The variant follows the
    // label colour it sits next to, because the brand rules rule out tinting
    // it to the theme.
    DevNull.DevNullMark {
      id: markOnDark
      size: 18
      surroundingColor: "#a9b1d6"
    }

    DevNull.DevNullMark {
      id: markOnLight
      size: 18
      surroundingColor: "#1a1b26"
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

    // "false" is a truthy string; a setting switched off through the CLI has
    // to read as off.
    shell.expect("notifications on by default", panel.notifyNewPosts === true)
    shell.expect("string false reads as off", emptyPanel.notifyNewPosts === false)
    shell.expect("string 0 reads as off", emptyPanel.showAvatars === false)
    shell.expect("string off reads as off", emptyPanel.includeReplies === false)

    // The switch exists and says which way it would go. It is not clicked
    // here: that would write to shell.json while the tests run.
    shell.expect("toggle is a real function", typeof panel.toggleNotify === "function")

    // With no feed yet the tooltip says what the panel holds, and it is now
    // the only place the count lives; the timer may already have a request in
    // flight, hence no exact number.
    shell.expect("the tooltip carries the count",
      panel.tooltipText.indexOf("commit") !== -1, panel.tooltipText)
    shell.expect("nothing fresh at rest", panel.hasFresh === false)
    shell.expect("refresh minute clamped", panel.refreshMinutes >= 1 && panel.refreshMinutes <= 60, String(panel.refreshMinutes))

    // ---- Signing in, signed out ---------------------------------------
    // Signing in is optional and nothing here clicks through it: with no
    // account file the panel is signed out and every request it makes is the
    // public one. The account tooltip is the way in and says so.
    shell.expect("signed out by default", panel.signedIn === false, String(panel.signedIn))
    shell.expect("no account name without an account", panel.accountName === "", panel.accountName)
    shell.expect("signed out offers a sign-in",
      panel.accountTooltip().length > 0 && panel.accountTooltip().indexOf("<") === -1, panel.accountTooltip())
    shell.expect("the sign-in has a key of its own",
      panel.keyPath.indexOf(panel.accountDir + "/device.key") === 0, panel.keyPath)
    shell.expect("the account is not kept in shell.json",
      panel.accountPath.indexOf("/omarchy/devnull/") !== -1, panel.accountPath)
    shell.expect("the sign-in is a function", typeof panel.startLogin === "function")
    // The two senders the flow drives — one for a feed, one for the
    // redemption — built by the panel, idle until they are asked for a
    // request.
    var senders = (panel.data || []).filter(function(kid) {
      return kid && typeof kid.send === "function" && typeof kid.abort === "function"
    })
    shell.expect("both signed-request senders exist", senders.length === 2, String(senders.length))
    shell.expect("they start idle", senders.every(function(sender) { return sender.step === "" }))
    // The handler the browser hands devnull:// to, resolved from this file's
    // own directory so it moves with the checkout.
    shell.expect("the callback handler resolves beside the panel",
      panel.callbackScript.length > 0 && /devnull-callback$/.test(panel.callbackScript), panel.callbackScript)

    // The bar slot draws the dev-null.sh mark, two slashes, as text in the
    // bar's own font; the SVG mark survives in the panel header only.
    shell.expect("the bar draws the brand's two slashes",
      widget.iconGlyph === "//", JSON.stringify(widget.iconGlyph))
    shell.expect("the pill no longer paints a count of its own",
      widget.panelItem.barText === undefined, String(widget.panelItem.barText))
    shell.expect("mark follows a light label", String(markOnDark.source).indexOf("dev-null-mark-on-dark.svg") !== -1, String(markOnDark.source))
    shell.expect("mark follows a dark label", String(markOnLight.source).indexOf("dev-null-mark-on-light.svg") !== -1, String(markOnLight.source))

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
    // Left and right step through the tabs and wrap at both ends. The step is
    // checked on its own: applying it would write shell.json.
    shell.expect("right steps to the next feed", panel.nextView(1) === "latest", panel.nextView(1))
    shell.expect("left steps to the previous feed", panel.nextView(-1) === "trending", panel.nextView(-1))
    shell.expect("the feed cycle wraps", panel.nextView(3) === "following", panel.nextView(3))
    // While a step's write is out, the next step starts from that request, not
    // from the tab the bar has not confirmed yet — otherwise a held arrow key
    // would keep landing on the same feed.
    panel.requestedView = "trending"
    shell.expect("a step continues from the last request",
      panel.nextView(1) === "following", panel.nextView(1))
    panel.requestedView = ""
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

    // ---- Notifications ------------------------------------------------
    // The argv is checked, never sent: the harness must not put a toast on
    // the user's desktop while it runs.
    var summary = Model.unseen(page.concat(parsed), [])
    var argv = panel.notifyArgv(summary)

    shell.expect("notify argv built", argv[0] === "omarchy-notification-send", String(argv[0]))
    shell.expect("notify names itself", argv[1] === "--app-name" && argv[2] === "dev-null.sh", argv.slice(1, 3).join(" "))
    shell.expect("notify replaces a fixed id", argv[argv.indexOf("--replace-id") + 1] === "91507")

    var headline = argv[argv.indexOf("91507") + 1]
    var body = argv[argv.indexOf("91507") + 2]
    shell.expect("notify headline is plain", headline.indexOf("<") === -1, headline)
    shell.expect("notify headline names the author", headline.indexOf("@brendt") !== -1, headline)
    shell.expect("notify body is plain", body.indexOf("<") === -1, body)
    shell.expect("notify body is not the headline", body !== headline, body)
    shell.expect("notify click target is last", argv[argv.length - 1] === summary.newest.url, argv[argv.length - 1])
    shell.expect("notify click target is the rebuilt url",
      summary.newest.url === "https://dev-null.sh/@brendt/commits/01a14a51-db13-7104-ba00-88e5315a0267", summary.newest.url)
    shell.expect("notify uses a browser, not a shell",
      argv[argv.length - 3] === "--exec" && argv[argv.length - 2] === "omarchy-launch-browser")

    shell.expect("nothing to notify about, nothing sent", panel.notifyArgv(Model.unseen([], [])).length === 0)

    // The sound that rides with it. The argv is checked, never run — a test
    // must not play a sound any more than it may put a toast on the desktop —
    // and with no notification service on this fake bar the DND check falls
    // away rather than throwing, which is the path a bar-host change takes.
    shell.expect("sound on by default", panel.notifySound === true)
    shell.expect("string false reads as off for the sound", emptyPanel.notifySound === false)
    shell.expect("sound is the freedesktop message event",
      panel.soundArgv().join(" ") === "canberra-gtk-play -i message-new-instant", panel.soundArgv().join(" "))
    shell.expect("sound switched off, nothing to play", emptyPanel.soundArgv().length === 0)
    shell.expect("no service to ask, the sound still plays", panel.soundArgv().length > 0)

    // Everything below applies feeds that look new while the panel is shut,
    // which is exactly what raises a toast. The argv was checked above; the
    // switch goes off here so the test cannot put one on the user's desktop.
    panel.settings = ({ notifyNewPosts: false })
    shell.expect("the harness mutes the toast", panel.notifyNewPosts === false)

    // The composition: a refresh that finds a commit the panel has not seen
    // raises the fresh count, and the same refresh a second time does not.
    // maybeNotify still runs, but the switch is off, so the tests cover the
    // counting half without a toast on the desktop.
    var freshFeed = Model.parseCommits(JSON.stringify({ data: [{
      id: "01a14b77-db13-7104-ba00-88e5315a0267",
      short_hash: "aa0267",
      body: "a commit that arrives after priming",
      created_at: "2026-10-17T12:00:00Z",
      stars_count: 0,
      replies_count: 0,
      author: { username: "richardkeep", name: "Richard", avatar_url: "https://avatars.githubusercontent.com/u/3?v=4" }
    }] }))

    panel.applyFeed(page)
    shell.expect("priming does not count as fresh", panel.freshCount === 0, String(panel.freshCount))
    panel.applyFeed(page.concat(freshFeed))
    shell.expect("a new commit counts once", panel.freshCount === 1, String(panel.freshCount))
    shell.expect("a new commit is announced in the tooltip",
      panel.tooltipText.indexOf("1 new") !== -1, panel.tooltipText)
    shell.expect("a new commit lights the glyph", widget.iconActive === true)
    panel.applyFeed(page.concat(freshFeed))
    shell.expect("the same refresh again counts nothing", panel.freshCount === 0, String(panel.freshCount))
    shell.expect("a quiet feed drops the count from the tooltip",
      panel.tooltipText.indexOf("new") === -1, panel.tooltipText)
    shell.expect("a quiet feed leaves the glyph plain", widget.iconActive === false)
    shell.expect("no click target without a url",
      panel.notifyArgv({count: 1, authors: ["brendt"], authorCount: 1, newest: {body: "x", url: ""}}).indexOf("--exec") === -1)

    // The seen ids belong to a feed. A commit first read on Latest is still
    // news on the watchlist, and the first load of a feed never counts.
    var latestOnly = Model.parseCommits(JSON.stringify({ data: [{
      id: "01a14c88-db13-7104-ba00-88e5315a0267",
      short_hash: "b5315a",
      body: "first seen on the latest feed",
      created_at: "2026-10-17T12:30:00Z",
      stars_count: 0,
      replies_count: 0,
      author: { username: "brendt", name: "Brent Roose" }
    }] }))
    panel.applyFeed(latestOnly, "latest")
    shell.expect("the first load of a feed counts nothing", panel.freshCount === 0, String(panel.freshCount))
    panel.applyFeed(latestOnly, "following")
    shell.expect("a commit seen on latest is still new on the watchlist",
      panel.freshCount === 1, String(panel.freshCount))
    panel.applyFeed(page.concat(freshFeed), "following")
    shell.expect("the watchlist feed is where it was", panel.freshCount === 0, String(panel.freshCount))

    // The panel builds its content lazily on first open, and the row delegates
    // only exist once it has: open it, then feed it a longer list and check
    // the rows actually took up space. An empty model would leave the riskiest
    // layout math untested.
    panel.open()
    Qt.callLater(function() {
      var before = shell.contentHeight(panel)
      shell.expect("content built on open", before > 0, String(before))

      var six = []
      for (var i = 0; i < 6; i++) {
        six = six.concat(Model.parseCommits(JSON.stringify({ data: [{
          id: "01a149c2-f76d-703d-ae60-88e5315a026" + i,
          short_hash: "cef761" + i,
          body: "row " + i + ", to prove the rows stack and the panel grows",
          created_at: "2026-10-17T11:0" + i + ":00Z",
          stars_count: 0,
          replies_count: 24 - i,
          author: { username: "brendt", name: "Brent Roose", avatar_url: "https://avatars.githubusercontent.com/u/2?v=4" }
        }] })))
      }
      panel.applyFeed(six)

      Qt.callLater(function() {
        var after = shell.contentHeight(panel)
        shell.expect("rows laid out", after > before + 200, before + " -> " + after)
        shell.expect("six arrivals are counted", panel.freshCount === 6, String(panel.freshCount))

        // The status line is the only place a partially failed refresh was
        // ever visible; it also carries how old the feed is. Both are checked
        // as plain text, like every other sink.
        shell.expect("status reports the update",
          panel.lastSuccessMs > 0 && panel.statusText.length > 0, panel.statusText)
        var beforeFailures = panel.failedRequests
        panel.failedRequests = [{ user: "ghost", replies: false }]
        shell.expect("partial failures are reported",
          panel.hasFailures && panel.statusText.indexOf("<") === -1, panel.statusText)

        // A feed that never arrived used to look exactly like an empty one in
        // the bar. It now tints the glyph with the urgent colour, and the
        // tooltip carries the reason.
        var beforeEntries = panel.entries
        var beforeSuccess = panel.lastSuccessMs
        panel.entries = []
        shell.expect("a failed feed tints the glyph",
          panel.hasFailures === true && widget.iconActive === true && widget.failed === true)
        shell.expect("the tooltip explains the failure",
          panel.tooltipText.indexOf("<") === -1 && panel.tooltipText.length > 0, panel.tooltipText)
        panel.entries = beforeEntries
        panel.failedRequests = beforeFailures

        // While another feed is loading over the rows still on screen, the
        // status says so and the rows dim rather than passing for the new feed.
        panel.loading = true
        panel.lastSuccessMs = 0
        shell.expect("a feed switch says it is fetching", panel.switchingFeed)
        panel.loading = false
        panel.lastSuccessMs = beforeSuccess

        // The rows read their age against nowMs, so a moving clock moves the
        // label; a Date.now() call inside the binding would freeze it.
        var wasNow = panel.nowMs
        var then = Date.parse("2026-10-17T12:00:00Z")
        var commitAt = then - 120000
        panel.nowMs = then
        var ageBefore = panel.ageLabelMs(commitAt)
        panel.nowMs = then + 60000
        shell.expect("the age label follows the clock",
          panel.ageLabelMs(commitAt) !== ageBefore, ageBefore)
        panel.nowMs = wasNow

        // The three tab labels are in the built content. Their text depends on
        // the shell's language, so they are matched by name in both
        // catalogs rather than compared literally.
        var labels = shell.texts(shell.keyboardPanel(panel).loadedContent).filter(function(value) {
          return /^(following|latest|trending|seguiti|recenti|di tendenza)$/i.test(String(value).trim())
        })
        shell.expect("three feed tabs", labels.length === 3, labels.join("|"))

        // The bell sits in the panel, so its state has to be readable there:
        // the switch is how a user turns notifications off without a shell.
        var bell = shell.texts(shell.keyboardPanel(panel).loadedContent).filter(function(value) {
          return /mute|muted|silenz|riattiv/i.test(String(value))
        })
        shell.expect("the notification switch states its state", bell.length > 0, bell.join("|"))

        // The watchlist is a visible, prunable list now, not only a setting.
        var built = shell.keyboardPanel(panel).loadedContent
        var builtTexts = shell.texts(built)
        var watching = builtTexts.filter(function(value) {
          return /^(watching|segui)\s+4\/12$/i.test(String(value).trim())
        })
        shell.expect("the watchlist is drawn", watching.length === 1, watching.join("|"))
        shell.expect("a watched user is a chip", builtTexts.some(function(value) {
          return String(value).trim() === "@mnapoli"
        }), builtTexts.join("|"))

        // Signed in, Following is the site's own follow graph rather than this
        // plugin's watchlist: the chips go away, the panel says whose follows
        // it is showing, and the watch button is not offered on a profile.
        panel.account = ({
          username: "ivo", name: "ivo", fingerprint: "SHA256:" + "A".repeat(43),
          device: "Omarchy bar", signedInAt: ""
        })
        shell.expect("an account signs the panel in", panel.signedIn === true)
        shell.expect("the tooltip names the account", panel.accountTooltip().indexOf("@ivo") !== -1, panel.accountTooltip())
        var signedTexts = shell.visibleTexts(built)
        shell.expect("the watchlist goes away when signed in", !signedTexts.some(function(value) {
          return /^(watching|segui)\s+4\/12$/i.test(String(value).trim())
        }), signedTexts.join("|"))
        shell.expect("signed in says whose following it is", signedTexts.some(function(value) {
          return /following is the people|following sono le persone/i.test(String(value))
        }), signedTexts.join("|"))
        panel.account = null
        shell.expect("signing out brings the watchlist back", panel.signedIn === false)
        shell.expect("signed out again, the chips are shown", shell.visibleTexts(built).some(function(value) {
          return /^(watching|segui)\s+4\/12$/i.test(String(value).trim())
        }))

        // A pasted repo link is not a person. It says so instead of doing
        // nothing, and never spends a request.
        panel.lookupUser("github.com/nunomaduro/laravel")
        shell.expect("a repo link is not a profile",
          panel.lookupInvalid === true && panel.lookingUp === false)
        panel.lookupUser("")
        shell.expect("an empty lookup clears the error", panel.lookupInvalid === false)

        // A row opens its replies in place, and a row without a URL has
        // nothing to copy — the copy action is checked as a call, never
        // executed, so the test cannot touch the clipboard.
        shell.expect("a row offers its replies", builtTexts.some(function(value) {
          return /show 24 replies|mostra 24 risposte/i.test(String(value))
        }), builtTexts.join("|"))

        // The page that carries them is parsed here and handed to the panel as
        // if it had already arrived: the request itself is a network call this
        // test must not make.
        var replyPage = Model.commitReplies(
          '<script type="application/json">' + JSON.stringify({
            component: "commit/show",
            props: {
              commit: { replies_count: 4 },
              replies: {
                data: [{
                  id: "01a149c4-f76d-703d-ae60-88e5315a0262",
                  body: "a reply read in place",
                  created_at: "2026-10-17T11:20:00Z",
                  replies_count: 0,
                  user: { username: "mnapoli", name: "Matthieu", avatar_url: "" }
                }],
                per_page: 3,
                next_page_url: "https://dev-null.sh/@brendt/commits/x?cursor=y"
              }
            }
          }) + "</script>"
        )
        shell.expect("a commit page's replies parse",
          !!replyPage && replyPage.replies.length === 1, replyPage ? String(replyPage.replies.length) : "null")
        shell.expect("the rest of the thread is counted",
          !!replyPage && replyPage.remaining === 3, replyPage ? String(replyPage.remaining) : "null")

        var rowId = panel.entries.length > 0 ? panel.entries[0].id : ""
        var pages = {}
        pages[rowId] = replyPage
        panel.replyPages = pages
        panel.toggleExpanded(rowId)
        shell.expect("the chevron expands that row", panel.expandedId === rowId, panel.expandedId)
        shell.expect("the replies are the ones it fetched",
          panel.repliesFor(rowId).length === 1, String(panel.repliesFor(rowId).length))
        shell.expect("the rest of the thread is pointed at the site",
          panel.repliesRemainingFor(rowId) === 3, String(panel.repliesRemainingFor(rowId)))
        panel.toggleExpanded(rowId)
        shell.expect("the chevron collapses it", panel.expandedId === "", panel.expandedId)
        shell.expect("a foreign commit page gets no request",
          Model.commitPageFetchArgs("https://evil.example/@brendt/commits/01a149c4-f76d-703d-ae60-88e5315a0262").length === 0)
        panel.copyCommitUrl({ id: "x", url: "" })
        shell.expect("a row with no url copies nothing", panel.copiedId === "", panel.copiedId)

        // A cursor move scrolls its row into view. The feed is a Flickable over
        // a Column inside the content component the panel builds lazily, and
        // the helper that moves it lives there too: the panel root has to ask
        // the loaded content. A root that reaches for the scroll area by id
        // instead throws ReferenceError, which aborts this function and fails
        // the run on the timeout — the bug this covers. Enough rows to overflow
        // the viewport, so the last one has to move the scroll.
        var overflow = []
        for (var j = 0; j < 40; j++) {
          overflow = overflow.concat(Model.parseCommits(JSON.stringify({ data: [{
            id: "01a149c3-f76d-703d-ae60-e82d796000" + (j < 10 ? "0" : "") + j,
            short_hash: "cef762" + j,
            body: "row " + j + ", to prove a cursor move scrolls the feed",
            created_at: "2026-10-17T10:00:00Z",
            stars_count: 40 - j,
            replies_count: j,
            author: { username: "brendt", name: "Brent Roose" }
          }] })))
        }

        // A row's y means nothing until the column has laid out, and the
        // panel's own refresh (at load and again when it opens) can land
        // between layout turns and put its feed — an empty one, with no API
        // reachable — in place of this. Re-apply until a turn passes untouched.
        // The panel rate-limits its own refreshes to one a minute, so this
        // settles after one or two tries; a feed that never settles is a
        // failure of its own rather than a silently weaker test.
        var attempts = 0
        function checkScroll() {
          attempts++
          panel.applyFeed(overflow)
          Qt.callLater(function() {
            var kept = panel.entries.length === overflow.length
            for (var i = 0; kept && i < panel.entries.length; i++) {
              kept = String(panel.entries[i].id).indexOf("01a149c3") === 0
            }
            if (!kept) {
              if (attempts < 8) {
                checkScroll()
                return
              }
              shell.expect("the harness feed stayed applied", false, String(panel.entries.length))
              finish()
              return
            }
            assertScroll()
          })
        }

        function assertScroll() {
          // The loaded content is the KeyboardPanel's, one level under the panel
          // root the harness holds.
          var content = shell.keyboardPanel(panel).loadedContent
          var scrollArea = shell.scroller(content)
          shell.expect("content owns the scroll helper",
            !!content && typeof content.scrollRowIntoView === "function", content ? "loaded" : "no loaded content")
          shell.expect("content owns the top helper",
            !!content && typeof content.scrollFeedToTop === "function", content ? "loaded" : "no loaded content")
          shell.expect("the feed has a scroll area", !!scrollArea)

          // moveCursor() is what the arrow keys call; the root function is also
          // called outright with the row, which is the call the broken panel
          // made with an id it could not see.
          panel.moveCursor(1)
          for (var k = 0; k < 100; k++) panel.moveCursor(1)
          shell.expect("the cursor is on the last row", panel.cursorIndex === panel.entries.length - 1,
            String(panel.cursorIndex))
          panel.ensureCursorVisible(shell.cursorRow(content, panel.cursorIndex))
          shell.expect("the cursor row scrolls into view", !!scrollArea && scrollArea.contentY > 0,
            scrollArea ? String(scrollArea.contentY) : "no scroll area")
          var deep = scrollArea ? scrollArea.contentY : 0

          // Rewinding has to bring the top back, or the scroll only ever grows.
          // The first commit row is below the header, so the top is that row's
          // own y, not zero.
          panel.moveCursor(-1)
          for (var m = 0; m < 100; m++) panel.moveCursor(-1)
          shell.expect("the cursor is back on the first row", panel.cursorIndex === 0, String(panel.cursorIndex))
          var firstRow = shell.cursorRow(content, 0)
          shell.expect("the first row is visible again",
            !!scrollArea && !!firstRow && scrollArea.contentY <= firstRow.y && scrollArea.contentY < deep,
            scrollArea && firstRow ? scrollArea.contentY + " vs row y " + firstRow.y : "missing")

          // A reopening panel starts at the top, and the helper it asks is the
          // content's, like the cursor one.
          panel.scrollFeedToTop()
          shell.expect("the feed scrolls back to the top", !!scrollArea && scrollArea.contentY === 0,
            scrollArea ? String(scrollArea.contentY) : "no scroll area")

          // The lookup box: its text belongs to the content, and the root's
          // lookupUser() once read searchField from out here, which threw the
          // moment Enter was pressed. Its own path is exercised through the
          // empty box (nothing to fetch), and the root function is called
          // directly too, because a JS call from here surfaces an exception
          // where a signal handler would only warn.
          var field = shell.textField(content)
          shell.expect("the lookup box is there", !!field)
          field.accepted()
          shell.expect("an empty lookup fetches nothing", panel.lookingUp === false && panel.lookup === null,
            "lookingUp " + panel.lookingUp)
          panel.lookupUser("")
          shell.expect("the root lookup takes its text as an argument", panel.lookingUp === false)

          // The lookup box fetches a profile, and it once had no command to
          // fetch with: Model.fetchArgs answered "nothing" for every profile
          // URL, so the box — and watch/unwatch with it — did nothing at all,
          // silently, on every release. These are the request it builds and
          // the state the panel enters while it waits.
          var profileArgs = Model.fetchArgs(Model.profileApiUrl("nunomaduro"))
          shell.expect("a profile has a request to make", profileArgs.length > 0, String(profileArgs.length))
          shell.expect("the profile request is the curl argv",
            profileArgs[0] === "curl"
              && profileArgs[profileArgs.length - 1] === "https://dev-null.sh/api/v1/users/nunomaduro")

          panel.lookupUser("nunomaduro")
          shell.expect("a valid lookup starts", panel.lookingUp === true, "lookingUp " + panel.lookingUp)
          // Invalidate the request so its late answer cannot land in a later
          // assertion; the process is left to finish on its own.
          panel.lookupUser("bad user")
          shell.expect("an invalid lookup stops the spinner", panel.lookingUp === false)

          // The cursor belongs to one visit: content stays loaded between
          // opens, so a stale index would highlight a row on a feed the user
          // has not looked at yet.
          panel.close()
          panel.open()
          shell.expect("the cursor does not survive a close",
            panel.cursorIndex === -1 && panel.cursorActive === false, String(panel.cursorIndex))

          // A reply is an item, not only model data: expanding a row whose
          // page is already known draws the answers under the body and names
          // the ones that stayed on the site. The page is handed over rather
          // than fetched, so this costs no request.
          var answered = Model.parseCommits(JSON.stringify({ data: [{
            id: "01a149c5-f76d-703d-ae60-88e5315a0263",
            short_hash: "a0263",
            body: "a commit with answers",
            created_at: "2026-10-17T10:30:00Z",
            stars_count: 0,
            replies_count: 4,
            author: { username: "brendt", name: "Brent Roose" }
          }] }))
          panel.applyFeed(answered)
          var cached = {}
          cached[answered[0].id] = replyPage
          panel.replyPages = cached
          panel.toggleExpanded(answered[0].id)

          Qt.callLater(function() {
            var replyTexts = shell.visibleTexts(shell.keyboardPanel(panel).loadedContent)
            shell.expect("the reply is drawn under its commit", replyTexts.some(function(value) {
              return String(value).trim() === "a reply read in place"
            }), replyTexts.join("|"))
            shell.expect("the replies left on the site are named", replyTexts.some(function(value) {
              return /3 more replies|3 altre risposte/i.test(String(value))
            }), replyTexts.join("|"))
            finish()
          })
        }

        checkScroll()
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

  // The visible strings bound in a subtree, so the harness can assert on what
  // the panel actually renders without reaching into ids it does not own. A
  // tooltip is a property, not a Text — the shared tooltip only builds on
  // hover — so those are collected too.
  function texts(item, out) {
    var found = out || []
    if (!item) return found
    if (typeof item.text === "string") found.push(item.text)
    if (typeof item.tooltipText === "string") found.push(item.tooltipText)
    if (typeof item.placeholderText === "string") found.push(item.placeholderText)
    var kids = item.children || []
    for (var i = 0; i < kids.length; i++) texts(kids[i], found)
    return found
  }

  // The same, but honouring `visible`: a signed-in panel keeps the watchlist
  // chips in the tree with visible false, so only their absence from here
  // proves they are not on screen.
  function visibleTexts(item, out) {
    var found = out || []
    if (!item || item.visible === false) return found
    if (typeof item.text === "string") found.push(item.text)
    if (typeof item.tooltipText === "string") found.push(item.tooltipText)
    var kids = item.children || []
    for (var i = 0; i < kids.length; i++) visibleTexts(kids[i], found)
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

  // The lookup box in the content: the one text field with a placeholder.
  function textField(item) {
    var kids = item ? (item.children || []) : []
    for (var i = 0; i < kids.length; i++) {
      var kid = kids[i]
      if (kid && typeof kid.placeholderText === "string" && typeof kid.accepted === "function") return kid
      var found = textField(kid)
      if (found) return found
    }
    return null
  }

  // The commit row for one index: every feed row carries its index.
  function cursorRow(item, index) {
    var kids = item ? (item.children || []) : []
    for (var i = 0; i < kids.length; i++) {
      var kid = kids[i]
      if (kid && kid.rowIndex === index && typeof kid.contentY !== "number") return kid
      var found = cursorRow(kid, index)
      if (found) return found
    }
    return null
  }

  // The single scroll area in the content: the only item with a contentY and a
  // contentHeight.
  function scroller(item) {
    var kids = item ? (item.children || []) : []
    for (var i = 0; i < kids.length; i++) {
      var kid = kids[i]
      if (kid && typeof kid.contentY === "number" && typeof kid.contentHeight === "number") return kid
      var found = scroller(kid)
      if (found) return found
    }
    return null
  }

  function finish() {
    console.log(failures === 0 ? "DEVNULL_SMOKE_OK" : "DEVNULL_SMOKE_FAIL count=" + failures)
    Qt.quit()
  }
}