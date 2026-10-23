// dev-null.sh model.
//
// The site publishes a public, read-only JSON API under /api/v1 that needs no
// authentication at all:
//
//   GET /api/v1/users/{username}           one public profile
//   GET /api/v1/users/{username}/commits   a user's commits, newest first, 20
//                                          per page
//   GET /api/v1/users/{username}/commits?replies=1
//                                          that user's replies, same paging;
//                                          the top-level list does not include
//                                          them, so a feed that wants both
//                                          asks twice
//   GET /api/v1/commits/{id}               one commit
//
// The replies to one commit are not on the public API: /api/v1/commits/{id}/replies
// answers 401 without a signature. They are read off the commit page itself,
// whose Inertia payload carries them in a `replies` prop (three per page).
//
// Rate limit: 60 requests per minute per IP. There is no global timeline
// endpoint and no search, so the plugin's feed is the merged commit log of a
// watchlist of usernames.
//
// Signing in is optional, and changes what "Following" means. The site has one
// way in — GitHub OAuth — and its callback is pinned to the site, so a widget
// cannot run that flow. It can use the approval the mobile app uses instead
// (see the Sign-in section below): an SSH key of the plugin's own is approved
// once from a browser page, and every request afterwards is signed with it.
// The signed-in API then answers the site's own logs, including the Following
// one the public API does not have.
//
// Everything below treats a response as untrusted input. Fields are read one
// by one with their expected type, every string is length-capped, markup and
// invisible characters are removed before a value can reach a Text, a tooltip,
// or a command line, and URLs are rebuilt from validated parts instead of
// being taken from the response.

// The three feeds the panel offers.
//
// Signed out, "following" is the plugin's watchlist: the site's own
// /log/following answers 302 to the login page, and the plugin has no session.
// The watchlist is the same idea — the people you chose to follow — and it is
// built from the public JSON API, one request per name.
//
// Signed in, all three come from the signed API, and "following" is the site's
// own follow graph rather than the watchlist.
//
// The pages stay for the signed-out case: "latest" and "trending" have no
// public API endpoint, but the site serves them as Inertia pages whose payload
// carries the same commit shape the API returns.
var VIEWS = ["following", "latest", "trending"];
var LOG_PATHS = { latest: "/log/latest", trending: "/log/trending" };

var BASE = "https://dev-null.sh";
var API = "https://dev-null.sh/api/v1";

// The names the widget watches until somebody writes a list of their own. The
// panel falls back to this one, and the tests hold manifest.json and the
// README to it, so the copies cannot drift apart.
var DEFAULT_WATCH = "nunomaduro,brendt,paulinevos,mnapoli";

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

