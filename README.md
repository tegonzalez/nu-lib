# Nu Script Library

`nu-lib` is a Nushell toolkit for building repository-local command line tools. It supplies reusable modules for argument parsing, pattern matching, filesystem queries, Markdown/text processing, structured rendering, terminal display, locking, testing, and bounded parallel execution.

The library is meant for scripts that need shell ergonomics without losing structured data. Tools exchange records, tables, lists, and strings; modules return structured values where possible; command entry points own user-facing IO.

## Purpose

Use `nu-lib` when a repo tool needs to parse command chains and global flags, filter paths or names with a compact pattern syntax, turn Markdown/filesystem/tree data into structured records, render output as terminal tables or JSON, run Nu tests, coordinate subprocess work, or keep terminal and file effects isolated behind explicit module boundaries.

The top-level contract is **isolate IO**: pure transforms accept data via `$in` or explicit arguments and return data; query modules isolate reads; mutating modules are marked; command entry points own `open`, `save`, `print`, and process exit behavior.

## Layout

| Path          | Purpose                                                             |
| ------------- | ------------------------------------------------------------------- |
| `bin/`        | Thin executable wrappers that call tool scripts under `tools/`.     |
| `tools/`      | End-user CLIs built from the library modules.                       |
| `lib/`        | Reusable Nushell modules and module-local specifications.           |
| `lib/tests/`  | Unit tests for library modules, runnable through `ntst`.            |
| `principles/` | Repo-specific support scripts for principle indexing.               |

## Tool Index

| Tool    | Purpose                         | Typical Use                                                     | Detailed Doc                  |
| ------- | ------------------------------- | --------------------------------------------------------------- | ----------------------------- |
| `lf`    | Filesystem discovery            | Find paths by path/name pattern and render matches as tables.   | Tool source: `tools/lf/lf.nu` |
| `show`  | Renderer demonstration          | Exercise renderer formats, folder renderers, and stream panels. | Tool source: `tools/show/`    |
| `ntst`  | Nu test discovery and execution | Discover `test_*.nu` files, run cases, list cases, and report.  | This README, test section     |
| `cg`    | TypeScript callgraph analysis   | Extract function-level call edges from TypeScript via ast-grep. | `tools/cg/README.md`          |

This README explains the library organization, bundled generic tools, and shared module contracts. Tool-specific docs live with the tool that owns the command surface.

## IO Contract

| Tier        | Description                                                        | Examples                                       |
| ----------- | ------------------------------------------------------------------ | ---------------------------------------------- |
| Pure        | No filesystem, terminal, subprocess, or process-exit effects.      | `pat`, `args`, `md`, `mermaid`, `rstr`, `rope` |
| Query IO    | Reads files, directories, or subprocess output without mutation.    | `fs glob-files`, `fs find`, `fs grep`          |
| Mutating IO | Writes files or changes durable state; marked in the module source. | `fs edit-lines`, `fs edit-section`             |
| Terminal IO | Owns ANSI, cursor movement, stdout panels, or stderr diagnostics.   | `render`, `stream`, `tui`, `log`               |

Command scripts are allowed to combine tiers. Library modules should keep effects localized so a caller can compose pure and query functions without hidden prints, saves, or exits.

## Module Index

| Module       | Purpose                        | Use When                                                               |
| ------------ | ------------------------------ | ---------------------------------------------------------------------- |
| `args.nu`    | Command argument normalization | A tool needs global flags, subcommands, command chains, or help text.  |
| `pat.nu`     | Two-channel pattern matching   | A command needs one compact argument for scope and expression filters. |
| `fs.nu`      | Filesystem query and edits     | A tool needs structured glob/find/grep results or bounded text edits.  |
| `md.nu`      | Markdown extraction            | A script needs headings, frontmatter, sections, code blocks, or links. |
| `mermaid.nu` | Mermaid diagram serialization  | A script needs to build diagram text from structured records.          |
| `rstr.nu`    | Region-marked strings          | Output needs style tags while remaining render-format independent.     |
| `styles.nu`  | Style names and atom sets      | Renderers need a shared vocabulary for headings, states, and labels.   |
| `rope.nu`    | Structured output composition  | Domain data must become renderer-ready tables, trees, or outlines.     |
| `render.nu`  | Final output rendering         | A rope must be emitted as rich terminal output, plain text, or JSON.   |
| `stream.nu`  | Live streaming display         | A long-running tool needs progress labels, tails, panels, or logs.     |
| `tui.nu`     | Terminal mechanics             | A renderer needs cursor movement, column width, or ANSI application.   |
| `log.nu`     | Diagnostic logging             | A tool needs level-controlled stderr messages.                         |
| `flock.nu`   | Advisory file locking          | A mutating tool needs a `mkdir`-based exclusive lock.                  |
| `pool.nu`    | Bounded subprocess parallelism | A runner needs to process many files with controlled concurrency.      |
| `test.nu`    | Unit test harness              | Nu test files need case records, assertions, filtering, and reporting. |

## Core Data Flow

Most tools follow this shape:

```nu
domain data | rope composer | render walk {format: "rich"}
```

The domain script owns discovery, validation, and IO. `rope.nu` turns domain data into a renderer contract. `render.nu` converts that contract into the selected output format.

For terminal-live tools, the flow is event-oriented and owned by `stream.nu`:

```nu
use ./lib/stream.nu *

let state = stream open {format: "rich"} [{name: "results", kind: "tail", height: 8}]
let state = stream step $state {_channel: "results", name: "case", result: "pass"}
stream close $state
```

`stream.nu` owns generic live labels, tail panels, flat/tree panels, logs, and close-time table/tail mechanics. Tools such as `ntst` own test-specific result records, failure detail, and final summary wording; they pass those domain events into the stream rather than moving test semantics into the renderer.

## Pattern Matching

`pat.nu` parses a single pattern argument into two channels:

