// Regression coverage for Model.js.
//
// The interesting cases are the ones a hostile or broken response produces:
// markup-shaped text heading for a Text or a tooltip, a URL pointing
// somewhere else, a username carrying shell metacharacters, a body far past
// what the panel will draw. Run with: node --test tests/
const test = require("node:test")
const assert = require("node:assert/strict")
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