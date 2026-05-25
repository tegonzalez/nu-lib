#!/usr/bin/env nu
# rope.nu — rope composers: rope tree, rope md, rope table, rope md-table
# Authority: nu/lib/render-spec.md
#
# Consumer surface (closed-world): rope tree, rope md, rope table, rope md-table.
# Rope records returned by these composers are OPAQUE to non-render consumers —
# they are consumed by `render walk`, never inspected by tools. Internal node
# keys (_fields, _children, _flat) are render-internal; consumers do not read
# or write them. Tools that need an output shape file an arch-evolution to
# extend this composer set; they do not build rope records by hand.
#
# Four composers convert logical-node or row data into ropes for use with render walk.
# All outputs are tree-shaped (rope tree, rope md, rope md-table) or flat-scoped (rope table).
#
# q value set: q ∈ {"visual", "text"} only. "rich" and "data" are INVALID per render-spec.md.
# rope tree and rope md do NOT mint id or parent_id — no {k:"id"} or {k:"parent_id"} is emitted.
# rope table reads id and parent_id from input rows only.

use ./rstr.nu *

# Detect whether a value is a pre-built rstr (list of rstr-node records).
# Returns true when describe starts with "list" or "table" (list<record> is described as table<...>).
def is-rstr [v: any] {
  let desc = ($v | describe)
  ($desc | str starts-with "list") or ($desc | str starts-with "table")
}

def is-format-value [v: any] {
  let desc = ($v | describe)
  if not ($desc | str starts-with "record") {
    return false
  }
  "_fmt" in ($v | columns)
}

# Detect whether a value is a pre-built rope (record with top-level _fields key).
def is-rope [v: any] {
  let desc = ($v | describe)
  if not ($desc | str starts-with "record") { return false }
  ($v | columns | any {|k| $k == "_fields"})
}

# Coerce a label value to rstr.
# Plain string labels are composer-owned and receive the depth heading style h1..h6.
# Pre-built rstr labels are caller-owned and pass through unchanged; callers that
# pre-style labels opt out of automatic heading decoration for that label.
def coerce-label [v: any, depth: int] {
  if (is-rstr $v) or (is-format-value $v) {
    $v
  } else {
    let h_level = ([$depth 6] | math min)
    let h_name = $"h($h_level)"
    $v | rstr of | rstr tag $h_name
  }
}

# Coerce a field value to rstr (no heading tagging).
def coerce-field-v [v: any] {
  if (is-rstr $v) or (is-format-value $v) {
    $v
  } else {
    $v | rstr of
  }
}

# Build the _fields list for a single rope md logical-node.
# depth: current depth (native int, root = 1)
# node: the logical-node record (has label, body?, fields?, children?)
#
# _fields order per nu/lib/render-spec.md:
#   1. non-root section break {v:"\n", q:"visual"} and {v:"\n", q:"text"} — combined with
#      renderer's inter-node newline yields a blank line between sections.
#   2. heading base {v:"# ".."###### "} — value-only; shown in visual formats and text.
#   3. stem {k:"name", v:<rstr>} — keyed name, rstr-tagged h1..h6.
#   4. optional body slot: anonymous newline then keyed {k:"body", v:<body>}.
#   5. post-heading visual newline {v:"\n", q:"visual"} — only when bullets follow
#      without an anonymous body.
#   6. per caller field: visual bullet {v:"\n- <key>: ", q:"visual"}, text bullet
#      {v:"\n- <key>=", q:"text"}, then keyed {k, v}.
# No id or parent_id is minted.
def build-node-fields [node: record, depth: int] {
  let is_root = ($depth == 1)

  # 1. Non-root section break — joins with renderer's per-envelope "\n" to produce
  #    a blank line between sections. Root emits nothing.
  let section_break = if $is_root { [] } else { [{v: "\n", q: "visual"}, {v: "\n", q: "text"}] }

  # 2. Heading base — value-only "# ".."###### " (depth clamped at 6).
  let h_level = ([$depth 6] | math min)
  let heading_prefix = (0..<$h_level | each {|_| "#"} | str join "")
  let base_field = [{v: $"($heading_prefix) "}]

  # 3. Keyed stem — node's short label, rstr-tagged h1..h6.
  let label_record = ($node | get label)
  let label_val = ($label_record | values | first)
  let label_rstr = (coerce-label $label_val $depth)
  let stem_field = [{k: "name", v: $label_rstr}]

  # 4. Optional top-level body slot — non-empty string body renders anonymously
  #    after the heading while remaining keyed for JSON output.
  let body_value = ($node | get body? | default null)
  let has_body = (($body_value | describe) == "string") and ($body_value != "")
  let body_fields = if $has_body {
    [
      {v: "\n", q: "visual"}
      {v: "\n", q: "text"}
      {k: "body", v: (coerce-field-v $body_value)}
    ]
  } else {
    []
  }

  # 5. Caller fields — each preceded by a visual bullet {v:"\n- <key>: ", q:"visual"} and a
  #    text bullet {v:"\n- <key>=", q:"text"}, then the keyed value.
  let caller_fields_record = ($node | get fields? | default {})
  let caller_fields = ($caller_fields_record | transpose k v | each {|pair|
    [
      {v: $"\n- ($pair.k): ", q: "visual"}
      {v: $"\n- ($pair.k)=", q: "text"}
      {k: $pair.k, v: (coerce-field-v $pair.v)}
    ]
  } | flatten)

  # 5. Post-heading visual newline — only when caller fields produce bullets
  #    directly after the heading.
  let has_bullets = ($caller_fields | is-not-empty)
  let post_heading = if ($has_bullets and not $has_body) { [{v: "\n", q: "visual"}] } else { [] }

  $section_break ++ $base_field ++ $stem_field ++ $body_fields ++ $post_heading ++ $caller_fields
}

