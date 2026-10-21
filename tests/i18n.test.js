// The catalogs and the keys the panel asks them for.
//
// A missing key is silent at runtime: the panel falls back to the English
// literal in the call, so the mistake only shows up as one row that refuses to
// translate. Run with: node --test tests/
const test = require("node:test")
const assert = require("node:assert/strict")
const fs = require("node:fs")
const path = require("node:path")
const Model = require("../Model.js")

const dir = path.join(__dirname, "..")
const read = (file) => JSON.parse(fs.readFileSync(path.join(dir, "i18n", file), "utf8"))
const en = read("en.json")
const it = read("it.json")

test("both catalogs carry the same keys", () => {
  assert.deepEqual(Object.keys(en).sort(), Object.keys(it).sort())
})

test("every literal key the panel asks for is in both catalogs", () => {
  const source = ["Panel.qml", "BarWidget.qml"]
    .map((file) => fs.readFileSync(path.join(dir, file), "utf8"))
    .join("\n")

  const keys = new Set()
  const call = /strings\.tn?\(\s*"([^"]+)"/g
  let match
  while ((match = call.exec(source)) !== null) {
    // `strings.t("age." + unit, ...)` builds its key at runtime; the units it
    // can produce are checked by the next test.
    if (!match[1].endsWith(".")) keys.add(match[1])
  }

  // A pattern that matches nothing would pass every assertion below.
  assert.ok(keys.size > 20, `found ${keys.size} keys`)
  for (const key of keys) {
    assert.ok(en[key] !== undefined, `en.json is missing ${key}`)
    assert.ok(it[key] !== undefined, `it.json is missing ${key}`)
  }
})

// ageUnit() decides the unit and the panel looks the label up by name, so a
// unit without a catalog entry would render as a raw key in the row.
test("the age catalog covers every unit the model can return", () => {
  const units = new Set(["seconds", "minutes", "hours", "days", "weeks", "months", "years"])
  for (const unit of units) {
    assert.ok(en["age." + unit] !== undefined, `en.json is missing age.${unit}`)
    assert.ok(it["age." + unit] !== undefined, `it.json is missing age.${unit}`)
  }

  // The model's own vocabulary, read from it rather than assumed.
  const now = Date.parse("2026-10-17T12:00:00Z")
  for (const iso of [
    "2026-10-17T11:59:30Z",
    "2026-10-17T11:45:00Z",
    "2026-10-17T09:00:00Z",
    "2026-10-15T12:00:00Z",
    "2026-10-01T12:00:00Z",
    "2026-06-01T12:00:00Z",
    "2024-09-01T12:00:00Z"
  ]) {
    assert.ok(units.has(Model.ageUnit(iso, now).unit), iso)
  }
})