| Form           | Scope Channel | Expr Channel |
| -------------- | ------------- | ------------ |
| `"token"`      | `"token"`     | `"*"`        |
| `"scope/"`     | `"scope"`     | `"*"`        |
| `":expr"`      | `"*"`         | `"expr"`     |
| `"scope:expr"` | `"scope"`     | `"expr"`     |

The scope channel is usually a path or namespace filter. The expr channel is usually a value, case, edge, or rendered-text filter. Callers decide what each channel means for their domain.

Matching has two tiers:

- Patterns containing `%` use LIKE-style matching; `%` matches within one segment and `%%` matches across path segments.
- Patterns without `%` use raw regex full-match semantics.

See `lib/pat-spec.md` for the complete grammar and edge cases.

## Structured Rendering

`rope.nu` and `render.nu` separate composition from presentation:

| Surface       | Responsibility                                                                       |
| ------------- | ------------------------------------------------------------------------------------ |
| Domain script | Creates domain records and decides what facts should be visible.                     |
| `rope.nu`     | Converts records or logical trees into rope nodes with fields, children, and layout. |
| `render.nu`   | Walks the rope and emits `rich`, `utf8`, `plain`, `text`, or `json`.                 |
| `rstr.nu`     | Carries region tags such as `h1`, `ok`, `error`, or `muted` without emitting ANSI.   |
| `tui.nu`      | Applies terminal capabilities and cursor mechanics.                                  |

`render.nu` does not invent domain text. Separators, headings, labels, and field order come from the composer. The renderer adds only format-specific structure such as borders, padding, JSON punctuation, and tree traversal joins.

See `lib/render-spec.md` for the rope contract and renderer rules.

## Tool Purposes

### `fd`

`fd` is a repo-local path finder. It walks from the current directory, matches path or basename through `pat.nu`, and renders the result through the rope/render pipeline.

```sh
fd args
fd 'lib/%%'
fd '%test%' -t tree
fd README -f json
```

The `expr` channel is reserved for future content grep. Current filters should use the path/name scope channel.

### `show`

`show` is a development aid for renderer behavior. It exercises static render formats, streaming display, and folder-to-rope projections.

```sh
show render
show stream
show folder nu-lib/lib --type md-table --format text
```

Use it when changing render, rope, stream, rstr, style, or TUI behavior and you need a quick visual check.

### `ntst`

`ntst` discovers Nu test files matching `**/test_*.nu`, runs them as subprocesses, and aggregates structured results. Each test file owns its imports and exposes a runner-compatible `main`.

```sh
ntst
ntst run 'lib/tests/%%'
ntst -v
ntst -f json
ntst lf
```

The runner uses `pool.nu` for bounded parallelism, `stream.nu` for live progress, and `test.nu` for case execution inside each test file.

### `cg`

`cg` analyzes TypeScript source trees with ast-grep and emits function-level call edges.

```sh
cg path/to/src
cg path/to/src someFunction
cg path/to/src -f json
```

Use `tools/cg/README.md` for namespace rules, filter forms, output shape, and current limitations.

## Module Reference

### `pat.nu` — Pattern-Spec Parser

**Import:** `use ./lib/pat.nu *`

Pure — no filesystem access.

Pat-spec is a compact single-argument filter syntax with two named channels. The first `:` separates scope from expr; bare tokens (no `:`) go to the scope channel.

| Form | `scope` | `expr` |
|------|---------|--------|
| `"token"` | `"token"` | `"*"` |
| `"scope/"` | `"scope"` (trailing delimiter stripped) | `"*"` |
| `":expr"` | `"*"` | `"expr"` |
| `"scope:expr"` | `"scope"` | `"expr"` |

`"*"` in either channel means "match all". Scope matching supports two tiers: LIKE tier (pattern contains `%`, where `%` matches within-segment and `%%` spans segments) and Regex tier (no `%`, treated as a raw full-match regex).

A pat record has four fields:

| Field | Default | Description |
|-------|---------|-------------|
| `scope` | — | Scope channel pattern |
| `scope_delim` | `"/"` | Delimiter for scope path segmentation |
| `expr` | — | Expr channel pattern (`"*"` = match all) |
| `expr_delim` | `null` | Delimiter for expr segmentation; `null` = single-segment mode |

| Function | Signature | Description |
|----------|-----------|-------------|
| `pat-config` | `--scope-delim --expr-delim` | Build a config record for `pat-parse` |
| `pat-parse` | `pat: string, cfg?: record` | Parse a pat-spec string into a pat record; `cfg` supplies custom delimiters |
| `pat-matches-scope` | `pat: record, key: string` | True if `key` matches scope; `"*"` always matches |
| `pat-matches-expr` | `pat: record, value: string` | True if `value` matches expr; `"*"` always matches |

**Usage:**
```nu
use ./lib/pat.nu *

let pat = pat-parse "todos:jwt"           # → {scope: "todos", scope_delim: "/", expr: "jwt", expr_delim: null}
pat-matches-scope $pat "todos"            # → true
pat-matches-expr  $pat "jwt token"        # → true

# LIKE tier: % matches within-segment characters (excludes delimiter)
let p2 = pat-parse "projects/%done%"
pat-matches-scope $p2 "projects/abc-done-xyz"  # → true

# Custom delimiter for dot-separated namespaces
let p3 = pat-parse "net.ipv4.tcp%" (pat-config --scope-delim ".")
```

---

### `args.nu` — Argument Processing

**Import:** `use ./lib/args.nu *`

| Function | Signature | Description |
|----------|-----------|-------------|
| `global-dto` | `spec parsed_globals` | Normalize Nu-parsed global flags using the spec; applies defaults; bool flags → false when absent |
| `split-chain` | `argv separator?="!"` | Split argv on separator into per-command segments; returns `list<list<string>>` |
| `parse-segment` | `spec segment` | Parse one `[cmd, ...tokens]` segment; returns `{command, flags, args}`; pure — no print/exit |
| `parse-chain` | `spec argv separator?="!"` | Compose `split-chain` + `parse-segment`; returns `list<record>`; empty argv → `[]` |
| `dispatch` | `cmd handlers args?=[]` | Route a command string to a closure in a handler record |
| `usage` | `spec` | Format a usage string from a command spec record |
| `cmd-usage` | `spec name` | Single-line usage string for one named command |
| `cmd-dto` | `spec name args global` | *(deprecated — no callers; will be removed)* Validate and normalize a parsed subcommand |