# Recursive DFS walker for rope md. Returns {rope_nodes: list<rope-node>}.
#
# Arguments:
#   node      — current logical-node record
#   depth     — current depth level (root = 1)
def walk-node [node: record, depth: int] {
  let fields = (build-node-fields $node $depth)

  # Get children list
  let children_list = ($node | get children? | default [])

  # DFS: walk each child.
  # Embedded ropes are placed verbatim; logical-nodes are recursed into.
  # Any other value is rejected with a build-time error.
  let child_rope_nodes = ($children_list | reduce --fold [] {|child, acc|
    let child_desc = ($child | describe)
    if (is-rope $child) {
      # Embedded rope: place verbatim, do not mint position fields or rewrap
      ($acc ++ [$child])
    } else if ($child_desc | str starts-with "record") {
      # Logical-node: recurse
      let child_r = (walk-node $child ($depth + 1))
      ($acc ++ $child_r.rope_nodes)
    } else {
      error make {msg: $"rope md: invalid child — expected a logical-node record or a pre-built rope, got ($child_desc)"}
    }
  })

  # Build rope node for this logical-node
  let rope_node = {
    _fields: $fields
    _children: $child_rope_nodes
  }

  {rope_nodes: [$rope_node]}
}

# Compose a logical-node (or list of logical-nodes) into a tree-shaped rope.
#
# Input shape (single node):
#   {label: {<name>: <string|rstr>}, body?: <string>, fields?: <record>, children?: <list>}
#
# Input shape (list):
#   list<logical-node>
#
# Output (tree-shaped rope, no _flat at any level):
#   - empty input              → {_fields: [], _children: []}
#   - single top-level node   → that node directly: {_fields, _children}
#   - multiple top-level nodes → {_fields: [], _children: [n1, n2, ...]}
#
# The label's KEY is a naming convention only — rope md does not emit a field from it.
# Plain-string label values are wrapped in rstr and tagged h1..h6 based on depth.
# Pre-built rstr label values are preserved byte-identical; this is for explicit
# caller styling, not for routine labels that should inherit heading depth.
# Caller fields (node.fields) become keyed {k, v} entries in input order.
# A non-empty string node.body becomes anonymous markdown body content after the
# heading and remains keyed as "body" for JSON output. node.fields.body stays a
# normal named field.
# No id or parent_id is minted — heading depth encodes the parent relationship.
# Embedded ropes in children are placed verbatim in _children — no modification.
# Any children element that is neither a logical-node nor a rope produces a build-time error.
export def "rope md" []: [record -> any, list -> any, nothing -> record] {
  let input = $in

  # If no input provided, return an empty leaf rope.
  if ($input == null) {
    return {_fields: [], _children: []}
  }

  # Normalize: wrap single record in list
  let nodes_list = if ($input | describe) =~ "^record" {
    [$input]
  } else {
    $input
  }

  # Walk each top-level node
  let rope_nodes = ($nodes_list | reduce --fold [] {|node, acc|
    let r = (walk-node $node 1)
    ($acc ++ $r.rope_nodes)
  })

  # Single top-level node: return directly as root.
  # Multiple top-level nodes: wrap in empty-_fields root.
  if (($rope_nodes | length) == 1) {
    ($rope_nodes | first)
  } else {
    {_fields: [], _children: $rope_nodes}
  }
}

