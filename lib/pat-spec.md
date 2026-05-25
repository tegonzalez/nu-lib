# pat-spec.md — Layered Pattern Engine

Authority document for `nu-lib/lib/pat.nu`. All pattern behavior is defined here; `pat.nu` is the canonical implementation.

Pattern objects are opaque. Consumers query via `pat stem` / `pat literal` / `pat any` / `pat match` / `pat filter`. Direct field access on pattern objects (`.tier`, `.any`, `.segments`, `.regex`, `.raw`, `.delim`) is forbidden.

---

## 1. Purpose and Architecture

This file is the single authority for the two-channel, two-tier segment pattern system. It is organized in two parts:

- **§§ 2–10 Public surface** — everything a tool author needs to consume `pat.nu`.
- **§ 11 Performance** — internal optimization notes for implementers.
- **Private Kernel** — internal algorithms normative for implementers of `pat.nu`; tool authors must not depend on them.

### 1.1 Layered Architecture

| Layer | Owner | Responsibility |
|---|---|---|
| A — Parse | pat | raw string + cfg → opaque pattern object. All promotion (trailing-slash, anchor_descend) happens here. |
| B — Accessors | pat | read-only views (`stem`, `literal`, `any`) on the pattern object |
| C — Match | pat | given a pattern + record list, annotate each record with emit and expand booleans |
| D — BFS loop | tool | seeds frontier with stem entry, calls match per level, collects emit, expands expand |
| E — Expr filter | tool (calls pat) | flat filter over walk output by value |
| F — Render | tool (using rope) | rope shape + render |

No layer reaches into another. Tools never inspect tiers, segments, regex, or any pattern-object internals. Pat never touches fs, store, graph, or rope.

---

## 2. Pattern Object

A pattern object is the opaque output of `pat parse`. Its internal state (tier, segments, residual matcher, regex) is private to `pat.nu`. Tool authors interact with pattern objects only through the six public functions enumerated in § 3.

Three observable states, distinguished by the public accessors:

| State | `pat literal` | `pat any` | Meaning |
|---|---|---|---|
| fully literal | `true` | `false` | exact stem entry; no walk required |
| universal | `false` | `true` | matches everything at every depth |
| filtered | `false` | `false` | has residual pattern; drives BFS via match |

`pat literal` and `pat any` are mutually exclusive: at most one is `true`; both being `true` is an invalid construction. Empty input (`""`) parses to `any = true, literal = false` — it is treated as universal (`%%`), not as a literal empty string.

---

## 3. Public Surface

Six public functions. Nothing else is callable from outside `pat.nu`.

```
pat parse  [raw: string, cfg: record] -> {scope: pattern, expr: pattern}
pat stem   [pattern] -> string
pat literal[pattern] -> bool
pat any    [pattern] -> bool
pat match  [pattern, records: list<{path: string, item: any}>]
             -> list<{record, emit: bool, expand: bool}>
pat filter [pattern, records: list, --value: closure]
             -> list<{record, emit: bool}>
```

### pat parse

`pat parse [raw: string, cfg: record] -> {scope: pattern, expr: pattern}`

The canonical entry point. Parses the two-channel form and returns a pair of opaque pattern objects. All promotion (trailing-slash, anchor_descend) is absorbed here. Tools never mutate patterns after parse.

**`cfg` shape:**

| Field | Type | Default | Purpose |
|---|---|---|---|
| `delim` | string | `"/"` | path segment separator for scope |
| `expr_delim` | string\|null | `null` | segment separator for expr (null = single-segment) |
| `anchors` | list\<string\> | `[]` | tokens that are not emittable entries (tool-supplied; e.g. fd: `[".", "..", "/"]`, store-like consumers: `[]`) |
| `anchor_descend` | bool | `false` | when true, an input that is empty or exactly one anchor token auto-promotes to `<token> + delim + %` (depth +1) |

**Grammar table:**

