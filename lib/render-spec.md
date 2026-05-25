# render-spec

`render walk` (the renderer) and the rope composers — `rope table`, `rope tree`, `rope md`, `rope md-table`.

## Overview

The rendering pipeline has two stages:

```
domain data  ──▶  rope composer  ──▶  rope  ──▶  render walk  ──▶  rich | utf8 | plain | text | json
```

Two APIs, two distinct inputs:

- **`render walk`** consumes one **rope** and emits one of five formats. It composes no content — it concatenates the item values a composer produced, joins nodes (in tree mode) with a newline, and inserts only structural scaffolding: JSON punctuation and flat-mode borders, padding, and header row.
- **rope composers** — `rope table`, `rope tree`, `rope md`, `rope md-table` — each consume domain data and produce a **rope**.

The **rope** is the contract between the two: composers produce it, `render walk` consumes it. This spec defines the rope first, then `render walk`, then the composers.

Out of scope: `render flat`, `render tree`, `render stream-*`, `render rstr`, `render strip-markup`, and the `rstr` library API.

## Terms

| Term          | Meaning |
|---------------|---------|
| rope          | A tree of nodes. The single input to `render walk`. |
| node          | One position in a rope. Carries the meta keys `_fields` (optional), `_children` (optional), `_flat` (optional). |
| field-node    | One unit of content in a node's `_fields`. Exactly two forms: leaf or kv. |
| leaf          | A field-node of the form `{v}` or `{v, q}`. No key. |
| kv            | A field-node of the form `{k, v}` or `{k, v, q}`. Has a key. |
| qualifier     | The `q` key on a field-node. When present, q ∈ `{"visual", "text"}`. Absent means visible in both byte streams. |
| fields        | A node's `_fields` — its field-nodes, in declaration order; 0 or more. |
| children      | A node's `_children` — its child nodes, in order; 0 or more. |
| name          | The first kv field-node of a node — its identity. |
| tree node     | A node with no `_flat` in scope (tree mode). |
| meta key      | A `_`-prefixed node key — `_fields`, `_children`, `_flat`. Never appears in output. |
| mode          | How a node renders: tree mode or flat mode, selected by `_flat`. |
| flat scope    | The subtree governed by one `_flat` declaration. `_flat` cascades to it. |
| composer      | A command that builds a rope from domain data — `rope table`, `rope tree`, `rope md`, `rope md-table`. |
| renderer      | `render walk`. Walks a rope and emits a format. |
| rstr          | Region-marked string: `list<rstr-node>`. Produced by `rstr of` / `rstr tag` / `rstr str`. |
| format-value  | Record `{_fmt: {rich?, utf8?, plain?, visual?, text?, json?}}` used as a field-node `v` when one semantic value needs format-specific bytes. |
| DFS           | Depth-first, pre-order traversal — a node's `_fields`, then its `_children`. |
| visual format | `rich`, `utf8`, or `plain`. Uses the visual byte stream; TTY-aware (consults `tui-columns` for flat-mode column budgets). |
| text format   | `text`. Uses the text byte stream; unbounded — no TTY consultation, no clip. |
| json format   | `json`. Key-driven; structural only. |
| visual byte stream | The byte stream for `rich`, `utf8`, and `plain`: field-nodes with `q` absent or `q == "visual"` are visible; field-nodes with `q == "text"` are hidden. |
| text byte stream   | The byte stream for `text`: field-nodes with `q` absent or `q == "text"` are visible; field-nodes with `q == "visual"` are hidden. |

## TTY vs Non-TTY Output Contract

`render walk` is TTY-aware. The single function `render-env` is the only call site that consults `tui-is-tty` and `tui-columns`. Its `cols` field propagates through `col-budgets` and the flat-mode emitters.

| format | TTY | width source | clip behavior |
|--------|-----|--------------|---------------|
| rich   | yes | `tui-columns` | weighted budgets fit to terminal width; clip per column policy |
| rich   | no  | `null` → natural widths | no clip (rich degrades; rich is meaningful only on TTY) |
| utf8   | yes | `tui-columns` | weighted budgets + clip |
| utf8   | no  | `null` → natural widths | no clip |
| plain  | yes | `tui-columns` | weighted budgets + clip |
| plain  | no  | `null` → natural widths | no clip |
| text   | any | `null` (unbounded by spec) | no clip; natural widths |
| json   | any | n/a | n/a (key-driven, no widths) |