**Recommended entry point pattern (`parse-chain`):**

```nu
use ./lib/args.nu

def my-spec [] {
  {
    name: "tool.nu"
    description: "What it does"
    default_command: "run"
    global_flags: [
      {name: format,  short: f, default: "rich", description: "Output format"}
      {name: verbose, short: v, bool: true,       description: "Extra columns"}
    ]
    commands: [
      {
        name: run
        args: ["pattern?"]
        description: "Run something"
        flags: [
          {name: glob, short: g, default: "**/test_*.nu", description: "Discovery glob"}
        ]
      }
      {name: ls, args: [], description: "List things"}
    ]
  }
}

def --wrapped main [...rest: string] {
  run-tool $rest
}
```

`--wrapped` is required so Nu does not intercept `--format`, `--verbose`, or any other global flag before `$rest` captures the full token stream. `args parse-global` and `args strip-global` handle flag extraction from the raw list. Without `--wrapped`, Nu's signature parser silently drops global flags before `run-tool` sees them.

> **Test-file mains are exempt.** Test files declare their own specific flags (e.g. `--filter`, `--tag`, `--format`, `--list`) explicitly on `def main` and do not delegate to args.nu. They must NOT use `--wrapped`.

**Spec shape:**
```nu
{
  name:            string
  description:     string
  default_command: string          # resolved when argv is empty
  global_flags: [
    {name: string, short?: string, bool?: bool, default?: any, description: string}
  ]
  commands: [
    {
      name:        string
      description: string
      args?:       list<string>    # trailing ? = optional, e.g. "path?"
      flags?: [
        {name: string, short?: string, bool?: bool, default?: any, description: string}
      ]
    }
  ]
}
```

**`parse-segment` contract:**
- First token must be a valid command name — unknown name → `error make`
- `--name value` / `-s value` for value flags; `--bool-flag` / `-b` for switches
- Unknown flag → `error make`; flag missing its value → `error make`
- Required positional absent → `error make`; optional absent → `null`
- `--flag=value` inline form → `error make`; combined short flags are not generally accepted
- Bool flags default to `false`; value flags apply `default` from spec or `null`

**Counted short flags:**
- Counted short flags are opt-in parser behavior. A repeated short token is counted only when the command flag spec explicitly enables that contract.
- `-FF` is the counted short flag case for command-local force level `2`; it is not a general combined-short form.
- `cat -F` and `cat -FF` are command-local force flags because they appear after the `cat` command token. `cat -F` and `cat --force` both set force level `1`.
- The global `-f <fmt>` remains available after a command token when the command does not claim lowercase `f`; for example, `cat -f json` selects JSON output format rather than command-local force.

---

### `render.nu` — Structured Output Renderer

**Import:** `use ./lib/render.nu`  <- namespace import; call as `render walk`.

Owns all stdout for complete formatted rope data. Callers pass renderer-ready structures and let `render walk` emit the selected byte stream. Depends on `tui.nu` for terminal measurements and visual formatting.

**Surviving surface:**

| Function | Signature | Description |
|----------|-----------|-------------|
| `render walk` | `cfg?={format:"rich"}` | Pipe a rope-composer output tree; renders the tree; formats: `rich` \| `utf8` \| `plain` \| `text` \| `json` |

**Removed:** `render flat`, `render tree`, and `render strip-markup` are no longer exported. Strip-markup functionality moved to `rstr.nu` as `rstr to-ansi`.

**`render walk`** accepts a rope-composer output tree as input. See `render-spec.md` for the full node contract: node shape, field-node vocabulary, qualifier rules, `_flat` directive, and format output rules.

**Config key for `render walk`:**

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `format` | string | `"rich"` | `rich` \| `utf8` \| `plain` \| `text` \| `json` |

#### Format capability axes

Five formats, three capability axes:

| format | byte-stream | color | borders | bounded |
|--------|-------------|:-----:|:-------:|:-------:|
| `rich`   | visual      | yes   | yes     | yes     |
| `utf8`   | visual      | no    | yes     | yes     |
| `plain`  | visual      | no    | no      | yes     |
| `text`   | text        | no    | no      | no      |
| `json`   | (k-driven)  | —     | —       | —       |

`rich`, `utf8`, and `plain` share the **visual byte stream** — they render the same field-nodes (those with `q` absent or `q == "visual"`). They differ only on color (ANSI escape sequences via rstr region tags) and borders (UTF-8 box-drawing in flat mode). `text` and `json` are unbounded pipe formats: `text` uses the text byte stream; `json` is key-driven (only kv field-nodes with `k` present appear, regardless of `q`). `text` and `json` output is byte-identical regardless of TTY state.

#### Field-node forms

A **field-node** is one unit of content in a node's `_fields`. Exactly two forms:

- **leaf** — `{v}` or `{v, q}`: anonymous; no key.
- **kv** — `{k, v}` or `{k, v, q}`: keyed; the `k` key must be a string.

The qualifier `q`, when present, must be one of `"visual"` or `"text"`. Absent means visible in both byte streams. Forbidden `q` values: `"rich"`, `"data"`, `"none"`, `"json"`, and any list — `render walk` errors on these.

| q value | Visible in |
|---------|-----------|
| absent | all formats |
| `"visual"` | visual formats (`rich`, `utf8`, `plain`) and json (kv only) |
| `"text"` | text format and json (kv only) |

A field-node `v` may be a scalar, an `rstr`, or a format-value record: `{_fmt: {rich?, utf8?, plain?, visual?, text?, json?}}`. Render chooses the exact format branch first, then falls back to the byte-stream branch (`visual` or `text`), then `json` where applicable. Use format-values when the same semantic value needs different user-facing bytes per format without changing field order, qualifiers, or stored domain data.

#### Three-primitive renderer

