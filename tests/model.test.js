// Regression coverage for Model.js.
//
// The interesting cases are the ones a hostile or broken response produces:
// markup-shaped text heading for a Text or a tooltip, a URL pointing
// somewhere else, a username carrying shell metacharacters, a body far past
// what the panel will draw. Run with: node --test tests/
const test = require("node:test")
const assert = require("node:assert/strict")
const fs = require("node:fs")
const path = require("node:path")
const Model = require("../Model.js")

const AUTHOR = {
  id: "01a13fa8-6cd4-70ef-b8e5-f46a3ca70ca8",
  username: "nunomaduro",
  name: "nunomaduro",
  avatar_url: "https://avatars.githubusercontent.com/u/5457236?v=4",
  bio: "staff software engineer at @laravel",
  company: "@laravel",
  location: "Portugal",
  website: "https://nunomaduro.com/sponsorships",
  html_url: "https://dev-null.sh/@nunomaduro",
  created_at: "2026-10-15T13:02:44Z"
}

function commit(overrides = {}) {
  return Object.assign({
    id: "01a149c1-f76d-703d-ae60-e82d7960889a",
    short_hash: "960889a",
    body: "wild 48 hours. still processing it tbh",
    parent_id: null,
    html_url: "https://dev-null.sh/@nunomaduro/commits/01a149c1-f76d-703d-ae60-e82d7960889a",
    created_at: "2026-10-17T12:06:50Z",
    stars_count: 50,
    replies_count: 9,
    link_preview: null,
    images: [],
    author: AUTHOR
  }, overrides)
}

function list(items) {
  return JSON.stringify({ data: items, links: {}, meta: {} })
}

// dev-null.sh issues commit ids as UUIDv7s: the last group is 12 hex digits.
function uuidId(index) {
  return `01a149c1-f76d-703d-ae60-${index.toString(16).padStart(12, "0")}`
}

// ---- usernames -----------------------------------------------------------

test("username accepts GitHub's shape and nothing else", () => {
  assert.equal(Model.username("nunomaduro"), "nunomaduro")
  assert.equal(Model.username("@brendt"), "brendt")
  assert.equal(Model.username("a"), "a")
  assert.equal(Model.username("a-b-9"), "a-b-9")
  assert.equal(Model.username("a".repeat(39)), "a".repeat(39))
})

test("username rejects anything that could leave the path", () => {
  for (const value of [
    "",
    "-leading",
    "trailing-",
    "a".repeat(40),
    "../../etc/passwd",
    "nuno maduro",
    "nuno'maduro",
    "nuno$(id)",
    "nuno;rm -rf /",
    "nuno&whoami",
    "https://evil.example/@nunomaduro",
    "nunomaduro/commits",
    "@",
    "nunomaduro\u0000"
  ]) {
    assert.equal(Model.username(value), "", `should reject ${JSON.stringify(value)}`)
  }
})

test("usernameFromInput takes a username or a profile link", () => {
  assert.equal(Model.usernameFromInput("nunomaduro"), "nunomaduro")
  assert.equal(Model.usernameFromInput(" @brendt "), "brendt")
  assert.equal(Model.usernameFromInput("https://github.com/nunomaduro"), "nunomaduro")
  assert.equal(Model.usernameFromInput("github.com/nunomaduro/"), "nunomaduro")
  assert.equal(Model.usernameFromInput("https://www.github.com/nunomaduro?tab=repos"), "nunomaduro")
  assert.equal(Model.usernameFromInput("https://dev-null.sh/@nunomaduro"), "nunomaduro")
  assert.equal(Model.usernameFromInput("https://dev-null.sh/@nunomaduro?x=1"), "nunomaduro")
})

test("usernameFromInput refuses anything that is not a profile", () => {
  for (const value of [
    "",
    "github.com/nunomaduro/laravel",
    "https://github.com/orgs/laravel",
    "https://evil.example/@nunomaduro",
    "nuno maduro",
  ]) {
    assert.equal(Model.usernameFromInput(value), "", `should reject ${JSON.stringify(value)}`)
  }
})

// ---- URLs ----------------------------------------------------------------

test("commitUrl is rebuilt from the validated parts, not the response", () => {
  const url = Model.commitUrl("nunomaduro", "01a149c1-f76d-703d-ae60-e82d7960889a")
  assert.equal(url, "https://dev-null.sh/@nunomaduro/commits/01a149c1-f76d-703d-ae60-e82d7960889a")
  assert.equal(Model.commitUrl("nunomaduro", "not-an-id"), "")
  assert.equal(Model.commitUrl("../../x", "01a149c1-f76d-703d-ae60-e82d7960889a"), "")
})

