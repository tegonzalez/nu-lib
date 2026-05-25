# render.nu — rope renderer
# Public surface: render walk (via module namespace: `use render.nu; ... | render walk {...}`)
# Authority: nu/lib/render-spec.md
#
# Width / clip / multi-line-cell / ellipsis / column-policy semantics live HERE,
# nowhere else. Tools pass values verbatim into rope composers; render owns all
# display normalization. See render-spec.md § Width Policy Ownership.
#
# TTY-aware: `render-env` is the only function that calls `tui-is-tty` and
# `tui-columns`. When stdout is not a TTY, `cols=null` propagates to
# `col-budgets`, which returns natural widths (no clip). This is the
# documented unbounded path per render-spec § TTY vs Non-TTY Output Contract.
# Captured stdout (pipes, agent tool output) reads the non-TTY path; set
# FORCE_TTY=1 to reproduce TTY rendering when stdout would be captured.

use ./tui.nu *
use ./rstr.nu *

# ── Capability resolver ────────────────────────────────────────────────────────

# Return the capability record for a given format string.
# Errors on unknown format.
def resolve-capability [format: string] {
  match $format {
    "rich"  => {format: "rich",  color: true,  borders: true,  bounded: true,  byte_stream: "visual"}
    "utf8"  => {format: "utf8",  color: false, borders: true,  bounded: true,  byte_stream: "visual"}
    "plain" => {format: "plain", color: false, borders: false, bounded: true,  byte_stream: "visual"}
    "text"  => {format: "text",  color: false, borders: false, bounded: false, byte_stream: "text"}
    "json"  => {format: "json",  color: false, borders: false, bounded: false, byte_stream: "json"}
    _       => { error make {msg: $"render walk: unknown format '($format)' — expected rich | utf8 | plain | text | json"} }
  }
}

# ── Environment resolver ───────────────────────────────────────────────────────

# Resolve TTY environment and terminal dimensions.
# This is the ONLY function that calls tui-is-tty and tui-columns.
# When cfg.format is absent, defaults to "rich" on TTY, "text" otherwise.
# Returns {format, caps, is_tty, cols}
def render-env [cfg: record] {
  let is_tty = tui-is-tty
  let fmt_raw = ($cfg | get format? | default null)
  let fmt = if $fmt_raw == null {
    if $is_tty { "rich" } else { "text" }
  } else {
    $fmt_raw
  }
  let caps = (resolve-capability $fmt)
  let cols = if $is_tty and $caps.bounded { tui-columns } else { null }
  {format: $caps.format, caps: $caps, is_tty: $is_tty, cols: $cols}
}

# ── Column width algorithm ─────────────────────────────────────────────────────