`render walk` uses three orthogonal primitives — no form-decode table:

1. **Walk `_fields` gated by q** — for each field-node in `_fields`, apply the format's visibility predicate (`visible_in_visual`, `visible_in_text`, or `emits_to_json`) and render the visible `v` values in declaration order.
2. **Accumulate keyed `{k, v}` for json** — kv field-nodes with `k` present are collected into a JSON object per node; anonymous leaf field-nodes never appear in json.
3. **Descend `_children`** — after a node's `_fields` are emitted, recurse into each child in `_children` in order.

The renderer injects nothing between the field-nodes of a single node — all separators, connectors, heading prefixes, and intra-node newlines are composer-supplied field-nodes.

#### TTY-access discipline

`tui-is-tty` and `tui-columns` are called **only inside `render-env`** at the top of `render walk`. No helper below `render-env` may read tui primitives. Flat-mode column emitters, tree-mode emitters, and all other helpers receive terminal state as parameters passed down from `render-env`.

`tui-columns` returns `int | null`. `null` means the terminal width is unknown; visual-class formats with `cols == null` fall back to natural widths (Case 1 — no-op). There is no hardcoded integer fallback.

#### Flat-mode column width

The column width algorithm lives in `col-budgets`, called only by the visual-class flat-mode emitter. `render-env` remains the only TTY probe site; the emitter receives `cols` as a parameter.

For `rich`, `utf8`, and `plain`, flat mode resolves each visible cell through the exact selected `_fmt` branch before budgeting. It then builds measured row templates from fixed fragments and column slots for the actual output shape. Width checks measure display cells and exclude ANSI bytes; they do not use hard-coded rich/utf8/plain formulas.

- **Case 1 — no-op:** every measured row template fits at natural widths, or `term_cols` is `null`. All columns keep natural width.
- **Case 2 — elastic shrink:** measured templates exceed the terminal width; elastic columns (`weight > 0`) share the remaining budget proportionally while protected columns keep natural width.
- **Case 3 — protected shrink:** elastic shrink still does not fit. All active columns shrink proportionally, floored at `min_w`.
- **Case 4 — whole-column sacrifice:** shrinking still does not fit. The renderer sacrifices columns by ascending weight, narrowest-first ties, protected columns last, appends a right-edge `…` sentinel column, and remeasures the same templates until they fit or no useful sacrifice remains.

Surviving columns keep their existing clipping and justification policy. The sentinel column renders header `…` and blank data cells.


**Walk usage:**
```nu
use ./lib/render.nu

$rope | render walk {format: "rich"}
$rope | render walk {format: "utf8"}
$rope | render walk {format: "plain"}
$rope | render walk {format: "text"}
$rope | render walk {format: "json"}
```

---

### `stream.nu` — Live Streaming Display

**Import:** `use ./lib/stream.nu *`  <- import exported stream commands; call as `stream open`, `stream step`, and `stream close`.

Owns generic live terminal streaming state. Channel declarations describe renderer mechanics (`label`, `tail`, `flat`, `tree`, `log`); domain tools decide what events mean in their own model.

| Function | Signature | Description |
|----------|-----------|-------------|
| `stream open` | `cfg channels` | Initialize streaming state from output config and channel declarations; appends a default `log` channel when absent. |
| `stream step` | `state event` | Route one event to a declared channel and return updated state; requires `event._channel`. |
| `stream close` | `state` | Close a stream opened by `stream open`; flush generic tail/table content and logs according to format and TTY state. |
| `stream finalize` | `cfg acc` | Legacy close path for old accumulator state; new callers should use `stream close`. |

**Streaming usage:**
```nu
use ./lib/stream.nu *

let channels = [
  {name: "output", kind: "tail", height: 8}
  {name: "telemetry", kind: "label"}
]
let state = stream open {format: "rich"} $channels
let state = $events | reduce --fold $state {|ev state| stream step $state $ev}
stream close $state
```

Tail and table fill behavior is generic stream behavior. Domain-specific footer text, failure detail, summary labels, and suppression policy belong to the tool using the stream, such as `ntst`, unless `stream.nu` grows an explicit generic primitive for that behavior.

---

### `tui.nu` — Terminal Mechanics

**Import:** `use ./lib/tui.nu *`

Sole owner of all ANSI escape codes, cursor movement, and color application (P-011). Presentation modules pass panel specs as plain strings or styled segment lists — never escape codes.

| Function | Signature | Description |
|----------|-----------|-------------|
| `tui-init` | `→ record` | Return initial opaque tui state `{prev: 0}` |
| `tui-draw` | `state panels` | Erase previous block, draw all panels top-to-bottom, return new state |
| `tui-close` | `state lines` | Exit panel mode: erase block, print lines linearly into scrollback |

**Panel record shape:**
```nu
{
  name:    string      # identity key
  content: record      # {type: "lines",  data: list<string>}
                       # OR {type: "styled", data: list<list<{text: string, style?: string}>>}
  height:  int | null  # null = content-driven; int = minimum height (pads with blanks)
}
```

**Tui state is opaque** — callers store it in `acc.tui` and pass it to `tui-draw`/`tui-close`; they never read or construct its contents directly (P-012).

---

### `log.nu` — Diagnostic Logging

**Import:** `use ./lib/log.nu *`

Writes to stderr only; stdout is never touched. Level controlled by `$env.NU_LOG_LEVEL` (default: `"warn"`).

| Function | Signature | Description |
|----------|-----------|-------------|
| `log error` | `msg: string` | Always emitted (level 1) |
| `log warn` | `msg: string` | Emitted at warn+ (level 2, default) |
| `log info` | `msg: string` | Emitted at info+ (level 3) |
| `log debug` | `msg: string` | Emitted at debug+ (level 4) |
| `log trace` | `msg: string` | Emitted at trace (level 5) |

**Usage:**
```nu
use ./lib/log.nu *

if ($debug | is-not-empty) { $env.NU_LOG_LEVEL = $debug }
log debug $"resolved glob: ($glob)"
log warn  $"skipping empty file: ($f)"
```

---

