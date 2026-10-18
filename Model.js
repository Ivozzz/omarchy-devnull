// dev-null.sh model.
//
// The site publishes a public, read-only JSON API under /api/v1 with no
// authentication:
//
//   GET /api/v1/users/{username}           one public profile
//   GET /api/v1/users/{username}/commits   a user's commits, newest first, 20
//                                          per page (?replies=1 for replies)
//   GET /api/v1/commits/{id}               one commit
//
// Rate limit: 60 requests per minute per IP. There is no global timeline
// endpoint and no search, so the plugin's feed is the merged commit log of a
// watchlist of usernames.
//
// Everything below treats a response as untrusted input. Fields are read one
// by one with their expected type, every string is length-capped, markup and
// invisible characters are removed before a value can reach a Text, a tooltip,
// or a command line, and URLs are rebuilt from validated parts instead of
// being taken from the response.

// The three feeds the panel offers.
//
// "following" is the plugin's watchlist: the site's own /log/following answers
// 302 to the login page, and this plugin has no session and wants none. The
// watchlist is the same idea — the people you chose to follow — and it is the
// only one of the three that works off the public JSON API.
//
// "latest" and "trending" have no API endpoint. The site serves them as
// Inertia pages whose payload carries the same commit shape the API returns,
// so those two are read from there.
var VIEWS = ["following", "latest", "trending"];
var LOG_PATHS = { latest: "/log/latest", trending: "/log/trending" };

var BASE = "https://dev-null.sh";
var API = "https://dev-null.sh/api/v1";

// dev-null.sh caps a commit body at 4000 characters.
var BODY_LIMIT = 4000;
var FEED_LIMIT = 40;
var WATCH_LIMIT = 12;
var SEEN_LIMIT = 400;
var RESPONSE_LIMIT = 2 * 1024 * 1024;
// A log page carries the whole UI around the feed; the trending one is ~420 KB
// today, so this leaves room without letting a response grow unbounded.
var PAGE_LIMIT = 4 * 1024 * 1024;

var LIMITS = {
  username: 39,
  name: 80,
  bio: 400,
  company: 80,
  location: 80,
  website: 200,
  hash: 12,
  id: 40,
  url: 300
};

// Tag-shaped runs are dropped rather than escaped: every value here is shown
// as plain text, and some of them reach Omarchy-owned components (bar
// tooltips) whose Text format the plugin cannot set. An AutoText sink would
// otherwise promote `<img src="https://tracker.invalid/pixel">` to rich text
// and fetch it.
function strip(value, keepNewlines) {
  if (value === undefined || value === null) return "";
  var s = typeof value === "string" ? value : String(value);

  s = s.replace(/<[^>]*>/g, " ").replace(/[<>]/g, " ");
  // Bidi controls can disguise a run of text (a "commi‮t" that reads as a
  // different word), and the other C0 controls break a single-line row.
  s = s.replace(/[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F\u200E\u200F\u202A-\u202E\u2066-\u2069]/g, "");

  return keepNewlines
    ? s.replace(/[^\S\n]+/g, " ").replace(/ *\n */g, "\n").replace(/\n{3,}/g, "\n\n").trim()
    : s.replace(/\s+/g, " ").trim();
}

function cap(value, limit) {
  return value.length > limit ? value.slice(0, limit).replace(/\s+\S*$/, "").trim() : value;
}

// One line, for names, hashes, excerpts, and anything handed to a tooltip.
function line(value, limit) {
  return cap(strip(value, false), limit);
}

// Line breaks kept, for a commit body shown over several lines.
function multiline(value, limit) {
  return cap(strip(value, true), limit);
}

function boundedLimit(value, fallback, max) {
  var n = parseInt(String(value), 10);
  if (isNaN(n) || n <= 0) return fallback;
  return Math.min(n, max);
}

function isObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function count(value) {
  var n = parseInt(value === undefined || value === null || value === "" ? "0" : String(value), 10);
  if (isNaN(n) || n < 0) return 0;
  return Math.min(n, 999999);
}

// JSON.parse over a body a network process produced. Anything over the cap, or
// anything unparseable, is dropped rather than partially read.
function parse(raw, byteLimit) {
  var s = String(raw === undefined || raw === null ? "" : raw).trim();
  if (s === "" || s.length > (byteLimit || RESPONSE_LIMIT)) return null;
  try {
    var value = JSON.parse(s);
    return isObject(value) ? value : null;
  } catch (e) {
    return null;
  }
}