| Input form | scope channel | expr channel | Notes |
|------------|---------------|--------------|-------|
| `""` (empty) | universal (`%%`) | universal | Empty input parses to universal, not literal |
| `"scope"` | `"scope"` | universal | Bare token → scope channel; expr is universal |
| `":expr"` | universal | `"expr"` | Leading `:` → scope is universal; expr has pattern |
| `"scope:"` | `"scope"` | universal | Trailing `:` → expr explicitly omitted; universal returned |
| `"scope:expr"` | `"scope"` | `"expr"` | First `:` splits channels; subsequent `:` belong to expr |

The first `:` is the channel separator. Subsequent colons are part of the expr value. Omitted channels return a universal pattern. Callers use `pat any` to test for this uniformly.

**Trailing-slash promotion (scope slot):** When the scope slot has a trailing `cfg.delim` (e.g. `"nu-lib/%/"`), the trailing delimiter is stripped and `delim + %` is appended before matcher construction. The promotion adds exactly one segment of depth — never unbounded. The promotion is parse-time only; no flag is returned.

| Input form | scope raw after promotion |
|-----------------------------------|---------------------------|
| `"nu-lib/%/"` | `"nu-lib/%/%"` |
| `"%/"` | `"%/%"` |
| `"%%/"` | `"%%/%"` |

**anchor_descend promotion:** When `cfg.anchor_descend = true` and the raw input is empty or exactly one token from `cfg.anchors`, the pattern auto-promotes to `<token> + cfg.delim + %` (single segment — depth +1, not unbounded). This only applies to empty inputs and exact anchor tokens; regex-tier patterns never promote via this rule (see § 7.3).

### pat stem

`pat stem [pattern] -> string`

Returns the literal prefix of the pattern as a single string, with any anchor token folded into the front (e.g. `"."`, `"./lib"`, `"/usr/bin"`). The tool's path-expand handles resolution. Never contains pattern characters (`%`, regex metacharacters).

For a universal pattern, `pat stem` returns `""`. For a fully literal pattern, `pat stem` returns the entire raw string.

### pat literal

`pat literal [pattern] -> bool`

Returns `true` when the pattern is fully literal (exact match against the stem; no BFS walk needed). `false` otherwise.

### pat any

`pat any [pattern] -> bool`

Returns `true` when the pattern is universal (matches everything at every depth). `false` otherwise.

### pat match

`pat match [pattern, records: list<{path: string, item: any}>] -> list<{record, emit: bool, expand: bool}>`

For each input record `{path, item}`, returns `{record, emit, expand}` with two independent booleans:

| emit | expand | Tool action |
|---|---|---|
| true | false | emit; do not expand |
| false | true | do not emit; pull children into next frontier |
| true | true | emit AND pull children into next frontier |
| false | false | prune entirely |

The seed record at `path = ""` is itself just another record; `pat match` decides its emit/expand the same way as every other record. The internal kernel that produces these booleans is documented in § 11 (Private Kernel).

### pat filter

`pat filter [pattern, records: list, --value: closure] -> list<{record, emit: bool}>`

Flat filter over a list of records by value. Never produces `expand`. Always called after the scope walk completes (layer E). The `--value` flag is mandatory; omitting it is an error.

**`--value` closure signature:** receives the whole record `{path, item}` and must return `string`. The returned string is the canonical identifier tested against the expr pattern. No default — callers must own canonical-identifier discipline (see § 9).

---

## 4. Pattern Object Semantics — Promotion Table

All promotion is parse-time. Tools never mutate patterns after parse.

| Input | Tier assigned | Notes |
|---|---|---|
| `""` (empty) | any | Empty → universal; `pat any` returns true |
| `"%%"` | any | Explicit universal |
| `"scope"` (no meta) | exact | Fully literal; `pat literal` returns true |
| `"scope/"` (trailing delim) | depends on scope | Trailing delimiter stripped then `%` appended (depth +1, single segment); result may be wildcard |
| `"scope/%"` | wildcard | Single-segment wildcard tail |
| `"scope/%%"` | wildcard | Multi-segment wildcard tail |
| `"[abc]+"` (regex meta, no `%`) | regex | Regex-like tier; no delimiter splitting |
| anchor token under anchor_descend | wildcard | Promoted to `<token> + delim + %` (depth +1, single segment listing) |