test("avatarUrl only lets GitHub's CDN through", () => {
  assert.equal(
    Model.avatarUrl("https://avatars.githubusercontent.com/u/5457236?v=4"),
    "https://avatars.githubusercontent.com/u/5457236?v=4"
  )
  for (const value of [
    "",
    "http://avatars.githubusercontent.com/u/5457236",           // not HTTPS
    "https://evil.example/pixel.png",
    "https://avatars.githubusercontent.com.evil.example/u/1",
    "file:///etc/passwd",
    "data:image/png;base64,AAAA"
  ]) {
    assert.equal(Model.avatarUrl(value), "", `should reject ${value}`)
  }
})

test("fetchArgs refuses any URL off the API base", () => {
  const args = Model.fetchArgs("https://dev-null.sh/api/v1/users/nunomaduro/commits")
  assert.equal(args[0], "curl")
  assert.equal(args.at(-1), "https://dev-null.sh/api/v1/users/nunomaduro/commits")
  assert.ok(args.includes("--max-time"))
  assert.ok(args.includes("--max-filesize"))

  assert.deepEqual(Model.fetchArgs("https://evil.example/api/v1/users/x/commits"), [])
  assert.deepEqual(Model.fetchArgs("https://dev-null.sh/api/v1/users/$(id)/commits"), [])
  assert.deepEqual(Model.fetchArgs("https://dev-null.sh/@nunomaduro"), [])
  assert.deepEqual(Model.fetchArgs(""), [])
  assert.deepEqual(Model.fetchArgs(null), [])

  const replies = Model.fetchArgs("https://dev-null.sh/api/v1/users/brendt/commits?replies=1")
  assert.equal(replies.at(-1), "https://dev-null.sh/api/v1/users/brendt/commits?replies=1")
})

// The lookup box fetches a profile, not a commit list. When this returned no
// command at all the box silently did nothing, on every release, because the
// only path the tests exercised was the empty one.
test("fetchArgs builds the profile request the lookup box needs", () => {
  const url = Model.profileApiUrl("nunomaduro")
  assert.equal(url, "https://dev-null.sh/api/v1/users/nunomaduro")

  const args = Model.fetchArgs(url)
  assert.equal(args[0], "curl")
  assert.equal(args.at(-1), "https://dev-null.sh/api/v1/users/nunomaduro")
  assert.ok(args.includes("--max-time"))

  // A user's path has no trailing slash, no query, and no deeper path: the two
  // shapes the plugin builds are commits and a profile, nothing else.
  for (const value of [
    "https://dev-null.sh/api/v1/users/nunomaduro/",
    "https://dev-null.sh/api/v1/users/nunomaduro?tab=repos",
    "https://dev-null.sh/api/v1/users/nunomaduro/commits/1",
    "https://dev-null.sh/api/v1/users/nunomaduro/commits?replies=0",
    "https://dev-null.sh/api/v1/users//commits",
    "https://dev-null.sh/api/v1/users/bad user",
    ""
  ]) {
    assert.deepEqual(Model.fetchArgs(value), [], `should refuse ${JSON.stringify(value)}`)
  }

  // An invalid username never becomes a URL in the first place.
  assert.equal(Model.profileApiUrl("bad user"), "")
  assert.deepEqual(Model.fetchArgs(Model.profileApiUrl("bad user")), [])
})

// ---- text ----------------------------------------------------------------

test("markup is dropped from a string, not escaped into it", () => {
  const evil = '<img src="https://tracker.invalid/pixel">hello <b>world</b>'
  const out = Model.line(evil, 400)
  assert.ok(!out.includes("<"), out)
  assert.ok(!out.includes(">"), out)
  assert.ok(!out.includes("tracker.invalid"), out)
  assert.ok(out.includes("hello"), out)
  assert.ok(out.includes("world"), out)
})

test("a body keeps its line breaks and loses everything invisible", () => {
  const body = "first line\n\nsecond\u0007 line\u202e reversed"
  const out = Model.multiline(body, Model.BODY_LIMIT)
  assert.ok(out.includes("\n"), "a line break survives")
  assert.ok(out.includes("first line"), JSON.stringify(out))
  assert.ok(out.includes("second line reversed"), JSON.stringify(out))
  assert.ok(!out.includes("\u0007"))
  assert.ok(!out.includes("\u202e"))
})

test("strings are capped", () => {
  const long = "x".repeat(5000)
  assert.equal(Model.line(long, 80).length, 80)
  assert.equal(Model.excerpt(long, 40).length, 41) // 40 plus the ellipsis
  assert.equal(Model.multiline(long, 100).length, 100)
})

test("excerpt cuts at a word boundary and marks the cut", () => {
  const out = Model.excerpt("one two three four five six seven", 12)
  assert.equal(out, "one two…")
})

test("count refuses junk and absurd numbers", () => {
  assert.equal(Model.count(undefined), 0)
  assert.equal(Model.count(null), 0)
  assert.equal(Model.count(""), 0)
  assert.equal(Model.count("12"), 12)
  assert.equal(Model.count("-5"), 0)
  assert.equal(Model.count("abc"), 0)
  assert.equal(Model.count("99999999999"), 999999)
})