### `flock.nu` — Advisory File Locking

**Import:** `use ./lib/flock.nu *`

Atomic mutex via `mkdir` on a `.lock/` directory beside the target file. Stale locks (from killed processes) are reclaimed automatically via PID liveness check.

| Function | Signature | Description |
|----------|-----------|-------------|
| `with-lock` | `file timeout_ms f` | Run closure `f` under an exclusive lock; throws on timeout; releases on exception |

**Usage:**
```nu
use ./lib/flock.nu *

with-lock $store_file 5000 {
  let data = (open --raw $store_file | from json)
  $data | upsert key "value" | to json | save --force $store_file
}
```

---

### `mermaid.nu` — Diagram Builders

**Import:** `use ./lib/mermaid.nu *`

Pure — builds diagram record trees and serializes them to Mermaid syntax strings. No print, no ANSI, no external calls.

| Function | Signature | Description |
|----------|-----------|-------------|
| `node` | `label children?=[]` | Create a diagram node `{label, children}` |
| `mindmap` | `root` | Wrap a root node into a mindmap diagram record |
| `flatten` | `→ string` | Serialize a diagram record to a Mermaid fenced-block string |

**Usage:**
```nu
use ./lib/mermaid.nu *

let diag = (mindmap (node "root" [
  (node "alpha" [(node "a1") (node "a2")])
  (node "beta")
]))
$"```mermaid\n($diag | flatten)\n```"
```

---

### `md.nu` — Markdown Processing

**Import:** `use ./lib/md.nu *`

All functions are **pure** — they accept a raw markdown string via `$in`.

| Function | Input | Output | Description |
|----------|-------|--------|-------------|
| `headings` | `string` | `table[{line, level, title, slug}]` | All headings with slugs |
| `frontmatter` | `string` | `record` | YAML frontmatter parsed to record; `{}` if absent |
| `sections` | `string` | `table[{heading, level, line, content}]` | Document split by heading, body trimmed |
| `code-blocks` | `string` | `table[{lang, line, code}]` | Fenced code blocks with language tag |
| `links` | `string` | `table[{text, url, line}]` | All `[text](url)` links |
| `text-nodes` | `list` (from `from md`) | `list<string>` | Flatten `from md` AST to text values |

**Typical pipeline:**
```nu
open --raw doc.md | md headings
open --raw doc.md | md sections | where level == 2
open --raw doc.md | md code-blocks | where lang == "nu"
open --raw doc.md | md frontmatter | get status
```

---

### `fs.nu` — Filesystem & Search

**Import:** `use ./lib/fs.nu *`

External deps: `rg` (ripgrep), `fd` — expected on PATH.

| Function | IO Tier | Signature | Description |
|----------|---------|-----------|-------------|
| `glob-files` | Query | `pattern --exclude?` | Files matching a glob; structured metadata |
| `find` | Query | `pattern dir --type --ext --hidden` | fd-backed name search |
| `grep` | Query | `pattern ...paths --glob --case-insensitive --fixed` | rg-backed content search |
| `edit-lines` | **Mutating** | `file transform` | Apply closure to each line, save in-place |
| `edit-section` | **Mutating** | `file heading content` | Replace a markdown section body in-place |

**grep output:** `table[{file, line, text, matches}]` — structured rg matches; exit 1 (no matches) returns `[]` cleanly.

**edit-section rules:** matches on exact heading title; replaces body up to the next heading at equal or higher level; preserves trailing newline convention.

---

### `rstr.nu` — Region-Marked String Library

**Import:** `use ./lib/rstr.nu *`

Pure — all functions operate on `rstr` values via pipeline. No filesystem access, no print, no ANSI codes. ANSI rendering of region names is the responsibility of the caller; see `render.nu` for styled output.

**Types:**

```
rstr       = list<rstr-node>
rstr-node  = {t: string}                      # text leaf
           | {r: string, c: list<rstr-node>}  # region node
```

**Serialized form:** `«name»content«/»` (U+00AB / U+00BB). Literal `«` in text leaves is escaped as `««`.

| Function | Signature | Description |
|----------|-----------|-------------|
| `rstr of` | `string →` | Escape a piped string and wrap it as a single text-leaf rstr |
| `rstr str` | `string →` | Parse an HTML-like string with `<tag>content</tag>` syntax into rstr regions; for constructing rstrs from inline-tagged strings |
| `rstr tag` | `name: string` | Wrap the input rstr in a named region node |
| `rstr concat` | `list<rstr> →` | Flatten a list of rstrs into one rstr |
| `rstr cat` | `b: list` | Append rstr `b` to the input rstr |
| `rstr len` | `→ int` | Total display width — counts terminal columns via `rstr display-len` (not byte length) |
| `rstr display-len` | `string →` | Pipe a plain string; returns display width in terminal columns, accounting for wide (CJK/multi-column) characters; signature: `string -> int` |
| `rstr plain` | `→ string` | Strip all region markers; return joined plain text |
| `rstr trim` | `width: int` | Truncate to display width; appends a `…` text node at the cut point |
| `rstr fill` | `width: int, align?: string` | Pad to `width` with spaces; `align` is `"left"` (default), `"right"`, or `"center"` |
| `rstr to-str` | `→ string` | Serialize the rstr to `«name»…«/»` wire format |
| `rstr from-str` | `string →` | Parse a `«name»…«/»` wire-format string into an rstr |
| `rstr regions` | `→ list<string>` | Return all region names depth-first |
| `rstr map-text` | `f: closure` | Apply closure `{|s| ...}` to every text-leaf string |

**Constructing a nested rstr:**
```nu
use ./lib/rstr.nu *

# "hello" wrapped in "dim", then concatenated with a plain " world"
let greeting = ("hello" | rstr of | rstr tag "dim") | rstr cat (" world" | rstr of)
# → [{r: "dim", c: [{t: "hello"}]}, {t: " world"}]
```