**anchor_descend and trailing-slash promotion** only apply when the input is empty or is exactly one token from `cfg.anchors`. Regex-tier patterns (containing regex metacharacters but no `%`) never promote via either rule.

---

## 5. Wildcard Tier

When a pattern contains `%`, the **wildcard tier** (LIKE tier) applies.

### 5.1 Single-Segment Wildcard: `%`

`%` within a single path segment matches any substring that does not cross a delimiter boundary.

- `projects/%` — matches any direct child of `projects` (one level).
- `projects/app%` — matches any child of `projects` whose name starts with `app`.
- `%/active` — matches `active` under any top-level node.

When `delim` is a non-empty string, `%` → `[^<delim>]*` (excludes the delimiter).
When `delim` is `null` or `""`, `%` → `.*` (any characters including delimiter).

### 5.2 Multi-Segment Wildcard: `%%`

`%%` as a complete segment matches zero or more complete path segments. It is a reserved pattern token, not a LIKE token; it does not participate in single-segment matching.

- `projects/%%/done` — matches `projects/done`, `projects/foo/done`, `projects/foo/bar/done`.
- `%%/active` — matches `active` at any depth including root level.
- `projects/%%` — matches `projects` (zero segments consumed) and any descendant.

`%%` consuming zero segments fires once before the child loop; the child loop keeps `si` constant so each child descends back into the same `%%` handler, preventing duplicate results.

The any-tier is an internal optimization label for the universal matcher (empty input, `%%` at top level). It is not part of the public grammar.

### 5.3 `like-to-regex [pattern: string, delim: string|null]`

Converts a wildcard-tier segment pattern to a regex string character by character:

| Character | Regex output |
|-----------|-------------|
| `%` when `delim` is a non-empty string | `[^<regex-escaped delim>]*` |
| `%` when `delim` is `null` or `""` | `.*` |
| Any other character | regex-escaped literal |

The resulting regex is used in a `^...$` anchored match.

---

## 6. Regex-Like Tier

When a pattern contains no `%` but contains regex metacharacters, the **regex-like tier** applies. This tier treats the pattern as a raw anchored regex applied to the full value string.

**Key rules:**

- `.` is **literal** by default. `README.md` matches the string `README.md`, not `READMExmd`.
- `[]` character classes are retained as regex syntax. `[abc]` matches `a`, `b`, or `c`.
- No `re:` prefix mode. Tier is detected automatically by the absence of `%` combined with the presence of metacharacters.
- The tier does **not** split on delimiter. The full pattern is applied as one regex to the full value string.

### 6.1 Tier Detection Summary

| Pattern contains | Tier |
|-----------------|------|
| No metacharacters at all | `exact` (string equality) |
| `%` (any position) | `wildcard` (LIKE tier, segment-aware) |
| No `%`, but has `[`, `]`, `+`, `?`, `(`, `)`, `{`, `}`, `\|`, `^`, `$` | `regex` (regex-like tier) |
| Empty or `%%` at top level | `any` (universal; internal optimization label) |

### 6.2 Examples

| Pattern | Matches | Does not match | Notes |
|---------|---------|----------------|-------|
| `README.md` | `README.md` | `READMExmd` | `.` is literal |
| `..` | `..` | `ab`, `a.` | Both dots literal |
| `test_[ab].nu` | `test_a.nu`, `test_b.nu` | `test_c.nu` | char class + literal dot |
| `tcp.+` | `tcpX`, `tcp123` | `tcp` | `.` literal, `+` is regex quantifier |
| `nu[0-9]+` | `nu1`, `nu42` | `nux` | char class with quantifier |

---

## 7. Canonical Tool Algorithm

Every pattern-consuming tool runs this loop. The only per-tool differences are `cfg`, the I/O closures, and the rope shape.