// ---- parsing -------------------------------------------------------------

test("parse drops oversized and unparseable bodies whole", () => {
  assert.equal(Model.parse(""), null)
  assert.equal(Model.parse("   "), null)
  assert.equal(Model.parse("{"), null)
  assert.equal(Model.parse("[1,2,3]"), null)
  assert.equal(Model.parse(JSON.stringify({ data: {} }), 8), null)
})

test("parseUser keeps the fields the panel draws", () => {
  const profile = Model.parseUser(JSON.stringify({
    data: Object.assign({}, AUTHOR, {
      commits_count: 57,
      followers_count: 1589,
      following_count: 55
    })
  }))

  assert.equal(profile.username, "nunomaduro")
  assert.equal(profile.commitsCount, 57)
  assert.equal(profile.followersCount, 1589)
  assert.equal(profile.pageUrl, "https://dev-null.sh/@nunomaduro")
  assert.equal(profile.avatarUrl, AUTHOR.avatar_url)
})

test("parseUser rejects a body without a usable username", () => {
  assert.equal(Model.parseUser(JSON.stringify({ data: { username: "bad user" } })), null)
  assert.equal(Model.parseUser(JSON.stringify({ message: "No query results" })), null)
  assert.equal(Model.parseUser("not json"), null)
})

test("parseCommits normalizes and caps the list", () => {
  const many = Array.from({ length: 60 }, (_, i) => commit({ id: uuidId(i) }))

  // One page is 20 commits; the panel merges several, so the default cap is
  // the feed size rather than a page size.
  assert.equal(Model.parseCommits(list(many), 20).length, 20)
  assert.equal(Model.parseCommits(list(many)).length, Model.FEED_LIMIT)

  const parsed = Model.parseCommits(list(many), 20)
  assert.equal(parsed[0].authorUsername, "nunomaduro")
  assert.equal(parsed[0].stars, 50)
  assert.equal(parsed[0].replies, 9)
  assert.equal(parsed[0].isReply, false)
  assert.ok(parsed[0].createdAtMs > 0)
})

test("parseCommits skips entries missing an id, an author, or a date", () => {
  const parsed = Model.parseCommits(list([
    commit(),
    commit({ id: "nope" }),
    commit({ author: null }),
    commit({ created_at: "yesterday" }),
    commit({ id: null })
  ]))
  assert.equal(parsed.length, 1)
})

test("parseCommits reads a reply", () => {
  const parsed = Model.parseCommits(list([commit({ parent_id: "01a14672-3333-73ab-8a0f-573452775ac0" })]))
  assert.equal(parsed[0].isReply, true)
})

// ---- merging -------------------------------------------------------------

test("mergeCommits dedupes by id and sorts newest first", () => {
  const older = Model.parseCommits(list([commit({
    id: uuidId(1),
    created_at: "2026-10-17T09:00:00Z"
  })]))
  const newer = Model.parseCommits(list([commit()]))

  const merged = Model.mergeCommits([older, newer, newer])
  assert.equal(merged.length, 2)
  assert.equal(merged[0].id, newer[0].id)
})

test("mergeCommits survives an empty or malformed bundle", () => {
  assert.deepEqual(Model.mergeCommits([]), [])
  assert.deepEqual(Model.mergeCommits(null), [])
  assert.deepEqual(Model.mergeCommits([null, "junk", []]), [])
})

// ---- watchlist -----------------------------------------------------------

test("watchList drops invalid names instead of failing the list", () => {
  assert.deepEqual(
    Model.watchList("nunomaduro, bad user ,brendt,,$(id),nunomaduro"),
    ["nunomaduro", "brendt"]
  )
})

test("watchList is deduplicated case-insensitively and capped", () => {
  assert.deepEqual(Model.watchList("nuno, NUNO, brendt"), ["nuno", "brendt"])
  const many = Array.from({ length: 30 }, (_, i) => `user${i}`).join(",")
  assert.equal(Model.watchList(many).length, Model.WATCH_LIMIT)
})

test("watchString is the round trip a shell.json edit stores", () => {
  assert.equal(Model.watchString(["nunomaduro", "brendt"]), "nunomaduro,brendt")
  assert.equal(Model.watchString(["nunomaduro", "bad user"]), "nunomaduro")
})

// The same four names are written in the model, in the manifest's defaults,
// and in the README's settings table. One of them drifting is a bug nobody
// notices until a fresh install watches somebody the docs do not mention.
test("the example watchlist lives in one place and the copies match", () => {
  assert.equal(Model.DEFAULT_WATCH, "nunomaduro,brendt,paulinevos,mnapoli")
  assert.equal(Model.watchList(Model.DEFAULT_WATCH).length, 4)

  const dir = path.join(__dirname, "..")
  const manifest = JSON.parse(fs.readFileSync(path.join(dir, "manifest.json"), "utf8"))
  assert.equal(manifest.barWidget.defaults.watch, Model.DEFAULT_WATCH)
  assert.equal(manifest.barWidget.schema.find((field) => field.key === "watch").defaultValue, Model.DEFAULT_WATCH)

  const readme = fs.readFileSync(path.join(dir, "README.md"), "utf8")
  assert.ok(readme.includes(Model.DEFAULT_WATCH), "the README documents the same list")
})