When stdout is not a TTY, `tui-is-tty` returns false and `cols` is `null`. `col-budgets` treats `null` as "no bound" and returns natural widths. This is the **documented unbounded path** — not a bug.

Captured stdout (pipes, command substitution, agent tool calls observing program output) is not a TTY. Programs and agents that inspect captured output are seeing the non-TTY path, which differs from what a user observes interactively in a terminal. To reproduce TTY rendering when stdout would otherwise be captured, set `FORCE_TTY=1` (the env var consulted by `tui-is-tty`). Diagnosis of layout behavior from captured stdout without `FORCE_TTY` is diagnosis of the wrong path.

## Width Policy Ownership

Render is the single point of width, clip, multi-line-cell, ellipsis, and column-policy semantics. Tools and other library modules:

- MUST pass cell values verbatim into rope composers. No truncation, no newline normalization, no width-hardcoding outside render.
- MUST NOT add policy keys to `_flat` or column-policy records beyond what render-spec documents (`weight`, `min`, `justify`, `clip`). Render is the only place that interprets policy keys.
- MUST NOT insert glyphs (ellipsis, separators, padding) into cell values. Render owns glyph placement.

If a tool needs a width-related behavior that render does not currently provide, that is a render-spec amendment — proposed, HITL-approved, regression-tested across every existing consumer — never a local tool-side patch. Local patches to width or display behavior in tools or in library modules other than render are contract violations.

## The rope

A **rope** is a tree of **nodes**. `render walk` accepts exactly one rope — its single root node.

### Node

A node is a record carrying only **meta keys**:

```
node = {
  _fields:    list<field-node>    # the node's content; 0 or more field-nodes; declaration order = render order
  _children?: list<node>          # child nodes; absent or empty → leaf node
  _flat?:     record              # column-policy map; its presence selects flat mode
}
```

This shape is recursive: every node, at every depth, carries only these keys. `_fields` is **required** (may be empty); `_children` and `_flat` are optional — an absent `_children` makes the node a leaf node. `_flat` may be declared on any node at any level. `render walk` errors on any other key on a node.

### Field-node

A **field-node** is one unit of content in a node's `_fields`. Exactly two forms:

**leaf** — `{v}` or `{v, q}`: no key; anonymous.

**kv** — `{k, v}` or `{k, v, q}`: has a key; keyed.

Fields:

- `v` — the value. **Required** on every field-node. It may be a native scalar, an rstr, or a format-value record `{_fmt: {rich?, utf8?, plain?, visual?, text?, json?}}`.
- `k` — the field-node's key. Must be a string when present. Present → the field-node is a **kv**; absent → **leaf**.
- `q` — the **qualifier**. Optional. When present, `q` must be one of `"visual"` or `"text"`. Absent means visible in both byte streams.

**Validity rules:**

- `v` is required on every field-node.
- `k` must be a string when present.
- `q` outside `{"visual", "text"}` is invalid — `render walk` errors. Forbidden values include `"rich"`, `"data"`, `"none"`, `"json"`, and any list.
- `{v, q: "visual"}` — leaf visible only in visual formats.
- `{v, q: "text"}` — leaf visible only in text format.
- `{k, v}` — kv visible in all formats including json.
- `{k, v, q: "visual"}` — kv visible in visual formats and json (json is key-driven, not byte-stream-filtered).
- `{k, v, q: "text"}` — kv visible in text format and json.

`_fields` declaration order is render order, identical across all formats. A format renders the subset of field-nodes visible in that format, in declaration order; it never reorders them.

When `v` is a format-value, render selects `_fmt.<format>` first (`rich`, `utf8`, `plain`, `text`, or `json`). If absent, it falls back to `_fmt.visual` for visual formats, `_fmt.text` for text, and `_fmt.json` for JSON where available. Selected scalar values are coerced to rstr for human byte streams; selected rstr values keep their regions; selected JSON values are emitted as JSON values. A format-value changes only the bytes for a value, never field visibility, field order, or node identity.

A node's **name** is its first kv field-node. It is the node's identity — the bare leading token in `text`, the heading in visual formats, the key-bearer in `json`.

### Visibility predicates

`render walk` uses exactly three orthogonal predicates. There is no form-decode table.

```
visible_in_visual(fn)  ≡  q absent  ∨  q == "visual"
visible_in_text(fn)    ≡  q absent  ∨  q == "text"
emits_to_json(fn)      ≡  k present
```

These three predicates are the complete visibility model. Every format decision is derived from them:

- Visual formats (`rich`, `utf8`, `plain`) render field-nodes where `visible_in_visual` is true.
- Text format renders field-nodes where `visible_in_text` is true.
- JSON format renders field-nodes where `emits_to_json` is true.

### How a field-node renders

`render walk` injects nothing between the field-nodes of a node — within a node every format is a verbatim concatenation of its visible field-nodes' `v` values, in declaration order. Every separator, space, `=`, `/`, `#`, connector, heading prefix, and intra-node newline is a **composer-supplied field-node**. The renderer's only inserted bytes are: the single newline that joins consecutive nodes in tree mode, JSON structural punctuation (`{} [] " : ,`), and flat-mode table structure (borders, column padding, header row, alignment whitespace).

A kv field-node therefore contributes:

| Format  | Contribution |
|---------|--------------|
| visual  | its `v` — the name styled as a heading; other kv field-nodes as plain values or column cells. |
| text    | its `v`. The `key=` label is **not** a renderer join — it is a composer-supplied `q: "text"` leaf placed immediately before the kv. |
| json    | `"k": v` — `render walk` assembles the object; the `"…":` punctuation is renderer-supplied JSON structure. |

A composer that wants per-format punctuation around a kv emits it as adjacent leaf field-nodes: a `{v, q: "visual"}` leaf for visual formats, a `{v, q: "text"}` leaf for `text`. This is how a value reads `dir` in visual formats but `type=dir` in `text` — same kv field-node, a `{v: " type=", q: "text"}` leaf beside it.

### `_flat` and modes

Every node renders in one **mode**:

- **tree mode** — no `_flat` in scope.
- **flat mode** — the node carries a `_flat`, or inherits one from an ancestor.

`_flat` is a record mapping a kv field-node's `k` to a **column policy**. Its presence — even `{}` — selects flat mode. `_flat` carries column policies only (`justify`, `weight`, `clip`, `min`). Any other key in `_flat` (`_layout`, `_headers`, `_fill`, `_sep`, `topology`) is forbidden — `render walk` errors.

`_flat` **cascades downward only**: a `_flat` declaration governs the declaring node and all its DFS descendants; it never affects ancestors. A descendant without `_flat` inherits the nearest ancestor's mode. A node that declares its own `_flat` opens **a new flat scope** at that node — whether its parent is in tree mode or flat mode. (A `_flat` rope nested as a child of a tree-mode node is exactly how `rope md-table` works.)

Mode governs all formats: visual formats (bordered or aligned table), `text` (borderless aligned table), and `json` (nested vs flat array).

Each column policy:

| Key       | Type                                        | Required | Description |
|-----------|---------------------------------------------|:--------:|-------------|
| `justify` | `"left"` \| `"right"` \| `"center"`         |   yes    | Alignment within the column budget. |
| `weight`  | int                                         |   yes    | Column protection level. `0` = protected: keeps natural width; exempt from elastic shrink; last to sacrifice. `N > 0` = elastic: participates in shrink and sacrifice. Higher N = larger budget claim = shrinks last, sacrificed last. |
| `clip`    | `"none"` \| `"rhs"` \| `"lhs"` \| `"wrap"` |    no    | Overflow handling within the column budget. `"none"` (default) leaves content unclipped. `"rhs"` ellipsis-trims from the right (keeps the head). `"lhs"` ellipsis-trims from the left (keeps the tail). `"wrap"` soft-wraps the cell across multiple lines. |
| `min`     | int                                         |    no    | Hard floor for column width in characters. When unset, defaults to the column header label length or policy `min` if set. |

Every key of a `_flat` record must name the `k` of a kv field-node in its flat scope; `render walk` errors otherwise. `_flat: {}` is flat mode with default policy.

> `clip: "wrap"` is **specified-but-not-implemented** and renders as `"none"` until implemented. Column sacrifice (Case 4) is implemented by the visual flat-mode row-template budgeting pass.

## render walk

`render walk` is the **renderer**: one rope in, one string out. All human-visible content originates from field-node `v` values that a composer produced; the renderer adds only the structural scaffolding listed in *How a field-node renders*.

### Signature

```nushell
$rope | render walk {format: "rich" | "utf8" | "plain" | "text" | "json"}
```

- **Input** — exactly one rope (one node record). A list, a scalar, or any non-record errors.
- **Argument** — a record with exactly the key `format`. `format` must be one of `"rich"`, `"utf8"`, `"plain"`, `"text"`, `"json"`. Any other value errors. `{format: "ansi"}` is rejected. `{output: {format: ...}}` is rejected.
- **Output** — a string.