// What a person might paste into the lookup box: a username, @username, or a
// profile URL copied out of the address bar on GitHub or dev-null.sh. A repo,
// commit, or any other path is not a profile and yields nothing.
function usernameFromInput(value) {
  var s = String(value === undefined || value === null ? "" : value).trim();
  if (s === "") return "";

  var direct = username(s);
  if (direct !== "") return direct;

  var bare = s.replace(/^https?:\/\//i, "").replace(/^www\./i, "");
  var match = /^(?:github\.com|dev-null\.sh)\/(?:@)?([A-Za-z0-9][A-Za-z0-9-]{0,38})\/?(?:[?#].*)?$/i.exec(bare);
  return match ? username(match[1]) : "";
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
//
// Two shapes are allowed: a user's commits (optionally replies) and a user's
// profile. The profile one is what the lookup box fetches; leaving it out
// returned no command at all, so the box silently did nothing.
function fetchArgs(url) {
  var s = String(url === undefined || url === null ? "" : url);
  if (s.indexOf(API + "/users/") !== 0) return [];
  if (!/^https:\/\/dev-null\.sh\/api\/v1\/users\/[A-Za-z0-9-]{1,39}(\/commits(\?replies=1)?)?$/.test(s)) return [];
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

// The replies to one commit are not on the public API — that route answers 401
// without a signature — but the Inertia page the browser opens carries them.
// Same allowlist idea as the log pages: one URL shape, rebuilt from a validated
// username and id, and anything else gets no command at all.
function commitPageFetchArgs(url) {
  var s = String(url === undefined || url === null ? "" : url);
  if (!/^https:\/\/dev-null\.sh\/@[A-Za-z0-9-]{1,39}\/commits\/[0-9a-fA-F]{8,12}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/.test(s)) return [];
  return [
    "curl", "-fsS", "--compressed",
    "--connect-timeout", "4",
    "--max-time", "12",
    "--max-filesize", String(PAGE_LIMIT),
    "-H", "Accept: text/html",
    s
  ];
}

// ---- Sign-in -------------------------------------------------------------
//
// dev-null.sh only signs people in with GitHub, and its OAuth callback is
// pinned to the site, so the plugin cannot run that flow. What it can use is
// the device approval the mobile app uses: the site approves an SSH key for a
// user once, from a page in the browser, and every API request afterwards is
// signed with it. Settings → Devices on the site lists the approval and can
// revoke it, with no password stored anywhere.
//
// The signed message is "<timestamp>\n<nonce>\n<METHOD>\n<path and query>\n<body>",
// with the timestamp and the nonce also in X-Devnull-Timestamp and
// X-Devnull-Nonce, and the signature (ssh-keygen -Y sign, namespace
// devnull-api) in X-SSH-Signature.
//
// Everything that goes into a signed message is built here and validated here.
// The key never leaves the plugin's own state directory, the private half is
// only ever read by ssh-keygen, and the signature is handed to the header as
// base64 with neither armor nor line breaks.

var AUTH_NAMESPACE = "devnull-api";
// The one redirect the site accepts for the approval page, so it is a constant
// here rather than anything a setting or a response could steer.
var CALLBACK_URL = "devnull://authorize";
var CALLBACK_SCHEME = "x-scheme-handler/devnull";
// What Settings → Devices will list the approval as.
var DEVICE_NAME = "Omarchy bar";

// The signed requests this plugin makes. Anything else yields no command at
// all, so a response or a setting cannot point a signed request elsewhere.
var SIGNED_PATHS = [
  "/api/v1/log/following",
  "/api/v1/log/latest",
  "/api/v1/log/trending",
  "/api/v1/devices"
];

// One of the three feeds as a signed API path. Signed out there is nothing to
// ask for here: Following has no public endpoint.
function logApiPath(name) {
  var v = view(name);
  return v === "" ? "" : "/api/v1/log/" + v;
}

// The path and query a signed request may carry, or "" for anything else.
function signedPath(pathAndQuery) {
  var p = String(pathAndQuery === undefined || pathAndQuery === null ? "" : pathAndQuery);
  return SIGNED_PATHS.indexOf(p) === -1 ? "" : p;
}

// The bytes ssh-keygen signs. Empty when any part is not the shape the server
// checks, so a malformed request never reaches the key.
function signedMessage(timestamp, nonce, method, pathAndQuery, body) {
  var ts = String(timestamp === undefined || timestamp === null ? "" : timestamp);
  var n = String(nonce === undefined || nonce === null ? "" : nonce);
  var m = String(method === undefined || method === null ? "" : method);
  var p = signedPath(pathAndQuery);
  var b = String(body === undefined || body === null ? "" : body);

  if (!/^\d{9,11}$/.test(ts)) return "";
  if (!/^[0-9a-f]{32}$/.test(n)) return "";
  if (m !== "GET" && m !== "POST") return "";
  if (p === "") return "";
  if (b.length > 4096) return "";

  return [ts, n, m, p, b].join("\n");
}

// The signature as a header value: the base64 body of the armored signature
// ssh-keygen writes, with nothing else. Any character outside base64 means the
// output was not a signature, and no command is built.
function signatureBody(raw) {
  var s = String(raw === undefined || raw === null ? "" : raw)
    .replace(/-----(BEGIN|END) SSH SIGNATURE-----/g, "")
    .replace(/\s+/g, "");
  return /^[A-Za-z0-9+/=]{40,4096}$/.test(s) ? s : "";
}

// The argv for one signed API call, with the body already signed. `curl -f` is
// deliberately left out: a revoked device answers 401 with a JSON body, and the
// panel needs that status to say "sign in again" instead of "could not read
// this feed". `-w` appends it after the body, which splitStatus takes off.
function signedFetchArgs(method, pathAndQuery, timestamp, nonce, signature, body) {
  var m = String(method === undefined || method === null ? "" : method);
  var p = signedPath(pathAndQuery);
  var sig = signatureBody(signature);
  var b = String(body === undefined || body === null ? "" : body);
  if (signedMessage(timestamp, nonce, m, p, b) === "" || sig === "") return [];

  var args = [
    "curl", "-sS", "--compressed",
    "--connect-timeout", "4",
    "--max-time", "12",
    "--max-filesize", String(RESPONSE_LIMIT),
    "-H", "Accept: application/json",
    "-H", "X-Devnull-Timestamp: " + String(timestamp),
    "-H", "X-Devnull-Nonce: " + String(nonce),
    "-H", "X-SSH-Signature: " + sig,
    "-w", "\n%{http_code}"
  ];

  if (m === "POST") {
    if (b === "") return [];
    args.push("-X", "POST", "-H", "Content-Type: application/json", "--data-binary", b);
  }

  args.push(BASE + p);
  return args;
}

// The page the browser opens to approve the plugin's key. Every parameter is
// validated against what the site accepts, and the redirect is the constant
// above, so the one-time code can only come back to the devnull:// handler.
function authorizeUrl(params) {
  var p = isObject(params) ? params : {};
  var fingerprint = String(p.fingerprint === undefined || p.fingerprint === null ? "" : p.fingerprint);
  var device = line(p.deviceName, 100);
  var challenge = String(p.challenge === undefined || p.challenge === null ? "" : p.challenge);
  var state = String(p.state === undefined || p.state === null ? "" : p.state);

  if (!/^SHA256:[A-Za-z0-9+/]{43}$/.test(fingerprint)) return "";
  if (device === "") return "";
  if (!/^[A-Za-z0-9_-]{43}$/.test(challenge)) return "";
  if (!/^[0-9a-f]{32}$/.test(state)) return "";

  return BASE + "/mobile/authorize"
    + "?fingerprint=" + encodeURIComponent(fingerprint)
    + "&device_name=" + encodeURIComponent(device)
    + "&code_challenge=" + encodeURIComponent(challenge)
    + "&code_challenge_method=S256"
    + "&state=" + encodeURIComponent(state)
    + "&redirect_uri=" + encodeURIComponent(CALLBACK_URL);
}

// The one-time code the approval page hands back, or "" when the URL is not
// the redirect this plugin asked for, carries no code, or carries a state that
// is not the one this attempt generated.
function parseCallbackUrl(raw, expectedState) {
  var s = String(raw === undefined || raw === null ? "" : raw).trim();
  if (s === "" || s.length > 4096) return "";

  // Some launchers (GIO's own `gio launch`, among others) re-serialise the URI
  // and give the empty path a slash, so devnull://authorize? and
  // devnull://authorize/? are both the same callback.
  var query = "";
  if (s.indexOf(CALLBACK_URL + "?") === 0) query = s.slice(CALLBACK_URL.length + 1);
  else if (s.indexOf(CALLBACK_URL + "/?") === 0) query = s.slice(CALLBACK_URL.length + 2);
  else return "";

  var params = {};
  var parts = query.split("&");
  for (var i = 0; i < parts.length; i++) {
    var eq = parts[i].indexOf("=");
    if (eq <= 0) continue;
    var value = parts[i].slice(eq + 1).replace(/\+/g, " ");
    try {
      params[parts[i].slice(0, eq)] = decodeURIComponent(value);
    } catch (e) {
      return "";
    }
  }

  var state = String(expectedState === undefined || expectedState === null ? "" : expectedState);
  if (state === "" || params.state !== state) return "";
  return /^[0-9a-f]{64}$/.test(String(params.code || "")) ? String(params.code) : "";
}

// The body that redeems the code for a device. The verifier is the one the
// challenge was made from; the server hashes it again and refuses a mismatch.
function deviceBody(code, verifier) {
  var c = String(code === undefined || code === null ? "" : code);
  var v = String(verifier === undefined || verifier === null ? "" : verifier);
  if (!/^[0-9a-f]{64}$/.test(c)) return "";
  if (!/^[A-Za-z0-9._~-]{43,128}$/.test(v)) return "";
  return JSON.stringify({ code: c, code_verifier: v });
}

// What the approval URL's PKCE challenge is: base64url of the SHA-256 of the
// verifier, without padding. The digest is computed by sha256sum (this file has
// no crypto) and arrives here as hex, which is turned into the 43 characters
// the site's own regex wants.
function base64UrlFromHex(value) {
  var hex = String(value === undefined || value === null ? "" : value).replace(/[^0-9a-fA-F]/g, "").toLowerCase();
  if (hex.length !== 64) return "";

  var alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
  var out = "";
  var i = 0;

  for (; i + 6 <= hex.length; i += 6) {
    var n = parseInt(hex.slice(i, i + 6), 16);
    out += alphabet[(n >> 18) & 63] + alphabet[(n >> 12) & 63] + alphabet[(n >> 6) & 63] + alphabet[n & 63];
  }

  var rest = hex.length - i;
  if (rest === 4) {
    var two = parseInt(hex.slice(i, i + 4), 16);
    out += alphabet[(two >> 10) & 63] + alphabet[(two >> 4) & 63] + alphabet[(two << 2) & 63];
  } else if (rest === 2) {
    var one = parseInt(hex.slice(i, i + 2), 16);
    out += alphabet[(one >> 2) & 63] + alphabet[(one << 4) & 63];
  }

  return /^[A-Za-z0-9_-]{43}$/.test(out) ? out : "";
}

// `od -An -N16 -tx1 /dev/urandom` prints hex in columns; this is the run of hex
// without the whitespace. Used for both the nonce (16 bytes) and the PKCE
// verifier (32 bytes), which are then checked for length by their callers.
function hexFromOd(raw) {
  return String(raw === undefined || raw === null ? "" : raw).replace(/[^0-9a-fA-F]/g, "").toLowerCase();
}

// `sha256sum` prints "<hex>  -" for its stdin.
function digestHex(raw) {
  var match = /([0-9a-fA-F]{64})/.exec(String(raw === undefined || raw === null ? "" : raw));
  return match ? match[1].toLowerCase() : "";
}

// `ssh-keygen -lf key.pub` prints "<bits> SHA256:<43 chars> <comment> (<type>)".
function fingerprintFromSshKeygen(raw) {
  var match = /(SHA256:[A-Za-z0-9+/]{43})/.exec(String(raw === undefined || raw === null ? "" : raw));
  return match ? match[1] : "";
}

// The file the plugin keeps its account in. The path is never read from the
// file: it is this one, under the plugin's own state directory.
function parseAccount(raw) {
  var data = parse(raw, 4096);
  if (!data) return null;

  var name = username(data.username);
  var fingerprint = String(data.fingerprint === undefined || data.fingerprint === null ? "" : data.fingerprint);
  if (name === "" || !/^SHA256:[A-Za-z0-9+/]{43}$/.test(fingerprint)) return null;

  return {
    username: name,
    name: line(data.name, LIMITS.name),
    fingerprint: fingerprint,
    device: line(data.device, 100),
    signedInAt: line(data.signed_in_at, 40)
  };
}

function accountJson(user, fingerprint, signedInAt) {
  var name = username(user && user.username);
  var fp = String(fingerprint === undefined || fingerprint === null ? "" : fingerprint);
  if (name === "" || !/^SHA256:[A-Za-z0-9+/]{43}$/.test(fp)) return "";

  return JSON.stringify({
    username: name,
    name: line(user && user.name, LIMITS.name),
    fingerprint: fp,
    device: DEVICE_NAME,
    signed_in_at: line(signedInAt, 40)
  }) + "\n";
}

// Where the plugin keeps the key, the approval and the message it signs. Under
// $XDG_STATE_HOME, never in shell.json: a private key does not belong in the
// file the settings form writes.
function stateDir(home, xdgStateHome) {
  var h = String(home === undefined || home === null ? "" : home).replace(/\/+$/, "");
  var x = String(xdgStateHome === undefined || xdgStateHome === null ? "" : xdgStateHome).replace(/\/+$/, "");
  if (h === "" && x === "") return "";
  return (x !== "" ? x : h + "/.local/state") + "/omarchy/devnull";
}

// The desktop entry that makes the browser hand the devnull:// redirect to the
// plugin's own script. Hidden from menus, and carrying nothing but that.
function desktopEntry(execPath) {
  var path = String(execPath === undefined || execPath === null ? "" : execPath);
  if (path === "" || /[\n\r"\\]/.test(path)) return "";

  return [
    "[Desktop Entry]",
    "Type=Application",
    "Name=/dev/null sign-in",
    "NoDisplay=true",
    "Terminal=false",
    "MimeType=" + CALLBACK_SCHEME + ";",
    "Exec=\"" + path + "\" %u",
    ""
  ].join("\n");
}

// The body of a signed response, and the status curl appended to it with -w.
function splitStatus(raw) {
  var text = String(raw === undefined || raw === null ? "" : raw);
  var match = /\n(\d{3})$/.exec(text);
  if (!match) return { status: 0, body: text };
  return { status: parseInt(match[1], 10), body: text.slice(0, match.index) };
}

// The commits array of a response, or null when it carries no feed at all. The
// panel needs that difference: an empty feed is not a failed one.
function feedList(raw) {
  var data = parse(raw);
  return data && Array.isArray(data.data) ? data.data : null;
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
//
// Returns the raw list, or null when the payload does not carry a feed at all.
// The panel needs that difference: an empty but readable feed is not a failed
// one, and saying "this feed could not be read" over a legitimate zero would
// be a lie.
function pageFeed(raw) {
  var page = inertiaPayload(raw);
  if (!page || !isObject(page.props)) return null;

  var commits = page.props.commits;
  if (isObject(commits) && Array.isArray(commits.data)) return commits.data;
  return Array.isArray(commits) ? commits : null;
}

function parseLogPage(raw, limit) {
  var list = pageFeed(raw);
  return list ? parseCommitList(list, limit) : [];
}

// The `replies` prop of a commit page: the first page of answers to one
// commit, plus the commit's own counter for the whole thread. The page carries
// three today and the rest behind a cursor, so this one request is all the
// panel spends per row; `remaining` is what stayed on the site.
//
// null means the page carried no replies prop at all, which is a page that
// could not be read. An empty list is a commit nobody has answered.
function commitReplies(raw) {
  var page = inertiaPayload(raw);
  if (!page || !isObject(page.props)) return null;

  var replies = page.props.replies;
  var list = isObject(replies) && Array.isArray(replies.data) ? replies.data : null;
  if (list === null) return null;

  var commit = isObject(page.props.commit) ? page.props.commit : {};
  var parsed = parseCommitList(list, FEED_LIMIT);
  var total = Math.max(count(commit.replies_count), parsed.length);

  return { replies: parsed, total: total, remaining: total - parsed.length };
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
  // An ISO string from a commit, or a millisecond timestamp the panel keeps
  // for "updated 2 minutes ago".
  var ms = typeof iso === "number" ? iso : Date.parse(String(iso === undefined || iso === null ? "" : iso));
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
  if (days < 365) return { unit: "months", value: Math.floor(days / 30) };
  return { unit: "years", value: Math.floor(days / 365) };
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
    DEFAULT_WATCH: DEFAULT_WATCH,
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
    usernameFromInput: usernameFromInput,
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
    AUTH_NAMESPACE: AUTH_NAMESPACE,
    DEVICE_NAME: DEVICE_NAME,
    CALLBACK_URL: CALLBACK_URL,
    CALLBACK_SCHEME: CALLBACK_SCHEME,
    logApiPath: logApiPath,
    signedPath: signedPath,
    signedMessage: signedMessage,
    signatureBody: signatureBody,
    signedFetchArgs: signedFetchArgs,
    authorizeUrl: authorizeUrl,
    parseCallbackUrl: parseCallbackUrl,
    deviceBody: deviceBody,
    base64UrlFromHex: base64UrlFromHex,
    hexFromOd: hexFromOd,
    digestHex: digestHex,
    fingerprintFromSshKeygen: fingerprintFromSshKeygen,
    parseAccount: parseAccount,
    accountJson: accountJson,
    stateDir: stateDir,
    desktopEntry: desktopEntry,
    splitStatus: splitStatus,
    feedList: feedList,
    parseUser: parseUser,
    parseCommit: parseCommit,
    parseCommitList: parseCommitList,
    parseCommits: parseCommits,
    inertiaPayload: inertiaPayload,
    pageFeed: pageFeed,
    parseLogPage: parseLogPage,
    commitPageFetchArgs: commitPageFetchArgs,
    commitReplies: commitReplies,
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