// ---- freshness -----------------------------------------------------------

test("the first refresh counts nothing as new", () => {
  const entries = Model.parseCommits(list([commit()]))
  assert.equal(Model.countUnseen(entries, []), 1)
  assert.equal(Model.countUnseen(entries, Model.markSeen([], entries)), 0)
})

test("unseen names who posted and hands back the newest", () => {
  const entries = Model.parseCommits(list([
    commit({ id: uuidId(1), created_at: "2026-10-17T12:00:00Z" }),
    commit({ id: uuidId(2), created_at: "2026-10-17T09:00:00Z", author: { username: "brendt" } }),
    commit({ id: uuidId(3), created_at: "2026-10-17T11:00:00Z", author: { username: "brendt" } })
  ]))
  const known = [entries[0].id]

  const summary = Model.unseen(entries, known)
  assert.equal(summary.count, 2)
  assert.deepEqual(summary.authors, ["brendt"])   // one entry per author
  assert.equal(summary.authorCount, 1)
  assert.equal(summary.newest.id, uuidId(3))     // the newer of the two unseen

  // A second pass over the same feed has nothing left to report.
  assert.equal(Model.unseen(entries, Model.markSeen(known, entries)).count, 0)
})

test("unseen caps the author list but still counts them all", () => {
  const entries = Model.parseCommits(list(
    Array.from({ length: 6 }, (_, i) => commit({ id: uuidId(i), author: { username: `user${i}` } }))
  ))
  const summary = Model.unseen(entries, [])

  assert.equal(summary.count, 6)
  assert.equal(summary.authors.length, 3)
  assert.equal(summary.authorCount, 6)
})

test("unseen ignores a junk entry without losing the rest", () => {
  const entries = Model.parseCommits(list([commit()]))
  const summary = Model.unseen([null, "junk", entries[0], {}], [])
  assert.equal(summary.count, 1)
  assert.deepEqual(summary.authors, ["nunomaduro"])
})

test("markSeen caps the memory it holds", () => {
  const entries = Array.from({ length: 500 }, (_, i) => ({ id: uuidId(i) }))
  assert.equal(Model.markSeen([], entries).length, Model.SEEN_LIMIT)
})

// ---- age -----------------------------------------------------------------

test("ageUnit picks the right unit", () => {
  const now = Date.parse("2026-10-17T12:00:00Z")
  const at = (iso) => Model.ageUnit(iso, now)

  assert.deepEqual(at("2026-10-17T11:59:30Z"), { unit: "seconds", value: 30 })
  assert.deepEqual(at("2026-10-17T11:45:00Z"), { unit: "minutes", value: 15 })
  assert.deepEqual(at("2026-10-17T09:00:00Z"), { unit: "hours", value: 3 })
  assert.deepEqual(at("2026-10-15T12:00:00Z"), { unit: "days", value: 2 })
  assert.deepEqual(at("2026-10-01T12:00:00Z"), { unit: "weeks", value: 2 })
  assert.deepEqual(at("2026-06-01T12:00:00Z"), { unit: "months", value: 4 })
  assert.deepEqual(at("2024-09-01T12:00:00Z"), { unit: "years", value: 2 })
  assert.equal(at("not a date"), null)
  assert.equal(at(undefined), null)
})

test("ageUnit accepts a millisecond timestamp", () => {
  const now = Date.parse("2026-10-17T12:00:00Z")
  assert.deepEqual(Model.ageUnit(now - 90000, now), { unit: "minutes", value: 1 })
  assert.equal(Model.ageUnit(NaN, now), null)
})

test("ageUnit never reports a negative age", () => {
  const future = Date.now() + 60000
  assert.deepEqual(Model.ageUnit(new Date(future).toISOString(), Date.now()).unit, "seconds")
})

// ---- views --------------------------------------------------------------

test("view accepts the three feeds and nothing else", () => {
  assert.equal(Model.view("following"), "following")
  assert.equal(Model.view("LATEST"), "latest")
  assert.equal(Model.view("Trending"), "trending")
  for (const value of ["", "log/latest", "latest?cursor=x", "../../etc", null, undefined]) {
    assert.equal(Model.view(value), "", `should reject ${JSON.stringify(value)}`)
  }
})