# Build _fields for a rope md-table node: heading only.
# Heading nodes use the same label contract as rope md: plain labels get h1..h6,
# pre-built rstr labels pass through unchanged, and leaf children grouped into
# tables do not become heading nodes.
# No id or parent_id minted; heading depth encodes structure.
def build-md-table-node-fields [node: record, depth: int, is_root: bool] {
  let rich_sep    = if $is_root { [] } else { [{v: "\n", q: "visual"}, {v: "\n", q: "text"}] }
  let h_level     = ([$depth 6] | math min)
  let h_prefix    = (0..<$h_level | each {|_| "#"} | str join "")
  let base_field  = [{v: $"($h_prefix) "}]
  let label_val   = ($node.label | values | first)
  let stem_field  = [{k: "name", v: (coerce-label $label_val $depth)}]
  let caller_fields = ($node | get fields? | default {} | transpose k v | each {|pair|
    [
      {v: $"\n- ($pair.k): ", q: "visual"}
      {v: $"\n- ($pair.k)=", q: "text"}
      {k: $pair.k, v: (coerce-field-v $pair.v)}
    ]
  } | flatten)
  let has_bullets = ($caller_fields | is-not-empty)
  let post_heading = if $has_bullets { [{v: "\n", q: "visual"}] } else { [] }
  $rich_sep ++ $base_field ++ $stem_field ++ $post_heading ++ $caller_fields
}

# Recursive DFS walker for rope md-table.
# Mirrors walk-node but partitions children into leaves (no children) and non-leaves.
# Leaves are grouped into a single rope table prepended before non-leaf children.
# Pre-built rope children are treated as non-leaves (placed verbatim).
def walk-md-table-node [node: record, parent_id: any, depth: int, columns: record] {
  let is_root = ($parent_id == null)
  let fields = (build-md-table-node-fields $node $depth $is_root)

  let children_list = ($node | get children? | default [])

  # Partition: leaves are logical-node records with no children; everything else is a non-leaf.
  let partitioned = ($children_list | reduce --fold {leaves: [], non_leaves: []} {|child, acc|
    let is_r = (is-rope $child)
    let desc = ($child | describe)
    let is_rec = ($desc | str starts-with "record")
    let has_children = (if (not $is_r and $is_rec) { ($child | get children? | default [] | is-not-empty) } else { false })
    if (not $is_r and $is_rec and not $has_children) {
      {leaves: ($acc.leaves | append [$child]), non_leaves: $acc.non_leaves}
    } else {
      {leaves: $acc.leaves, non_leaves: ($acc.non_leaves | append [$child])}
    }
  })

  # Process non-leaves: ropes verbatim, logical-nodes recurse.
  let non_leaf_rope_nodes = ($partitioned.non_leaves | reduce --fold [] {|child, acc|
    if (is-rope $child) {
      ($acc ++ [$child])
    } else if (($child | describe) | str starts-with "record") {
      let r = (walk-md-table-node $child $node ($depth + 1) $columns)
      ($acc ++ $r.rope_nodes)
    } else {
      error make {msg: $"rope md-table: invalid child — expected logical-node or pre-built rope, got ($child | describe)"}
    }
  })

  # Group leaves into a single rope table, placed before non-leaf children.
  let table_rope_list = if ($partitioned.leaves | is-empty) {
    []
  } else {
    let leaf_rows = ($partitioned.leaves | each {|leaf|
      let label_key = ($leaf.label | columns | first)
      let label_val = ($leaf.label | values | first)
      let leaf_fields = ($leaf | get fields? | default {})
      {} | insert $label_key $label_val | merge $leaf_fields
    })
    [($leaf_rows | rope table --columns $columns)]
  }

  let rope_node = {
    _fields: $fields
    _children: ($table_rope_list ++ $non_leaf_rope_nodes)
  }

  {rope_nodes: [$rope_node]}
}