# Compute per-column budgets for flat-mode table rendering from measured row
# templates. Fixed fragments and column slots are resolved for the selected
# visual format before this helper runs; this helper only applies renderer
# shrink and sacrifice policy to those templates.
# Called only by visual-class flat-mode emitter.
#
# Parameters:
#   flat        — the _flat policy record
#   nat         — record of {col: natural_width} for each column
#   col_order   — list of column keys in display order
#   term_cols   — terminal width (int or null); null → Case 1
#   templates   — resolved row templates with fixed fragments and column slots
#
# Returns:
#   {columns, budgets, sacrificed, sentinel}
def col-budgets [flat: any, nat: record, col_order: list, term_cols: any, templates: record] {
  let sentinel_col = "__render_sentinel"

  let fixed_width = {|s| $s | rstr display-len}

  let slot_natural = {|template, col|
    if $col == $sentinel_col {
      1
    } else if $template.kind == "header" {
      $col | rstr display-len
    } else if $template.kind == "data" {
      let cell = ($template.cells | get --optional $col | default null)
      if $cell == null { 0 } else { $cell.width }
    } else {
      0
    }
  }

  let slot_width = {|template, col, budgets|
    let budget = ($budgets | get --optional $col | default 0)
    if $template.kind == "rule" {
      $budget + 2
    } else if $col == $sentinel_col {
      $budget
    } else if $template.kind == "data" {
      let cell = ($template.cells | get --optional $col | default null)
      let natural = if $cell == null { 0 } else { $cell.width }
      let clip = if $cell == null { "none" } else { $cell.clip }
      if $clip == "rhs" or $clip == "lhs" {
        $budget
      } else {
        [$natural $budget] | math max
      }
    } else {
      let natural = (do $slot_natural $template $col)
      [$natural $budget] | math max
    }
  }

  let template_width = {|template, cols, budgets|
    let parts = if $templates.borders {
      if $template.kind == "rule" {
        let left = ($template | get left)
        let sep = ($template | get sep)
        let right = ($template | get right)
        let init = [{kind: "fixed", text: $left}]
        let body = ($cols | enumerate | reduce --fold $init {|item, acc|
          let suffix = if $item.index == (($cols | length) - 1) { $right } else { $sep }
          $acc ++ [{kind: "slot", col: $item.item}, {kind: "fixed", text: $suffix}]
        })
        $body
      } else {
        let init = [{kind: "fixed", text: "│"}]
        let body = ($cols | enumerate | reduce --fold $init {|item, acc|
          let suffix = if $item.index == (($cols | length) - 1) { "│" } else { "│" }
          $acc ++ [{kind: "fixed", text: " "}, {kind: "slot", col: $item.item}, {kind: "fixed", text: " "}, {kind: "fixed", text: $suffix}]
        })
        $body
      }
    } else {
      $cols | enumerate | reduce --fold [] {|item, acc|
        let prefix = if $item.index == 0 { [] } else { [{kind: "fixed", text: "  "}] }
        $acc ++ $prefix ++ [{kind: "slot", col: $item.item}]
      }
    }

    $parts | reduce --fold 0 {|part, acc|
      if $part.kind == "fixed" {
        $acc + (do $fixed_width $part.text)
      } else {
        $acc + (do $slot_width $template $part.col $budgets)
      }
    }
  }

  let max_template_width = {|cols, budgets|
    if ($cols | is-empty) {
      0
    } else {
      $templates.rows | reduce --fold 0 {|template, acc|
        [$acc (do $template_width $template $cols $budgets)] | math max
      }
    }
  }

  let fits = {|cols, budgets|
    if $term_cols == null {
      true
    } else {
      (do $max_template_width $cols $budgets) <= $term_cols
    }
  }

  let min_widths = {|cols|
    $cols | reduce --fold {} {|col, acc|
      if $col == $sentinel_col {
        $acc | upsert $col 1
      } else {
        let policy = ($flat | get --optional $col | default {})
        let min_w = ($policy | get min? | default ($col | rstr display-len))
        $acc | upsert $col $min_w
      }
    }
  }

  let with_sentinel = {|cols|
    if ($cols | is-empty) { [$sentinel_col] } else { $cols ++ [$sentinel_col] }
  }

  let allocate = {|cols, sentinel|
    let render_cols = if $sentinel { do $with_sentinel $cols } else { $cols }
    let nat_all = ($render_cols | reduce --fold {} {|col, acc|
      if $col == $sentinel_col {
        $acc | upsert $col 1
      } else {
        $acc | upsert $col ($nat | get --optional $col | default 0)
      }
    })
    let natural_budgets = $nat_all

    if (do $fits $render_cols $natural_budgets) {
      return $natural_budgets
    }

    let fixed_only = ($render_cols | reduce --fold {} {|col, acc| $acc | upsert $col 0})
    let fixed_cost = (do $max_template_width $render_cols $fixed_only)
    let reserved = if $sentinel { 1 } else { 0 }
    let available = if $term_cols == null {
      $cols | reduce --fold 0 {|col, acc| $acc + ($nat | get --optional $col | default 0)}
    } else {
      [($term_cols - $fixed_cost - $reserved) 0] | math max
    }

    let real_min_ws = (do $min_widths $cols)
    let total_nat = ($cols | reduce --fold 0 {|col, acc| $acc + ($nat | get --optional $col | default 0)})

    let protected_w = ($cols | reduce --fold 0 {|col, acc|
      let w = ($flat | get --optional $col | default {} | get weight? | default 0)
      if $w == 0 { $acc + ($nat | get --optional $col | default 0) } else { $acc }
    })

    let elastic_cols = ($cols | where {|col|
      ($flat | get --optional $col | default {} | get weight? | default 0) > 0
    })

    let elastic_budget = ([($available - $protected_w) 0] | math max)

    let total_weight = ($elastic_cols | reduce --fold 0 {|col, acc|
      $acc + ($flat | get --optional $col | default {} | get weight? | default 1)
    })

    let first_pass = ($elastic_cols | reduce --fold {budgets: {}, leftover: $elastic_budget} {|col, acc|
      let nat_w = ($nat | get --optional $col | default 0)
      let w = ($flat | get --optional $col | default {} | get weight? | default 1)
      let min_w = ($real_min_ws | get --optional $col | default 0)
      let share = if $total_weight > 0 { ($acc.leftover * $w) // $total_weight } else { $nat_w }
      let capped = ([$nat_w $share] | math min)
      let budget = ([$capped $min_w] | math max)
      let used = if $nat_w < $share { $nat_w } else { $share }
      let leftover = $acc.leftover - $used
      {budgets: ($acc.budgets | upsert $col $budget), leftover: $leftover}
    })

    let remaining_leftover = $first_pass.leftover
    let first_budgets = $first_pass.budgets

    let undersized = ($elastic_cols | where {|col|
      let nat_w = ($nat | get --optional $col | default 0)
      let budget = ($first_budgets | get --optional $col | default 0)
      $budget < $nat_w
    })

    let second_budgets = if $remaining_leftover > 0 and ($undersized | length) > 0 {
      let redist_weight = ($undersized | reduce --fold 0 {|col, acc|
        $acc + ($flat | get --optional $col | default {} | get weight? | default 1)
      })
      $undersized | reduce --fold $first_budgets {|col, acc_b|
        let nat_w = ($nat | get --optional $col | default 0)
        let w = ($flat | get --optional $col | default {} | get weight? | default 1)
        let min_w = ($real_min_ws | get --optional $col | default 0)
        let extra = if $redist_weight > 0 { ($remaining_leftover * $w) // $redist_weight } else { 0 }
        let current = ($acc_b | get --optional $col | default 0)
        let capped = ([$nat_w ($current + $extra)] | math min)
        let new_budget = ([$capped $min_w] | math max)
        $acc_b | upsert $col $new_budget
      }
    } else {
      $first_budgets
    }

    let case2 = ($cols | reduce --fold {} {|col, acc|
      let w = ($flat | get --optional $col | default {} | get weight? | default 0)
      let budget = if $w == 0 {
        $nat | get --optional $col | default 0
      } else {
        $second_budgets | get --optional $col | default 0
      }
      $acc | upsert $col $budget
    })
    let case2_all = if $sentinel { $case2 | upsert $sentinel_col 1 } else { $case2 }

    if (do $fits $render_cols $case2_all) {
      return $case2_all
    }

    let case3 = ($cols | reduce --fold {} {|col, acc|
      let nat_w = ($nat | get --optional $col | default 0)
      let min_w = ($real_min_ws | get --optional $col | default 0)
      let budget = if $total_nat > 0 {
        [($available * $nat_w // $total_nat) $min_w] | math max
      } else {
        $min_w
      }
      $acc | upsert $col $budget
    })
    if $sentinel { $case3 | upsert $sentinel_col 1 } else { $case3 }
  }

  let initial_budgets = (do $allocate $col_order false)
  if (do $fits $col_order $initial_budgets) {
    return {columns: $col_order, budgets: $initial_budgets, sacrificed: [], sentinel: false}
  }

  # Case 4: whole-column sacrifice. Droppable columns go first by ascending
  # weight, then narrowest natural width; protected columns are considered last.
  let sacrifice_order = ($col_order | enumerate | each {|item|
    let col = $item.item
    let weight = ($flat | get --optional $col | default {} | get weight? | default 0)
    let protected = if $weight == 0 { 1 } else { 0 }
    {col: $col, protected: $protected, weight: $weight, width: ($nat | get --optional $col | default 0), index: $item.index}
  } | sort-by protected weight width index | each {|item| $item.col})

  $sacrifice_order | reduce --fold {columns: $col_order, budgets: $initial_budgets, sacrificed: [], sentinel: false, done: false} {|col, acc|
    if $acc.done {
      $acc
    } else {
      let sacrificed = ($acc.sacrificed | append $col)
      let remaining = ($col_order | where {|c| not ($c in $sacrificed)})
      let budgets = (do $allocate $remaining true)
      let render_cols = (do $with_sentinel $remaining)
      let did_fit = (do $fits $render_cols $budgets)
      {columns: $render_cols, budgets: $budgets, sacrificed: $sacrificed, sentinel: true, done: $did_fit}
    }
  } | reject done
}


# ── Validation ────────────────────────────────────────────────────────────────

# Validate a single field-node.
# v required; q ∈ {"visual","text"} or absent — on ALL field-nodes regardless of k presence.
def validate-field-node [field: record] {
  let q = ($field | get q? | default null)
  let k = ($field | get k? | default null)

  # k must be string when present
  if $k != null and ($k | describe) != "string" {
    error make {msg: "render walk: field-node k must be a string"}
  }

  # v is required (may be null — null v is allowed; the key must exist)
  # We check that v key exists by seeing if describe doesn't panic, which it won't.
  # Actually in Nu, if a key is absent `get k?` returns null too. We accept null v.

  if $q != null {
    if $q not-in ["visual" "text"] {
      error make {msg: $"render walk: invalid field-node qualifier '($q)'"}
    }
  }
}

# Validate a node record recursively.
# Errors on unknown node keys, invalid _flat keys, invalid field-nodes.
def validate-node [node: record] {
  let node_cols = ($node | columns)
  let allowed_node_keys = ["_fields" "_children" "_flat"]
  for nk in $node_cols {
    if not ($nk in $allowed_node_keys) {
      error make {msg: $"render walk: unknown node key '($nk)'; only _fields, _children, _flat are permitted"}
    }
  }

  # Validate _flat if present
  if "_flat" in $node_cols {
    let flat_rec = ($node | get _flat)
    if $flat_rec != null {
      let flat_cols = ($flat_rec | columns)
      # Build the set of keyed field-node names in this node's _fields
      let keyed_field_names = ($node | get --optional "_fields" | default [] | where {|f| ($f | get k? | default null) != null} | each {|f| $f.k})
      for fk in $flat_cols {
        if not ($fk in $keyed_field_names) {
          error make {msg: $"render walk: unknown _flat key '($fk)'"}
        }
        let policy = ($flat_rec | get $fk)
        if ($policy | describe) == "record" {
          let justify = ($policy | get justify? | default null)
          if $justify != null and $justify not-in ["left" "right" "center"] {
            error make {msg: $"render walk: column policy justify must be left | right | center, got '($justify)'"}
          }
        }
      }
    }
  }

  # Validate field-nodes
  let fields = ($node | get --optional "_fields" | default [])
  for field in $fields {
    validate-field-node $field
  }

  # Recurse into children
  let children = ($node | get --optional "_children" | default [])
  for child in $children {
    validate-node $child
  }
}

# ── Visibility predicates ────────────────────────────────────────────────────

# visible_in_visual: q absent OR q == "visual"
def visible-in-visual [field: record] {
  let q = ($field | get q? | default null)
  $q == null or $q == "visual"
}

# visible_in_text: q absent OR q == "text"
def visible-in-text [field: record] {
  let q = ($field | get q? | default null)
  $q == null or $q == "text"
}

# emits_to_json: k present
def emits-to-json [field: record] {
  ($field | get k? | default null) != null
}

# ── v coercion helpers ───────────────────────────────────────────────────────

def is-format-value [v: any] {
  let desc = ($v | describe)
  if not ($desc | str starts-with "record") {
    return false
  }
  "_fmt" in ($v | columns)
}

def pick-format-value [v: any, format: any, stream: string] {
  if not (is-format-value $v) {
    return $v
  }
  let fmt = ($v | get _fmt)
  let exact = if $format == null { null } else { $fmt | get --optional $format | default null }
  if $exact != null {
    return $exact
  }
  let picked = match $stream {
    "visual" => { $fmt | get --optional visual | default ($fmt | get --optional text | default ($fmt | get --optional json | default "")) }
    "text" => { $fmt | get --optional text | default ($fmt | get --optional plain | default ($fmt | get --optional visual | default ($fmt | get --optional json | default ""))) }
    "json" => { $fmt | get --optional json | default ($fmt | get --optional text | default ($fmt | get --optional plain | default ($fmt | get --optional visual | default ""))) }
    _ => { $v }
  }
  $picked
}

# Coerce a field v to an rstr list for a byte stream.
def v-to-rstr-stream [v: any, stream: string, format: any = null] {
  let v = (pick-format-value $v $format $stream)
  if $v == null {
    null
  } else {
    let desc = ($v | describe)
    if ($desc | str starts-with "list") or ($desc | str starts-with "table") {
      $v
    } else {
      [{t: ($v | into string)}]
    }
  }
}

# Coerce a field v to an rstr list.
def v-to-rstr [v: any] {
  v-to-rstr-stream $v "visual" "rich"
}

# Coerce a field v for JSON output.
# Native scalars preserved; rstr rendered as plain text via rstr flatten false.
def v-to-json [v: any] {
  let v = (pick-format-value $v "json" "json")
  if $v == null {
    null
  } else {
    let desc = ($v | describe)
    if ($desc | str starts-with "list") or ($desc | str starts-with "table") {
      $v | rstr flatten false
    } else {
      $v
    }
  }
}

# ── DFS traversal (envelope collector) ────────────────────────────────────────

# Traverse a node DFS pre-order, collecting envelopes.
# Envelope: {flat: record|null, scope_gid: int, rope: node}
# Returns {envs: list, next_gid: int}
def walk-traverse [
  node: record
  inherited_flat: any = null
  inherited_gid: int = -1
  next_gid: int = 0
] {
  let node_cols = ($node | columns)
  let has_flat = ("_flat" in $node_cols)
  let node_flat_raw = if $has_flat { $node | get _flat } else { null }
  let children = ($node | get --optional "_children" | default [])

  if $has_flat {
    let my_gid = $next_gid
    let next_for_children = ($next_gid + 1)
    let my_envelope = {flat: $node_flat_raw, scope_gid: $my_gid, rope: $node}
    let child_result = ($children | reduce --fold {envs: [], next_gid: $next_for_children} {|child, acc|
      let result = (walk-traverse $child $node_flat_raw $my_gid $acc.next_gid)
      {envs: ($acc.envs ++ $result.envs), next_gid: $result.next_gid}
    })
    {envs: ([$my_envelope] ++ $child_result.envs), next_gid: $child_result.next_gid}
  } else {
    let my_envelope = {flat: $inherited_flat, scope_gid: $inherited_gid, rope: $node}
    let child_result = ($children | reduce --fold {envs: [], next_gid: $next_gid} {|child, acc|
      let result = (walk-traverse $child $inherited_flat $inherited_gid $acc.next_gid)
      {envs: ($acc.envs ++ $result.envs), next_gid: $result.next_gid}
    })
    {envs: ([$my_envelope] ++ $child_result.envs), next_gid: $child_result.next_gid}
  }
}

# ── emit-bytes ────────────────────────────────────────────────────────────────

# Emit visible bytes for one node: walks _fields using appropriate visibility predicate,
# then descends _children. Used for tree-mode rendering in both visual and text streams.
# stream: "visual" | "text"
# Returns a list of string parts (to be joined by the caller).
def emit-bytes-node [node: record, stream: string, format: string, color: bool] {
  let fields = ($node | get --optional "_fields" | default [])
  let parts = ($fields | each {|field|
    let visible = if $stream == "visual" {
      visible-in-visual $field
    } else {
      visible-in-text $field
    }
    if not $visible { null } else {
      let v = ($field | get v? | default null)
      if $v == null { null } else {
        let rstr_val = (v-to-rstr-stream $v $stream $format)
        $rstr_val | rstr flatten $color
      }
    }
  } | where {|p| $p != null})
  $parts | str join ""
}

# Collect DFS-ordered lines from a tree-mode rope using the given byte stream.
# Returns list<string> (one line per node).
def emit-bytes-tree [node: record, stream: string, format: string, color: bool] {
  let line = (emit-bytes-node $node $stream $format $color)
  let children = ($node | get --optional "_children" | default [])
  let child_lines = ($children | each {|child| emit-bytes-tree $child $stream $format $color} | flatten)
  if ($line | str length) > 0 {
    [$line] ++ $child_lines
  } else {
    $child_lines
  }
}

# ── emit-json ────────────────────────────────────────────────────────────────

# Recursively produce JSON for a rope node.
# Returns {mode: "flat"|"default"|"transparent", val: list|record}
def emit-json-node [node: record] {
  let has_flat = ("_flat" in ($node | columns))
  let fields_list = ($node | get --optional "_fields" | default [])
  let keyed = ($fields_list | where {|f| emits-to-json $f})
  let obj = ($keyed | reduce --fold {} {|f acc|
    let v = ($f | get v? | default null)
    $acc | upsert $f.k (v-to-json $v)
  })
  let children_raw = ($node | get --optional "_children" | default [])

  if $has_flat {
    let child_rows = ($children_raw | reduce --fold [] {|child acc|
      let cr = (emit-json-node $child)
      if $cr.mode == "flat" {
        $acc ++ $cr.val
      } else if $cr.mode == "transparent" {
        $acc ++ $cr.val
      } else {
        $acc ++ [$cr.val]
      }
    })
    {mode: "flat", val: ([$obj] ++ $child_rows)}
  } else {
    let obj_is_empty = (($obj | columns | length) == 0)
    let child_items = ($children_raw | reduce --fold [] {|child acc|
      let cr = (emit-json-node $child)
      if $cr.mode == "flat" {
        $acc ++ [$cr.val]
      } else if $cr.mode == "transparent" {
        $acc ++ $cr.val
      } else {
        $acc ++ [$cr.val]
      }
    })
    if $obj_is_empty and ($child_items | length) > 0 {
      {mode: "transparent", val: $child_items}
    } else {
      let result = if ($child_items | length) > 0 {
        $obj | upsert children $child_items
      } else {
        $obj
      }
      {mode: "default", val: $result}
    }
  }
}

# ── Visual-class flat-mode emitter ────────────────────────────────────────────

# Render all flat-scope envelopes as a bordered or space-aligned table.
# Returns a list<string> of lines.
def emit-flat-visual [envelopes: list, flat_raw: any, caps: record, term_cols: any, format: string] {
  let color = $caps.color
  let borders = $caps.borders
  let sentinel_col = "__render_sentinel"

  # Pass 1: resolve every visible kv cell for the selected visual format, then
  # build measured row templates. The budgeting pass sees fixed fragments plus
  # column slots for the actual output shape, not a format-specific formula.
  let pass1 = ($envelopes | reduce --fold {order: [], widths: {}, seen: {}, rows: []} {|evp, acc|
    let node = $evp.rope
    let fields_list = ($node | get --optional "_fields" | default [])
    let vis_fields = ($fields_list | where {|f| visible-in-visual $f})
    let keyed = ($vis_fields | where {|f| ($f | get k? | default null) != null})
    let row_acc = ($keyed | reduce --fold {order: $acc.order, widths: $acc.widths, seen: $acc.seen, cells: {}} {|f, inner|
      let k = $f.k
      let v = ($f | get v? | default null)
      let rstr_val = (v-to-rstr-stream $v "visual" $format | default [])
      let cell_len = ($rstr_val | rstr len)
      let not_seen = ($inner.seen | get --optional $k | default null) == null
      let new_order = if $not_seen { $inner.order | append $k } else { $inner.order }
      let key_len = if $not_seen { $k | rstr display-len } else { $inner.seen | get $k }
      let new_seen = if $not_seen { $inner.seen | upsert $k $key_len } else { $inner.seen }
      let existing_w = ($inner.widths | get --optional $k | default 0)
      let new_w = [$existing_w $cell_len $key_len] | math max
      let new_widths = ($inner.widths | upsert $k $new_w)
      let policy = ($flat_raw | get --optional $k | default {})
      let justify = ($policy | get justify? | default "left")
      let clip = ($policy | get clip? | default "none")
      let new_cells = if $v == null {
        $inner.cells
      } else {
        $inner.cells | upsert $k {rstr: $rstr_val, width: $cell_len, justify: $justify, clip: $clip}
      }
      {order: $new_order, widths: $new_widths, seen: $new_seen, cells: $new_cells}
    })
    {order: $row_acc.order, widths: $row_acc.widths, seen: $row_acc.seen, rows: ($acc.rows | append {kind: "data", cells: $row_acc.cells})}
  })

  let col_order = $pass1.order
  let nat_widths = $pass1.widths

  if ($col_order | is-empty) {
    return []
  }

  let template_rows = if $borders {
    [{kind: "rule", left: "╭", sep: "┬", right: "╮"}, {kind: "header"}, {kind: "rule", left: "├", sep: "┼", right: "┤"}] ++ $pass1.rows ++ [{kind: "rule", left: "╰", sep: "┴", right: "╯"}]
  } else {
    [{kind: "header"}] ++ $pass1.rows
  }
  let templates = {borders: $borders, rows: $template_rows}

  let plan = (col-budgets $flat_raw $nat_widths $col_order $term_cols $templates)
  let render_cols = $plan.columns
  let budgets = $plan.budgets
  let data_rows = $pass1.rows

  let render_rule = {|left, sep, right|
    let segs = ($render_cols | each {|k|
      let w = ($budgets | get --optional $k | default 0)
      0..<($w + 2) | each {|_| "─"} | str join ""
    })
    $"($left)($segs | str join $sep)($right)"
  }

  let render_header_cell = {|k|
    let w = ($budgets | get --optional $k | default 0)
    let label = if $k == $sentinel_col { "…" } else { $k }
    if $color and $k != $sentinel_col {
      let rval = ($label | rstr of | rstr tag "key")
      let filled = ($rval | rstr fill $w "left")
      $filled | rstr flatten $color
    } else {
      $label | fill -w $w -a l
    }
  }

  let render_data_cell = {|row, k|
    let w = ($budgets | get --optional $k | default 0)
    if $k == $sentinel_col {
      "" | fill -w $w -a l
    } else {
      let cell = ($row.cells | get --optional $k | default null)
      if $cell == null {
        "" | fill -w $w -a l
      } else {
        let filled = ($cell.rstr | rstr fill $w $cell.justify)
        let trimmed = if $cell.clip == "rhs" {
          $filled | rstr trim $w
        } else if $cell.clip == "lhs" {
          $filled | rstr trim-lhs $w
        } else {
          $filled
        }
        $trimmed | rstr flatten $color
      }
    }
  }

  mut lines: list<string> = []
  if $borders {
    $lines = ($lines | append (do $render_rule "╭" "┬" "╮"))
    let hdr_cells = ($render_cols | each {|k| $" ((do $render_header_cell $k)) "})
    $lines = ($lines | append $"│($hdr_cells | str join '│')│")
    $lines = ($lines | append (do $render_rule "├" "┼" "┤"))

    for row in $data_rows {
      let row_cells = ($render_cols | each {|k| $" ((do $render_data_cell $row $k)) "})
      $lines = ($lines | append $"│($row_cells | str join '│')│")
    }

    $lines = ($lines | append (do $render_rule "╰" "┴" "╯"))
  } else {
    let hdr_cells = ($render_cols | each {|k| do $render_header_cell $k})
    $lines = ($lines | append ($hdr_cells | str join "  " | str trim -r))
    $lines = ($lines | append "")

    for row in $data_rows {
      let row_cells = ($render_cols | each {|k| do $render_data_cell $row $k})
      $lines = ($lines | append ($row_cells | str join "  " | str trim -r))
    }
  }

  $lines
}


# ── Text flat-mode emitter ────────────────────────────────────────────────────

# Render all flat-scope envelopes as a borderless aligned text table.
# Returns a list<string> of lines.
def emit-flat-text [envelopes: list, flat_raw: any] {
  # Pass 1: natural widths (no TTY consultation)
  let pass1 = ($envelopes | reduce --fold {order: [], widths: {}, seen: {}} {|evp, acc|
    let node = $evp.rope
    let fields_list = ($node | get --optional "_fields" | default [])
    let vis_fields = ($fields_list | where {|f| visible-in-text $f})
    let keyed = ($vis_fields | where {|f| ($f | get k? | default null) != null})
    $keyed | reduce --fold $acc {|f inner|
      let k = $f.k
      let v = ($f | get v? | default null)
      let rstr_val = (v-to-rstr-stream $v "text" "text" | default [])
      let cell_plain = ($rstr_val | rstr flatten false)
      let cell_len = ($cell_plain | rstr display-len)
      let not_seen = ($inner.seen | get --optional $k | default null) == null
      let new_order = if $not_seen { $inner.order | append $k } else { $inner.order }
      let key_len = if $not_seen { $k | rstr display-len } else { $inner.seen | get $k }
      let new_seen = if $not_seen { $inner.seen | upsert $k $key_len } else { $inner.seen }
      let existing_w = ($inner.widths | get --optional $k | default 0)
      let new_w = [$existing_w $key_len $cell_len] | math max
      let new_widths = ($inner.widths | upsert $k $new_w)
      {order: $new_order, widths: $new_widths, seen: $new_seen}
    }
  })

  let col_order = $pass1.order
  let key_widths = $pass1.widths

  if ($col_order | is-empty) {
    return []
  }

  # Header row + blank separator
  let header = ($col_order | each {|k|
    let w = ($key_widths | get $k)
    let policy = ($flat_raw | get --optional $k | default {})
    let justify = ($policy | get justify? | default "left")
    let align_char = if $justify == "right" { "r" } else if $justify == "center" { "c" } else { "l" }
    $k | fill -w $w -a $align_char
  } | str join "  " | str trim -r)

  mut lines: list<string> = [$header, ""]

  # Data rows
  for evp in $envelopes {
    let node = $evp.rope
    let fields_list = ($node | get --optional "_fields" | default [])
    let vis_fields = ($fields_list | where {|f| visible-in-text $f})
    let row_parts = ($vis_fields | each {|field|
      let k = ($field | get k? | default null)
      let v = ($field | get v? | default null)
      if $k == null {
        # leaf: emit as plain text
        if $v == null { null } else {
          let rstr_val = (v-to-rstr-stream $v "text" "text" | default [])
          $rstr_val | rstr flatten false
        }
      } else {
        # kv: aligned column cell
        let val = if $v == null { "" } else {
          let rstr_val = (v-to-rstr-stream $v "text" "text" | default [])
          $rstr_val | rstr flatten false
        }
        let budget = ($key_widths | get --optional $k | default ($val | rstr display-len))
        let policy = ($flat_raw | get --optional $k | default {})
        let justify = ($policy | get justify? | default "left")
        let clip = ($policy | get clip? | default "none")
        let align_char = if $justify == "right" { "r" } else if $justify == "center" { "c" } else { "l" }
        let filled = ($val | fill -w $budget -a $align_char)
        if $clip == "rhs" and ($val | rstr display-len) > $budget {
          let cut_w = ([($budget - 1) 0] | math max)
          let cut = ($val | split chars | take $cut_w | str join)
          $"($cut)…" | fill -w $budget -a l
        } else if $clip == "lhs" and ($val | rstr display-len) > $budget {
          let keep_w = ([($budget - 1) 0] | math max)
          let chars = ($val | split chars)
          let total = ($chars | length)
          let keep = ($chars | skip ($total - $keep_w) | str join)
          $"…($keep)" | fill -w $budget -a l
        } else {
          $filled
        }
      }
    } | where {|p| $p != null})
    if ($row_parts | is-not-empty) {
      $lines = ($lines | append ($row_parts | str join "  " | str trim -r))
    }
  }

  $lines
}

# ── render walk (public entry point) ──────────────────────────────────────────

# Walk a rope and emit the requested format.
#
# Input:  exactly one rope (record with _fields, _children?, _flat? keys)
# Cfg:    {format: "rich" | "utf8" | "plain" | "text" | "json"}
#         format defaults to "rich" when TTY, "text" otherwise
#
# Output: string
export def walk [cfg: record = {}] {
  let input = $in

  # Validate cfg: must have at most key {format}
  let cfg_cols = ($cfg | columns)
  for ck in $cfg_cols {
    if $ck != "format" {
      error make {msg: $"render walk: unknown cfg key '($ck)'; cfg must contain only format"}
    }
  }

  # Reject non-record input
  let input_desc = ($input | describe)
  if not ($input_desc | str starts-with "record") {
    error make {msg: $"render walk requires a single rope record; received: ($input_desc)"}
  }

  # Validate format value when present (before calling render-env to give a clear error)
  let fmt_explicit = ($cfg | get format? | default null)
  if $fmt_explicit != null and $fmt_explicit not-in ["rich" "utf8" "plain" "text" "json"] {
    error make {msg: $"render walk: unknown format '($fmt_explicit)' — expected rich | utf8 | plain | text | json"}
  }

  # Validate the rope recursively
  validate-node $input

  # Resolve environment (render-env is the sole site of tui-is-tty / tui-columns;
  # default-format selection also lives there)
  let renv = (render-env $cfg)
  let caps = $renv.caps
  let fmt = $renv.format
  let term_cols = $renv.cols

  match $fmt {
    "json" => {
      let json_result = (emit-json-node $input)
      if $json_result.mode == "flat" {
        $json_result.val | to json
      } else if $json_result.mode == "transparent" {
        $json_result.val | to json
      } else {
        [$json_result.val] | to json
      }
    }
    "text" => {
      # Text format: tree mode uses visible_in_text; flat mode uses borderless table at natural widths
      let traverse_result = (walk-traverse $input null -1 0)
      let envelopes = $traverse_result.envs

      # Collect unique scope_gids for flat groups
      let flat_gids = ($envelopes | where {|evp| $evp.scope_gid >= 0} | each {|evp| $evp.scope_gid} | uniq)

      # Pre-compute group metadata (pass1 only — text uses natural widths)
      let group_meta = ($flat_gids | reduce --fold {} {|gid acc|
        let group_evps = ($envelopes | where {|evp| $evp.scope_gid == $gid})
        let first_evp = ($group_evps | first)
        let grp_flat = ($first_evp | get flat? | default null)
        let flat_lines = (emit-flat-text $group_evps $grp_flat)
        $acc | upsert ($gid | into string) {flat_lines: $flat_lines, emitted: false}
      })

      mut grp_meta = $group_meta
      mut text_lines: list<string> = []

      for evp in $envelopes {
        let gid = $evp.scope_gid
        if $gid < 0 {
          # Tree mode: emit visible_in_text fields verbatim
          let line = (emit-bytes-node $evp.rope "text" "text" false)
          if ($line | str trim) != "" {
            $text_lines = ($text_lines | append ($line | str trim -r))
          }
        } else {
          let gid_str = ($gid | into string)
          let meta = ($grp_meta | get $gid_str)
          if not $meta.emitted {
            $text_lines = ($text_lines ++ $meta.flat_lines)
            $grp_meta = ($grp_meta | upsert $gid_str ($meta | upsert emitted true))
          }
        }
      }
      $text_lines | str join "\n"
    }
    _ => {
      # Visual formats: rich / utf8 / plain
      let traverse_result = (walk-traverse $input null -1 0)
      let envelopes = $traverse_result.envs

      let flat_gids = ($envelopes | where {|evp| $evp.scope_gid >= 0} | each {|evp| $evp.scope_gid} | uniq)

      let group_meta = ($flat_gids | reduce --fold {} {|gid acc|
        let group_evps = ($envelopes | where {|evp| $evp.scope_gid == $gid})
        let first_evp = ($group_evps | first)
        let grp_flat = ($first_evp | get flat? | default null)
        let flat_lines = (emit-flat-visual $group_evps $grp_flat $caps $term_cols $fmt)
        $acc | upsert ($gid | into string) {flat_lines: $flat_lines, emitted: false}
      })

      mut grp_meta = $group_meta
      mut visual_lines: list<string> = []

      for evp in $envelopes {
        let gid = $evp.scope_gid
        if $gid < 0 {
          let line = (emit-bytes-node $evp.rope "visual" $fmt $caps.color)
          if ($line | str length) > 0 {
            $visual_lines = ($visual_lines | append $line)
          }
        } else {
          let gid_str = ($gid | into string)
          let meta = ($grp_meta | get $gid_str)
          if not $meta.emitted {
            $visual_lines = ($visual_lines ++ $meta.flat_lines)
            $grp_meta = ($grp_meta | upsert $gid_str ($meta | upsert emitted true))
          }
        }
      }
      $visual_lines | str join "\n"
    }
  }
}