```nu
let {scope: p, expr: q} = pat parse $raw $cfg

# Scope walk — BFS, frontier-by-frontier
let stem = pat stem $p
mut frontier = [{path: "", item: (tool.item-of $stem)}]
mut out = []
while ($frontier | is-not-empty) {
  let r = pat match $p $frontier
  out = $out ++ ($r | where emit | each {|x| $x.record})
  frontier = $r | where expand | each {|x|
    tool.expand $x.record | each {|c|
      {path: (path-join $x.record.path $c.name), item: $c.item}
    }
  } | flatten
}

# Expr post-filter
let final = if (pat any $q) { $out } else {
  pat filter $q $out --value {|r| tool.value-of $r.item}
    | where emit | each {|x| $x.record}
}

# Tool composes rope, renders
$final | tool.compose | rope <shape> | render walk $fmt
```

### 7.1 Tool Configuration Examples

| Tool | cfg.anchors | cfg.anchor_descend | Notes |
|---|---|---|---|
| `fd` / `lf` | `[".", "..", "/"]` | `true` | Filesystem anchors; bare `.` promotes to `./ %%` |
| store-like consumer | `[]` | `false` | No anchor tokens in key space |

### 7.2 pat stem Usage

`pat stem` returns the literal prefix as a single string. Tools pass it to their `item-of` closure for path resolution. For filesystem tools, `path expand` resolves anchors (`.`, `..`, `/`). Store-like consumers can use the stem directly as a key prefix.

### 7.3 Regex-Tier and Promotion

Regex-tier patterns (containing regex metacharacters but no `%`) never promote via trailing-slash or anchor_descend rules. Both promotion rules apply only to empty inputs and exact anchor tokens.

---

## 8. Policies (Hard)

1. **All promotion is parse-time.** Tools never mutate patterns after parse. Trailing-slash and anchor_descend expansions are absorbed into the matcher inside `pat parse`.
2. **Pattern objects are opaque to tools.** Tiers, segments, regex strings, and residual state are not exposed. The grep pattern `\$\w+\.(tier|any|segments|regex|raw|delim)\b` must not appear in tool code.
3. **BFS is tool-owned; pruning is pat-owned.** Tools schedule and do I/O; pat decides per-record emit and expand.
4. **`pat filter` (expr) is flat.** Never produces expand. Always called after the scope walk completes.
5. **`cfg.anchors` is the only source of anchor knowledge.** Pat has no built-in fs/store/graph awareness.
6. **`cfg.anchor_descend` is the only switch that promotes bare anchors.** Tools with anchor-as-alias domains (fd) set true; tools without anchors leave false.
7. **No universal `*` in the public grammar.** Empty input and `%%` are semantically equivalent (both parse to the universal pattern). The any-tier survives internally as an optimization label only.
8. **Render hints do not live in pat.** No render shape returned from parse or match. Tools choose render based on their own UX rules.

---

## 9. Canonical Identifier Discipline

The scope channel matches against an entry's **canonical identifier** — one string per entry that uniquely identifies it within its domain.

### 9.1 Canonical Identifier by Tool Class

| Tool class | Canonical identifier |
|------------|---------------------|
| Filesystem walk | Relative path from the walk root (e.g. `lib/pat.nu`) |
| Key/value store | Key path (e.g. `projects/nu-lib/context/decisions`) |
| Code graph | Qualified namespace (e.g. `nu.lib.pat.path-match`) |
| Test discovery | Qualified test name (e.g. `pat::path-match::full-consume`) |

### 9.2 `--value` Closure Contract

The `--value` closure passed to `pat filter` MUST:
- Receive the whole record `{path, item}`.
- Return exactly one `string` — the canonical identifier for the entry.

The `--value` flag is mandatory; omitting it is an error that forces callers to own canonical-identifier discipline.

### 9.3 Anti-Pattern: Multi-Field Co-Feeding

**Invalid:** returning `[$row.path $row.name]` or any combination that mixes a full path with a basename or other sub-component field.

**Reason:** basename is always a single path segment. A wildcard matcher using `%` trivially matches every basename, silently corrupting tier semantics. Patterns that should discriminate on path depth stop discriminating.

### 9.4 Cross-Reference: Full-Consumption Rule

The full-consumption rule (§ 11.2) — that wildcard-tier path-match returns `true` only when both pattern segments AND key segments are fully consumed — only applies when the value being tested is the same kind of string the matcher's delimiter grammar was designed against.