**`rstr str` — inline-tagged construction:**
```nu
use ./lib/rstr.nu *

# Parse HTML-like tags into rstr regions directly
"<h1>title</h1>" | rstr str
# → [{r: "h1", c: [{t: "title"}]}]

"<bold>hello</bold> world" | rstr str
# → [{r: "bold", c: [{t: "hello"}]}, {t: " world"}]
```

**`to-str` / `from-str` round-trip:**
```nu
use ./lib/rstr.nu *

let original = ("«x»hi«/»" | rstr from-str)
let wire     = ($original | rstr to-str)   # → "«x»hi«/»"
let restored = ($wire | rstr from-str)     # equal to $original
```

**`len` / `fill` / `trim`:**
```nu
use ./lib/rstr.nu *

# len counts display width (terminal columns), not bytes — wide chars count as 2
"hello" | rstr of | rstr tag "dim" | rstr len   # → 5

# display-len measures a plain string's terminal column width
"hello" | rstr display-len   # → 5

# fill pads to width; default align is left
"hi" | rstr of | rstr fill 5                    # → [{t: "hi"}, {t: "   "}]
"hi" | rstr of | rstr fill 5 "right"            # → [{t: "   "}, {t: "hi"}]
"hi" | rstr of | rstr fill 6 "center"           # → [{t: "  "}, {t: "hi"}, {t: "  "}]

# trim truncates to display width and appends "…"
"hello world" | rstr of | rstr trim 5           # → [{t: "hell"}, {t: "…"}]
```

**ANSI rendering note:** `rstr.nu` contains no ANSI escape codes. To render region names as terminal colors or styles, pass the rstr to a caller that maps region names to styled segments and delegates to `render.nu` / `tui.nu` for actual escape-code emission (see P-011).

---

### `rope.nu` — Rope Composers

**Import:** `use ./lib/rope.nu *`

Pure — no filesystem access, no print, no ANSI escape codes. See `lib/render-spec.md` as the authoritative specification.

**IO Contract tier:** Pure.

**Composers:**

| Composer | Input | Output mode | Description |
|----------|-------|-------------|-------------|
| `rope table` | `$rows \| rope table --columns(-c): record = {}` | flat | Flat table rope from a list of records |
| `rope tree` | `$logical \| rope tree` | tree | Tree rope from a logical-tree record |
| `rope md` | `$logical \| rope md` | tree | Markdown-outline rope from a logical-tree record |
| `rope md-table` | `$logical \| rope md-table --columns(-c): record = {}` | tree | Heading+table rope (heading row per branch, table of leaf columns) |

All four composers produce a rope for use with `render walk {format: "rich" | "utf8" | "plain" | "text" | "json"}`.

`rope table` emits `_flat: {}` at root so `render walk` produces a flat JSON array and two-pass column-aligned output. `rope tree`, `rope md`, and `rope md-table` produce tree-mode ropes.

#### Logical-tree input shape

| Key | Required | Description |
|-----|----------|-------------|
| `label` | yes | Record with exactly one key-value pair; key is a naming convention, value is a plain string, pre-built rstr, or format-value |
| `fields?` | no | Record of named caller-supplied fields; each value is a plain string, pre-built rstr, or format-value |
| `children?` | no | `list<logical-node>` — nested subtree |

`rope md` accepts either a single logical-tree record or a list of logical-tree records at the top level.

#### Label styling contract

| Label Value        | Composer Behavior                                                                                                             | Use When                                                |
| ------------------ | ----------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------- |
| Plain string       | `rope tree`, `rope md`, and heading nodes in `rope md-table` wrap it as an `rstr` tagged `h1` through `h6` by depth.          | The label should inherit composer-defined heading style. |
| Pre-built `rstr`   | The value passes through byte-identical; no automatic `h1` through `h6` tag is added.                                         | The caller is intentionally overriding label styling.   |
| Format-value       | The record passes through unchanged; render selects its exact format or stream branch before rstr coercion.                    | The caller needs different bytes for `rich`, `utf8`, `plain`, `text`, or `json`. |

Do not pre-tag routine labels with ad hoc regions such as `name` when using `rope md` or `rope md-table`; that makes the label caller-owned and bypasses the depth heading styles.

#### What rope composers do NOT mint

`rope tree` and `rope md` do **not** mint `id` or `parent_id`. Heading depth in `rope md` encodes parent relationships structurally. Caller-supplied identity (when desired) arrives through the logical-node `fields` record and is read from input rows by `rope table`.

#### What `rope md` preserves (rstr passthrough)

Pre-built rstr values and format-values in `label` or `fields` are passed through byte-identical into the emitted `_fields`. This is the customization path: callers supply rstr styling or per-format value branches and `rope md` does not override them.

#### Default heading style for plain-string label values

When the `label` value is a plain string, `rope md` wraps it as:

```nu
$v | rstr of | rstr tag $"h(($depth | math min 6))"
```

This yields `h1` at depth 1 through `h6` at depth 6 and beyond. Heading styles are defined in `styles.nu`:

| Style | Atoms              |
| ----- | ------------------ |
| `h1`  | `[bold ul purple]` |
| `h2`  | `[bold ul cyan]`   |
| `h3`  | `[bold yellow]`    |
| `h4`  | `[bold]`           |
| `h5`  | `[ul]`             |
| `h6`  | `[italic]`         |

For `rope md-table`, the same heading style rule applies to branch heading nodes. Leaf children are grouped into a table, so those leaf labels render as table cells rather than Markdown headings.

#### Per-node `_fields` declaration order (rope md)

1. Section break (non-root) — `{v: "\n", q: "visual"}` and `{v: "\n", q: "text"}` leaves
2. Heading prefix — `{v: "# "…"###### "}` leaf (`q` absent; depth clamped at 6)
3. Name stem — `{k: "name", v: <label>}` kv field-node (rstr-tagged `h1`..`h6`)
4. Post-heading newline — `{v: "\n", q: "visual"}` (when bullets follow)
5. Per `fields` entry — visual bullet leaf `{v: "\n- <key>: ", q: "visual"}`, text bullet leaf `{v: "\n- <key>=", q: "text"}`, then the kv `{k, v}`