// A GitHub username, validated before it goes anywhere near a URL. 39
// characters is GitHub's own limit; no leading or trailing hyphen.
//
// Checked against the raw value, not the stripped one: a name carrying a
// control character is rejected outright rather than cleaned into a name that
// happens to look valid.
function username(value) {
  var s = String(value === undefined || value === null ? "" : value).trim().replace(/^@/, "");
  return /^[A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?$/.test(s) ? s : "";
}

// A commit id as dev-null.sh issues it (a UUIDv7: hex and dashes only).
function commitId(value) {
  var s = line(value, LIMITS.id);
  return /^[0-9a-fA-F]{8,12}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/.test(s) ? s : "";
}

// An ISO-8601 instant, kept only if it parses.
function timestamp(value) {
  var s = line(value, 40);
  if (!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/.test(s)) return null;
  var ms = Date.parse(s);
  return isNaN(ms) ? null : { iso: s, ms: ms };
}

// Avatars come from GitHub's CDN. Every other host, and every non-HTTPS URL,
// is dropped, so the shell never loads an image from an arbitrary place.
function avatarUrl(value) {
  var s = line(value, LIMITS.url);
  return /^https:\/\/(avatars|user-images)\.githubusercontent\.com\//.test(s) ? s : "";
}

function profileApiUrl(name) {
  var u = username(name);
  return u === "" ? "" : API + "/users/" + encodeURIComponent(u);
}

function commitsApiUrl(name, includeReplies) {
  var u = username(name);
  if (u === "") return "";
  return API + "/users/" + encodeURIComponent(u) + "/commits" + (includeReplies ? "?replies=1" : "");
}

function pageUrl(name) {
  var u = username(name);
  return u === "" ? "" : BASE + "/@" + encodeURIComponent(u);
}

// The one URL this plugin hands to the browser, rebuilt from the validated
// username and id instead of taken from the response.
function commitUrl(name, id) {
  var u = username(name);
  var cid = commitId(id);
  if (u === "" || cid === "") return "";
  return BASE + "/@" + u + "/commits/" + cid;
}

// The argv for one API call. Built as an argv vector, never as a shell string,
// so nothing a response or a setting contains can be reinterpreted by a
// shell. The host is fixed here; only the validated path varies, and a URL
// that is not on the API base yields no command at all.
function fetchArgs(url) {
  var s = String(url === undefined || url === null ? "" : url);
  if (s.indexOf(API + "/users/") !== 0) return [];
  if (!/^https:\/\/dev-null\.sh\/api\/v1\/users\/[A-Za-z0-9-]{1,39}\/commits(\?replies=1)?$/.test(s)) return [];
  return [
    "curl", "-fsS", "--compressed",
    "--connect-timeout", "4",
    "--max-time", "8",
    "--max-filesize", String(RESPONSE_LIMIT),
    "-H", "Accept: application/json",
    s
  ];
}

// One of the three feeds, or "" for anything else.
function view(value) {
  var v = line(value, 16).toLowerCase();
  return VIEWS.indexOf(v) !== -1 ? v : "";
}

// The log page for a view. "following" has none: it is the watchlist, built
// from the API rather than from a page.
function logUrl(name) {
  var path = LOG_PATHS[name];
  return path === undefined ? "" : BASE + path;
}

// The argv for one log page. Its own allowlist, separate from the API's, and
// compared against the whole URL rather than a prefix: there are exactly two
// acceptable URLs and the table above is where they come from, so no setting
// or response can steer this one anywhere.
function pageFetchArgs(url) {
  var s = String(url === undefined || url === null ? "" : url);
  if (s !== logUrl("latest") && s !== logUrl("trending")) return [];
  return [
    "curl", "-fsS", "--compressed",
    "--connect-timeout", "4",
    "--max-time", "12",
    "--max-filesize", String(PAGE_LIMIT),
    "-H", "Accept: text/html",
    s
  ];
}

function parseUser(raw) {
  var data = parse(raw);
  var u = data && isObject(data.data) ? data.data : null;
  if (!u) return null;

  var name = username(u.username);
  if (name === "") return null;

  return {
    username: name,
    name: line(u.name, LIMITS.name),
    bio: line(u.bio, LIMITS.bio),
    company: line(u.company, LIMITS.company),
    location: line(u.location, LIMITS.location),
    website: line(u.website, LIMITS.website),
    avatarUrl: avatarUrl(u.avatar_url),
    commitsCount: count(u.commits_count),
    followersCount: count(u.followers_count),
    followingCount: count(u.following_count),
    pageUrl: pageUrl(name)
  };
}

function parseCommit(value) {
  if (!isObject(value)) return null;

  // The API nests the author under `author`, the log pages' payload under
  // `user`. Same shape otherwise, so one parser reads both.
  var author = isObject(value.author) ? value.author : (isObject(value.user) ? value.user : {});
  var name = username(author.username);
  var id = commitId(value.id);
  if (name === "" || id === "") return null;

  var created = timestamp(value.created_at);
  if (!created) return null;

  return {
    id: id,
    shortHash: line(value.short_hash, LIMITS.hash),
    authorUsername: name,
    authorName: line(author.name, LIMITS.name),
    avatarUrl: avatarUrl(author.avatar_url),
    body: multiline(value.body, BODY_LIMIT),
    createdAt: created.iso,
    createdAtMs: created.ms,
    stars: count(value.stars_count),
    replies: count(value.replies_count),
    isReply: value.parent_id !== undefined && value.parent_id !== null,
    url: commitUrl(name, id)
  };
}

// One commit per raw entry, skipping whatever does not carry an id, an author,
// or a date, and never reading past the cap.
function parseCommitList(list, limit) {
  var max = boundedLimit(limit, FEED_LIMIT, FEED_LIMIT);
  var out = [];
  for (var i = 0; i < list.length && out.length < max; i++) {
    var commit = parseCommit(list[i]);
    if (commit) out.push(commit);
  }
  return out;
}

function parseCommits(raw, limit) {
  var data = parse(raw);
  var list = data && Array.isArray(data.data) ? data.data : [];
  return parseCommitList(list, limit);
}

// The JSON script tag an Inertia page carries its props in. Nothing else on the
// page is read: the surrounding markup is never parsed, so a redesign of the
// HTML costs nothing here.
function inertiaPayload(raw) {
  var text = String(raw === undefined || raw === null ? "" : raw);
  if (text === "" || text.length > PAGE_LIMIT) return null;

  var marker = text.indexOf('type="application/json"');
  if (marker === -1) return null;

  var open = text.indexOf(">", marker);
  if (open === -1) return null;
  var close = text.indexOf("</script>", open);
  if (close === -1) return null;

  return parse(text.slice(open + 1, close), PAGE_LIMIT);
}

// Latest and Trending, read from the page's own payload. The commits there
// carry the same fields the public API returns, so they go through the same
// validation and the same URL rebuild.
function parseLogPage(raw, limit) {
  var page = inertiaPayload(raw);
  if (!page || !isObject(page.props)) return [];

  var commits = page.props.commits;
  var list = isObject(commits) && Array.isArray(commits.data) ? commits.data : [];
  return parseCommitList(list, limit);
}

// The error body a 404 carries, for the "no such user" state.
function parseErrorMessage(raw) {
  var data = parse(raw, 4096);
  return data ? line(data.message, 160) : "";
}

// One entry per id across every watched user, newest first.
function mergeCommits(bundles, limit) {
  var max = boundedLimit(limit, FEED_LIMIT, FEED_LIMIT);
  var groups = Array.isArray(bundles) ? bundles : [];
  var seen = {};
  var out = [];

  for (var g = 0; g < groups.length && out.length < max; g++) {
    var list = Array.isArray(groups[g]) ? groups[g] : [];
    for (var i = 0; i < list.length && out.length < max; i++) {
      var commit = list[i];
      if (!isObject(commit)) continue;
      var id = commitId(commit.id);
      if (id === "" || seen[id]) continue;
      seen[id] = true;
      out.push(commit);
    }
  }

  out.sort(function(a, b) { return (b.createdAtMs || 0) - (a.createdAtMs || 0) });
  return out.slice(0, max);
}

// The watchlist setting: comma-separated usernames. An invalid entry is
// dropped rather than failing the list, so a typo costs one name, not the
// panel.
function watchList(value, limit) {
  var max = boundedLimit(limit, WATCH_LIMIT, WATCH_LIMIT);
  var parts = String(value === undefined || value === null ? "" : value).split(",");
  var seen = {};
  var out = [];

  for (var i = 0; i < parts.length && out.length < max; i++) {
    var u = username(parts[i]);
    var key = u === "" ? "" : u.toLowerCase();
    if (u === "" || seen[key]) continue;
    seen[key] = true;
    out.push(u);
  }
  return out;
}

function watchString(list) {
  return watchList(Array.isArray(list) ? list.join(",") : list).join(",");
}

// The first lines of a body on one line, for a feed row. A code fence or a
// long paragraph reads badly squeezed into two lines, so it is cut at a word
// boundary and marked with an ellipsis.
function excerpt(body, limit) {
  var max = boundedLimit(limit, 160, BODY_LIMIT);
  var full = line(body, BODY_LIMIT);
  return full.length > max ? full.slice(0, max).replace(/\s+\S*$/, "") + "…" : full;
}

// Coarse age for a row timestamp. The unit comes back rather than a finished
// string, so the panel can render it in the shell's language.
function ageUnit(iso, nowMs) {
  var ms = Date.parse(String(iso === undefined || iso === null ? "" : iso));
  if (isNaN(ms)) return null;

  var now = typeof nowMs === "number" && !isNaN(nowMs) ? nowMs : Date.now();
  var seconds = Math.max(0, Math.floor((now - ms) / 1000));

  if (seconds < 60) return { unit: "seconds", value: Math.max(1, seconds) };
  var minutes = Math.floor(seconds / 60);
  if (minutes < 60) return { unit: "minutes", value: minutes };
  var hours = Math.floor(minutes / 60);
  if (hours < 24) return { unit: "hours", value: hours };
  var days = Math.floor(hours / 24);
  if (days < 7) return { unit: "days", value: days };
  if (days < 30) return { unit: "weeks", value: Math.floor(days / 7) };
  return { unit: "months", value: Math.floor(days / 30) };
}

// Ids already counted, so the bar can report what arrived since the last
// refresh. Kept in memory for the shell session; nothing is written to disk.
function markSeen(previous, entries) {
  var known = Array.isArray(previous) ? previous : [];
  var list = Array.isArray(entries) ? entries : [];
  var seen = {};
  var out = [];

  function push(value) {
    var id = commitId(value);
    if (id === "" || seen[id]) return;
    seen[id] = true;
    out.push(id);
  }

  for (var i = 0; i < known.length && out.length < SEEN_LIMIT; i++) push(known[i]);
  for (var j = 0; j < list.length && out.length < SEEN_LIMIT; j++) {
    if (isObject(list[j])) push(list[j].id);
  }
  return out;
}

// What arrived since the last refresh: how many commits, who posted them, and
// the newest one to link to. Every string here is already stripped, which is
// what makes it safe to hand to a notification — that card renders its body as
// StyledText on purpose, so a notification is a markup sink like any other.
function unseen(entries, previous) {
  var known = Array.isArray(previous) ? previous : [];
  var list = Array.isArray(entries) ? entries : [];
  var seen = {};
  var authors = {};
  var order = [];
  var fresh = 0;
  var newest = null;

  for (var i = 0; i < known.length; i++) seen[String(known[i])] = true;

  for (var j = 0; j < list.length; j++) {
    var entry = list[j];
    if (!isObject(entry)) continue;
    // Same rule as markSeen: an entry without a usable id was never recorded
    // as seen, so counting it here would notify for something nobody can open.
    var id = commitId(entry.id);
    if (id === "" || seen[id]) continue;

    fresh++;
    seen[id] = true;
    if (!newest || (entry.createdAtMs || 0) > (newest.createdAtMs || 0)) newest = entry;

    var author = username(entry.authorUsername);
    if (author !== "" && !authors[author]) {
      authors[author] = true;
      order.push(author);
    }
  }

  return { count: fresh, authors: order.slice(0, 3), authorCount: order.length, newest: newest };
}

function countUnseen(entries, previous) {
  return unseen(entries, previous).count;
}

if (typeof module !== "undefined") {
  module.exports = {
    BASE: BASE,
    API: API,
    BODY_LIMIT: BODY_LIMIT,
    FEED_LIMIT: FEED_LIMIT,
    WATCH_LIMIT: WATCH_LIMIT,
    SEEN_LIMIT: SEEN_LIMIT,
    PAGE_LIMIT: PAGE_LIMIT,
    VIEWS: VIEWS,
    LIMITS: LIMITS,
    strip: strip,
    line: line,
    multiline: multiline,
    isObject: isObject,
    count: count,
    parse: parse,
    username: username,
    commitId: commitId,
    timestamp: timestamp,
    avatarUrl: avatarUrl,
    profileApiUrl: profileApiUrl,
    commitsApiUrl: commitsApiUrl,
    pageUrl: pageUrl,
    commitUrl: commitUrl,
    fetchArgs: fetchArgs,
    view: view,
    logUrl: logUrl,
    pageFetchArgs: pageFetchArgs,
    parseUser: parseUser,
    parseCommit: parseCommit,
    parseCommitList: parseCommitList,
    parseCommits: parseCommits,
    inertiaPayload: inertiaPayload,
    parseLogPage: parseLogPage,
    parseErrorMessage: parseErrorMessage,
    mergeCommits: mergeCommits,
    watchList: watchList,
    watchString: watchString,
    excerpt: excerpt,
    ageUnit: ageUnit,
    markSeen: markSeen,
    countUnseen: countUnseen,
    unseen: unseen
  };
}