test("logUrl only answers for the two pages that exist", () => {
  assert.equal(Model.logUrl("latest"), "https://dev-null.sh/log/latest")
  assert.equal(Model.logUrl("trending"), "https://dev-null.sh/log/trending")
  assert.equal(Model.logUrl("following"), "")
  assert.equal(Model.logUrl("../login"), "")
})

test("pageFetchArgs takes exactly the two log pages", () => {
  const args = Model.pageFetchArgs(Model.logUrl("trending"))
  assert.equal(args[0], "curl")
  assert.equal(args.at(-1), "https://dev-null.sh/log/trending")
  assert.ok(args.includes("--max-filesize"))

  for (const value of [
    "https://dev-null.sh/log/following",        // 302 to the login page
    "https://dev-null.sh/log/latest?cursor=x",  // pagination is not wired up
    "https://evil.example/log/latest",
    "https://dev-null.sh/log/latest/../../login",
    "",
    null
  ]) {
    assert.deepEqual(Model.pageFetchArgs(value), [], `should refuse ${value}`)
  }
})

// A log page as the site serves it: the feed inside an Inertia payload, with
// the same commit shape the public API returns.
function logPage(commits) {
  return `<!DOCTYPE html><html><head><title>Latest</title></head><body>
    <div id="app"></div>
    <script type="application/json" id="app">${JSON.stringify({
      component: "log/show",
      props: {
        errors: {},
        name: "/dev/null",
        commits: { path: "https://dev-null.sh/log/latest", data: commits }
      }
    })}</script>
    <script type="module" src="/build/assets/app.js"></script>
  </body></html>`
}

test("inertiaPayload reads the JSON script tag and nothing else", () => {
  const page = Model.inertiaPayload(logPage([commit()]))
  assert.ok(page)
  assert.equal(page.component, "log/show")
  assert.equal(page.props.commits.data.length, 1)
})

test("inertiaPayload survives a page it cannot use", () => {
  assert.equal(Model.inertiaPayload(""), null)
  assert.equal(Model.inertiaPayload("<html><body>no payload</body></html>"), null)
  assert.equal(Model.inertiaPayload('<script type="application/json">{oops</script>'), null)
  assert.equal(Model.inertiaPayload('<script type="application/json">'), null)
  assert.equal(Model.inertiaPayload('<script type="application/json">{"a":1}'), null)
  assert.equal(Model.inertiaPayload("x".repeat(Model.PAGE_LIMIT + 1)), null)
})

test("parseLogPage normalizes the feed out of a page", () => {
  const parsed = Model.parseLogPage(logPage([commit(), commit({ id: uuidId(1) })]))

  assert.equal(parsed.length, 2)
  assert.equal(parsed[0].authorUsername, "nunomaduro")
  assert.equal(parsed[0].stars, 50)
  assert.equal(parsed[0].url, "https://dev-null.sh/@nunomaduro/commits/01a149c1-f76d-703d-ae60-e82d7960889a")
})

test("parseLogPage returns nothing rather than throwing on a page it cannot read", () => {
  assert.deepEqual(Model.parseLogPage(""), [])
  assert.deepEqual(Model.parseLogPage("<html><body>login</body></html>"), [])
  assert.deepEqual(Model.parseLogPage(logPage([])), [])
  assert.deepEqual(Model.parseLogPage(logPage([{ id: "nope" }])), [])
})

// A feed that is genuinely empty and a page that could not be read both parse
// to no rows. The panel says "this feed could not be read" only for the second
// one, so the model has to tell them apart.
test("pageFeed separates an empty feed from an unreadable page", () => {
  assert.deepEqual(Model.pageFeed(logPage([])), [])
  assert.equal(Model.pageFeed(logPage([commit()])).length, 1)
  assert.equal(Model.pageFeed("<html><body>login</body></html>"), null)
  assert.equal(Model.pageFeed(""), null)
  assert.equal(Model.pageFeed('<script type="application/json">{"props":{}}</script>'), null)
})

test("a log page cannot smuggle markup or a foreign URL into a row", () => {
  const parsed = Model.parseLogPage(logPage([commit({
    author: Object.assign({}, AUTHOR, {
      avatar_url: "https://evil.example/pixel.png",
      username: "bad user"
    })
  })]))

  assert.equal(parsed.length, 0)

  const kept = Model.parseLogPage(logPage([commit({ body: '<img src="https://tracker.invalid/p">hello' })]))
  assert.ok(!kept[0].body.includes("<"))
  assert.ok(!kept[0].body.includes("tracker.invalid"))
})

// ---- signing in ---------------------------------------------------------
//
// The flow is the mobile app's: a browser approves an SSH key for the account,
// and every request afterwards is signed with it. What the model owns is the
// shape of every byte that leaves the plugin — the message ssh-keygen signs,
// the headers it goes in, the page the browser opens, and the one-time code
// that comes back. The panel owns the processes that carry them.