# Compose a logical-node tree into a rope where leaf siblings are grouped into a rope table.
#
# Input shape: same as rope md — {label, fields?, children?} or list thereof.
# --columns(-c): column policy overrides passed through to rope table for leaf grouping.
#   q ∈ {absent, "visual", "text"}; q:"data" is rejected.
#
# Policy:
#   Non-leaf children (have children of their own) become heading nodes and recurse.
#   Leaf children (no children) at each level are collected into one rope table, placed
#   before non-leaf children. Pre-built rope children are placed verbatim as non-leaves.
export def "rope md-table" [--columns(-c): record = {}]: [record -> any, list -> any, nothing -> record] {
  let input = $in

  if ($input == null) {
    return {_fields: [], _children: []}
  }

  let nodes_list = if ($input | describe) =~ "^record" {
    [$input]
  } else {
    $input
  }

  let rope_nodes = ($nodes_list | reduce --fold [] {|node, acc|
    let r = (walk-md-table-node $node null 1 $columns)
    ($acc ++ $r.rope_nodes)
  })

  # Single top-level node: return directly as root.
  # Multiple top-level nodes: wrap in empty-_fields root.
  if (($rope_nodes | length) == 1) {
    ($rope_nodes | first)
  } else {
    {_fields: [], _children: $rope_nodes}
  }
}

# Compose a list<record> into a flat-mode rope for tabular rendering.
#
# Input: list<record>  — rows of data (piped in)
# --columns (-c): record — per-column policy overrides, keyed by column name
#
# Per-column override may carry any subset of {justify, weight, clip, min} plus optional q.
# q must be "visual" or "text" when present; q:"data" is REJECTED (render-spec.md §rope table).
#   q:"visual" — column visible in visual formats and json; hidden in text.
#   q:"text"   — column visible in text format and json; hidden in visual formats.
#   q absent   — visible in all formats (default).
#
# Default column policy: {justify: "left", weight: 0, clip: "rhs"}
#
# Output shape:
#   {_flat: {<col>: <policy>, ...}, _fields: [<first-row kv nodes>], _children: [<remaining-row nodes>]}
#
# Column set = union of all row keys; first-row keys come first (in key order),
# then any additional keys found in later rows (in order of first appearance).
# Keys absent or null in a given row are omitted from that row's _fields list.
#
# Empty input returns: {_fields: [], _flat: {}, _children: []}.
#
# Field values are stored raw (not coerced to rstr) so v-to-json preserves native types.
export def "rope table" [--columns(-c): record = {}]: list -> record {
  let rows = $in

  # Early return on empty input
  if ($rows | is-empty) {
    return {_fields: [], _flat: {}, _children: []}
  }

  # Derive column order: first-row keys first, then additional keys from later rows.
  let first_cols = ($rows | first | columns)
  # Stable union: accumulate unique column names across all rows in discovery order.
  let all_cols = ($rows | each { columns } | flatten | reduce --fold [] {|col, acc|
    if ($col in $acc) { $acc } else { $acc | append $col }
  })
  # Extra cols = those not in first row, in discovery order.
  let extra_cols = ($all_cols | where {|c| not ($c in $first_cols)})
  let cols = ($first_cols | append $extra_cols)

  # Build merged policy per column: default merged with caller overrides.
  # q key (if present in override) is validated and extracted for field node emission;
  # it is excluded from the _flat alignment policy.
  # q:"data" is rejected — only "visual" and "text" are valid per render-spec.md.
  let default_policy = {justify: "left", weight: 0, clip: "rhs"}

  let col_meta = ($cols | each {|col|
    let override = ($columns | get --optional $col | default {})
    let q        = ($override | get q? | default null)
    # Validate q when present
    if $q != null and $q != "visual" and $q != "text" {
      let errmsg = ("rope table: invalid q value '" + $q + "' for column '" + $col + "' -- q must be visual or text (q:data and q:rich are rejected)")
      error make {msg: $errmsg}
    }
    let policy   = ($default_policy | merge ($override | reject -o q))
    {col: $col, q: $q, policy: $policy}
  })

  # _flat only covers columns present in the first row's emitted _fields: render walk
  # validates _flat keys against the declaring node's _fields only. Columns absent or
  # null in the first row are excluded from _flat and use default policy in the emitter.
  let first_row_emitted_cols = ($rows | first | transpose k v | where {|kv| $kv.v != null} | each {|kv| $kv.k})
  let flat_val = ($col_meta | where {|m| $m.col in $first_row_emitted_cols} | reduce --fold {} {|m, acc|
    $acc | upsert $m.col $m.policy
  })

  # Build _fields for one row, applying q qualifier when set.
  # Keys absent or null in the row are omitted entirely (so json output skips them).
  # Values stored raw so v-to-json preserves native types.
  let build_fields = {|row|
    $col_meta | each {|m|
      let val = ($row | get --optional $m.col)
      if $val == null { null } else {
        let node = {k: $m.col, v: $val}
        if $m.q != null { $node | upsert q $m.q } else { $node }
      }
    } | where { $in != null }
  }

  let first_row   = ($rows | first)
  let root_fields = (do $build_fields $first_row)

  let child_nodes = ($rows | skip 1 | each {|row|
    {_fields: (do $build_fields $row)}
  })

  {
    _flat: $flat_val
    _fields: $root_fields
    _children: $child_nodes
  }
}