### Format properties

| format | byte-stream | color | borders | bounded |
|--------|-------------|:-----:|:-------:|:-------:|
| `rich`   | visual      | yes   | yes     | yes     |
| `utf8`   | visual      | no    | yes     | yes     |
| `plain`  | visual      | no    | no      | yes     |
| `text`   | text        | no    | no      | no      |
| `json`   | (k-driven)  | —     | —       | —       |

- **color: yes** — ANSI escape sequences via rstr region tags.
- **borders: yes** — UTF-8 box-drawing characters in flat mode.
- **bounded: yes** — the format consults `tui-columns` for flat-mode column shrink.
- `text` and `json` never consult `tui-*` primitives. `text` and `json` output is byte-identical regardless of TTY state.
- `rich`, `utf8`, and `plain` share the visual byte stream and differ only on capability axes (color, borders, bounded).

### Centralized TTY access

`tui-is-tty` and `tui-columns` are called **only inside `render-env`** at the top of `render walk`. No helper below `render-env` may call either primitive. This rule applies without exception: flat-mode column emitters, tree-mode emitters, and all other helpers receive terminal state as parameters passed down from `render-env`.

`tui-columns` returns `int | null`. `null` means the terminal width is unknown. Visual-class formats with `cols == null` must fall back to natural widths (Case 1 — no-op). There is no hardcoded integer fallback anywhere.

### Walk

`render walk` traverses the rope depth-first, pre-order: a node's `_fields`, then each child in `_children`. At each node it resolves the mode and emits the node's field-nodes by the rules below.

### Output: visual formats (rich / utf8 / plain)

`visible_in_visual` selects the field-nodes: those with `q` absent or `q == "visual"`. Each visible `v` renders:

- **`rich`** — with ANSI color and style per rstr region tags; native scalars via `into string`.
- **`utf8`** — same as `rich` but rstr renders to plain text (no ANSI escape sequences); UTF-8 borders retained.
- **`plain`** — same as `utf8` but no borders; columns are space-aligned only.

All three formats:

- **Tree mode** — each node's visible field-nodes concatenated verbatim in declaration order; consecutive nodes joined by a single newline.
- **Flat mode** — a header row of the kv columns' keys, two-pass column alignment across the flat scope, value-only and `q: "visual"` leaf field-nodes inline. `rich` and `utf8` use UTF-8 box-drawing borders; `plain` uses space alignment only. All three enforce TTY width via the column width algorithm (Cases 1–3) using the `tui-columns` value from `render-env`.

### Output: text

`visible_in_text` selects the field-nodes: those with `q` absent or `q == "text"`. All columns always render at natural width — no clipping, no sacrifice.

- **Tree mode** — each node's visible field-nodes concatenated verbatim in declaration order; consecutive nodes joined by a single newline. Line shape is composer-determined: `rope tree` bakes no intra-node newlines (one line per node); `rope md` bakes `\n` field-nodes (a multi-line outline per node).
- **Flat mode** — a borderless aligned table: a header row of column keys, a blank line, then data rows. Lines may exceed terminal width. All columns present. No width math; `tui-columns` is never consulted.

### Output: json

`emits_to_json` selects the field-nodes: those with `k` present. Anonymous leaf field-nodes never appear. Shape is governed by `_flat`. All fields always present.

- **Tree form** — tree mode. Each node is a JSON object of its kv field-nodes plus a `children` array of its child objects; `children` is omitted when the node has no children.
- **Flat form** — flat mode. The flat scope serializes as one JSON array — one object per node, DFS pre-order, holding its kv field-nodes. No `children` key.
- A flat-form subtree nested under a tree-form parent contributes its array as one element of the parent's `children`.
- A node with no kv field-nodes produces no object; its children are emitted in its place.
- Native scalar `v` types are preserved; rstr values render to plain text.

### Flat-mode column width algorithm

The column width algorithm lives in exactly one helper, `col-budgets`, called only by the visual-class flat-mode emitter. `text` contains no width math.

Visual flat mode first resolves every visible cell through `v-to-rstr-stream` for the selected exact visual format (`rich`, `utf8`, or `plain`). The emitter then builds row templates for the actual output shape. A row template is made of measured fixed fragments (borders, padding, separators, corners, or spaces) and column slots (header, data, rule, and optional sentinel slots). All measurements use terminal display width and do not count ANSI bytes.