const TS = "1761220800"
const NONCE = "0123456789abcdef0123456789abcdef"
const SIGNATURE_ARMOR = "-----BEGIN SSH SIGNATURE-----\n" +
  "U1NIU0lHAAAAAQAAAB0AAAALc3NoLWVkMjU1MTkAAAAg\n" +
  "-----END SSH SIGNATURE-----\n"

test("logApiPath names the signed logs and nothing else", () => {
  assert.equal(Model.logApiPath("following"), "/api/v1/log/following")
  assert.equal(Model.logApiPath("Latest"), "/api/v1/log/latest")
  assert.equal(Model.logApiPath("trending"), "/api/v1/log/trending")
  for (const value of ["", "log/latest", "../me", "latest?cursor=1", null, undefined]) {
    assert.equal(Model.logApiPath(value), "", `should reject ${JSON.stringify(value)}`)
  }
})

test("signedPath is an allowlist, not a passthrough", () => {
  assert.equal(Model.signedPath("/api/v1/log/following"), "/api/v1/log/following")
  assert.equal(Model.signedPath("/api/v1/devices"), "/api/v1/devices")
  for (const value of [
    "/api/v1/me",
    "/api/v1/users/nunomaduro",
    "/api/v1/log/following?page=2",
    "/api/v1/devices/../log/latest",
    "https://evil.example/api/v1/devices",
    "",
    null
  ]) {
    assert.equal(Model.signedPath(value), "", `should refuse ${value}`)
  }
})

test("signedMessage is the byte string the server checks", () => {
  assert.equal(
    Model.signedMessage(TS, NONCE, "GET", "/api/v1/log/following", ""),
    `${TS}\n${NONCE}\nGET\n/api/v1/log/following\n`
  )

  // Every part has to be the shape the server verifies, or nothing is signed.
  assert.equal(Model.signedMessage("12345", NONCE, "GET", "/api/v1/log/following", ""), "")
  assert.equal(Model.signedMessage(TS + "x", NONCE, "GET", "/api/v1/log/following", ""), "")
  assert.equal(Model.signedMessage(TS, NONCE.toUpperCase(), "GET", "/api/v1/log/following", ""), "")
  assert.equal(Model.signedMessage(TS, NONCE.slice(1), "GET", "/api/v1/log/following", ""), "")
  assert.equal(Model.signedMessage(TS, NONCE, "DELETE", "/api/v1/log/following", ""), "")
  assert.equal(Model.signedMessage(TS, NONCE, "GET", "/api/v1/me", ""), "")
  assert.equal(Model.signedMessage(TS, NONCE, "POST", "/api/v1/devices", "x".repeat(4097)), "")
})

test("signatureBody takes the armor off and nothing else", () => {
  const body = Model.signatureBody(SIGNATURE_ARMOR)
  assert.match(body, /^[A-Za-z0-9+/=]{40,4096}$/)
  assert.ok(!body.includes("-") && !body.includes("\n"))

  for (const value of ["", "not a signature", "<html>", "-----BEGIN SSH SIGNATURE-----\nshort\n", null]) {
    assert.equal(Model.signatureBody(value), "", `should refuse ${JSON.stringify(value)}`)
  }
})

test("signedFetchArgs carries the headers and never hides the status", () => {
  const signature = Model.signatureBody(SIGNATURE_ARMOR)
  const args = Model.signedFetchArgs("GET", "/api/v1/log/following", TS, NONCE, signature, "")

  assert.equal(args[0], "curl")
  assert.ok(args.includes(`X-Devnull-Timestamp: ${TS}`))
  assert.ok(args.includes(`X-Devnull-Nonce: ${NONCE}`))
  assert.ok(args.includes(`X-SSH-Signature: ${signature}`))
  // The status has to survive as the last line: a revoked device answers 401
  // with a body, and the panel says "sign in again" off that status.
  assert.equal(args[args.indexOf("-w") + 1], "\n%{http_code}")
  assert.ok(!args.includes("-f"))
  assert.equal(args.at(-1), "https://dev-null.sh/api/v1/log/following")
  assert.ok(!args.includes("-X"))

  const post = Model.signedFetchArgs("POST", "/api/v1/devices", TS, NONCE, signature, '{"code":"x"}')
  assert.equal(post[post.indexOf("-X") + 1], "POST")
  assert.equal(post[post.indexOf("--data-binary") + 1], '{"code":"x"}')

  // Anything the model did not build is refused whole, never partly built.
  assert.deepEqual(Model.signedFetchArgs("GET", "https://evil.example/api/v1/log/following", TS, NONCE, signature, ""), [])
  assert.deepEqual(Model.signedFetchArgs("GET", "/api/v1/me", TS, NONCE, signature, ""), [])
  assert.deepEqual(Model.signedFetchArgs("GET", "/api/v1/log/following", TS, NONCE, "<html>", ""), [])
  assert.deepEqual(Model.signedFetchArgs("DELETE", "/api/v1/log/following", TS, NONCE, signature, ""), [])
  // A POST with no body has nothing to sign.
  assert.deepEqual(Model.signedFetchArgs("POST", "/api/v1/devices", TS, NONCE, signature, ""), [])
})