# Build a connector rstr from ancestor last/not-last context.
# prefix_bars: list<bool> — each entry is true when that ancestor was NOT the last child
#   (true → emit │, false → emit spaces)
# is_last: bool — true when this node is the last sibling
# Returns a rstr tagged "connector".
def build-connector-rstr [prefix_bars: list<bool>, is_last: bool] {
  # Build the prefix string from ancestor bars
  let prefix_str = ($prefix_bars | reduce --fold "" {|bar, acc|
    if $bar { $"($acc)│   " } else { $"($acc)    " }
  })
  # Local glyph
  let glyph = if $is_last { "└──▶ " } else { "├──▶ " }
  let full_str = $"($prefix_str)($glyph)"
  $full_str | rstr of | rstr tag "connector"
}

# Build the _fields list for a single rope-tree node, per nu/lib/render-spec.md.
# connector_rstr:   null for root, rstr for non-root
# label_val:        the label value (rstr or plain) — node's short leaf label
# node_fields:      the fields record (may be null)
# depth:            current depth (root = 1)
# ancestor_labels:  list<string> of ancestor short labels, root→parent order
#
# The renderer inserts zero bytes between adjacent fields — every space and
# every "key=" punctuation is baked here by the composer. visual formats emit
# q-absent and q:"visual" item values; text emits q-absent and q:"text" item values;
# json emits keyed items only (k present), regardless of q.
#
# _fields order (per nu/lib/render-spec.md §rope tree):
#   1. connector       {v: <rstr>, q:"visual"}            — non-root only
#   2. base            {v: "<ancestor-path>/", q:"text"}  — text-only path prefix; root empty
#   3. stem            {k:"name", v:<rstr>}               — keyed name; in visual/text/json
#   4. per caller field: visual space {v:" ", q:"visual"}, text prefix {v:" <key>=", q:"text"},
#      then keyed {k, v} (q-absent — value shows in visual and text)
# No id or parent_id is minted.
def build-tree-node-fields [
  connector_rstr: any,
  label_val: any,
  node_fields: any,
  depth: int,
  ancestor_labels: list<string>
] {
  let is_root = ($connector_rstr == null)

  # 1. Connector: {v: rstr, q: "visual"} — only for non-root
  let connector_field = if not $is_root {
    [{v: $connector_rstr, q: "visual"}]
  } else {
    []
  }

  # 2. Text-only base — ancestor short labels joined with "/" plus trailing "/".
  #    Root has empty base.
  let base_str = if ($ancestor_labels | is-empty) {
    ""
  } else {
    $"($ancestor_labels | str join '/')/"
  }
  let base_field = [{v: $base_str, q: "text"}]

  # 3. Keyed stem — node's short leaf label
  let label_rstr = (coerce-label $label_val $depth)
  let stem_field = [{k: "name", v: $label_rstr}]

  # 4. Caller fields — each preceded by a visual-only space and a text-only " key="
  let caller_fields = if $node_fields != null {
    ($node_fields | transpose k v | each {|pair|
      [
        {v: " ", q: "visual"}
        {v: $" ($pair.k)=", q: "text"}
        {k: $pair.k, v: (coerce-field-v $pair.v)}
      ]
    } | flatten)
  } else {
    []
  }

  $connector_field ++ $base_field ++ $stem_field ++ $caller_fields
}

