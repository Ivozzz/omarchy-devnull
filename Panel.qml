import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

// The /dev/null panel: three feeds (the people you watch or the site's own
// follows, Latest, Trending) plus a lookup box for any GitHub username on
// dev-null.sh.
//
// Signed out, "following" is the plugin's own watchlist, merged from one API
// request per watched user, plus a second one each when replies are switched
// on. Those run strictly one after another (60/minute per IP is the whole
// budget). Signed in, all three feeds come from the site's own signed API —
//  one request each — and Following is the real follow graph.
//
// The last good feed stays on screen while a refresh runs.
Panel {
  id: root
  moduleName: "io.github.ivozzz.devnull"
  ipcTarget: "io.github.ivozzz.devnull"
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
  readonly property string defaultWatch: Model.DEFAULT_WATCH
  readonly property var watchList: Model.watchList(setting("watch", root.defaultWatch))
  // True when the entry never carried a watchlist of its own, so the four
  // names are this plugin's examples rather than a choice.
  readonly property bool watchIsDefault: setting("watch", undefined) === undefined
  readonly property string view: Model.view(setting("view", "following")) || "following"
  readonly property var views: Model.VIEWS

  // A boolean setting arrives in two shapes: a real boolean when the settings
  // form wrote it, and a string when `omarchy bar set` did — and "false" is a
  // truthy string, so reading it the obvious way would leave a feature the
  // user just switched off switched on.
  function boolSetting(name, fallback) {
    var value = setting(name, undefined)
    if (value === undefined || value === null) return fallback
    if (typeof value === "boolean") return value
    var text = String(value).trim().toLowerCase()
    if (text === "false" || text === "0" || text === "no" || text === "off") return false
    if (text === "true" || text === "1" || text === "yes" || text === "on") return true
    return fallback
  }

  // A view changed from anywhere — a tab click or `omarchy bar set` — refills
  // the feed straight away instead of leaving the old one up until the timer.
  // It is also the answer to a step the arrows asked for: clear it once the bar
  // confirms, or write the step that arrived while this one was out.
  onViewChanged: {
    root.viewWritePending = false
    if (root.requestedView === root.view) root.requestedView = ""
    else root.commitView()
    // A different feed is a different list: keeping the old index would
    // highlight an unrelated row, and keeping the old offset would leave the
    // viewport somewhere in the middle of it. The old update time belongs to
    // the old feed too, so the status line waits for this one to land.
    root.resetCursor()
    root.lastSuccessMs = 0
    // The count belonged to the feed being left; the bar must not show it over
    // the new tab before that feed has answered.
    root.freshCount = 0
    root.collapseExpanded()
    root.copiedId = ""
    // Whatever is in flight belongs to the feed being left. Bumping the epoch
    // here, not only when the reload starts, closes the gap in which a late
    // response could land on the new tab.
    root.fetchEpoch += 1
    root.abortFetches()
    root.loading = true
    Qt.callLater(function() {
      root.scrollFeedToTop()
      root.refresh(true)
    })
  }
  // A second request per watched user: the API answers ?replies=1 with
  // replies only, so "include" means an extra fetch, not a wider page.
  readonly property bool includeReplies: root.boolSetting("includeReplies", false)
  readonly property int refreshMinutes: Math.max(1, Math.min(60, parseInt(setting("refreshMinutes", 5), 10) || 5))
  readonly property bool showAvatars: root.boolSetting("showAvatars", true)
  // A desktop notification when a watched developer posts. On by default,
  // because that is the point of watching somebody; `notifyNewPosts false`
  // turns it off. The README says so too — the widget refreshes on a timer
  // whether or not anyone is looking at it, and this is the one part of that
  // the user sees outside the panel.
  readonly property bool notifyNewPosts: root.boolSetting("notifyNewPosts", true)
  // A sound with that notification, so a post that lands while the panel is
  // shut is heard as well as seen. The notification service has no sound of its
  // own, so this is a second command beside the send; it takes the same switch
  // as the toast and is silenced with it by Do Not Disturb or a snooze.
  readonly property bool notifySound: root.boolSetting("notifySound", true)

  // ---- Account (optional) ----------------------------------------------
  // Signing in is a key the site approved for this widget, not a password and
  // not a session: it lives in the plugin's own state directory, under
  // $XDG_STATE_HOME, and never in shell.json. Signed out, everything still
  // works off the public API and the log pages.
  readonly property string home: String(Quickshell.env("HOME") || "")
  readonly property string xdgStateHome: String(Quickshell.env("XDG_STATE_HOME") || "")
  readonly property string accountDir: Model.stateDir(root.home, root.xdgStateHome)
  readonly property string keyPath: root.accountDir === "" ? "" : root.accountDir + "/device.key"
  readonly property string accountPath: root.accountDir === "" ? "" : root.accountDir + "/account.json"
  readonly property string callbackPath: root.accountDir === "" ? "" : root.accountDir + "/callback"
  readonly property string verifierPath: root.accountDir === "" ? "" : root.accountDir + "/verifier"
  readonly property string desktopPath: root.home === ""
    ? "" : root.home + "/.local/share/applications/devnull-callback.desktop"
  // The script the devnull:// redirect lands in. It sits beside this file, so
  // it moves with the plugin checkout.
  readonly property string callbackScript: {
    var url = String(Qt.resolvedUrl("bin/devnull-callback"))
    return url.indexOf("file://") === 0 ? decodeURIComponent(url.slice(7)) : ""
  }

  property var account: null
  readonly property bool signedIn: root.account !== null
  // The site's reply names the account, and that is what the panel shows; it is
  // already validated by the model (a username or nothing).
  readonly property string accountName: root.account ? String(root.account.username) : ""
  // Set when the site answers 401: the key was revoked under Settings →
  // Devices (or the account is gone), and the panel says so instead of
  // reporting a feed it could not read.
  property bool accountExpired: false
  // "" when nothing is happening, otherwise the step of the sign-in the panel
  // is on. "error" keeps the last error on screen until the next attempt.
  property string loginStep: ""
  property string loginError: ""
  property string loginState: ""
  property string loginVerifier: ""
  property string loginChallenge: ""
  property string loginUrl: ""
  property string loginFingerprint: ""
  readonly property bool signingIn: root.loginStep !== "" && root.loginStep !== "error"

  // ---- Feed state -------------------------------------------------------
  property var entries: []
  property var bundles: ({})
  property var attempts: ({})
  // One entry per request still to make: { user, replies }. Replies are a
  // second request per watched user, because the API's ?replies=1 answers
  // with replies only — it does not merge them into the top-level list.
  property var pending: []
  // The requests that came back unreadable, in the same shape. The status line
  // counts them and the retry asks for exactly these again.
  property var failedRequests: []
  property string activeUser: ""
  property bool activeReplies: false
  property var retryRequest: null
  property bool loading: false
  property int freshCount: 0
  // Ids already counted as seen, per feed, kept in memory for the shell
  // session only. Per feed because a commit on Latest is not news on the
  // watchlist, and counting it twice would turn the pill into decoration.
  property var seenByView: ({})
  // Bumped on every new feed load. Responses carry the epoch they were asked
  // for and are dropped when it no longer matches, so switching feeds while a
  // request is in flight cannot paint the old feed under the new tab.
  property int fetchEpoch: 0
  property int activeEpoch: 0
  // The API allows 60 requests a minute per IP and a refresh costs one request
  // per watched user, so reopening the panel must not be able to spend the
  // whole budget in a minute.
  property double lastRefreshMs: 0
  // When the last refresh actually put commits on screen. The status line
  // under the tabs says so, which is also the only way to tell a feed that is
  // quiet from one that stopped updating.
  property double lastSuccessMs: 0
  // Ages are computed against this instead of Date.now(): a binding that calls
  // Date.now() directly has no dependency to re-evaluate, so a row would keep
  // saying "2 minutes ago" until the feed changed. The timer below moves it.
  property double nowMs: Date.now()

  // ---- Lookup state -----------------------------------------------------
  property var lookup: null
  property bool lookupMissing: false
  property bool lookupInvalid: false
  property bool lookingUp: false
  // A second lookup while the first is still out must not paint the first
  // answer over it: the older reply is dropped, like a stale feed reply.
  property int lookupEpoch: 0
  property int lookupActiveEpoch: 0

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
    months: "%1 months ago",
    years: "%1 years ago"
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
  // The bar shows a single glyph, so the count it used to paint beside the
  // mark lives in the tooltip. It counts what arrived, not what the feed
  // holds: the feed size is almost always the same number (40), so it read as
  // decoration there.
  readonly property string tooltipText: root.fill(
    strings.tn("panel.commits", entries.length, "%1 commits"),
    Commons.I18n.formatNumber(entries.length)
  ) + " · " + root.viewLabel(root.view)
    + (root.freshCount > 0
      ? " · " + root.fill(strings.tn("panel.fresh", freshCount, "%1 new"),
        Commons.I18n.formatNumber(root.freshCount))
      : "")
    + (root.hasFailures ? " · " + root.statusText : "")

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

  // A failure used to be visible only when the whole feed was empty, so two
  // watched developers timing out while the other two answered looked like a
  // complete feed. The status line under the tabs reports it either way, and
  // offers the retry.
  readonly property bool hasFailures: root.failedRequests.length > 0 || root.viewFailed

  readonly property string statusText: {
    if (root.accountExpired) return strings.t("account.expired", "The sign-in was revoked. Sign in again.")
    if (root.viewFailed) return strings.t("panel.unavailable", "This feed could not be read.")
    if (root.switchingFeed) return strings.t("panel.fetching", "Fetching…")

    var parts = []
    if (root.lastSuccessMs > 0) {
      parts.push(root.fill(
        strings.t("panel.updated", "Updated %1"),
        root.ageLabelMs(root.lastSuccessMs)
      ))
    }
    if (root.failedRequests.length > 0) {
      parts.push(root.fill(
        strings.tn("panel.failed", root.failedRequests.length, "%1 requests failed"),
        Commons.I18n.formatNumber(root.failedRequests.length)
      ))
    }
    return parts.join(" · ")
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

  // The panel keeps its scroll offset and its keyboard cursor between opens:
  // content stays loaded after the first one. Both belong to a single visit,
  // so they start clean every time, and the ages are recomputed at the same
  // moment even if they sat still while the panel was shut.
  onOpenedChanged: {
    root.nowMs = Date.now()
    root.resetCursor()
    root.collapseExpanded()
    root.copiedId = ""
    if (root.opened) Qt.callLater(root.scrollFeedToTop)
  }

  function resetCursor() {
    root.cursorActive = false
    root.cursorIndex = -1
  }

  function scrollFeedToTop() {
    // The scroll area is inside the lazily built content, which the panel root
    // cannot name; it is asked to move its own viewport.
    var content = panel.loadedContent
    if (content && typeof content.scrollFeedToTop === "function")
      content.scrollFeedToTop()
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

  // Stops whatever is in flight and forgets which request it was. The epoch,
  // not this, is what makes a late stdout callback harmless.
  function abortFetches() {
    if (feedProc.running) feedProc.running = false
    if (pageProc.running) pageProc.running = false
    feedSign.abort()
    retryTimer.stop()
    root.activeUser = ""
    root.activeReplies = false
    root.retryRequest = null
  }

  // `force` is for the explicit ones (the r key, middle click, a tab change);
  // opening the panel and the refresh timer take the quiet path.
  function refresh(force) {
    var now = Date.now()
    if (!force && root.lastRefreshMs > 0 && now - root.lastRefreshMs < 60000) return
    root.lastRefreshMs = now

    root.fetchEpoch += 1
    root.activeEpoch = root.fetchEpoch
    root.abortFetches()

    root.failedRequests = []
    // A log page that failed to parse must not keep the status line on
    // "This feed could not be read" after switching back to the watchlist.
    root.viewFailed = false
    // Signed in, every feed is one signed API call: no watchlist merge, and no
    // page parsing.
    if (root.signedIn) {
      root.startSignedFetch()
      return
    }
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
    // One request for the top-level commits, and — when the setting is on —
    // one more for the replies. They are separate lists on the API, so a feed
    // that wants both asks twice.
    root.pending = []
    for (var i = 0; i < users.length; i++) {
      root.pending.push({ user: users[i], replies: false })
      if (root.includeReplies) root.pending.push({ user: users[i], replies: true })
    }
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
    Util.execArgv(["omarchy-bar", "set", "io.github.ivozzz.devnull", "view", next])
  }

  // Left and right step through the tabs in the order they are drawn, wrapping
  // at either end: Following, Latest, Trending and back.
  //
  // A step is saved through shell.json like a tab click, but that is a round
  // trip — the CLI writes the file, the bar reads it back — and a held arrow
  // key outruns it: every press would step from the tab it just left and land
  // on the same one. So the step is taken from the last request rather than
  // from the confirmed view, and while one write is out only the newest
  // request is kept, written when the bar answers.
  property string requestedView: ""
  property bool viewWritePending: false
  readonly property string stepFrom: requestedView !== "" ? requestedView : view
  // What the tabs draw. A write is a round trip through shell.json, so the
  // confirmed `view` lags a click; without this the old tab stays selected
  // while the new one is already being fetched.
  readonly property string displayView: requestedView !== "" ? requestedView : view
  // Rows on screen that belong to the feed being left: they stay readable
  // while the next one loads, dimmed, instead of pretending to be the new one.
  readonly property bool switchingFeed: root.loading && root.lastSuccessMs === 0 && root.entries.length > 0

  function nextView(step) {
    var names = root.views
    if (names.length === 0 || step === 0) return root.stepFrom
    var index = names.indexOf(root.stepFrom)
    if (index < 0) index = 0
    return names[(((index + step) % names.length) + names.length) % names.length]
  }

  function cycleView(step) {
    var next = root.nextView(step)
    if (next === root.stepFrom) return
    root.requestedView = next
    root.commitView()
  }

  function commitView() {
    if (root.viewWritePending) return
    if (root.requestedView === "" || root.requestedView === root.view) return
    root.viewWritePending = true
    root.setView(root.requestedView)
  }

  // A click on a tab is an absolute choice, not a step: it drops whatever the
  // arrows still had waiting to be written.
  function pickView(name) {
    root.requestedView = ""
    root.viewWritePending = false
    root.setView(name)
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
    if (root.activeEpoch !== root.fetchEpoch) return
    root.loading = false
    // A page that carries a feed and no commits is an empty feed; a page
    // without one is the failure this state exists for.
    root.viewFailed = Model.pageFeed(raw) === null
    root.applyFeed(Model.parseLogPage(raw))
  }

  // One signed request, for whichever feed is current. `fetchEpoch` guards it
  // like the pages and the watchlist: a late answer for a feed the user has
  // left is dropped instead of painted under the new tab.
  function startSignedFetch() {
    var path = Model.logApiPath(root.view)
    if (path === "" || root.keyPath === "" || root.accountDir === "") {
      root.loading = false
      root.viewFailed = true
      return
    }
    root.loading = true
    feedSign.send("GET", path, "")
  }

  function onSignedFeedResponse(raw, status) {
    if (root.activeEpoch !== root.fetchEpoch) return
    root.loading = false

    // 401 is the key the site no longer honours, 403 a banned account: both
    // mean the approval is gone, which is a different thing from a feed that
    // could not be read, and the status line says so.
    if (status === 401 || status === 403) {
      root.accountExpired = true
      root.failedRequests = []
      root.viewFailed = false
      root.entries = []
      root.freshCount = 0
      return
    }

    var list = Model.feedList(raw)
    root.viewFailed = status !== 200 || list === null
    if (list === null) {
      root.applyFeed([])
      return
    }
    root.accountExpired = false
    root.applyFeed(Model.parseCommitList(list, Model.FEED_LIMIT))
  }

  // A signed request that could not even be built: ssh-keygen refused, the key
  // is gone, the disk is full. The key is what is missing in practice, so the
  // panel asks for a new sign-in rather than blaming the network.
  function onSignedFeedFailed(reason) {
    if (root.activeEpoch !== root.fetchEpoch) return
    root.loading = false
    root.viewFailed = true
    root.entries = []
    root.freshCount = 0
    root.accountExpired = true
  }

  function nextUser() {
    if (root.pending.length === 0) {
      root.finish()
      return
    }
    root.startFetch(root.pending.shift())
  }

  // One request. The shape is the same as a `pending` entry: { user, replies }.
  function startFetch(request) {
    if (root.activeEpoch !== root.fetchEpoch) return
    var user = request && request.user ? String(request.user) : ""
    var replies = request ? request.replies === true : false
    var args = Model.fetchArgs(Model.commitsApiUrl(user, replies))
    if (args.length === 0) {
      root.failedRequests = root.failedRequests.concat([{ user: user, replies: replies }])
      root.nextUser()
      return
    }
    root.activeUser = user
    root.activeReplies = replies
    feedProc.command = args
    feedProc.running = true
  }

  // The key one request's retry budget is kept under. A user's commits and
  // their replies are two requests and get two budgets.
  function requestKey(request) {
    var user = request && request.user ? String(request.user) : ""
    return user + (request && request.replies === true ? "?replies=1" : "")
  }

  function onFeedResponse(raw) {
    if (root.activeEpoch !== root.fetchEpoch) return
    var user = root.activeUser
    var replies = root.activeReplies
    root.activeUser = ""
    root.activeReplies = false
    if (user === "") return

    var key = root.requestKey({ user: user, replies: replies })
    var commits = Model.parseCommits(raw)
    if (commits.length > 0) {
      // Keep whatever this user contributed earlier: the other half of their
      // feed, or a page that arrived before a retry must not shrink it.
      root.bundles = withKey(root.bundles, user, (root.bundles[user] || []).concat(commits))
      root.attempts = withKey(root.attempts, key, 0)
      root.nextUser()
      return
    }

    var tries = root.attempts[key] || 0
    if (tries < 1) {
      root.attempts = withKey(root.attempts, key, tries + 1)
      root.retryRequest = { user: user, replies: replies }
      retryTimer.restart()
      return
    }

    root.failedRequests = root.failedRequests.concat([{ user: user, replies: replies }])
    root.nextUser()
  }

  function finish() {
    if (root.activeEpoch !== root.fetchEpoch) return
    root.loading = false

    var groups = []
    for (var name in root.bundles) {
      if (root.bundles[name] && root.bundles[name].length > 0) groups.push(root.bundles[name])
    }

    root.applyFeed(Model.mergeCommits(groups, Model.FEED_LIMIT))
  }

  // The status line's retry. On the watchlist it asks only the requests that
  // failed, so it does not spend the successful ones again; anything else (a
  // log page, a feed that never arrived) is refreshed outright.
  function retry() {
    if (root.loading) return
    if (root.view === "following" && root.failedRequests.length > 0) {
      var requests = root.failedRequests.slice()
      root.failedRequests = []
      for (var i = 0; i < requests.length; i++)
        root.attempts = root.withKey(root.attempts, root.requestKey(requests[i]), 0)
      root.pending = requests
      root.loading = true
      root.lastRefreshMs = Date.now()
      root.fetchEpoch += 1
      root.activeEpoch = root.fetchEpoch
      root.nextUser()
      return
    }
    root.refresh(true)
  }

  // One place decides what a feed means for the rest of the panel: the rows,
  // the count in the bar, what counts as new since the last refresh, and
  // whether that is worth a notification. Each feed keeps its own list of what
  // has been shown, so Latest cannot pass for news on the watchlist, and the
  // first load of a feed has nothing to compare against: nothing in it reads
  // as new and nothing in it notifies.
  // `forView` names the feed the rows belong to, which is the current one
  // unless a caller says otherwise. The seen-ids bookkeeping is keyed by it, so
  // a commit that arrived on Latest is not counted again on the watchlist.
  function applyFeed(commits, forView) {
    var key = forView || root.view
    var known = root.seenByView[key]
    var wasPrimed = Array.isArray(known)
    var summary = Model.unseen(commits, wasPrimed ? known : [])
    var fresh = wasPrimed ? summary.count : 0

    root.seenByView = root.withKey(root.seenByView, key, Model.markSeen(wasPrimed ? known : [], commits))

    root.entries = commits
    root.freshCount = fresh
    if (commits.length > 0) root.lastSuccessMs = Date.now()
    if (root.cursorIndex >= commits.length) root.cursorIndex = commits.length - 1

    if (wasPrimed) root.maybeNotify(summary)
  }

  // ---- Notifications -----------------------------------------------------
  // Only for the watchlist: Latest and Trending are everybody's posts, and a
  // notification for those would be noise. Skipped while the panel is open,
  // since the rows are already on screen. Dedup is the seen-ids bookkeeping
  // above — a commit is counted once, so it notifies once.
  function maybeNotify(summary) {
    if (!root.notifyNewPosts) return
    if (root.view !== "following") return
    if (root.opened) return
    if (!summary || summary.count === 0) return

    var argv = root.notifyArgv(summary)
    if (argv.length === 0) return
    Util.execArgv(argv)
    root.playNotifySound()
  }

  // The argv for one notification. A list, never a shell string: the headline
  // and the body carry text that came off the network, and the click target is
  // the commit URL the model rebuilt from a validated username and id.
  //
  // `--app-name dev-null.sh` is deliberate. The notification service treats
  // Omarchy's own action toasts as ephemeral and lets them past Do Not
  // Disturb; a background feed update is neither, so it names itself and takes
  // the ordinary path: silenced by DND, kept in history.
  function notifyArgv(summary) {
    if (!summary || summary.count === 0) return []

    var names = []
    for (var i = 0; i < summary.authors.length; i++) names.push("@" + summary.authors[i])
    var headline = root.fill(strings.t("notify.authors", "%1 posted on /dev/null"), names.join(", "))
    if (headline === "") return []

    var body = ""
    if (summary.count > 1) {
      body = root.fill(
        strings.tn("notify.count", summary.count, "%1 new commits"),
        Commons.I18n.formatNumber(summary.count)
      ) + "\n"
    }
    if (summary.newest) body += Model.excerpt(summary.newest.body, 140)
    if (body === "") body = headline

    var argv = [
      "omarchy-notification-send",
      "--app-name", "dev-null.sh",
      "-g", "\uf120",
      // A fixed replacement id: a burst while you are away updates one
      // notification instead of stacking five.
      "--replace-id", "91507",
      headline,
      body
    ]

    // --exec has to come last: it swallows the rest of the argv.
    if (summary.newest && summary.newest.url !== "") {
      argv.push("--exec", "omarchy-launch-browser", summary.newest.url)
    }
    return argv
  }

  // The sound that rides with a notification, or an empty list when there is
  // none to play. A list for the same reason as the notification's: it is run
  // as an argv vector, never re-parsed by a shell.
  //
  // `message-new-instant` is the freedesktop sound event for an arriving
  // message, and canberra resolves it through the sound theme the user has
  // active, so changing the theme changes what is heard.
  function soundArgv() {
    if (!root.notifySound) return []
    // The sound has to stop where the toast stops. The notification service's
    // own `quiet` flag covers both switches: Do Not Disturb and a snooze. (The
    // older check read `doNotDisturb` alone, so a snoozed service swallowed
    // the toast and played the sound.) If the service is not reachable the
    // check is skipped, not the sound: the plugin cannot see the setting
    // either way, and a notification that was sent and never seen is a bigger
    // surprise than one that was heard.
    var service = root.bar && root.bar.shell
      && typeof root.bar.shell.firstPartyServiceFor === "function"
      ? root.bar.shell.firstPartyServiceFor("omarchy.notifications") : null
    if (service && (service.quiet === true || service.doNotDisturb === true)) return []
    return ["canberra-gtk-play", "-i", "message-new-instant"]
  }

  function playNotifySound() {
    var argv = root.soundArgv()
    if (argv.length === 0) return
    Util.execArgv(argv)
  }

  Timer {
    id: retryTimer
    interval: 2500
    onTriggered: {
      var request = root.retryRequest
      root.retryRequest = null
      // Nothing to retry means the batch was aborted (a feed switch, a new
      // refresh): restarting it here would run alongside the new one.
      if (request) root.startFetch(request)
    }
  }

  // Paused while the panel is open: a background refresh would reorder the
  // rows under the cursor and the scroll while somebody is reading them. The
  // timer restarts on close, and triggeredOnStart catches the feed up right
  // away — the quiet path's one-minute guard still applies.
  Timer {
    id: refreshTimer
    interval: root.refreshMinutes * 60 * 1000
    running: !root.opened
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  // Moves the clock the age labels read, so "2 minutes ago" becomes "3" while
  // the panel is open. Only while it is: a closed panel has nobody to show it
  // to, and this keeps the row bindings from re-evaluating every half minute.
  Timer {
    id: ageTimer
    interval: 30000
    running: root.opened
    repeat: true
    triggeredOnStart: true
    onTriggered: root.nowMs = Date.now()
  }

  Timer {
    id: copiedReset
    interval: 1500
    onTriggered: root.copiedId = ""
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

  // The commit page a row's replies are read from. One at a time: opening a
  // second row cancels the first rather than racing it.
  Process {
    id: repliesProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.onRepliesResponse(text)
    }
  }

  Process {
    id: lookupProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (root.lookupActiveEpoch !== root.lookupEpoch) return
        root.lookingUp = false
        root.lookupInvalid = false
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

  // ---- Sign-in plumbing -------------------------------------------------
  // One message, one signature, one request each. The two senders write to
  // different files so a feed refresh and a sign-in cannot clobber each
  // other's message.
  SignedRequest {
    id: feedSign
    keyPath: root.keyPath
    directory: root.accountDir
    slot: "sign-feed"
    onFinished: function(body, status) { root.onSignedFeedResponse(body, status) }
    onFailed: function(reason) { root.onSignedFeedFailed(reason) }
  }

  SignedRequest {
    id: loginSign
    keyPath: root.keyPath
    directory: root.accountDir
    slot: "sign-login"
    onFinished: function(body, status) { root.onDeviceResponse(body, status) }
    onFailed: function(reason) {
      if (root.loginStep !== "redeem") return
      root.loginFailed(strings.t("account.failed", "The sign-in did not complete."))
    }
  }

  // The account, read synchronously so the first refresh already knows whether
  // it should sign its request.
  FileView {
    id: accountFile
    path: root.accountPath
    blockLoading: true
    blockWrites: true
    atomicWrites: true
    printErrors: false
  }

  // These two are written and then read by the next command in the chain, so
  // the write has to be on disk when setText returns, not queued.
  FileView {
    id: schemeFile
    path: root.desktopPath
    blockWrites: true
    atomicWrites: true
    printErrors: false
  }

  FileView {
    id: verifierFile
    path: root.verifierPath
    blockWrites: true
    atomicWrites: true
    printErrors: false
  }

  Component.onCompleted: root.loadAccount()

  function loginBroke() {
    root.loginFailed(strings.t("account.failed", "The sign-in did not complete."))
  }

  Process {
    id: dirProc
    onExited: function(code) {
      if (root.loginStep !== "start") return
      if (code !== 0) return root.loginBroke()
      root.loginPrepare()
    }
  }

  Process {
    id: appDirProc
    onExited: function(code) {
      if (root.loginStep !== "start") return
      if (code !== 0) return root.loginBroke()
      root.loginKey()
    }
  }

  // Every removal runs here. Only the key step waits for one — the key has to
  // be made after the old one is gone — so that is the only continuation.
  Process {
    id: removeProc
    onExited: function(code) {
      if (root.removeQueue.length > 0) {
        var queued = root.removeQueue
        root.removeQueue = []
        removeProc.command = ["rm", "-f"].concat(queued)
        removeProc.running = true
        return
      }
      if (root.loginStep === "key") root.loginKeyReady()
    }
  }

  Process {
    id: keygenProc
    onExited: function(code) {
      if (root.loginStep !== "key") return
      if (code !== 0) return root.loginBroke()
      root.loginReadFingerprint()
    }
  }

  Process {
    id: fingerprintProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (root.loginStep !== "key") return
        var fingerprint = Model.fingerprintFromSshKeygen(text)
        if (fingerprint === "") return root.loginBroke()
        root.loginFingerprint = fingerprint
        root.loginEntropy()
      }
    }
  }

  Process {
    id: entropyProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (root.loginStep !== "key") return
        root.loginEntropyReady(text)
      }
    }
  }

  Process {
    id: digestProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (root.loginStep !== "key") return
        root.loginChallengeReady(text)
      }
    }
  }

  Process {
    id: mimeProc
    onExited: function(code) {
      if (root.loginStep !== "key") return
      // Without the handler the browser has nowhere to send the code, so this
      // is a failure rather than something to retry quietly.
      if (code !== 0) return root.loginBroke()
      desktopDbProc.command = ["update-desktop-database", root.home + "/.local/share/applications"]
      desktopDbProc.running = true
    }
  }

  // xdg-mime writes the preference, but GIO and the portal a browser asks to
  // open devnull:// only list handlers the desktop database knows about. Skip
  // this and the browser answers "no application available" for a scheme
  // xdg-mime already points at.
  Process {
    id: desktopDbProc
    onExited: function(code) {
      if (root.loginStep !== "key") return
      if (code !== 0) return root.loginBroke()
      root.loginOpen()
    }
  }

  // A step that never got off the ground — no ssh-keygen, no xdg-mime, a
  // process that failed to start — would otherwise leave the clock spinning
  // for good. Every local step here takes well under a second, so a step with
  // nothing running ten seconds later is stuck rather than slow. The browser
  // wait is deliberately not covered: that one is the user's to take, and the
  // button cancels it.
  Timer {
    id: loginWatchdog
    interval: 10000
    repeat: true
    running: root.loginStep === "start" || root.loginStep === "key"
    onTriggered: {
      if (dirProc.running || appDirProc.running || removeProc.running || keygenProc.running
          || fingerprintProc.running || entropyProc.running || digestProc.running
          || mimeProc.running || desktopDbProc.running) return
      root.loginFailed(strings.t("account.failed", "The sign-in did not complete."))
    }
  }

  // The redirect the handler wrote. Polled rather than watched: the file only
  // exists between the approval and the redemption, and is deleted after.
  Timer {
    id: callbackPoll
    interval: 700
    repeat: true
    onTriggered: {
      if (root.loginStep !== "waiting") {
        callbackPoll.stop()
        return
      }
      if (callbackCat.running) return
      callbackCat.command = ["cat", root.callbackPath]
      callbackCat.running = true
    }
  }

  Process {
    id: callbackCat
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.onCallback(text)
    }
  }

  // ---- Notifications toggle ---------------------------------------------
  // A setting the user can see and change from here, rather than one that
  // only exists as a command in the README. Written through omarchy-bar like
  // every other setting, so it comes back through `settings` on its own.
  function toggleNotify() {
    Util.execArgv([
      "omarchy-bar", "set", "io.github.ivozzz.devnull", "notifyNewPosts",
      root.notifyNewPosts ? "false" : "true"
    ])
  }

  // ---- Lookup and watchlist --------------------------------------------
  // The username comes in as an argument rather than being read off the lookup
  // box: that field is part of the panel's lazily built content, in a component
  // scope of its own, and naming it from here is a runtime ReferenceError —
  // which is what pressing Enter in an empty box used to do. The content owns
  // the field and passes its text.
  function lookupUser(text) {
    // A pasted profile link is the common case; a repo link is not a person,
    // and silently doing nothing there left the box looking broken.
    var name = Model.usernameFromInput(text)
    if (name === "") {
      root.lookup = null
      root.lookupMissing = false
      root.lookingUp = false
      root.lookupEpoch += 1
      root.lookupInvalid = String(text === undefined || text === null ? "" : text).trim() !== ""
      return
    }
    var args = Model.fetchArgs(Model.profileApiUrl(name))
    // The model only refuses a URL it did not build, which cannot happen for
    // a validated username. If it ever does, say so instead of going quiet.
    if (args.length === 0) {
      root.lookup = null
      root.lookingUp = false
      root.lookupMissing = false
      root.lookupInvalid = true
      return
    }

    if (lookupProc.running) lookupProc.running = false
    root.lookupEpoch += 1
    root.lookupActiveEpoch = root.lookupEpoch
    root.lookingUp = true
    root.lookup = null
    root.lookupMissing = false
    root.lookupInvalid = false
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
  //
  // The new list comes back through `settings` on its own. The refetch waits
  // for that round trip instead of for a guessed delay: the old 600ms timer
  // could fire before the bar had written the file, and then fetch the list
  // the user had just changed.
  property bool watchWritePending: false
  function persistWatch(value) {
    root.watchWritePending = true
    Util.execArgv(["omarchy-bar", "set", "io.github.ivozzz.devnull", "watch", value])
  }
  onWatchListChanged: {
    if (!root.watchWritePending) return
    root.watchWritePending = false
    root.refresh(true)
  }

  // ---- Signing in -------------------------------------------------------
  // The steps, in order, and what answers each one:
  //
  //   start      install -d       the private state directory, then the
  //                                applications directory for the handler
  //   key        ssh-keygen       a key of the plugin's own, no passphrase
  //              ssh-keygen -lf   its fingerprint, which the approval names
  //              od               the PKCE verifier and the state
  //              sha256sum        the challenge hash of the verifier
  //              ssh-keygen       the devnull:// handler, registered with
  //                                xdg-mime before the page opens
  //   waiting    the browser      the approval page, polled for the redirect
  //   redeem     SignedRequest    POST /api/v1/devices with the one-time code
  //
  // A failure anywhere keeps the message on screen. Nothing is retried on its
  // own: a key that was never approved is thrown away, and the next attempt
  // starts from a fresh one.

  // The account file is the whole of the signed-in state: readable and carrying
  // a username means signed in, anything else means signed out. It is read once
  // at startup, and set by the sign-in itself — never watched, because
  // sign-out deletes it and a watched file would only report what the panel
  // already knows.
  function loadAccount() {
    var text = accountFile.text()
    root.account = text === "" ? null : Model.parseAccount(text)
    if (root.account === null) root.accountExpired = false
  }

  function startLogin() {
    if (root.signingIn) return
    if (root.accountDir === "" || root.keyPath === "" || root.callbackScript === "") {
      root.loginFailed(strings.t("account.noHome", "No home directory to keep the key in."))
      return
    }

    // Signing in again replaces whatever account was there, and the panel
    // falls back to the watchlist while the browser is open. A request from a
    // previous attempt must not land in this one.
    loginSign.abort()
    feedSign.abort()
    root.account = null
    root.accountExpired = false
    root.loginError = ""
    root.loginStep = "start"
    root.loginFingerprint = ""
    root.loginState = ""
    root.loginVerifier = ""
    root.loginChallenge = ""
    root.loginUrl = ""

    dirProc.command = ["install", "-d", "-m", "700", root.accountDir]
    dirProc.running = true
  }

  function loginPrepare() {
    appDirProc.command = ["install", "-d", "-m", "755", root.home + "/.local/share/applications"]
    appDirProc.running = true
  }

  // Anything an attempt may have left behind, including the account being
  // replaced. The private key goes too: the next attempt makes its own.
  function loginCleanup() {
    root.removeFiles(root.accountPath, root.keyPath, root.keyPath + ".pub",
                     root.callbackPath, root.verifierPath,
                     root.accountDir + "/sign-feed", root.accountDir + "/sign-feed.sig",
                     root.accountDir + "/sign-login", root.accountDir + "/sign-login.sig")
  }

  // Paths waiting for the removal process that is already running. Two
  // cleanups can overlap — a failure during a sign-out, say — and a Process
  // cannot be given a new command while it runs.
  property var removeQueue: []

  function removeFiles() {
    var paths = []
    for (var i = 0; i < arguments.length; i++) {
      var path = String(arguments[i] === undefined || arguments[i] === null ? "" : arguments[i])
      if (path !== "") paths.push(path)
    }
    if (paths.length === 0) return
    if (removeProc.running) {
      root.removeQueue = root.removeQueue.concat(paths)
      return
    }
    // argv, never a shell string: these paths are the plugin's own, and none of
    // them came off the network.
    removeProc.command = ["rm", "-f"].concat(paths)
    removeProc.running = true
  }

  // The cleanup runs first and the key is made when it has finished: the
  // removal is a process of its own, and starting ssh-keygen beside it would
  // let the two race over the same path. removeProc calls loginKeyReady().
  function loginKey() {
    root.loginStep = "key"
    root.loginCleanup()
  }

  function loginKeyReady() {
    if (root.loginStep !== "key") return
    keygenProc.command = [
      "ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", Model.DEVICE_NAME, "-f", root.keyPath
    ]
    keygenProc.running = true
  }

  function loginReadFingerprint() {
    fingerprintProc.command = ["ssh-keygen", "-lf", root.keyPath + ".pub"]
    fingerprintProc.running = true
  }

  function loginEntropy() {
    // 48 bytes: 32 for the PKCE verifier, 16 for the state. One read is enough
    // for both, and neither leaves the panel before the approval.
    entropyProc.command = ["od", "-An", "-N48", "-tx1", "/dev/urandom"]
    entropyProc.running = true
  }

  function loginEntropyReady(hex) {
    var bytes = Model.hexFromOd(hex)
    root.loginVerifier = bytes.slice(0, 64)
    root.loginState = bytes.slice(64, 96)
    if (!/^[0-9a-f]{64}$/.test(root.loginVerifier) || !/^[0-9a-f]{32}$/.test(root.loginState)) {
      root.loginFailed(strings.t("account.failed", "The sign-in did not complete."))
      return
    }

    // sha256sum hashes a file rather than an argument, and the verifier has to
    // reach the site only as a hash: it is written under the 0700 directory,
    // hashed, and removed with the rest of the attempt.
    verifierFile.setText(root.loginVerifier)
    digestProc.command = ["sha256sum", root.verifierPath]
    digestProc.running = true
  }

  function loginChallengeReady(digest) {
    root.loginChallenge = Model.base64UrlFromHex(Model.digestHex(digest))
    if (root.loginChallenge === "") {
      root.loginFailed(strings.t("account.failed", "The sign-in did not complete."))
      return
    }
    root.loginUrl = Model.authorizeUrl({
      fingerprint: root.loginFingerprint,
      deviceName: Model.DEVICE_NAME,
      challenge: root.loginChallenge,
      state: root.loginState
    })
    if (root.loginUrl === "") {
      root.loginFailed(strings.t("account.failed", "The sign-in did not complete."))
      return
    }

    // The browser hands devnull:// back to whatever xdg-mime points that scheme
    // at, so the handler is written and registered before the page opens.
    schemeFile.setText(Model.desktopEntry(root.callbackScript))
    mimeProc.command = ["xdg-mime", "default", "devnull-callback.desktop", Model.CALLBACK_SCHEME]
    mimeProc.running = true
  }

  function loginOpen() {
    if (root.loginUrl === "") {
      root.loginFailed(strings.t("account.failed", "The sign-in did not complete."))
      return
    }
    root.loginStep = "waiting"
    Util.execArgv(["omarchy-launch-browser", root.loginUrl])
    callbackPoll.restart()
  }

  // The URL the browser opened, read from the file the handler writes. Nothing
  // in it is trusted: the prefix, the state, and the shape of the code are
  // checked before the code is redeemed.
  function onCallback(raw) {
    if (root.loginStep !== "waiting") return
    var text = String(raw === undefined || raw === null ? "" : raw).trim()
    if (text === "") return

    callbackPoll.stop()
    var code = Model.parseCallbackUrl(text, root.loginState)
    if (code === "") {
      root.loginFailed(strings.t("account.cancelled", "The approval did not come back. Try again."))
      return
    }

    var body = Model.deviceBody(code, root.loginVerifier)
    if (body === "") {
      root.loginFailed(strings.t("account.failed", "The sign-in did not complete."))
      return
    }
    root.loginStep = "redeem"
    loginSign.send("POST", "/api/v1/devices", body)
  }

  function onDeviceResponse(raw, status) {
    if (root.loginStep !== "redeem") return
    if (status !== 200 && status !== 201) {
      var message = Model.parseErrorMessage(raw)
      root.loginFailed(message !== "" ? message : strings.t("account.failed", "The sign-in did not complete."))
      return
    }

    var user = Model.parseUser(raw)
    var json = user ? Model.accountJson(user, root.loginFingerprint, new Date().toISOString()) : ""
    var account = json === "" ? null : Model.parseAccount(json)
    if (!user || !account) {
      root.loginFailed(strings.t("account.failed", "The sign-in did not complete."))
      return
    }

    accountFile.setText(json)
    root.account = account
    root.loginStep = ""
    root.loginError = ""
    root.loginVerifier = ""
    // The watchlist's seen ids do not belong to the site's own follows: a
    // commit first seen on one would not notify on the other.
    root.seenByView = root.withKey(root.seenByView, "following", [])
    // The one-time code and the verifier that redeemed it are spent, and there
    // is no reason to leave them on disk for the next request to trip over.
    root.removeFiles(root.callbackPath, root.verifierPath,
                     root.accountDir + "/sign-login", root.accountDir + "/sign-login.sig")
    root.refresh(true)
  }

  function loginFailed(message) {
    callbackPoll.stop()
    if (callbackCat.running) callbackCat.running = false
    loginSign.abort()
    root.loginStep = "error"
    root.loginError = String(message === undefined || message === null ? "" : message)
    root.loginCleanup()
  }

  function cancelLogin() {
    if (!root.signingIn) {
      root.loginError = ""
      root.loginStep = ""
      return
    }
    root.loginStep = ""
    root.loginError = ""
    callbackPoll.stop()
    if (callbackCat.running) callbackCat.running = false
    loginSign.abort()
    root.loginCleanup()
  }

  function signOut() {
    feedSign.abort()
    loginSign.abort()
    root.account = null
    root.accountExpired = false
    root.loginStep = ""
    root.loginError = ""
    root.seenByView = root.withKey(root.seenByView, "following", [])
    // The approval on the site is not this plugin's to delete — the API has no
    // route for it — so the README says where to revoke it.
    root.removeFiles(root.accountPath, root.keyPath, root.keyPath + ".pub",
                     root.callbackPath, root.verifierPath, root.desktopPath,
                     root.accountDir + "/sign-feed", root.accountDir + "/sign-feed.sig",
                     root.accountDir + "/sign-login", root.accountDir + "/sign-login.sig")
    root.refresh(true)
  }

  function toggleAccount() {
    if (root.signingIn) root.cancelLogin()
    else if (root.signedIn && !root.accountExpired) root.signOut()
    else root.startLogin()
  }

  function accountTooltip() {
    if (root.signingIn) return strings.t("account.pending", "Waiting for the browser — click to cancel")
    if (root.signedIn && !root.accountExpired) {
      return root.fill(strings.t("account.signedIn", "Signed in as @%1 — click to sign out"), root.accountName)
    }
    if (root.accountExpired) return strings.t("account.renew", "Sign in again")
    return strings.t("account.signIn", "Sign in with GitHub")
  }

  // ---- Commit actions ---------------------------------------------------
  // Which row is expanded to its full body and replies, and which one just had
  // its link copied — a row that answers a right click with nothing looks
  // broken.
  property string expandedId: ""
  property string copiedId: ""
  // One commit page per row, kept for the visit: expanding the same row twice
  // must not spend a second request on it.
  property var replyPages: ({})
  property bool repliesLoading: false
  property bool repliesFailed: false
  // A reply that arrives after the row was collapsed, or after another row was
  // opened, belongs to a request nobody is waiting for any more.
  property int repliesEpoch: 0
  property int repliesActiveEpoch: 0

  function openCommit(entry) {
    // Rebuilt in the model from a validated username and id, so this is a
    // dev-null.sh commit page and nothing else.
    if (!entry || entry.url === "") return
    Util.execArgv(["omarchy-launch-browser", entry.url])
  }

  // The one thing a read-only feed still needs: the address of a commit, for
  // pasting into a chat or an issue. wl-copy ships with the clipboard plugin.
  function copyCommitUrl(entry) {
    if (!entry || entry.url === "") return
    Util.execArgv(["wl-copy", "--", entry.url])
    root.copiedId = entry.id
    copiedReset.restart()
  }

  function toggleExpanded(id) {
    if (root.expandedId === id) {
      root.collapseExpanded()
      return
    }
    root.cancelReplies()
    root.expandedId = id
    root.loadReplies(id)
  }

  function collapseExpanded() {
    root.expandedId = ""
    root.cancelReplies()
  }

  // Drops whatever reply request is in flight and anything waiting on it. The
  // epoch, not this, is what makes a late stdout callback harmless.
  function cancelReplies() {
    root.repliesEpoch += 1
    root.repliesLoading = false
    root.repliesFailed = false
    root.repliesActiveEpoch = 0
    if (repliesProc.running) repliesProc.running = false
  }

  function entryById(id) {
    for (var i = 0; i < root.entries.length; i++) {
      if (root.entries[i].id === id) return root.entries[i]
    }
    return null
  }

  // The replies to one commit come off its page, not the API. A commit nobody
  // has answered has nothing to fetch, so expanding it only shows the whole
  // body.
  function loadReplies(id) {
    if (id === "" || root.replyPages[id] !== undefined) return
    var entry = root.entryById(id)
    if (!entry || entry.replies <= 0) return
    var args = Model.commitPageFetchArgs(Model.commitUrl(entry.authorUsername, entry.id))
    if (args.length === 0) {
      root.repliesFailed = true
      return
    }
    root.repliesEpoch += 1
    root.repliesActiveEpoch = root.repliesEpoch
    root.repliesLoading = true
    root.repliesFailed = false
    repliesProc.command = args
    repliesProc.running = true
  }

  function onRepliesResponse(raw) {
    if (root.repliesActiveEpoch !== root.repliesEpoch) return
    root.repliesLoading = false
    var id = root.expandedId
    var page = Model.commitReplies(raw)
    if (page === null) {
      root.repliesFailed = true
      return
    }
    root.replyPages = root.withKey(root.replyPages, id, page)
  }

  function repliesFor(id) {
    var page = root.replyPages[id]
    return page ? page.replies : []
  }

  function repliesRemainingFor(id) {
    var page = root.replyPages[id]
    return page ? page.remaining : 0
  }

  // A commit the feed counted replies for, but whose page carried none (a
  // deleted or still-moderated answer): the row says so instead of showing an
  // empty space under the body.
  function repliesEmptyFor(id) {
    var page = root.replyPages[id]
    return page !== undefined && page.replies.length === 0
  }

  function openProfile(name) {
    var url = Model.pageUrl(name)
    if (url === "") return
    Util.execArgv(["omarchy-launch-browser", url])
  }

  // ---- Display helpers --------------------------------------------------
  function ageLabel(iso) {
    return root.ageLabelMs(Date.parse(String(iso === undefined || iso === null ? "" : iso)))
  }

  function ageLabelMs(ms) {
    var age = Model.ageUnit(ms, root.nowMs)
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
    // The feed's scroll area is built lazily inside the panel's content, in a
    // component scope of its own: `feedScroll` is not visible here, and naming
    // it from the panel root is a runtime ReferenceError, not a load error. The
    // content scrolls its own row and is asked to.
    var content = panel.loadedContent
    if (content && typeof content.scrollRowIntoView === "function")
      content.scrollRowIntoView(row)
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
      id: contentRoot
      implicitHeight: feedColumn.implicitHeight + hintLine.implicitHeight + Style.space(8)
      anchors.fill: parent
      blocked: searchField.activeFocus
      onMoveRequested: function(dx, dy) {
        if (dy !== 0) root.moveCursor(dy)
        else if (dx !== 0) root.cycleView(dx)
      }
      onActivateRequested: root.activateCursor()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(text) {
        if (text === "r" || text === "R") root.refresh(true)
        else if (text === "/") searchField.forceActiveFocus()
        else if (text === "1") root.pickView("following")
        else if (text === "2") root.pickView("latest")
        else if (text === "3") root.pickView("trending")
      }

      // Bring one row into the viewport. Defined here, beside the scroll area it
      // moves, because that area is part of this lazily built content: the
      // panel root cannot see `feedScroll` (naming it from there is a runtime
      // ReferenceError), and the root is not a Flickable either. The feed is a
      // Flickable over a Column rather than a ListView, so there is no
      // positionViewAtIndex to call — a row's own y is already its offset in
      // the scrolled content, and scrolling is what turns a cursor move at the
      // edge into the next row coming up rather than a highlight sliding off.
      function scrollFeedToTop() {
        feedScroll.contentY = 0
      }

      function scrollRowIntoView(row) {
        if (!row) return
        var margin = Style.space(12)
        var top = row.y
        var bottom = top + row.height
        if (top < feedScroll.contentY + margin) {
          feedScroll.contentY = Math.max(0, top - margin)
        } else if (bottom > feedScroll.contentY + feedScroll.height - margin) {
          var lowest = Math.max(0, feedScroll.contentHeight - feedScroll.height)
          feedScroll.contentY = Math.min(lowest, bottom + margin - feedScroll.height)
        }
      }

      Flickable {
        id: feedScroll
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: hintLine.top
        anchors.bottomMargin: Style.space(8)
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

              DevNullMark {
                anchors.verticalCenter: parent.verticalCenter
                size: Style.space(20)
                surroundingColor: root.barForeground
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

            Row {
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(4)

              // Signed out this is the way in; signed in it says who, and a
              // click signs out. While the browser is open it is the cancel.
              PanelActionButton {
                id: accountButton
                anchors.verticalCenter: parent.verticalCenter
                iconText: root.signedIn && !root.accountExpired
                  ? "\uf007"  // nf-fa-user
                  : (root.signingIn ? "\uf017" : "\uf09b")  // clock / github
                foreground: root.accountExpired ? Commons.Color.urgent : root.barForeground
                tooltipText: root.accountTooltip()
                onClicked: root.toggleAccount()

                RotationAnimator on rotation {
                  running: root.signingIn && !Style.reduceMotion
                  from: 0
                  to: 360
                  duration: 1400
                  loops: Animation.Infinite
                }
              }

              PanelActionButton {
                id: refreshButton
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
          }

          // ---- Lookup --------------------------------------------------
          Row {
            width: parent.width
            spacing: Style.space(6)

            TextField {
              id: searchField
              width: parent.width - lookupButton.width - notifyButton.width - parent.spacing * 2
              placeholderText: strings.t("search.placeholder", "GitHub username")
              foreground: root.barForeground
              font.family: root.bar.fontFamily
              onAccepted: root.lookupUser(searchField.text)

              // The key catcher is blocked while this field has focus, so Esc
              // has to hand focus back itself instead of just emptying the
              // box and leaving the user stuck in it.
              Keys.onPressed: function(event) {
                if (event.key === Qt.Key_Escape) {
                  if (searchField.text !== "") {
                    searchField.text = ""
                    root.lookup = null
                    root.lookupMissing = false
                    root.lookupInvalid = false
                  } else {
                    contentRoot.forceActiveFocus()
                  }
                  event.accepted = true
                  return
                }
                // Down leaves the box and starts walking the feed where the
                // eye already is, instead of requiring a click.
                if (event.key === Qt.Key_Down || event.key === Qt.Key_Up) {
                  contentRoot.forceActiveFocus()
                  root.moveCursor(event.key === Qt.Key_Down ? 1 : -1)
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
                root.lookupUser(searchField.text)
              }

              RotationAnimator on rotation {
                running: root.lookingUp && !Style.reduceMotion
                from: 0
                to: 360
                duration: 900
                loops: Animation.Infinite
              }
            }

            // The notification switch, next to the lookup rather than buried
            // in a settings file. Off state is dimmed rather than hidden: the
            // point is that the choice exists, so it stays visible either way.
            PanelActionButton {
              id: notifyButton
              anchors.verticalCenter: parent.verticalCenter
              iconText: root.notifyNewPosts ? "\uf0f3" : "\uf0f4"  // bell / bell-slash
              foreground: root.notifyNewPosts ? root.barForeground : Qt.darker(root.barForeground, 1.5)
              tooltipText: root.notifyNewPosts
                ? strings.t("notify.action.off", "Notifications on — click to mute")
                : strings.t("notify.action.on", "Notifications off — click to unmute")
              onClicked: root.toggleNotify()
            }
          }

          // ---- Sign-in progress and errors ----------------------------
          // The browser is the only place the approval can happen, so the
          // panel says what it is waiting for instead of looking stuck.
          Text {
            width: parent.width
            visible: root.signingIn || (root.loginStep === "error" && root.loginError !== "")
            text: root.loginStep === "error"
              ? root.loginError
              : (root.loginStep === "waiting"
                ? strings.t("account.approve", "Approve the /dev/null app in your browser, then come back here.")
                : strings.t("account.preparing", "Preparing the sign-in…"))
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
            color: root.loginStep === "error" ? Commons.Color.urgent : Qt.darker(root.barForeground, 1.35)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          // ---- Profile card for a looked-up user ----------------------
          Rectangle {
            id: profileCard
            visible: root.lookingUp || root.lookupInvalid || !!root.lookup || root.lookupMissing
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
                visible: root.lookingUp
                text: strings.t("search.looking", "Looking up…")
                textFormat: Text.PlainText
                color: Qt.darker(root.barForeground, 1.4)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.bodySmall
                font.italic: true
              }

              Text {
                width: parent.width
                visible: root.lookupInvalid
                text: strings.t("search.invalid", "That is not a GitHub username or a profile link.")
                textFormat: Text.PlainText
                wrapMode: Text.WordWrap
                color: Qt.darker(root.barForeground, 1.4)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.bodySmall
              }

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
                  // Signed in, Following is the site's own follow graph, so a
                  // watch button here would promise something it cannot do.
                  visible: !!root.lookup && !root.signedIn
                  iconText: root.lookup && root.isWatched(root.lookup.username) ? "\uf00c" : "\uf067"
                  tooltipText: root.lookup && root.isWatched(root.lookup.username)
                    ? strings.t("action.unwatch", "Stop watching")
                    : strings.t("action.watch", "Watch")
                  onClicked: root.toggleWatch(root.lookup.username)
                }
              }
            }
          }

          // ---- Watching ------------------------------------------------
          // The watchlist used to be invisible: the only way to remove
          // somebody was to find them again in the lookup box. The chips make
          // it a list you can see, open, and prune.
          //
          // Signed in they are hidden, because Following is then the site's own
          // follow graph: the chips would claim an influence they no longer
          // have, and following people is done on the site.
          Column {
            width: parent.width
            spacing: Style.space(6)
            visible: !root.signedIn && root.watchList.length > 0

            PanelSectionHeader {
              text: root.fill(strings.t("watch.title", "Watching %1/%2"), [
                Commons.I18n.formatNumber(root.watchList.length),
                Commons.I18n.formatNumber(Model.WATCH_LIMIT)
              ])
              foreground: root.barForeground
              fontFamily: root.bar.fontFamily
            }

            Flow {
              width: parent.width
              spacing: Style.space(6)

              Repeater {
                model: root.watchList

                WatchChip {
                  required property var modelData
                  user: String(modelData)
                }
              }
            }

            Text {
              width: parent.width
              visible: root.watchIsDefault
              text: strings.t("watch.hint", "These four are examples — look up a username above to build your own list.")
              textFormat: Text.PlainText
              wrapMode: Text.WordWrap
              color: Qt.darker(root.barForeground, 1.4)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          // Signed in, Following is not this plugin's watchlist any more: it is
          // the site's own follow graph, and the panel says whose. The chips
          // would claim an influence they no longer have, and following people
          // is done on the site.
          Text {
            width: parent.width
            visible: root.signedIn
            text: root.fill(
              strings.t("account.following", "Signed in as @%1 — Following is the people they follow on /dev/null."),
              root.accountName
            )
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
            color: Qt.darker(root.barForeground, 1.35)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
          }

          PanelSeparator {
            visible: root.entries.length > 0
              || (root.signedIn ? root.view === "following" : root.watchList.length > 0)
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
                activeView: root.displayView
                onPicked: root.pickView(modelData)
              }
            }
          }

          // ---- Status -------------------------------------------------
          // How old the feed is, and whether part of it is missing. Both used
          // to be invisible whenever rows were on screen: a refresh that lost
          // two users out of four still looked like a complete feed.
          Row {
            id: statusRow
            width: parent.width
            spacing: Style.space(6)
            visible: root.lastSuccessMs > 0 || root.hasFailures || root.switchingFeed

            Text {
              width: Math.max(0, parent.width - (statusRetry.visible ? statusRetry.width + statusRow.spacing : 0))
              anchors.verticalCenter: parent.verticalCenter
              text: root.statusText
              textFormat: Text.PlainText
              elide: Text.ElideRight
              color: root.hasFailures ? Commons.Color.accent : Qt.darker(root.barForeground, 1.4)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
            }

            PanelActionButton {
              id: statusRetry
              anchors.verticalCenter: parent.verticalCenter
              visible: root.hasFailures
              iconText: "\uf01e"  // nf-fa-repeat
              foreground: Commons.Color.accent
              tooltipText: strings.t("action.retry", "Retry")
              onClicked: root.retry()
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
            visible: root.entries.length === 0 && !root.signedIn
              && root.view === "following" && root.watchList.length === 0
            text: strings.t("panel.noWatch", "Nobody to watch yet. Look up a username above.")
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
            color: Qt.darker(root.barForeground, 1.4)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          Text {
            width: parent.width
            visible: root.entries.length === 0 && root.loading
              && (root.view !== "following" || root.signedIn || root.watchList.length > 0)
            text: strings.t("panel.fetching", "Fetching…")
            textFormat: Text.PlainText
            color: Qt.darker(root.barForeground, 1.4)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
            font.italic: true
          }

        }
      }

      // Keys nobody finds by accident. Outside the Flickable, so the line
      // stays put while the feed scrolls under it.
      Text {
        id: hintLine
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        text: strings.t("panel.hints", "↵ open · r refresh · / search · 1–3 feeds · Esc close")
        textFormat: Text.PlainText
        elide: Text.ElideRight
        horizontalAlignment: Text.AlignRight
        color: Qt.darker(root.barForeground, 1.65)
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.caption
      }
    }
  }

  // One watched person: a chip that opens their profile, with the remove
  // action on its right edge.
  component WatchChip: Rectangle {
    id: watchChip
    required property string user

    readonly property bool hot: chipArea.containsMouse

    width: chipLabel.implicitWidth + chipRemove.width + Style.space(12)
    height: Style.space(26)
    radius: Style.cornerRadius
    color: watchChip.hot ? Style.hoverFillFor(root.barForeground, Commons.Color.accent) : "transparent"
    border.width: Style.normalBorderWidth
    border.color: Qt.darker(root.barForeground, 1.6)

    Text {
      id: chipLabel
      anchors.left: parent.left
      anchors.leftMargin: Style.space(7)
      anchors.verticalCenter: parent.verticalCenter
      text: "@" + watchChip.user
      textFormat: Text.PlainText
      color: root.barForeground
      font.family: root.bar.fontFamily
      font.pixelSize: Style.font.caption
    }

    PanelActionButton {
      id: chipRemove
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      iconText: "\uf00d"  // nf-fa-times
      foreground: Qt.darker(root.barForeground, 1.4)
      tooltipText: root.fill(strings.t("watch.remove", "Stop watching @%1"), watchChip.user)
      onClicked: root.toggleWatch(watchChip.user)
    }

    MouseArea {
      id: chipArea
      anchors.left: parent.left
      anchors.right: chipRemove.left
      anchors.top: parent.top
      anchors.bottom: parent.bottom
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: root.openProfile(watchChip.user)
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

    readonly property bool expanded: root.expandedId === commitRow.entry.id

    hasCursor: root.cursorActive && root.cursorIndex === rowIndex
    onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(commitRow)
    foreground: root.barForeground
    fill: Style.hoverFillFor(root.barForeground, Commons.Color.accent)
    implicitHeight: rowLayout.implicitHeight + Style.space(12)
    opacity: root.switchingFeed ? 0.45 : 1

    Behavior on opacity {
      NumberAnimation { duration: Style.duration(140); easing.type: Easing.OutCubic }
    }

    Row {
      id: rowLayout
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(6)
      anchors.rightMargin: Style.space(6) + expandButton.width
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

          // The right click answered, so the row says what it did. Without
          // this a copy and a missed click looked the same.
          Text {
            visible: root.copiedId === commitRow.entry.id
            text: strings.t("row.copied", "copied")
            textFormat: Text.PlainText
            color: Commons.Color.accent
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
          // Expanded, the row shows the body the feed already carries; the
          // cap is only there so a pathological commit cannot make one row
          // taller than the panel.
          maximumLineCount: commitRow.expanded ? 40 : 3
          elide: commitRow.expanded ? Text.ElideNone : Text.ElideRight
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

        // ---- Replies ---------------------------------------------
        // Expanding a row reads its answers in place. The public API has no
        // replies route, so they come off the commit's own page, which carries
        // the first three: one request per row, and the line at the bottom says
        // how many stayed on the site.
        Column {
          id: repliesColumn
          width: parent.width
          spacing: Style.space(5)
          visible: commitRow.expanded

          Text {
            width: parent.width
            visible: commitRow.entry.replies > 0
              && root.repliesLoading && root.expandedId === commitRow.entry.id
            text: strings.t("row.loadingReplies", "Loading replies…")
            textFormat: Text.PlainText
            color: Qt.darker(root.barForeground, 1.45)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
            font.italic: true
          }

          Text {
            width: parent.width
            wrapMode: Text.WordWrap
            visible: root.repliesFailed && root.expandedId === commitRow.entry.id
            text: strings.t("row.repliesFailed", "Could not read the replies.")
            textFormat: Text.PlainText
            color: Qt.darker(root.barForeground, 1.45)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
          }

          Text {
            width: parent.width
            visible: commitRow.entry.replies === 0 || root.repliesEmptyFor(commitRow.entry.id)
            text: strings.t("row.noReplies", "No replies yet.")
            textFormat: Text.PlainText
            color: Qt.darker(root.barForeground, 1.55)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
            font.italic: true
          }

          Repeater {
            model: root.repliesFor(commitRow.entry.id)

            Row {
              id: replyRow
              required property var modelData
              width: repliesColumn.width
              spacing: Style.space(8)

              SizedImage {
                width: Style.space(18)
                height: Style.space(18)
                visible: root.showAvatars && replyRow.modelData.avatarUrl !== ""
                url: replyRow.modelData.avatarUrl
              }

              Column {
                width: replyRow.width - Style.space(18) - replyRow.spacing
                spacing: Style.space(1)

                Row {
                  width: parent.width
                  spacing: Style.space(6)

                  Text {
                    text: "@" + replyRow.modelData.authorUsername
                    textFormat: Text.PlainText
                    color: root.barForeground
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: true
                  }

                  Text {
                    width: Math.max(0, parent.width - x - Style.space(40))
                    text: root.ageLabel(replyRow.modelData.createdAt)
                    textFormat: Text.PlainText
                    horizontalAlignment: Text.AlignRight
                    elide: Text.ElideRight
                    color: Qt.darker(root.barForeground, 1.6)
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.caption
                    anchors.verticalCenter: parent.verticalCenter
                  }
                }

                Text {
                  width: parent.width
                  text: replyRow.modelData.body
                  textFormat: Text.PlainText
                  wrapMode: Text.WordWrap
                  maximumLineCount: 3
                  elide: Text.ElideRight
                  color: Qt.darker(root.barForeground, 1.2)
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.bodySmall
                }

                // A reply that was answered in turn: the count is there, the
                // answers themselves are one click away on the site.
                Text {
                  visible: replyRow.modelData.replies > 0
                  text: "\uf0e0 " + Commons.I18n.formatNumber(replyRow.modelData.replies)
                  textFormat: Text.PlainText
                  color: Qt.darker(root.barForeground, 1.5)
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }
            }
          }

          Text {
            width: parent.width
            wrapMode: Text.WordWrap
            visible: root.repliesRemainingFor(commitRow.entry.id) > 0
            text: root.fill(
              strings.tn("row.moreReplies", root.repliesRemainingFor(commitRow.entry.id), "%1 more replies on dev-null.sh"),
              Commons.I18n.formatNumber(root.repliesRemainingFor(commitRow.entry.id))
            )
            textFormat: Text.PlainText
            color: Qt.darker(root.barForeground, 1.45)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
            font.italic: true
          }
        }
      }
    }

    // The row's body stays in the panel: clicking the row still opens the
    // commit, while this chevron reads the whole thing and its replies in
    // place. z keeps it above the row's MouseArea, which covers the rest of
    // the surface.
    PanelActionButton {
      id: expandButton
      z: 2
      anchors.right: parent.right
      anchors.rightMargin: Style.space(3)
      anchors.top: parent.top
      anchors.topMargin: Style.space(6)
      iconText: commitRow.expanded ? "\uf077" : "\uf078"  // chevron up / down
      foreground: Qt.darker(root.barForeground, 1.4)
      tooltipText: commitRow.expanded
        ? (commitRow.entry.replies > 0
          ? strings.t("row.hideReplies", "Hide replies")
          : strings.t("row.collapse", "Collapse"))
        : (commitRow.entry.replies > 0
          ? root.fill(
            strings.tn("row.showReplies", commitRow.entry.replies, "Show %1 replies"),
            Commons.I18n.formatNumber(commitRow.entry.replies)
          )
          : strings.t("row.expand", "Show full commit"))
      onClicked: root.toggleExpanded(commitRow.entry.id)
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      acceptedButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton
      onContainsMouseChanged: if (containsMouse) {
        root.cursorActive = true
        root.cursorIndex = commitRow.rowIndex
      }
      // Left opens the commit, middle the author's profile, right copies the
      // link — the feed is read-only, and that is the useful trio.
      onClicked: function(mouse) {
        if (mouse.button === Qt.MiddleButton) root.openProfile(commitRow.entry.authorUsername)
        else if (mouse.button === Qt.RightButton) root.copyCommitUrl(commitRow.entry)
        else root.openCommit(commitRow.entry)
      }
    }
  }

  // One signed API request: a nonce, the message ssh-keygen signs, the armored
  // signature reduced to the header's base64, and the request itself. Every
  // step is a process of its own because the Process here cannot write to a
  // stdin and close it — ssh-keygen reads the message from a file it wrote,
  // and its signature from another.
  component SignedRequest: Item {
    id: signRequest
    visible: false

    required property string keyPath
    required property string directory
    // Names the files one sender owns, so two requests in flight cannot
    // overwrite each other's message.
    required property string slot

    signal finished(string body, int status)
    signal failed(string reason)

    // "" when idle, otherwise the step this request is on. A reply that arrives
    // after abort() lands on "" and is dropped.
    property string step: ""
    property string method: "GET"
    property string path: ""
    property string body: ""
    property string timestamp: ""
    property string nonce: ""

    readonly property string messagePath: signRequest.directory === ""
      ? "" : signRequest.directory + "/" + signRequest.slot
    readonly property string signaturePath: signRequest.messagePath + ".sig"

    function send(requestMethod, pathAndQuery, requestBody) {
      signRequest.abort()
      if (signRequest.keyPath === "" || signRequest.messagePath === "") {
        signRequest.fail("missing")
        return
      }
      signRequest.method = String(requestMethod)
      signRequest.path = String(pathAndQuery)
      signRequest.body = String(requestBody === undefined || requestBody === null ? "" : requestBody)
      // Seconds, which is what the header carries. The server allows a small
      // window either side of its own clock.
      signRequest.timestamp = String(Math.floor(Date.now() / 1000))
      signRequest.step = "nonce"
      nonceProc.command = ["od", "-An", "-N16", "-tx1", "/dev/urandom"]
      nonceProc.running = true
    }

    function abort() {
      signRequest.step = ""
      if (nonceProc.running) nonceProc.running = false
      if (sigRemoveProc.running) sigRemoveProc.running = false
      if (signProc.running) signProc.running = false
      if (catProc.running) catProc.running = false
      if (curlProc.running) curlProc.running = false
    }

    function fail(reason) {
      signRequest.step = ""
      signRequest.failed(String(reason))
    }

    // The bytes to sign, or "" when the request is not the shape the server
    // checks — in which case nothing reaches the key.
    function message() {
      return Model.signedMessage(signRequest.timestamp, signRequest.nonce, signRequest.method,
                                 signRequest.path, signRequest.body)
    }

    function sign() {
      var text = signRequest.message()
      if (text === "") {
        signRequest.fail("message")
        return
      }
      // blockWrites on the FileView: ssh-keygen has to see the file by now.
      messageFile.setText(text)
      // ssh-keygen refuses to overwrite an existing .sig, silently and with a
      // zero exit status, so a stale one from an earlier request has to go.
      signRequest.step = "sign"
      sigRemoveProc.command = ["rm", "-f", signRequest.signaturePath]
      sigRemoveProc.running = true
    }

    FileView {
      id: messageFile
      path: signRequest.messagePath
      blockWrites: true
      atomicWrites: true
      printErrors: false
    }

    Process {
      id: nonceProc
      stdout: StdioCollector {
        waitForEnd: true
        onStreamFinished: {
          if (signRequest.step !== "nonce") return
          var hex = Model.hexFromOd(text)
          if (!/^[0-9a-f]{32}$/.test(hex)) {
            signRequest.fail("nonce")
            return
          }
          signRequest.nonce = hex
          signRequest.sign()
        }
      }
    }

    Process {
      id: sigRemoveProc
      onExited: function(code) {
        if (signRequest.step !== "sign") return
        signProc.command = [
          "ssh-keygen", "-Y", "sign", "-n", Model.AUTH_NAMESPACE,
          "-f", signRequest.keyPath, signRequest.messagePath
        ]
        signProc.running = true
      }
    }

    Process {
      id: signProc
      onExited: function(code) {
        if (signRequest.step !== "sign") return
        // A zero exit with no signature is the same refusal as an error: the
        // cat below finds nothing and the request is dropped.
        if (code !== 0) {
          signRequest.fail("sign")
          return
        }
        catProc.command = ["cat", signRequest.signaturePath]
        catProc.running = true
      }
    }

    Process {
      id: catProc
      stdout: StdioCollector {
        waitForEnd: true
        onStreamFinished: {
          if (signRequest.step !== "sign") return
          var args = Model.signedFetchArgs(signRequest.method, signRequest.path,
                                           signRequest.timestamp, signRequest.nonce, text,
                                           signRequest.body)
          if (args.length === 0) {
            signRequest.fail("signature")
            return
          }
          signRequest.step = "request"
          curlProc.command = args
          curlProc.running = true
        }
      }
    }

    Process {
      id: curlProc
      stdout: StdioCollector {
        waitForEnd: true
        onStreamFinished: {
          if (signRequest.step !== "request") return
          var split = Model.splitStatus(text)
          signRequest.step = ""
          signRequest.body = ""
          signRequest.nonce = ""
          signRequest.finished(split.body, split.status)
        }
      }
    }
  }
}