test("authorizeUrl pins every parameter it builds", () => {
  const fingerprint = "SHA256:" + "A".repeat(43)
  const challenge = "B".repeat(43)
  const state = "c".repeat(32)

  const url = Model.authorizeUrl({ fingerprint, deviceName: "Omarchy bar", challenge, state })
  assert.ok(url.startsWith("https://dev-null.sh/mobile/authorize?"))
  const query = new URL(url).searchParams
  assert.equal(query.get("fingerprint"), fingerprint)
  assert.equal(query.get("device_name"), "Omarchy bar")
  assert.equal(query.get("code_challenge"), challenge)
  assert.equal(query.get("code_challenge_method"), "S256")
  assert.equal(query.get("state"), state)
  // The one redirect the site accepts for the approval page, so the code can
  // only come back to the plugin's own handler.
  assert.equal(query.get("redirect_uri"), "devnull://authorize")

  assert.equal(Model.authorizeUrl({ fingerprint: "SHA256:short", deviceName: "x", challenge, state }), "")
  assert.equal(Model.authorizeUrl({ fingerprint, deviceName: "", challenge, state }), "")
  assert.equal(Model.authorizeUrl({ fingerprint, deviceName: "x", challenge: challenge.slice(1) + "+", state }), "")
  assert.equal(Model.authorizeUrl({ fingerprint, deviceName: "x", challenge, state: state.toUpperCase() }), "")
  assert.equal(Model.authorizeUrl(null), "")
})

test("parseCallbackUrl only redeems its own redirect and state", () => {
  const state = "a".repeat(32)
  const code = "b".repeat(64)

  assert.equal(Model.parseCallbackUrl(`devnull://authorize?state=${state}&code=${code}`, state), code)

  // GIO's launcher re-serialises the empty path as "/", and that is still the
  // same callback; anything else past the scheme is not.
  assert.equal(Model.parseCallbackUrl(`devnull://authorize/?state=${state}&code=${code}`, state), code)
  assert.equal(Model.parseCallbackUrl(`devnull://authorize/?state=${"c".repeat(32)}&code=${code}`, state), "")
  assert.equal(Model.parseCallbackUrl(`devnull://authorize/x?state=${state}&code=${code}`, state), "")

  // A state from another attempt, another scheme, another path, a missing or
  // malformed code: nothing is redeemed.
  assert.equal(Model.parseCallbackUrl(`devnull://authorize?state=${"c".repeat(32)}&code=${code}`, state), "")
  assert.equal(Model.parseCallbackUrl(`devnullx://authorize?state=${state}&code=${code}`, state), "")
  assert.equal(Model.parseCallbackUrl(`devnull://login?state=${state}&code=${code}`, state), "")
  assert.equal(Model.parseCallbackUrl(`devnull://authorize?state=${state}`, state), "")
  assert.equal(Model.parseCallbackUrl(`devnull://authorize?state=${state}&code=${code.toUpperCase()}`, state), "")
  assert.equal(Model.parseCallbackUrl(`devnull://authorize?state=${state}&code=${code.slice(1)}`, state), "")
  assert.equal(Model.parseCallbackUrl("", state), "")
  assert.equal(Model.parseCallbackUrl(null, state), "")
  assert.equal(Model.parseCallbackUrl(`devnull://authorize?state=${state}&code=${code}`, ""), "")
})

test("deviceBody is the redemption the server expects", () => {
  const code = "b".repeat(64)
  const verifier = "v".repeat(43)

  assert.deepEqual(JSON.parse(Model.deviceBody(code, verifier)), { code, code_verifier: verifier })

  for (const value of ["", code.slice(1), code.toUpperCase(), "z".repeat(64)]) {
    assert.equal(Model.deviceBody(value, verifier), "", `code ${value}`)
  }
  for (const value of ["", "short", "v".repeat(129)]) {
    assert.equal(Model.deviceBody(code, value), "", `verifier ${value}`)
  }
})

test("base64UrlFromHex is the PKCE challenge the site's regex wants", () => {
  const { createHash } = require("node:crypto")
  const verifier = "x".repeat(43)
  const digest = createHash("sha256").update(verifier)

  const challenge = Model.base64UrlFromHex(digest.copy().digest("hex"))
  assert.equal(challenge, createHash("sha256").update(verifier).digest("base64url"))
  assert.match(challenge, /^[A-Za-z0-9_-]{43}$/)

  for (const value of ["", "0".repeat(63), "0".repeat(65), "zz".repeat(32), null]) {
    assert.equal(Model.base64UrlFromHex(value), "", `should refuse ${JSON.stringify(value)}`)
  }
})