# Recursive DFS walker for rope tree.
# Returns {rope_nodes: list<rope-node>}.
#
# Arguments:
#   node            — current logical-node record
#   depth           — current depth level (root = 1)
#   prefix_bars     — list<bool> tracking ancestor continuation (true = has continuation bar)
#   is_root         — bool: when true, no connector field is emitted
#   is_last         — bool: when true, use └──▶ glyph, else ├──▶
#   ancestor_labels — list<string> of ancestor short labels, root→parent order
def tree-walk-node [
  node: record,
  depth: int,
  prefix_bars: list<bool>,
  is_root: bool,
  is_last: bool,
  ancestor_labels: list<string>
] {
  # Extract label key and value
  let label_record = ($node | get label)
  let label_val = ($label_record | values | first)

  # Build connector rstr (null for root)
  let connector_rstr = if $is_root {
    null
  } else {
    (build-connector-rstr $prefix_bars $is_last)
  }

  # Get node fields record
  let node_fields = ($node | get fields? | default null)

  # Build this node's _fields
  let fields = (build-tree-node-fields $connector_rstr $label_val $node_fields $depth $ancestor_labels)

  # Short label string for threading into children's base prefix.
  # Use the raw string when label is plain; for an rstr, extract plain text.
  let my_label_str = if (is-rstr $label_val) {
    ($label_val | rstr plain)
  } else {
    ($label_val | into string)
  }
  let child_ancestor_labels = ($ancestor_labels ++ [$my_label_str])

  # Get children list
  let children_list = ($node | get children? | default [])
  let child_count = ($children_list | length)

  # For children's prefix_bars: append whether THIS node has more siblings after it.
  # If this node is not last (has continuation), children see a bar (true).
  # If this node is last (no continuation), children see spaces (false).
  let child_prefix_bars = if $is_root {
    # Root's children don't inherit any prefix from root
    $prefix_bars
  } else {
    ($prefix_bars ++ [( not $is_last )])
  }

  # DFS walk children
  let child_rope_nodes = ($children_list | enumerate | reduce --fold [] {|indexed, acc|
    let child = $indexed.item
    let child_index = $indexed.index
    let child_is_last = ($child_index == ($child_count - 1))
    let child_desc = ($child | describe)
    if (is-rope $child) {
      # Embedded rope: place verbatim
      ($acc ++ [$child])
    } else if ($child_desc | str starts-with "record") {
      # Logical-node: recurse
      let child_r = (tree-walk-node $child ($depth + 1) $child_prefix_bars false $child_is_last $child_ancestor_labels)
      ($acc ++ $child_r.rope_nodes)
    } else {
      error make {msg: $"rope tree: invalid child — expected a logical-node record or a pre-built rope, got ($child_desc)"}
    }
  })

  let rope_node = {
    _fields: $fields
    _children: $child_rope_nodes
  }

  {rope_nodes: [$rope_node]}
}

# Compose a logical-node (or list of logical-nodes) into a tree-shaped rope with visual connectors.
#
# Input shape (single node):
#   {label: {<name>: <string|rstr>}, fields?: <record>, children?: <list>}
#
# Input shape (list):
#   list<logical-node>
#
# Output (tree-shaped rope, no _flat at any level):
#   - empty input              → {_fields: [], _children: []}
#   - single top-level node   → that node directly: {_fields, _children}
#   - multiple top-level nodes → {_fields: [], _children: [n1, n2, ...]}
#
# Per-node _fields order (see nu/lib/render-spec.md §rope tree):
#   1. connector       {v: <connector-rstr>, q:"visual"} — non-root only.
#   2. base            {v: "<ancestor-path>/", q:"text"} — text-only; root empty.
#   3. stem            {k:"name", v:<rstr>} — keyed name.
#   4. per caller field: visual space {v:" ", q:"visual"}, text prefix {v:" <key>=", q:"text"},
#      then keyed {k, v}.
# No id or parent_id is minted.
#
# Connector rstrs: full visual prefix — ancestor bars (│) plus local glyph (├──▶ or └──▶).
# Tagged with rstr tag "connector".
# Embedded ropes in children are placed verbatim in _children.
export def "rope tree" []: [record -> record, list -> record, nothing -> record] {
  let input = $in

  if ($input == null) {
    return {_fields: [], _children: []}
  }

  # Normalize: wrap single record in list
  let nodes_list = if ($input | describe) =~ "^record" {
    [$input]
  } else {
    $input
  }

  let node_count = ($nodes_list | length)

  # Walk each top-level node
  let rope_nodes = ($nodes_list | enumerate | reduce --fold [] {|indexed, acc|
    let node = $indexed.item
    let node_index = $indexed.index
    let node_is_last = ($node_index == ($node_count - 1))
    if (is-rope $node) {
      # Top-level embedded rope: place verbatim
      ($acc ++ [$node])
    } else {
      # Top-level logical-nodes: treated as root (no connector, no prefix bars)
      let r = (tree-walk-node $node 1 [] true $node_is_last [])
      ($acc ++ $r.rope_nodes)
    }
  })

  # Single top-level node: return that node directly as the root.
  # Multiple top-level nodes: wrap in empty-_fields root.
  if (($rope_nodes | length) == 1) {
    ($rope_nodes | first)
  } else {
    {_fields: [], _children: $rope_nodes}
  }
}