Let:
- `term_cols` = value from `tui-columns` passed down from `render-env` (int or null)
- `nat_w(col)` = natural display width of column `col` after exact format resolution, including the header label and all data cells in that column
- `fixed_w(template)` = measured width of a row template's fixed fragments and per-slot fixed padding for the active columns
- `available(template)` = `term_cols - fixed_w(template)` for the active row-template shape
- `min_w(col)` = `policy.min` if set, else header label display width

**Case 1 — no-op fit:**
Condition: every measured row template fits at natural widths, OR `term_cols` is `null`.
Action: keep all natural widths. No column adjustment occurs.

**Case 2 — elastic shrink:**
Condition: at least one measured row template exceeds `term_cols`, AND at least one elastic column (`weight > 0`) has `nat_w > min_w`.
Protected columns (`weight: 0`) keep `nat_w`. Elastic columns share the remaining template budget proportionally.

```
protected_w    = Σ nat_w(col)  for all cols where weight == 0
elastic_budget = max(available - protected_w, 0)
share(col)     = elastic_budget × weight(col) / Σ weights(elastic cols)
budget(col)    = max(min(nat_w(col), share(col)), min_w(col))
```

Unused budget from elastic columns where `nat_w < share` is redistributed to remaining elastic columns in one extra pass. Case 2 succeeds only when the measured row templates fit with the resulting budgets.

**Case 3 — protected shrink:**
Condition: elastic shrink does not make every measured row template fit.
All active columns shrink proportionally to `nat_w`, floored at `min_w`.

```
budget(col) = max(available × nat_w(col) / total_nat, min_w(col))
```

Case 3 succeeds only when the measured row templates fit with the resulting budgets.

**Case 4 — whole-column sacrifice:**
When shrinking cannot make the active row templates fit, the renderer sacrifices whole columns as generic renderer policy. Sacrifice order is ascending `weight`; ties use narrowest natural width first, then original column order. Protected columns (`weight: 0`) are considered after droppable weighted columns.

Each sacrifice attempt removes the sacrificed columns from the active column-slot set, appends one right-edge sentinel column, remeasures the same fixed-fragment/column-slot templates, and reruns the shrink algorithm. The sentinel header is `…`; sentinel data cells are blank. Remaining columns keep their normal clipping and justification policy. If no useful sacrifice can make the templates fit, the renderer returns the narrowest measured plan it can produce rather than using any format-specific width formula.


### Rejections

`render walk` errors on:

- Input that is not a single record.
- Any node key outside `{_fields, _children, _flat}` — one generic error per category.
- Any field-node with `q` outside `{"visual", "text"}` — one generic error.
- A `_flat` key naming no kv field-node in its flat scope — one generic error.
- A column-policy `justify` outside `{"left", "right", "center"}` — one generic error.

## rope composers

A **composer** builds a rope from domain data. The composer owns all content: every `v`, every connector, every heading prefix, every intra-node separator. `render walk` adds none of it.

Composers must not fabricate domain data: `rope tree` and `rope md` do not mint `id` or `parent_id`. `rope table` reads them from input rows. When caller-supplied identity is desired, it arrives through the logical-node `fields` record.

### Composition

Composition is rope nesting: a rope produced by one composer may be placed as an entry of another composer's logical `children`. The composer detects a pre-built rope (a record carrying `_fields` or `_flat`) and places it verbatim as a child node. A `rope table` (flat mode) nested under a tree-mode node renders as a flat island inside the outline — `rope md-table` automates exactly this composition.

### rope table

```nushell
$rows | rope table --columns(-c): record = {}
```

- **Input** — `list<record>`. The column set is the union of all row keys: first-row keys first (in key order), then any keys appearing only in later rows (in first-appearance order).
- **`--columns`** — per-column policy overrides, keyed by column name. A column's record may carry any subset of `{justify, weight, clip, min}` plus an optional `q`. When `q` is given, it must be `"visual"` or `"text"` (q: `"data"` is **rejected**):
  - `q: "visual"` — that column's kv field-nodes are visible in visual formats and json; hidden in text.
  - `q: "text"` — that column's kv field-nodes are visible in text format and json; hidden in visual formats.
  - `q` absent — visible in all formats (default).
  Per-column default: `{justify: "left", weight: 1}`.
- **Output** — one rope in flat mode. The root `_flat` is the column-policy map (the `q` override is consumed for field-node visibility and is not part of `_flat`). The first row's values become the root's `_fields`; each remaining row becomes a child node. Keys absent or null in a row are omitted from that row's `_fields`.
- Empty input → `{_fields: [], _flat: {}, _children: []}`.