Valid `q` values on any field-node: `"visual"`, `"text"`, or absent. `q: "rich"` and `q: "data"` are forbidden — `render walk` errors on them.

#### Pipeline pattern

```nu
use ./lib/rope.nu *
use ./lib/render.nu

# flat table
$rows    | rope table | render walk {format: "rich"}
$rows    | rope table | render walk {format: "json"}

# tree / markdown outline
$logical | rope tree  | render walk {format: "rich"}
$logical | rope md    | render walk {format: "text"}

# heading + table (grouped output)
$logical | rope md-table | render walk {format: "rich"}
```

#### Usage snippets

**Workflow branch fold-to-spec fragment:**
```nu
use ./lib/rope.nu *
use ./lib/render.nu

# Build a logical tree from branch records
let logical = ($projects | each {|p|
  {
    label: {name: $p.name}
    fields: {status: $p.status, path: $p.path}
    children: ($p.tasks | each {|t| {label: {name: $t.name} fields: {done: $t.done}}})
  }
})
$logical | rope md | render walk {format: "rich"}
```

**`show.nu` folder-to-spec fragment:**
```nu
use ./lib/rope.nu *
use ./lib/render.nu

# Build a logical tree from a folder listing
def folder-tree [root: string] {
  {
    label: {name: $root}
    children: (ls $root | each {|e| {label: {name: $e.name} fields: {type: $e.type, size: ($e.size | into string)}}})
  }
}
folder-tree "src" | rope md | render walk {format: "text"}
```

---

### `styles.nu` — Style Atom and Aggregate Table

**Import:** `use ./lib/styles.nu *`

Pure — no filesystem access, no print, no ANSI escape codes emitted. Returns plain string names; callers pass those names to `tui.nu` / `render.nu` for actual escape-code application.

**Atoms** (primitive ANSI attribute names):

| Name | ANSI effect |
|------|-------------|
| `bold` | Bold / bright weight |
| `dim` | Dimmed / faint weight |
| `ul` | Underline |
| `italic` | Italic |
| `red` | Foreground red |
| `green` | Foreground green |
| `yellow` | Foreground yellow |
| `blue` | Foreground blue |
| `magenta` | Foreground magenta |
| `cyan` | Foreground cyan |
| `bg-red` | Background red |
| `bg-green` | Background green |
| `bg-yellow` | Background yellow |
| `bg-blue` | Background blue |
| `bg-magenta` | Background magenta |
| `bg-cyan` | Background cyan |

**Aggregates** (named composites of atoms):

| Name | Atoms | Description |
|------|-------|-------------|
| `h1` | `[bold ul]` | Top-level heading |
| `h2` | `[bold]` | Second-level heading |
| `h3` | `[ul]` | Third-level heading |
| `error` | `[bold red]` | Error message |
| `warn` | `[bold yellow]` | Warning message |
| `ok` | `[bold green]` | Success / OK state |
| `muted` | `[dim]` | De-emphasised text |
| `key` | `[bold cyan]` | Key / label in a key-value pair |
| `val` | `[dim]` | Value in a key-value pair |

**API:**

| Function | Signature | Description |
|----------|-----------|-------------|
| `styles get` | `name: string → list<string>` | Atom list for the style; single-element list for atoms; error if name is unknown |
| `styles has` | `name: string → bool` | True if name is a known atom or aggregate |
| `styles table` | `→ table<name atoms kind>` | Full style table; `kind` is `"atom"` or `"aggregate"` |

**Usage:**
```nu
use ./lib/styles.nu *

# Resolve a named style to its atom list
styles get "h1"     # → [bold ul]
styles get "bold"   # → [bold]
styles get "error"  # → [bold red]

# Check membership without throwing
styles has "warn"   # → true
styles has "nope"   # → false

# Enumerate all styles
styles table | where kind == "aggregate"
styles table | select name kind
```

---

### `test.nu` — Unit Test Harness

**Import:** `use ./lib/test.nu *`

All harness functions follow the isolate-IO discipline. The IUT is a closure in each test record; the test file owns all IO.

**Test record shape:**
```nu
{
  name:     string          # required — kebab-case slug, e.g. "mod-01-what-it-checks"
  iut:      closure         # required — {|input| ...} wraps the function under test
  input:    any             # required — DTO passed to iut
  expected: any             # required — expected output DTO
  tags?:    list<string>    # optional — for --tag selection
  assert?:  closure         # optional — {|actual expected| bool}; overrides assert-eq
  skip?:    bool            # optional
}
```

| Function | IO Tier | Signature | Description |
|----------|---------|-----------|-------------|
| `assert-eq` | Pure | `actual expected` | Deep structural equality |
| `assert-contains` | Pure | `actual expected` | Partial match; every key in `expected` exists in `actual` with equal value; recurses into nested records |
| `list-cases` | Pure | `→ list` | Project cases to `{name, tags, skip}` metadata; used by `--list` |
| `run` | Pure | `--filter --tag` | Filter and run `$in` case list; yields interleaved `running`/result records |
| `summarize` | Pure | `→ record` | Aggregate `$in` result list into pass/fail/skip/error counts |
| `report` | IO | `--format --file` | Print results + summary from `$in`; exits non-zero on any fail or error |

---

### `pool.nu` — Bounded Parallel Job Pool

**Import:** `use ./lib/pool.nu *`

Launches up to N concurrent `nu` subprocesses via Nu's `job spawn` / `job send` / `job recv` message-passing. Workers send completion payloads to the main thread (ID 0); the main thread refills slots as they free. Child faults (non-zero exit) are captured by the parse closure as error events — they never panic `pool-run`.

| Function | Signature | Description |
|----------|-----------|-------------|
| `pool-run` | `files extra_args step --jobs(-j): int=0 --init: record={} --parse: closure → record` | Run files in parallel; call `step(acc, ev)` for each parsed event in completion order; return final acc |

**Parameters:**