---

## 10. pat stem Accessor — Decomposition Semantics

`pat stem` is the sole public accessor for the literal walk-root of a pattern. It replaces the retired `pat seed` operation.

### 10.1 Return Shape

`pat stem [pattern] -> string`

Returns a single string with the anchor token (if any) folded into the front, followed by literal segments joined by `cfg.delim`. The tool's path-expand handles anchor resolution.

| Input pattern | pat stem returns | pat literal | pat any |
|---------------|-----------------|-------------|---------|
| `""` (empty) | `""` | false | true |
| `lib` | `"lib"` | true | false |
| `lib/args.nu` | `"lib/args.nu"` | true | false |
| `lib/%%` | `"lib"` | false | false |
| `./lib` | `"./lib"` | true | false |
| `./lib/%%` | `"./lib"` | false | false |
| `..` | `".."` | true | false |
| `../Y` | `"../Y"` | true | false |
| `/Z` | `"/Z"` | true | false |
| `/usr/bin` | `"/usr/bin"` | true | false |
| `/usr/%/lib` | `"/usr"` | false | false |
| `/%%` | `"/"` | false | false |
| `%%/X` | `""` | false | false |
| `%/X` | `""` | false | false |
| `projects.%` (delim=`.`) | `"projects"` | false | false |

Notes:
- Empty input: universal; stem is `""`, `pat any` is true.
- Fully literal patterns: stem equals the full input, `pat literal` is true.
- Patterns beginning with a wildcard segment (`%%/X`, `%/X`): stem is `""` — the tool seeds at the root.
- `pat literal` true implies the tool performs no BFS walk; it resolves the stem directly.

### 10.2 pat.nu fs-Agnosticism

`pat.nu` performs **no filesystem operations**:
- No path resolution (no `path expand`, no `path join`).
- No `./` normalization.
- No `..` resolution.
- No glob expansion.
- No `stat` calls.
- No file `open`.

`pat stem` is a **purely syntactic** accessor on the pattern object. The calling tool is solely responsible for resolving the returned string to a concrete walk anchor via its own I/O layer.

---

## 11. Performance

Matcher precomputation avoids per-call overhead:

- **Exact tier**: match is a direct string equality test. No regex engine invoked. Patterns with no metacharacters are detected and stored as exact at construction time; internal optimization, not behaviorally observable.
- **Any tier**: match is a single boolean field check. Zero computation. Fast-path for the universal pattern is kept internal.
- **Segment plan** (wildcard tier with delimiter): segments pre-split at construction; path-match walks the pre-split list rather than splitting on every call.
- **Regex-like tier**: regex field stores the pre-compiled pattern string. The regex engine is invoked once per value tested. The tier does not split on delimiter (no segment overhead).

---

## Private Kernel

The following algorithms are **private to `pat.nu`**. They are normative for implementers of `pat.nu`; tool authors must not depend on them. The public API (`pat match`, `pat filter`) is the only stable interface.

### PK-1. `segment-match [seg-pat: string, value: string, delim: string|null]`

Apply the two-tier rule to one segment pair. Returns `bool`.

`segment-match` operates on ONE segment pair only. Multi-segment matching is the job of `path-match` (PK-2).

- If `%` appears in `seg-pat`: call `like-to-regex(seg-pat, delim)` → `rx`; return `value =~ "^($rx)$"`.
- Otherwise: return `value =~ "^($seg-pat)$"` (regex-like or exact, depending on content).

### PK-2. `path-match [pattern: string, key: string, delim: string]`

Splits both `pattern` and `key` on `delim`, then walks the segment-pattern list against the key-segment list.

**Algorithm:**