### rope tree

```nushell
$logical | rope tree
```

- **Input** — one logical-node, or `list<logical-node>`:

```
logical-node = {
  label:     record         # required; exactly one key; value is a string or rstr
  fields?:   record         # optional; named values (string or rstr)
  children?: list           # optional; logical-nodes and/or pre-built ropes
}
```

Logical-node label values have a two-mode styling contract:

| Label value      | Composer behavior                                                                                  |
|------------------|----------------------------------------------------------------------------------------------------|
| plain string     | The composer owns styling and wraps the value as an rstr tagged `h1` through `h6` by depth.        |
| pre-built `rstr` | The caller owns styling; the composer preserves the rstr byte-identical and adds no heading tag.   |

Use plain string labels for normal `rope tree`, `rope md`, and `rope md-table` headings. Pass a pre-built `rstr` label only when the caller intentionally overrides the composer-defined heading style.

- **Output** — one root-level rope in tree mode (no `_flat`). Given a single top-level logical-node, that node is returned directly as the root. Given multiple top-level nodes, they are wrapped in one empty-`_fields` root: `{_fields: [], _children: [...]}`. Empty input → `{_fields: [], _children: []}`.
- Each logical-node becomes a node whose `_fields` are, in declaration order:
  1. **connector** — `{v: <connector-rstr>, q: "visual"}`, visual-only leaf; absent on the root. The composer precomputes the full visual prefix — ancestor bars plus the local glyph (`├──▶` / `└──▶`) — as an rstr tagged `connector`.
  2. **name stem** — `{k: "name", v: <short label>}`, kv field-node.
  3. per `fields` entry — `{v: " ", q: "visual"}` (visual spacing leaf), `{v: " <key>=", q: "text"}` (text label leaf), then the kv `{k, v}`.
- The name uses a simple keyed stem: visual formats and `json` show the short label (`a.nu`); `text` shows the qualified path (`src/a.nu`) via a composer-supplied `q: "text"` base leaf placed immediately before the name stem.
- There is no id-display leaf. No `id` or `parent_id` is minted by `rope tree`; caller-supplied identity (when desired) arrives through the `fields` record.

### rope md

```nushell
$logical | rope md
```

- **Input** — the logical-node shape of `rope tree`, plus optional top-level `body?: string` on each logical-node.
- **Output** — one root-level rope in tree mode (no `_flat`). Given a single top-level node, that node is returned directly as the root. Given multiple top-level nodes, they are wrapped in one empty-`_fields` root: `{_fields: [], _children: [...]}`. Empty input → `{_fields: [], _children: []}`.
- Each logical-node at depth `D` becomes a node whose `_fields` are, in declaration order:
  1. **section break** (non-root only) — `{v: "\n", q: "visual"}` and `{v: "\n", q: "text"}`; combined with the renderer's inter-node newline this yields the blank line between sections.
  2. **heading prefix** — `{v: "# " … "###### "}` (leaf field-node, `q` absent; `D` clamped at 6); shown in visual formats and `text`.
  3. **name stem** — `{k: "name", v: <short label>}`, kv field-node, rstr-tagged `h1`..`h6`.
  4. **body slot** — for a non-empty string `body`, `{v: "\n", q: "visual"}`, `{v: "\n", q: "text"}`, then `{k: "body", v: <body>}`. Human markdown formats and `text` render this as anonymous body content immediately after the heading; `json` preserves it as `"body": <body>`.
  5. **post-heading newline** — `{v: "\n", q: "visual"}`, emitted only when bullets follow directly after the heading.
  6. per `fields` entry — `{v: "\n- <key>: ", q: "visual"}`, `{v: "\n- <key>=", q: "text"}`, then the kv `{k, v}`.
- The name stem follows the logical-node label styling contract: plain strings receive `h1` through `h6` by depth; pre-built `rstr` labels are preserved without an added heading tag.
- The `fields` record remains the named-field path. Every `fields` entry, including caller-supplied `fields.body`, renders as a bullet (`- body: ...` in visual formats, `- body=...` in `text`) and is not treated as anonymous body content.
- Empty, null, and non-string `body` values are not broadened by this contract; only non-empty string `body` values get the anonymous body slot.
- No `id` or `parent_id` is minted by `rope md`. Heading depth encodes the parent relationship; there is no position metadata. Caller-supplied identity (when desired) arrives through the `fields` record.
- Visual formats produce a markdown outline — the heading carries its `#` prefix; anonymous `body` content appears immediately below the heading; `fields` render as `- key: value` bullets. `text` is a multi-line outline — heading on its own line, anonymous `body` content when present, and `fields` as `- key=value` bullets. `json` is tree form and preserves the body slot as keyed data.