test("the tool output is read by its shape, not by position", () => {
  // od prints hex in columns of whitespace; the run of hex is what is wanted.
  assert.equal(Model.hexFromOd(" 0a 1b\n 2c 3d\n"), "0a1b2c3d")
  assert.equal(Model.hexFromOd(" 5f 3A \n"), "5f3a")
  assert.equal(Model.hexFromOd(""), "")

  assert.equal(Model.digestHex("a".repeat(64) + "  -\n"), "a".repeat(64))
  assert.equal(Model.digestHex("A".repeat(64) + "  -"), "a".repeat(64))
  assert.equal(Model.digestHex("junk"), "")
  assert.equal(Model.digestHex(null), "")

  // ssh-keygen -lf key.pub prints "<bits> SHA256:<43 chars> <comment> (<type>)".
  assert.equal(
    Model.fingerprintFromSshKeygen("256 SHA256:" + "A".repeat(43) + " Omarchy bar (ED25519)"),
    "SHA256:" + "A".repeat(43)
  )
  assert.equal(Model.fingerprintFromSshKeygen("key.pub is not a public key file"), "")
  assert.equal(Model.fingerprintFromSshKeygen(null), "")
})

test("the account file round trips and refuses anything else", () => {
  const fingerprint = "SHA256:" + "A".repeat(43)
  const account = Model.parseAccount(Model.accountJson({ username: "ivo", name: "Ivo" }, fingerprint, "2026-10-22T12:00:00Z"))

  assert.equal(account.username, "ivo")
  assert.equal(account.name, "Ivo")
  assert.equal(account.fingerprint, fingerprint)
  assert.equal(account.device, "Omarchy bar")
  assert.equal(account.signedInAt, "2026-10-22T12:00:00Z")

  // No usable username or no usable fingerprint is not an account.
  assert.equal(Model.parseAccount(JSON.stringify({ username: "bad name", fingerprint })), null)
  assert.equal(Model.parseAccount(JSON.stringify({ username: "ivo", fingerprint: fingerprint.toLowerCase() })), null)
  assert.equal(Model.parseAccount("not json"), null)
  assert.equal(Model.parseAccount(""), null)

  assert.equal(Model.accountJson({ username: "bad name" }, fingerprint, ""), "")
  assert.equal(Model.accountJson({ username: "ivo" }, "nope", ""), "")
  assert.equal(Model.accountJson(null, fingerprint, ""), "")
})

test("stateDir follows XDG and never lands in shell.json's directory", () => {
  assert.equal(Model.stateDir("/home/ivo", ""), "/home/ivo/.local/state/omarchy/devnull")
  assert.equal(Model.stateDir("/home/ivo", "/tmp/x/"), "/tmp/x/omarchy/devnull")
  assert.equal(Model.stateDir("", "/tmp/x"), "/tmp/x/omarchy/devnull")
  assert.equal(Model.stateDir("", ""), "")
  assert.equal(Model.stateDir(null, undefined), "")
})

test("desktopEntry points the scheme at the plugin's own script", () => {
  const script = "/home/ivo/.config/omarchy/plugins/io.github.ivozzz.devnull/bin/devnull-callback"
  const entry = Model.desktopEntry(script)

  assert.ok(entry.includes("MimeType=x-scheme-handler/devnull;"))
  assert.ok(entry.includes(`Exec="${script}" %u`))
  assert.ok(entry.includes("NoDisplay=true"))

  // A path that could smuggle a second key, or break the quoting, is refused
  // rather than escaped: the plugin never writes one.
  assert.equal(Model.desktopEntry(""), "")
  assert.equal(Model.desktopEntry('/tmp/evil" %u\nExec=/bin/sh'), "")
})

test("splitStatus takes curl's status off the body", () => {
  assert.deepEqual(Model.splitStatus('{"data":[]}\n200'), { status: 200, body: '{"data":[]}' })
  assert.deepEqual(
    Model.splitStatus('{"message":"This key isn\'t approved for this device.","code":"device_not_approved"}\n401'),
    { status: 401, body: '{"message":"This key isn\'t approved for this device.","code":"device_not_approved"}' }
  )
  // No status line at all: a request that never got an answer.
  assert.deepEqual(Model.splitStatus(""), { status: 0, body: "" })
  assert.deepEqual(Model.splitStatus("junk"), { status: 0, body: "junk" })
  assert.deepEqual(Model.splitStatus(null), { status: 0, body: "" })
})

test("feedList separates an empty feed from an unreadable one", () => {
  assert.deepEqual(Model.feedList('{"data":[]}'), [])
  assert.equal(Model.feedList(JSON.stringify({ data: [commit()] })).length, 1)
  assert.equal(Model.feedList('{"data":{"id":"x"}}'), null)
  assert.equal(Model.feedList('{"message":"Invalid signature."}'), null)
  assert.equal(Model.feedList("not json"), null)
  assert.equal(Model.feedList(""), null)
})