1. `seg-pats ← pattern.split(delim)`
2. `key-segs ← key.split(delim)`
3. Recursively walk `seg-pats` (index `si`) against `key-segs` (cursor `ki`):
   - If `si == len(seg-pats)` and `ki == len(key-segs)`: **return true** — all consumed.
   - If `si == len(seg-pats)` and `ki < len(key-segs)`: **return false** — unconsumed key segs remain.
   - If `seg-pats[si] == "%%"`: try consuming 0, 1, 2, … key-segs until the remainder matches; return true on first success, false if none succeed.
   - Otherwise: if `ki == len(key-segs)`, return false; call `segment-match(seg-pats[si], key-segs[ki], delim)`; on match advance both cursors by one and recurse; on mismatch return false.
4. Return false if the walk completes without satisfying step 3's success condition.

> **Full-consumption is required:** a successful match consumes ALL key segments. When pattern segments are exhausted but key segments remain unconsumed, the match returns false.

**Examples:**

| Call | Result | Reason |
|------|--------|--------|
| `path-match "%" "cg" "/"` | `true` | 1 pat seg, 1 key seg; both consumed |
| `path-match "%" "cg/tests" "/"` | `false` | pat exhausted; key has unconsumed seg |
| `path-match "lib" "lib/args.nu" "/"` | `false` | pat exhausted; key has unconsumed seg |
| `path-match "lib/%" "lib/args/extra" "/"` | `false` | pat exhausted; key has unconsumed seg |
| `path-match "lib/%%" "lib/args/extra" "/"` | `true` | `%%` consumes 2 remaining segs |
| `path-match "%%/X" "a/b/X" "/"` | `true` | `%%` consumes 2 leading segs; X matches X |
| `path-match "%%/X" "a/b/X/Y" "/"` | `false` | after X, key has unconsumed Y |

### PK-3. `pat-at [pattern, path: string] -> {emit: bool, expand: bool}`

The per-path predicate that underlies `pat match`. `pat match` lifts this from per-path to per-batch.

**Verdict table:**

| Path | Pattern state | emit | expand | Notes |
|------|---------------|------|--------|-------|
| `""` (seed) | universal | true | true | Universal matches everything at every depth |
| `""` (seed) | filtered | false | true | Empty prefix is always a valid prefix of any non-empty pattern |
| `""` (seed) | literal | true | false | Tool seeds BFS with the stem entry (`item-of $stem`). Literal pattern matches it directly; no walk needed. |
| past literal depth | literal | false | false | Unreachable in canonical algorithm (literal/seed emits with `expand=false`, so walk ends); listed for completeness. |
| prefix of pattern | filtered | false | true | Valid prefix; may still reach a match |
| full match | filtered | true | true or false | Depends on whether `%%` allows further extension |
| mismatch | filtered | false | false | Prune |
| any path | universal | true | true | Universal; emit and expand always |

**Common bugs:**
- **prefix-match drift**: Implementations that forget to enforce `ki == len(key-segs)` at pattern exhaustion will incorrectly accept values whose segment prefix matches. Surfaced by `pat match` returning emit=true for `"cg/tests"` when pattern is `"cg"`.

### PK-4. Edge Cases

**`%%` consuming zero segments:** `%%` matches the empty sub-path. `"a/%%/b"` matches key `"a/b"`.

**`%%` at start or end:** `"%%/done"` matches `"done"` (zero leading segments consumed) and `"x/y/done"`. `"projects/%%"` matches `"projects"` and `"projects/a/b/c"`.

**Any-tier sentinel:** The universal pattern bypasses all pattern logic and always emits true and expands true. It is not produced by `%` in a pattern — it is produced only when the input is empty or `%%` at top level.

**Regex-like tier — dot is literal:** A pattern in the regex-like tier treats `.` as a literal character. `"README.md"` matches only `README.md`. For a scope with `scope_delim "."`, the pattern `"net.ipv4.tcp.+"` is regex-like; the entire pattern is applied as one regex to the whole key string without splitting on `.`.

**Custom delimiter — dot-namespace:** Passing `{delim: "."}` switches scope segmentation to dot-separated namespaces. `pat parse "net.ipv4.tcp%" {delim: "."}` produces a scope pattern with `tier = "wildcard"`, `segments = ["net", "ipv4", "tcp%"]`. The last segment `"tcp%"` is LIKE-tier and matches `"tcp_syncookies"` (excludes `.`).