### rope md-table

```nushell
$logical | rope md-table --columns(-c): record = {}
```

- **Input** — the logical-node shape of `rope tree` / `rope md`.
- **`--columns`** — per-column policy overrides, passed through to the embedded `rope table`. The `q` value set is the same as `rope table`: `q ∈ {absent, "visual", "text"}`; `q: "data"` is rejected.
- **Output** — one root-level rope, tree mode at the heading nodes with embedded flat-mode table islands. Given a single top-level node, that node is returned directly. Given multiple top-level nodes, they are wrapped in one empty-`_fields` root: `{_fields: [], _children: [...]}`. Empty input → `{_fields: [], _children: []}`.
- For each logical-node, its `children` are partitioned: **leaves** (logical-nodes with no children of their own) and **non-leaves** (logical-nodes with children, plus any pre-built ropes). The leaves are collected into one embedded `rope table` (composition); the resulting flat-mode rope is placed first in `_children`, followed by the recursively built non-leaf children.
- Heading nodes carry the heading prefix, the name stem, and `fields` bullets. Heading-node name stems follow the logical-node label styling contract. Leaf children grouped into the embedded table render as table cells, not Markdown headings. No `id` or `parent_id` is minted.

## Conformance

Twenty canonical forms — four composers × five formats — over one fixture: directory `src` containing files `a.nu` and `b.nu`.

Notes on format rendering:
- **rich**: color + UTF-8 borders + TTY-bounded; ANSI styling via rstr region tags.
- **utf8**: same shape as `rich`; no ANSI escape sequences; UTF-8 borders kept.
- **plain**: no borders; space-aligned columns; no color.
- **text**: borderless; one-line-per-node (tree mode) or aligned table (flat mode); natural width; never clipped.
- **json**: tree form (no `_flat`) = nested objects with `children` arrays; flat form (with `_flat`) = one array of objects.

`rope tree` and `rope md` do not mint `id` or `parent_id` — none appears in any format from these composers. `rope table` takes `id` and `parent_id` from input rows; with `--columns {id: {q: "text"}, parent_id: {q: "text"}}` they appear in `text` and `json` but not in `rich`/`utf8`/`plain`.

### rope table

`rope table` over rows `{id, name, type, size, parent_id}`, with `id` and `parent_id` declared as text-only columns (`--columns {id: {q: "text"}, parent_id: {q: "text"}}`).

#### rich

`q: "text"` columns (`id`, `parent_id`) are hidden in visual formats (not in visual byte stream).

```
╭──────────┬──────┬────────╮
│ name     │ type │ size   │
├──────────┼──────┼────────┤
│ src      │ dir  │ 4.0 kB │
│ src/a.nu │ file │ 1KB    │
│ src/b.nu │ file │ 2KB    │
╰──────────┴──────┴────────╯
```

> note: headers have ANSI style via rstr

#### utf8

Identical to `rich`; rstr renders to plain text (no ANSI escape sequences). UTF-8 borders kept.

```
╭──────────┬──────┬────────╮
│ name     │ type │ size   │
├──────────┼──────┼────────┤
│ src      │ dir  │ 4.0 kB │
│ src/a.nu │ file │ 1KB    │
│ src/b.nu │ file │ 2KB    │
╰──────────┴──────┴────────╯
```

#### plain

`q: "text"` columns (`id`, `parent_id`) are hidden. No borders, space-aligned.

```
name      type  size

src       dir   4.0 kB
src/a.nu  file  1KB
src/b.nu  file  2KB
```

#### text

`q: "text"` columns appear; all columns present at natural width.

```
id  name      type  size    parent_id

1   src       dir   4.0 kB
2   src/a.nu  file  1KB     1
3   src/b.nu  file  2KB     1
```

#### json

Flat form (`_flat` present) — one array, one object per row. All kv field-nodes present.

```json
[
  {"id": 1, "name": "src", "type": "dir", "size": "4.0 kB"},
  {"id": 2, "name": "src/a.nu", "type": "file", "size": "1KB", "parent_id": 1},
  {"id": 3, "name": "src/b.nu", "type": "file", "size": "2KB", "parent_id": 1}
]
```

### rope tree

`rope tree` over the logical tree `src → {a.nu, b.nu}`. No `id` or `parent_id` minted.

#### rich

