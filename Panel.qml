import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

// The /dev/null panel: three read-only feeds (the people you watch, Latest,
// Trending) plus a lookup box for any GitHub username on dev-null.sh.
//
// "following" has no page on the site — /log/following redirects to the login
// — so it is the plugin's own watchlist, merged from one API request per
// watched user. Those run strictly one after another (60/minute per IP is the
// whole budget). The last good feed stays on screen while a refresh runs.
Panel {
  id: root
  moduleName: "Ivozzz.devnull"
  ipcTarget: "Ivozzz.devnull"
  manageIpc: false

  property var anchorItem: null
  property bool openedFromHotkey: false

  // The bar tracks the widget mounted in its slot, not this nested panel:
  // everything the bar identifies a panel by has to be that widget.
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  // ---- Settings (read from this widget's inline shell.json entry) --------
  // The manifest carries the same defaults for the settings form, but a bar
  // entry written by `omarchy plugin enable` has no settings block at all, so
  // the fallback lives here too or the widget starts with nothing to read.
  readonly property string defaultWatch: "nunomaduro,brendt,paulinevos,mnapoli"
  readonly property var watchList: Model.watchList(setting("watch", root.defaultWatch))
  readonly property string view: Model.view(setting("view", "following")) || "following"
  readonly property var views: Model.VIEWS

  // A view changed from anywhere — a tab click or `omarchy bar set` — refills
  // the feed straight away instead of leaving the old one up until the timer.
  onViewChanged: Qt.callLater(function() { root.refresh(true) })
  readonly property bool includeReplies: !!setting("includeReplies", false)
  readonly property int refreshMinutes: Math.max(1, Math.min(60, parseInt(setting("refreshMinutes", 5), 10) || 5))
  readonly property bool showAvatars: !!setting("showAvatars", true)

  // ---- Feed state -------------------------------------------------------
  property var entries: []
  property var bundles: ({})
  property var attempts: ({})
  property var pending: []
  property var failedUsers: []
  property string activeUser: ""
  property string retryUser: ""
  property bool loading: false
  property int freshCount: 0
  // Ids already counted, kept in memory for the shell session only.
  property var seenIds: []
  property bool primed: false
  // The API allows 60 requests a minute per IP and a refresh costs one request
  // per watched user, so reopening the panel must not be able to spend the
  // whole budget in a minute.
  property double lastRefreshMs: 0

  // ---- Lookup state -----------------------------------------------------
  property var lookup: null
  property bool lookupMissing: false
  property bool lookingUp: false

  // A log page that came back with no readable feed: a login wall, a
  // redesigned payload, or a network blip that curl let through.
  property bool viewFailed: false

  // ---- Keyboard cursor --------------------------------------------------
  property bool cursorActive: false
  property int cursorIndex: -1

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  // English text for the window between startup and the catalog loading, or
  // for a key a catalog does not carry: a raw key would otherwise reach a row.
  readonly property var ageFallbacks: ({
    seconds: "%1 second ago",
    minutes: "%1 minutes ago",
    hours: "%1 hours ago",
    days: "%1 days ago",
    weeks: "%1 weeks ago",
    months: "%1 months ago"
  })

  // Qt's arg() warns and does nothing when a template carries no %1, which is
  // what a half-edited catalog produces; this leaves such a template alone.
  // Values fill %1, %2, ... in order and may be passed as a list.
  function fill(template, values) {
    var text = String(template === undefined || template === null ? "" : template)
    var list = Array.isArray(values) ? values : [values]
    for (var i = list.length - 1; i >= 0; i--) {
      text = text.replace("%" + (i + 1), String(list[i]))
    }
    return text
  }

  // ---- Bar contract -----------------------------------------------------
  readonly property bool hasFresh: freshCount > 0
  readonly property string barText: entries.length === 0
    ? (loading ? "…" : "–")
    : Commons.I18n.formatNumber(entries.length)
  readonly property string tooltipText: root.fill(
    strings.tn("panel.commits", entries.length, "%1 commits"),
    Commons.I18n.formatNumber(entries.length)
  ) + " · " + root.viewLabel(root.view)

  readonly property string summaryText: {
    var commits = root.fill(
      strings.tn("panel.commits", entries.length, "%1 commits"),
      Commons.I18n.formatNumber(entries.length)
    )
    if (freshCount <= 0) return commits
    return root.fill(strings.t("panel.summary", "%1 · %2"), [
      commits,
      root.fill(strings.tn("panel.fresh", freshCount, "%1 new"), Commons.I18n.formatNumber(freshCount))
    ])
  }

  function open() {
    openedFromHotkey = false
    setCenterHoverRevealSuppressed(false)
    root.controller.show()
    root.refresh()
  }

  function openFromHotkey() {
    openedFromHotkey = true
    root.controller.show()
    root.refresh()
    // Set after showing: showing hands the popout coordinator over, and that
    // handoff closes whichever panel was open, clearing the shared flag.
    Qt.callLater(function() {
      if (root.opened) setCenterHoverRevealSuppressed(true)
    })
  }

  function close() {
    setCenterHoverRevealSuppressed(false)
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.openFromHotkey()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  function setCenterHoverRevealSuppressed(value) {
    if (root.bar && typeof root.bar.setCenterHoverRevealSuppressed === "function")
      root.bar.setCenterHoverRevealSuppressed(value)
    else if (root.bar && "centerHoverRevealSuppressed" in root.bar)
      root.bar.centerHoverRevealSuppressed = value
  }

  // ---- Fetching ---------------------------------------------------------
  // A shallow copy with one key replaced: bindings on `bundles`/`attempts`
  // only re-evaluate when the property itself is reassigned.
  function withKey(source, key, value) {
    var next = {}
    for (var name in source) next[name] = source[name]
    next[key] = value
    return next
  }

  // `force` is for the explicit ones (the r key, middle click, a tab change);
  // opening the panel and the refresh timer take the quiet path.
  function refresh(force) {
    var now = Date.now()
    if (!force && root.lastRefreshMs > 0 && now - root.lastRefreshMs < 60000) return
    root.lastRefreshMs = now

    root.failedUsers = []
    if (root.view !== "following") {
      root.startPageFetch()
      return
    }

    var users = root.watchList
    if (users.length === 0) {
      root.pending = []
      root.loading = false
      return
    }
    root.bundles = {}
    root.attempts = {}
    root.pending = users.slice()
    root.loading = true
    root.nextUser()
  }

  // ---- Views -------------------------------------------------------------
  // A tab change is a setting change, so it goes through the same shell.json
  // round trip as the watchlist and lands back in `settings` on its own; the
  // view binding above picks it up and refills the feed.
  function setView(name) {
    var next = Model.view(name)
    if (next === "" || next === root.view) return
    Util.execArgv(["omarchy-bar", "set", "Ivozzz.devnull", "view", next])
  }

  function viewLabel(name) {
    var key = "view." + name
    return strings.t(key, name)
  }

  function startPageFetch() {
    var args = Model.pageFetchArgs(Model.logUrl(root.view))
    root.viewFailed = false
    if (args.length === 0) {
      root.loading = false
      root.viewFailed = true
      return
    }
    root.loading = true
    pageProc.command = args
    pageProc.running = true
  }

  function onPageResponse(raw) {
    root.loading = false
    var commits = Model.parseLogPage(raw)
    root.viewFailed = commits.length === 0
    root.applyFeed(commits)
  }

  function nextUser() {
    if (root.pending.length === 0) {
      root.finish()
      return
    }
    root.startFetch(root.pending.shift())
  }

  function startFetch(user) {
    var args = Model.fetchArgs(Model.commitsApiUrl(user, root.includeReplies))
    if (args.length === 0) {
      root.failedUsers = root.failedUsers.concat([user])
      root.nextUser()
      return
    }
    root.activeUser = user
    feedProc.command = args
    feedProc.running = true
  }

  function onFeedResponse(raw) {
    var user = root.activeUser
    root.activeUser = ""
    if (user === "") return

    var commits = Model.parseCommits(raw)
    if (commits.length > 0) {
      // Keep whatever this user contributed earlier: a partial page must not
      // shrink the feed.
      root.bundles = withKey(root.bundles, user, (root.bundles[user] || []).concat(commits))
      root.attempts = withKey(root.attempts, user, 0)
      root.nextUser()
      return
    }

    var tries = root.attempts[user] || 0
    if (tries < 1) {
      root.attempts = withKey(root.attempts, user, tries + 1)
      root.retryUser = user
      retryTimer.restart()
      return
    }

    root.failedUsers = root.failedUsers.concat([user])
    root.nextUser()
  }

  function finish() {
    root.loading = false

    var groups = []
    for (var name in root.bundles) {
      if (root.bundles[name] && root.bundles[name].length > 0) groups.push(root.bundles[name])
    }

    root.applyFeed(Model.mergeCommits(groups, Model.FEED_LIMIT))
  }

  // One place decides what a feed means for the rest of the panel: the rows,
  // the count in the bar, and what counts as new since the last refresh. The
  // first refresh has nothing to compare against, so nothing in it reads as
  // new.
  function applyFeed(commits) {
    var fresh = root.primed ? Model.countUnseen(commits, root.seenIds) : 0
    root.seenIds = Model.markSeen(root.primed ? root.seenIds : [], commits)
    root.primed = true

    root.entries = commits
    root.freshCount = fresh
    if (root.cursorIndex >= commits.length) root.cursorIndex = commits.length - 1
  }

  Timer {
    id: retryTimer
    interval: 2500
    onTriggered: {
      var user = root.retryUser
      root.retryUser = ""
      if (user === "") {
        root.nextUser()
        return
      }
      root.startFetch(user)
    }
  }

  Timer {
    id: refreshTimer
    interval: root.refreshMinutes * 60 * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  Process {
    id: feedProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.onFeedResponse(text)
    }
  }

  Process {
    id: pageProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.onPageResponse(text)
    }
  }

  Process {
    id: lookupProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.lookingUp = false
        var profile = Model.parseUser(text)
        // A 404 answers with a message body, not a profile.
        if (!profile) {
          root.lookup = null
          root.lookupMissing = true
          return
        }
        root.lookup = profile
        root.lookupMissing = false
      }
    }
  }

  // ---- Lookup and watchlist --------------------------------------------
  function lookupUser() {
    var name = Model.username(searchField.text)
    if (name === "") {
      root.lookup = null
      root.lookupMissing = false
      return
    }
    var args = Model.fetchArgs(Model.profileApiUrl(name))
    if (args.length === 0) return

    root.lookingUp = true
    root.lookup = null
    root.lookupMissing = false
    lookupProc.command = args
    lookupProc.running = true
  }

  function isWatched(name) {
    var user = Model.username(name).toLowerCase()
    if (user === "") return false
    var list = root.watchList
    for (var i = 0; i < list.length; i++) {
      if (list[i].toLowerCase() === user) return true
    }
    return false
  }

  function toggleWatch(name) {
    var user = Model.username(name)
    if (user === "") return

    var list = root.watchList.slice()
    var index = -1
    for (var i = 0; i < list.length; i++) {
      if (list[i].toLowerCase() === user.toLowerCase()) index = i
    }

    if (index >= 0) {
      list.splice(index, 1)
    } else {
      // The cap is the API's own limit on how much one shell can spend per
      // refresh; refusing is clearer than a setting edit that silently drops
      // the name.
      if (list.length >= Model.WATCH_LIMIT) return
      list.push(user)
    }

    root.persistWatch(Model.watchString(list))
  }

  // shell.json is this widget's settings store and omarchy-bar is its only
  // writer, so the edit goes through the bar command. Passed as argv, never a
  // shell string, so a username stays data.
  function persistWatch(value) {
    Util.execArgv(["omarchy-bar", "set", "Ivozzz.devnull", "watch", value])
    // The new watchlist has to come back through shell.json before a refresh
    // can read it, so the fetch waits a beat instead of re-reading the old one.
    refreshAfterSave.restart()
  }

  Timer {
    id: refreshAfterSave
    interval: 600
    onTriggered: root.refresh(true)
  }

  // ---- Commit actions ---------------------------------------------------
  function openCommit(entry) {
    // Rebuilt in the model from a validated username and id, so this is a
    // dev-null.sh commit page and nothing else.
    if (!entry || entry.url === "") return
    Util.execArgv(["omarchy-launch-browser", entry.url])
  }

  function openProfile(name) {
    var url = Model.pageUrl(name)
    if (url === "") return
    Util.execArgv(["omarchy-launch-browser", url])
  }

  // ---- Display helpers --------------------------------------------------
  function ageLabel(iso) {
    var age = Model.ageUnit(iso, Date.now())
    if (!age) return ""
    return root.fill(
      strings.tn("age." + age.unit, age.value, root.ageFallbacks[age.unit]),
      Commons.I18n.formatNumber(age.value)
    )
  }

  function excerpt(entry) {
    return entry ? Model.excerpt(entry.body, 180) : ""
  }

  function profileStats(profile) {
    if (!profile) return ""
    return root.fill(strings.t("profile.stats", "%1 · %2"), [
      root.fill(
        strings.tn("profile.commits", profile.commitsCount, "%1 commits"),
        Commons.I18n.formatNumber(profile.commitsCount)
      ),
      root.fill(
        strings.tn("profile.followers", profile.followersCount, "%1 followers"),
        Commons.I18n.formatNumber(profile.followersCount)
      )
    ])
  }

  function moveCursor(dy) {
    if (root.entries.length === 0) return
    root.cursorActive = true
    var next = root.cursorIndex + dy
    if (next < 0) next = 0
    if (next > root.entries.length - 1) next = root.entries.length - 1
    root.cursorIndex = next
  }

  function activateCursor() {
    if (!root.cursorActive || root.cursorIndex < 0) return
    root.openCommit(root.entries[root.cursorIndex])
  }

  function ensureCursorVisible(row) {
    feedScroll.positionViewAtIndex(root.cursorIndex, ListView.Contain)
  }

  // ---- Panel ------------------------------------------------------------
  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: true
    focusTarget: panel.loadedContent
    contentWidth: panel.fittedContentWidth(Style.space(520))
    contentHeight: panel.fittedContentHeight(panel.loadedContentHeight, Style.space(600))

    content: PanelKeyCatcher {
      implicitHeight: feedColumn.implicitHeight
      anchors.fill: parent
      blocked: searchField.activeFocus
      onMoveRequested: function(dx, dy) { if (dy !== 0) root.moveCursor(dy) }
      onActivateRequested: root.activateCursor()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(text) {
        if (text === "r" || text === "R") root.refresh(true)
        else if (text === "/") searchField.forceActiveFocus()
        else if (text === "1") root.setView("following")
        else if (text === "2") root.setView("latest")
        else if (text === "3") root.setView("trending")
      }

      Flickable {
        id: feedScroll
        anchors.fill: parent
        contentWidth: width
        contentHeight: feedColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height

        Column {
          id: feedColumn
          width: feedScroll.width
          spacing: Style.space(10)

          // ---- Header: identity, size of the feed, refresh ------------
          Item {
            width: parent.width
            implicitHeight: Style.space(28)

            Row {
              anchors.left: parent.left
              anchors.leftMargin: Style.space(2)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(8)

              Text {
                anchors.verticalCenter: parent.verticalCenter
                text: "\uf120"  // nf-fa-terminal
                textFormat: Text.PlainText
                color: root.barForeground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.title
              }

              Text {
                anchors.verticalCenter: parent.verticalCenter
                text: "/dev/null"
                textFormat: Text.PlainText
                color: root.barForeground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.title
                font.bold: true
              }

              Text {
                anchors.verticalCenter: parent.verticalCenter
                text: root.summaryText
                textFormat: Text.PlainText
                color: root.hasFresh ? Commons.Color.accent : Qt.darker(root.barForeground, 1.4)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
              }
            }

            PanelActionButton {
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              iconText: "\uf021"  // nf-fa-refresh; spins while a fetch is in flight
              foreground: root.barForeground
              tooltipText: strings.t("action.refresh", "Refresh (r)")
              onClicked: root.refresh(true)

              RotationAnimator on rotation {
                running: root.loading && !Style.reduceMotion
                from: 0
                to: 360
                duration: 900
                loops: Animation.Infinite
              }
            }
          }

          // ---- Lookup --------------------------------------------------
          Row {
            width: parent.width
            spacing: Style.space(6)

            TextField {
              id: searchField
              width: parent.width - lookupButton.width - parent.spacing
              placeholderText: strings.t("search.placeholder", "GitHub username")
              foreground: root.barForeground
              font.family: root.bar.fontFamily
              onAccepted: root.lookupUser()

              Keys.onPressed: function(event) {
                if (event.key === Qt.Key_Escape) {
                  searchField.text = ""
                  root.lookup = null
                  root.lookupMissing = false
                  event.accepted = true
                }
              }
            }

            PanelActionButton {
              id: lookupButton
              anchors.verticalCenter: parent.verticalCenter
              iconText: "\uf002"  // nf-fa-search
              foreground: root.barForeground
              tooltipText: strings.t("search.action", "Look up")
              onClicked: {
                searchField.forceActiveFocus()
                root.lookupUser()
              }

              RotationAnimator on rotation {
                running: root.lookingUp && !Style.reduceMotion
                from: 0
                to: 360
                duration: 900
                loops: Animation.Infinite
              }
            }
          }

          // ---- Profile card for a looked-up user ----------------------
          Rectangle {
            id: profileCard
            visible: !!root.lookup || root.lookupMissing
            width: parent.width
            implicitHeight: profileColumn.implicitHeight + Style.space(16)
            radius: Style.cornerRadius
            color: Style.hoverFillFor(root.barForeground, Commons.Color.accent)

            Column {
              id: profileColumn
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.top: parent.top
              anchors.margins: Style.space(10)
              spacing: Style.space(6)

              Text {
                width: parent.width
                visible: root.lookupMissing
                text: strings.t("search.missing", "No dev-null.sh profile for that username.")
                textFormat: Text.PlainText
                wrapMode: Text.WordWrap
                color: Qt.darker(root.barForeground, 1.4)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.bodySmall
              }

              Row {
                width: parent.width
                visible: !!root.lookup
                spacing: Style.space(10)

                SizedImage {
                  width: Style.space(34)
                  height: Style.space(34)
                  url: root.lookup && root.showAvatars ? root.lookup.avatarUrl : ""
                }

                Column {
                  width: parent.width - Style.space(34) - watchButton.width - Style.space(20)
                  spacing: Style.space(2)

                  // The name opens the user's page on dev-null.sh.
                  Text {
                    id: profileName
                    width: parent.width
                    text: root.lookup ? (root.lookup.name !== "" ? root.lookup.name : root.lookup.username) : ""
                    textFormat: Text.PlainText
                    elide: Text.ElideRight
                    color: root.barForeground
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.subtitle
                    font.bold: true

                    TapHandler {
                      enabled: !!root.lookup
                      onTapped: root.openProfile(root.lookup.username)
                    }
                    HoverHandler {
                      cursorShape: root.lookup ? Qt.PointingHandCursor : Qt.ArrowCursor
                    }
                  }

                  Text {
                    width: parent.width
                    text: root.lookup ? root.profileStats(root.lookup) : ""
                    textFormat: Text.PlainText
                    elide: Text.ElideRight
                    color: Qt.darker(root.barForeground, 1.4)
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.caption
                  }

                  Text {
                    width: parent.width
                    visible: root.lookup && root.lookup.bio !== ""
                    text: root.lookup ? root.lookup.bio : ""
                    textFormat: Text.PlainText
                    wrapMode: Text.WordWrap
                    maximumLineCount: 2
                    elide: Text.ElideRight
                    color: Qt.darker(root.barForeground, 1.3)
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.bodySmall
                  }
                }

                PanelActionButton {
                  id: watchButton
                  anchors.verticalCenter: parent.verticalCenter
                  visible: !!root.lookup
                  iconText: root.lookup && root.isWatched(root.lookup.username) ? "\uf00c" : "\uf067"
                  tooltipText: root.lookup && root.isWatched(root.lookup.username)
                    ? strings.t("action.unwatch", "Stop watching")
                    : strings.t("action.watch", "Watch")
                  onClicked: root.toggleWatch(root.lookup.username)
                }
              }
            }
          }

          PanelSeparator {
            visible: root.entries.length > 0
            foreground: root.barForeground
          }

          // ---- Feed selector ------------------------------------------
          // Same three names the site uses for its own log tabs, so the bar
          // and the site read the same way.
          Row {
            id: viewTabs
            width: parent.width
            spacing: Style.space(4)

            Repeater {
              model: root.views

              ViewTab {
                required property var modelData
                viewName: modelData
                activeView: root.view
                onPicked: root.setView(modelData)
              }
            }
          }

          // ---- Feed ---------------------------------------------------
          Repeater {
            model: root.entries

            CommitRow {
              required property var modelData
              required property int index

              width: feedColumn.width
              rowIndex: index
              entry: modelData
            }
          }

          // ---- States -------------------------------------------------
          Text {
            width: parent.width
            visible: root.entries.length === 0 && root.view === "following" && root.watchList.length === 0
            text: strings.t("panel.noWatch", "Nobody to watch yet. Look up a username above.")
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
            color: Qt.darker(root.barForeground, 1.4)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          Text {
            width: parent.width
            visible: root.entries.length === 0 && root.loading && (root.view !== "following" || root.watchList.length > 0)
            text: strings.t("panel.fetching", "Fetching…")
            textFormat: Text.PlainText
            color: Qt.darker(root.barForeground, 1.4)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
            font.italic: true
          }

          Text {
            width: parent.width
            visible: root.entries.length === 0 && !root.loading && (root.viewFailed || root.failedUsers.length > 0)
            text: root.view === "following"
              ? root.fill(
                  strings.tn("panel.failed", root.failedUsers.length, "%1 requests failed"),
                  Commons.I18n.formatNumber(root.failedUsers.length)
                )
              : strings.t("panel.unavailable", "This feed could not be read.")
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
            color: Qt.darker(root.barForeground, 1.4)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
          }
        }
      }
    }
  }

  // One feed tab. A label and an underline, not a cursor row: the tab bar is
  // a mode switch, and the commit rows below keep the single-selection
  // highlight to themselves.
  component ViewTab: Item {
    id: viewTab
    required property string viewName
    required property string activeView
    signal picked()

    readonly property bool selected: viewTab.viewName === viewTab.activeView

    width: viewLabel.implicitWidth + Style.space(18)
    height: Style.space(26)

    Rectangle {
      anchors.fill: parent
      radius: Style.cornerRadius
      color: viewTabArea.containsMouse && !viewTab.selected
        ? Style.hoverFillFor(root.barForeground, Commons.Color.accent)
        : "transparent"
    }

    Text {
      id: viewLabel
      anchors.centerIn: parent
      text: root.viewLabel(viewTab.viewName)
      textFormat: Text.PlainText
      color: viewTab.selected ? root.barForeground : Qt.darker(root.barForeground, 1.4)
      font.family: root.bar.fontFamily
      font.pixelSize: Style.font.body
      font.bold: viewTab.selected
    }

    Rectangle {
      anchors.bottom: parent.bottom
      anchors.horizontalCenter: parent.horizontalCenter
      width: viewLabel.implicitWidth + Style.space(10)
      height: Style.spacing.hairline * 2
      visible: viewTab.selected
      color: Commons.Color.accent
    }

    MouseArea {
      id: viewTabArea
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: viewTab.picked()
    }
  }

  // A commit row. The cursor highlight is owned by the panel, never by the
  // mouse, so exactly one row reads as selected at any time.
  component CommitRow: CursorSurface {
    id: commitRow
    required property var entry
    required property int rowIndex

    hasCursor: root.cursorActive && root.cursorIndex === rowIndex
    onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(commitRow)
    foreground: root.barForeground
    fill: Style.hoverFillFor(root.barForeground, Commons.Color.accent)
    implicitHeight: rowLayout.implicitHeight + Style.space(12)

    Row {
      id: rowLayout
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(6)
      anchors.rightMargin: Style.space(6)
      spacing: Style.space(10)

      SizedImage {
        width: Style.space(26)
        height: Style.space(26)
        visible: root.showAvatars && commitRow.entry.avatarUrl !== ""
        url: commitRow.entry.avatarUrl
      }

      Column {
        width: parent.width - Style.space(26) - Style.space(10)
        spacing: Style.space(3)

        Row {
          width: parent.width
          spacing: Style.space(6)

          Text {
            text: "@" + commitRow.entry.authorUsername
            textFormat: Text.PlainText
            color: root.barForeground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.body
            font.bold: true
          }

          Text {
            // Only the API carries the short hash; the log pages keep it out
            // of their payload, and reading it would mean parsing markup.
            visible: commitRow.entry.shortHash !== ""
            text: commitRow.entry.shortHash
            textFormat: Text.PlainText
            color: Qt.darker(root.barForeground, 1.5)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
            anchors.verticalCenter: parent.verticalCenter
          }

          Text {
            width: Math.max(0, parent.width - x - Style.space(80))
            text: root.ageLabel(commitRow.entry.createdAt)
            textFormat: Text.PlainText
            horizontalAlignment: Text.AlignRight
            elide: Text.ElideRight
            color: Qt.darker(root.barForeground, 1.5)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
            anchors.verticalCenter: parent.verticalCenter
          }

          Text {
            visible: commitRow.entry.isReply
            text: strings.t("row.reply", "reply")
            textFormat: Text.PlainText
            color: Qt.darker(root.barForeground, 1.6)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
            font.italic: true
            anchors.verticalCenter: parent.verticalCenter
          }
        }

        Text {
          width: parent.width
          text: root.excerpt(commitRow.entry)
          textFormat: Text.PlainText
          wrapMode: Text.WordWrap
          maximumLineCount: 3
          elide: Text.ElideRight
          color: Qt.darker(root.barForeground, 1.15)
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.bodySmall
        }

        Row {
          spacing: Style.space(10)

          Text {
            visible: commitRow.entry.stars > 0
            // Icon-font glyph, then the count the API returned.
            text: "\uf005 " + Commons.I18n.formatNumber(commitRow.entry.stars)
            textFormat: Text.PlainText
            color: Qt.darker(root.barForeground, 1.4)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
          }

          Text {
            visible: commitRow.entry.replies > 0
            text: "\uf0e0 " + Commons.I18n.formatNumber(commitRow.entry.replies)
            textFormat: Text.PlainText
            color: Qt.darker(root.barForeground, 1.4)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
          }
        }
      }
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onContainsMouseChanged: if (containsMouse) {
        root.cursorActive = true
        root.cursorIndex = commitRow.rowIndex
      }
      onClicked: root.openCommit(commitRow.entry)
    }
  }
}