| Parameter | Type | Description |
|-----------|------|-------------|
| `files` | `list<string>` | Nu scripts to execute; each invoked as `nu $f ...$extra_args` |
| `extra_args` | `list<string>` | Forwarded verbatim to every worker |
| `step` | `closure(acc, event) → acc` | Called per event in completion order |
| `--jobs(-j)` | `int` | Max concurrent workers; `0` resolves to `sys cpu \| length` at call time |
| `--init` | `record` | Initial accumulator; defaults to `{}` |
| `--parse` | `closure(file, out) → list<event>` | Parses one worker's `complete` result into event records |

**Interrupt handling:** when `job recv` is interrupted (Ctrl-C or SIGTERM from wrapper), the catch block kills all active job IDs with `job kill` and returns the partial accumulator. Wrap `pool-run` in `try { ... } catch {|_| $in}` when a clean finalize step is needed after interruption.

**Observing active workers:**

`Ctrl-Z` (SIGTSTP) freezes the entire foreground process group — the bash wrapper, the main `nu` process, and all child `nu $file` processes pause together. Then inspect:

```sh
pstree -p $(pgrep -f ntst.nu)   # full tree with PIDs; shows N live test workers
ps --ppid $(pgrep -f ntst.nu)   # direct children only = active worker processes
```

Child processes appear under the main `nu` PID even though they were spawned from `job` threads (Linux assigns ppid from the process, not the spawning thread). Resume with `fg`.

**Usage:**
```nu
use ./lib/pool.nu *

let acc = pool-run $files [] {|acc ev| process-event $cfg $acc $ev}
  --jobs $n
  --init {pass: 0, fail: 0, failures: []}
  --parse {|f out| parse-worker-output $f $out}
```

---

## Writing a Test File

Test files are named `test_<module>.nu`, live anywhere under the project root, and are discovered by `ntst` via glob. Each file defines a `cases []` function and a runner-compatible `def main`.

### Minimal template

```nu
#!/usr/bin/env nu

use ../../lib/test.nu *
use ../../my-module.nu *   # module under test

def cases [] {[

  {
    name: "mod-01-basic-happy-path"
    iut:  {|i| my-fn $i.a $i.b}
    input:    {a: 3, b: 4}
    expected: 7
  }

]}

def main [
  --filter(-f): string = ""
  --tag(-t):    string = ""
  --format:     string = "text"   # text | json | jsonl  (jsonl required by ntst runner)
  --list(-l)                      # emit case metadata as JSON for ntst lf
] {
  if $list { cases | list-cases | to json | print; return }
  cases | run --filter $filter --tag $tag | report --format $format --file $env.CURRENT_FILE
}
```

### Assertion styles

```nu
# 1. Default: deep equality (assert-eq)
{
  name: "slugify-lowercases-and-hyphenates"
  iut:  {|i| slugify $i.s}
  input:    {s: "Hello World"}
  expected: "hello-world"
}

# 2. Partial record match (assert-contains)
#    Passes as long as every key in `expected` appears in `actual` with the same value.
#    Extra keys in `actual` are ignored. Recurses into nested records.
{
  name: "safe-div-zero-shape-(partial-match)"
  iut:  {|i| safe-div $i.a $i.b}
  input:    {a: 1.0, b: 0.0}
  expected: {ok: false}
  assert:   {|actual expected| assert-contains $actual $expected}
}

# 3. Custom assertion closure
{
  name: "result-list-is-non-empty"
  iut:  {|i| discover $i.glob}
  input:    {glob: "**/*.nu"}
  expected: null
  assert:   {|actual _| ($actual | length) > 0}
}

# 4. Error testing — IUT must throw and message must contain a fragment
def expect-err [fn: closure, input: any, fragment: string] {
  try { do $fn $input; false } catch {|e| $e.msg | str contains $fragment}
}

{
  name: "parse-segment-unknown-flag-errors"
  iut:  {|i| expect-err {|s| parse-segment $s ["run" "--bad"]} $i "unknown flag"}
  input:    (my-spec)
  expected: true
}
```

### Tags and skip

```nu
# Tag a case for selective runs:  bin/ntst run --tag smoke
{
  name: "quick-sanity-check"
  tags: [smoke]
  iut:  {|i| 1 + 1}
  input:    null
  expected: 2
}

# Skip a case (counted but not run):
{
  name: "wip-not-implemented-yet"
  skip: true
  iut:  {|i| not-yet-done $i}
  input:    {}
  expected: {}
}
```

### Spec factory for pure-function tests

Closures cannot capture module-level `let` bindings in Nu. Use a `def` so each case can call it via `$i.spec` or inline:

```nu
def my-spec [] {
  {
    name: "tool"
    description: "..."
    global_flags: [
      {name: verbose, short: v, bool: true, description: "verbose"}
    ]
    commands: [
      {name: run, args: ["pattern?"], description: "run", flags: [
        {name: glob, short: g, default: "**/*.nu", description: "glob"}
      ]}
    ]
  }
}

{
  name: "parse-chain-single-command-returns-length-1-list"
  iut:  {|i| parse-chain $i.spec $i.argv | length}
  input:    {spec: (my-spec), argv: ["run"]}
  expected: 1
}
```

### Running tests

```sh
# Directly:
nu path/to/test_my_module.nu                    # all cases
nu path/to/test_my_module.nu --filter "slug-fragment"
nu path/to/test_my_module.nu --tag smoke
nu path/to/test_my_module.nu --list             # case names only

# Via ntst runner (discovers all test_*.nu under the project):
bin/ntst                                  # run all
bin/ntst run 'lib/tests/%%'               # scoped to a subtree
bin/ntst -v                               # verbose (adds # and duration_ms columns)
bin/ntst -f json                          # JSON output
bin/ntst lf                               # list all discovered cases
```

---

## Tests

Unit tests for library modules live in `lib/tests/`.

| File                     | Covers                                                                    |
| ------------------------ | ------------------------------------------------------------------------- |
| `lib/tests/test_args.nu` | `global-dto`, `split-chain`, `parse-segment`, `parse-chain` -- 23 cases. |

Run via the test runner:
```sh
bin/ntst run 'lib/tests/%%'
```