Connector tree; metadata follows the name. No id prefix.

```
src dir 4.0 kB
├──▶ a.nu file 1KB
└──▶ b.nu file 2KB
```

> note: names have ANSI style via rstr

#### utf8

Identical to `rich`; rstr renders to plain text (no ANSI escape sequences).

```
src dir 4.0 kB
├──▶ a.nu file 1KB
└──▶ b.nu file 2KB
```

#### plain

Identical to `utf8`; rstr renders to plain text. Tree mode has no renderer-supplied borders regardless of format.

```
src dir 4.0 kB
├──▶ a.nu file 1KB
└──▶ b.nu file 2KB
```

#### text

Name qualified to a full path by the text-only base leaf; fields as `key=value`. No `id` or `parent_id`.

```
src type=dir size=4.0 kB
src/a.nu type=file size=1KB
src/b.nu type=file size=2KB
```

#### json

Tree form (no `_flat`) — nested `children`. No `id` or `parent_id`.

```json
[
  {"name": "src", "type": "dir", "size": "4.0 kB", "children": [
    {"name": "a.nu", "type": "file", "size": "1KB"},
    {"name": "b.nu", "type": "file", "size": "2KB"}
  ]}
]
```

### rope md

`rope md` over the same logical tree. No `id` or `parent_id` minted.

#### rich

Markdown outline; `id` and `parent_id` absent (not minted; heading depth encodes structure).

```
# src

- type: dir
- size: 4.0 kB

## a.nu

- type: file
- size: 1KB

## b.nu

- type: file
- size: 2KB
```

> note: headings have ANSI style via rstr

#### utf8

Identical to `rich`; rstr renders to plain text (no ANSI escape sequences).

```
# src

- type: dir
- size: 4.0 kB

## a.nu

- type: file
- size: 1KB

## b.nu

- type: file
- size: 2KB
```

#### plain

Identical to `utf8`; rstr renders to plain text. Tree mode has no renderer-supplied borders regardless of format.

```
# src

- type: dir
- size: 4.0 kB

## a.nu

- type: file
- size: 1KB

## b.nu

- type: file
- size: 2KB
```

#### text

Multi-line outline; heading on its own line; fields as `- key=value` bullets. No `id` or `parent_id`.

```
# src
- type=dir
- size=4.0 kB

## a.nu
- type=file
- size=1KB

## b.nu
- type=file
- size=2KB
```

#### json

Tree form — nested `children`. No `id` or `parent_id`.

```json
[
  {"name": "src", "type": "dir", "size": "4.0 kB", "children": [
    {"name": "a.nu", "type": "file", "size": "1KB"},
    {"name": "b.nu", "type": "file", "size": "2KB"}
  ]}
]
```

### rope md-table

`rope md-table` over the same logical tree — `src`'s leaf children (`a.nu`, `b.nu`) are grouped into one embedded `rope table`. No `id` or `parent_id` is minted.

#### rich

```
# src

- type: dir
╭──────┬──────┬──────╮
│ name │ type │ size │
├──────┼──────┼──────┤
│ a.nu │ file │ 1KB  │
│ b.nu │ file │ 2KB  │
╰──────┴──────┴──────╯
```

> note: headings and headers have ANSI style via rstr

#### utf8

Identical to `rich`; rstr renders to plain text (no ANSI escape sequences). UTF-8 borders kept.

```
# src

- type: dir
╭──────┬──────┬──────╮
│ name │ type │ size │
├──────┼──────┼──────┤
│ a.nu │ file │ 1KB  │
│ b.nu │ file │ 2KB  │
╰──────┴──────┴──────╯
```

#### plain

Heading and bullets unchanged (tree mode, visual items visible). Embedded table uses space alignment; no borders.

```
# src

- type: dir
name  type  size

a.nu  file  1KB
b.nu  file  2KB
```

#### text

```
# src
- type=dir
name  type  size

a.nu  file  1KB
b.nu  file  2KB
```

#### json

Tree form with the embedded table as a flat sub-array inside `children`.

```json
[
  {"name": "src", "type": "dir", "children": [
    [
      {"name": "a.nu", "type": "file", "size": "1KB"},
      {"name": "b.nu", "type": "file", "size": "2KB"}
    ]
  ]}
]
```

## Implementation notes

- `clip: "wrap"` is specified-but-not-implemented; it renders as `"none"` until implemented.
- Column sacrifice (Case 4) is implemented for visual flat mode by sacrificing measured column slots and appending the right-edge sentinel column.
