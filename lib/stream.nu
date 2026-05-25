# stream.nu — live streaming display subsystem
#
# Public surface: stream open / step / close / finalize
#
# stream open    — initialise a stream state from cfg and channel declarations
# stream step    — route one event into the live display (label / tail / flat / tree / log)
# stream close   — close a stream opened by stream open; flush scrollback
# stream finalize — legacy close; clear live block and print full archive table
#
# Channel kinds: label | tail | flat | tree | log
#   label  — named label update; value appears in a TUI label panel or printed as "[name]  value"
#   tail   — streaming rows accumulated in an archive; displayed live in a TUI tail panel
#   flat   — full panel replacement; rows formatted as aligned lines in a TUI flat panel
#   tree   — recursive tree structure; rendered rich or indented text in a TUI panel
#   log    — append-only log entries; routed to TUI log panel or stderr
#
# Depends on: tui.nu (terminal mechanics), styles.nu (style table), rstr.nu (rich-string ops),
#             log.nu (log helpers)

use ./tui.nu *
use ./styles.nu *
use ./rstr.nu *
use ./log.nu *

# ── Private helpers ───────────────────────────────────────────────────────────

# Resolve format and color mode from cfg.
# Returns {format: string, color: bool}.
#   format: rich | text | json | jsonl — passed through unchanged; callers handle TTY concerns
#   color:  true when format is rich AND stdout is a TTY AND NO_COLOR is unset
def effective-format [cfg: record] {
  let out = ($cfg | get output? | default {})
  let fmt = ($out | get format? | default ($cfg | get format? | default "rich"))
  let no_color = ($env | get NO_COLOR? | default null)
  let color = $fmt == "rich" and $no_color == null and (tui-is-tty)
  {format: $fmt, color: $color}
}

def render-apply [name: string, text: string] {
  if not (styles has $name) { return $text }
  tui-atoms (styles get $name) $text
}

# Recursively render one rstr-node to a plain string, applying ANSI styles when color is true.
def rstr-node-to-ansi [node: record, color: bool] {
  if ($node | get t?) != null {
    $node.t
  } else {
    let joined = ($node.c | each {|child| rstr-node-to-ansi $child $color} | str join "")
    if $color and (styles has $node.r) {
      tui-atoms (styles get $node.r) $joined
    } else {
      $joined
    }
  }
}

# Render a cell value to a plain or styled string.
# Accepts a plain string or wire-format rstr (`«name»text«/»` spans).
# When color: true — apply tui-atoms for known style names; strip unknown tags.
# When color: false — strip all markup tags and return plain text.
def render-markup [color: bool] {
  let v = $in
  let s = ($v | into string)
  let nodes = ($s | rstr from-str)
  $nodes | each {|node| rstr-node-to-ansi $node $color} | str join ""
}

# Render a list of rows as aligned columns; returns list<string> of lines.
# format: "rich" → UTF-8 bordered table (╭─┬─╮ / ├─┼─┤ / ╰─┴─╯)
# format: "text" → borderless whitespace-aligned
# Width computation always uses render-markup with color:false for accurate plain lengths.
def render-aligned-lines [cols: list, format: string, color: bool, min_widths: record = {}] {
  let data = $in
  if ($data | is-empty) { return [] }
  # compute per-column widths: max(header length, max plain cell length, min_widths floor)
  let widths = $cols | each {|col|
    let header_len = ($col | rstr display-len)
    let cell_max = ($data | each {|r|
      $r | get --optional $col | default "" | render-markup false | rstr display-len
    } | if ($in | is-empty) { [0] } else { $in } | math max)
    let floor = ($min_widths | get --optional $col | default 0)
    [$header_len $cell_max $floor] | math max
  }
  # TTY-bounded column widths: cap on real TTY
  let tty = (tui-is-tty)
  let widths = if $tty and $format == "rich" {
    let overhead = ($cols | length) * 3 + 1
    let total = ($widths | math sum) + $overhead
    let term_w = (tui-columns)
    if $term_w != null and $total > $term_w {
      let available = $term_w - $overhead
      let maxes = ($cols | zip $widths | reduce --fold {} {|p acc| $acc | upsert $p.0 $p.1 })
      let clamped = (tui-col-widths $maxes $cols $available)
      $cols | each {|col| $clamped | get $col }
    } else {
      $widths
    }
  } else {
    $widths
  }
  mut lines: list<string> = []
  if $format == "rich" {
    # ── bordered table ────────────────────────────────────────────────────────
    let top_parts = ($cols | zip $widths | each {|p| 0..<($p.1 + 2) | each {|_| "─"} | str join ""})
    let top    = $"╭($top_parts | str join '┬')╮"
    let sep    = $"├($top_parts | str join '┼')┤"
    let bot    = $"╰($top_parts | str join '┴')╯"
    # header — h1-styled when color is true
    let hdr_cells = ($cols | zip $widths | each {|p|
      let plain = ($p.0 | fill -w $p.1 -a l)
      let cell  = if $color { render-apply "key" $plain } else { $plain }
      $" ($cell) "
    })
    let hdr = $"│($hdr_cells | str join '│')│"
    $lines = ($lines | append $top)
    $lines = ($lines | append $hdr)
    $lines = ($lines | append $sep)
    # data rows
    for r in $data {
      let row_cells = ($cols | zip $widths | each {|p|
        let capped_w  = $p.1
        let plain     = ($r | get --optional $p.0 | default "" | render-markup false)
        let plain_len = ($plain | rstr display-len)
        let truncate  = $tty and $plain_len > $capped_w
        let styled = if $truncate {
          tui-truncate $plain $capped_w
        } else {
          $r | get --optional $p.0 | default "" | render-markup $color
        }
        let pad    = if $truncate { 0 } else { $capped_w - $plain_len }
        let spaces = (0..<$pad | each {|_| " "} | str join "")
        $" ($styled)($spaces) "
      })
      $lines = ($lines | append $"│($row_cells | str join '│')│")
    }
    $lines = ($lines | append $bot)
  } else {
    # ── borderless whitespace-aligned ─────────────────────────────────────────
    let header = ($cols | zip $widths | each {|p| $p.0 | fill -w $p.1 -a l} | str join "  ")
    $lines = ($lines | append $header)
    for r in $data {
      let row = ($cols | zip $widths | each {|p|
        let plain  = ($r | get --optional $p.0 | default "" | render-markup false)
        let styled = ($r | get --optional $p.0 | default "" | render-markup $color)
        let pad    = $p.1 - ($plain | rstr display-len)
        let spaces = (0..<$pad | each {|_| " "} | str join "")
        $"($styled)($spaces)"
      } | str join "  ")
      $lines = ($lines | append $row)
    }
  }
  $lines
}


# DEPRECATED: use `stream open` instead.
# Kept for internal compatibility; callers should migrate to stream open.
def fold-state [] {
  {slots: {archive: {rows: [], col_widths: {}}, progress: {labels: {}, active: null}, log: []}, tui: null, tty: (tui-is-tty)}
}

def get-cols [cfg: record, r: record] {
  let out      = ($cfg | get output? | default {})
  let cfg_cols = ($out | get cols? | default ($cfg | get cols? | default null))
  if $cfg_cols != null {
    $cfg_cols
  } else {
    $r | columns | where {|c| not ($c | str starts-with "_")}
  }
}

# ── Tree helpers ─────────────────────────────────────────────────────────────

def is-branch-node [] {
  let kind = ($in | describe)
  $kind =~ "^record"
}

def get-lit-node [key: string] {
  $in | transpose k v | where k == $key | if ($in | is-empty) { null } else { first | get v }
}

def render-tree-text [node: any, depth: int] {
  let prefix = (0..($depth - 1) | each {|_| "#"} | str join "")
  if ($node | is-branch-node) {
    let own_value = ($node | get-lit-node "")
    let children  = ($node | transpose k v | where k != "")
    let own_part  = if $own_value != null { $"($own_value)\n\n" } else { "" }
    let child_part = ($children | each {|row|
      if ($row.v | is-branch-node) {
        [$"($prefix) ($row.k)", (render-tree-text $row.v ($depth + 1))] | str join "\n"
      } else {
        $"($prefix) ($row.k)\n($row.v)"
      }
    } | str join "\n\n")
    $"($own_part)($child_part)"
  } else {
    $"($node)"
  }
}

def heading-style [depth: int] {
  let names = ["h1" "h2" "h3" "h4" "h5" "h6"]
  $names | get -o ([$depth 5] | math min)
}

def render-tree-rich [node: any, depth: int] {
  let prefix = (0..($depth - 1) | each {|_| "#"} | str join "")
  if ($node | is-branch-node) {
    let own_value = ($node | get-lit-node "")
    let children  = ($node | transpose k v | where k != "")
    let own_part  = if $own_value != null { $"($own_value)\n\n" } else { "" }
    let child_part = ($children | each {|row|
      let heading = (render-apply (heading-style ($depth - 1)) $"($prefix) ($row.k)")
      if ($row.v | is-branch-node) {
        [$heading, (render-tree-rich $row.v ($depth + 1))] | str join "\n"
      } else {
        $"($heading)\n($row.v)"
      }
    } | str join "\n\n")
    $"($own_part)($child_part)"
  } else {
    $"($node)"
  }
}

# ── Public ────────────────────────────────────────────────────────────────────

# Initialise a stream state from cfg and channel declarations.
# Channel record shape: {name: string, kind: string, height?: int}
#   kinds — label | tail | flat | tree | log
# Appends a default {name: "log", kind: "log"} channel when absent.
# When tui-is-tty and format is rich, initialises the TUI with panel declarations.
# Returns: {cfg, channels, is_tty: bool, col_maxes: {}, tui}
export def "stream open" [cfg: record, channels: list<record>] {
  let has_log = ($channels | any {|ch| $ch.name == "log"})
  let log_height = ($cfg | get log_height? | default 4)
  let channels = if $has_log {
    $channels
  } else {
    $channels | append {name: "log", kind: "log", height: $log_height}
  }
  let is_tty = (tui-is-tty)
  let fmt = ($cfg | get format? | default ($cfg | get output?.format? | default "rich"))
  let tui = if $is_tty and $fmt == "rich" {
    let panel_decls = ($channels | each {|ch|
      let base = {name: $ch.name, type: $ch.kind}
      if $ch.kind != "log" and ($ch | get height? | default null) != null {
        let display_h = if $ch.kind == "tail" { $ch.height + 4 } else { $ch.height }
        $base | upsert height $display_h
      } else {
        $base
      }
    })
    tui-init $panel_decls
  } else {
    null
  }
  {cfg: $cfg, channels: $channels, is_tty: $is_tty, col_maxes: {}, rows: {}, labels: {}, tui: $tui}
}

# Route one event: stream step <state-from-stream-open> <event>
# state must have {cfg, channels, is_tty, col_maxes, tui} from stream open.
# Dispatches by event._channel (required) and channel kind. Returns updated state.
#
# Channel routing:
#   label  — tui-label (rich+tty); print "[name]  value" (text); jsonl (json)
#   tail   — format row using state.col_maxes; tui-append (rich+tty); print (text); jsonl (json)
#   flat   — tui-set with event.rows formatted as lines (rich+tty); print rows (text); jsonl (json)
#   tree   — render-tree-rich/text; tui-set (rich+tty); indented lines (text); raw record jsonl (json)
#   log    — tui-append (rich+tty); print --stderr (text/json)
export def "stream step" [state: record, ...rest] {
  let rest_len = ($rest | length)

  if $rest_len != 1 {
    error make {msg: "render stream-step: requires exactly 2 arguments (state, event)"}
  }

  let event = ($rest | get 0)

  # Validate _channel present
  if "_channel" not-in ($event | columns) {
    error make {msg: "render stream-step: event missing required '_channel' field"}
  }
  let ch_name = ($event | get _channel)

  # Validate channel declared in state.channels
  let ch_matches = ($state.channels | where {|ch| $ch.name == $ch_name})
  if ($ch_matches | is-empty) {
    error make {msg: $"render stream-step: channel '($ch_name)' not declared in state.channels"}
  }
  let ch_record = ($ch_matches | first)
  let ch_kind = $ch_record.kind

  let cfg = $state.cfg
  let fmt = ($cfg | get format? | default ($cfg | get output?.format? | default "rich"))
  let is_rich_tty = ($state.is_tty and $fmt == "rich")

  # Dispatch by channel kind
  let state = match $ch_kind {
    "label" => {
      let name  = $ch_name
      let value = ($event | get value? | default "")
      let state = ($state | upsert labels ($state.labels | upsert $name $value))
      let state = if $is_rich_tty {
        let tui1 = (tui-label $state.tui $name $value)
        let tui2 = (tui-draw $tui1)
        $state | upsert tui $tui2
      } else { $state }
      match $fmt {
        "text" => { print $"[($name)]  ($value)" }
        "json" | "jsonl" => { print ($event | to json --raw) }
        _ => {}
      }
      $state
    }
    "tail" => {
      let clean = ($event | reject _channel)
      let cols  = ($clean | columns | where {|c| not ($c | str starts-with "_")})
      # Update col_maxes expand-only
      let col_maxes = $cols | reduce --fold $state.col_maxes {|col w|
        let len = ($clean | get --optional $col | default "" | render-markup false | rstr display-len)
        let cur = ($w | get --optional $col | default ($col | rstr display-len))
        $w | upsert $col ([$cur $len] | math max)
      }
      let state = ($state | upsert col_maxes $col_maxes)
      let ch_rows = (($state.rows | get -o $ch_name | default []) | append $clean)
      let state = ($state | upsert rows ($state.rows | upsert $ch_name $ch_rows))
      let state = if $is_rich_tty {
        let ch      = ($state.channels | where {|c| $c.name == $ch_name} | first)
        let visible = ($ch_rows | last ($ch | get height? | default 8))
        let lines   = ($visible | render-aligned-lines $cols "rich" true $col_maxes)
        let tui1    = (tui-set $state.tui $ch_name $lines)
        let tui2    = (tui-draw $tui1)
        $state | upsert tui $tui2
      } else { $state }
      match $fmt {
        "text" => {
          let row_str = ($cols | each {|col|
            $clean | get --optional $col | default "" | into string
          } | str join "  ")
          print $"[($ch_name)]  ($row_str)"
        }
        "json" | "jsonl" => { print ($event | to json --raw) }
        _ => {}
      }
      $state
    }
    "flat" => {
      let rows = ($event | get rows? | default [])
      let state = if $is_rich_tty {
        let lines = if ($rows | is-not-empty) {
          let cols = ($rows | first | columns | where {|c| not ($c | str starts-with "_")})
          $rows | render-aligned-lines $cols $fmt true {}
        } else { [] }
        let tui1 = (tui-set $state.tui $ch_name $lines)
        let tui2 = (tui-draw $tui1)
        $state | upsert tui $tui2
      } else { $state }
      match $fmt {
        "text" => {
          if ($rows | is-not-empty) {
            let cols = ($rows | first | columns | where {|c| not ($c | str starts-with "_")})
            $rows | render-aligned $cols $fmt false
          }
        }
        "json" | "jsonl" => { print ($event | to json --raw) }
        _ => {}
      }
      $state
    }
    "tree" => {
      let node = ($event | get node? | default ($event | reject _channel))
      let state = if $is_rich_tty {
        let text = (render-tree-rich $node 1)
        let tui1 = (tui-set $state.tui $ch_name [$text])
        let tui2 = (tui-draw $tui1)
        $state | upsert tui $tui2
      } else { $state }
      match $fmt {
        "text" => { print (render-tree-text $node 1) }
        "rich" => { if not $is_rich_tty { print (render-tree-text $node 1) } }
        "json" | "jsonl" => { print ($node | to json --raw) }
        _ => {}
      }
      $state
    }
    "log" => {
      let lvl  = ($event | get level? | default "debug")
      let text = ($event | get text?  | default ($event | reject _channel | to nuon))
      let state = if $is_rich_tty {
        let tui1 = (tui-append $state.tui $ch_name $"[($lvl)] ($text)")
        let tui2 = (tui-draw $tui1)
        $state | upsert tui $tui2
      } else {
        print --stderr $"[($lvl)] ($text)"
        $state
      }
      $state
    }
    _ => {
      error make {msg: $"render stream-step: unknown channel kind '($ch_kind)' for channel '($ch_name)'"}
    }
  }

  $state
}

# Close a stream opened by stream open.
# Takes new-style state {cfg, channels, is_tty, col_maxes, tui}.
#
# Per-kind closure behaviour:
#   label — skip (labels are ephemeral; not included in scrollback)
#   tail  — collect panel content lines as scrollback
#   flat  — collect panel content lines as scrollback
#   tree  — collect panel content lines as scrollback
#   log   — print each entry to stderr
#
# If rich+tty: call tui-close with collected scrollback lines (erases live block, prints linearly).
# If text/json: output was already live-emitted; just flush log entries to stderr.
export def "stream close" [state: record] {
  let cfg = $state.cfg
  let fmt = ($cfg | get format? | default ($cfg | get output?.format? | default "rich"))
  let is_rich_tty = ($state.is_tty and $fmt == "rich")
  let is_rich     = ($fmt == "rich")

  # Collect log entries from tui panel (rich+tty path)
  mut log_entries = []
  for ch in $state.channels {
    if $ch.kind == "log" and $is_rich_tty and $state.tui != null {
      let panel = ($state.tui.panels | where {|p| $p.name == $ch.name} | first | default null)
      if $panel != null {
        for line in $panel.content {
          $log_entries = ($log_entries | append $line)
        }
      }
    }
  }

  if $is_rich {
    # Render all accumulated tail-channel rows as a single bordered table
    let all_rows  = ($state | get rows? | default {} | values | flatten)
    let cfg_cols  = ($cfg | get output? | default {} | get cols? | default null)
    let color     = $is_rich_tty
    let table_lines = if ($all_rows | is-not-empty) {
      let cols = if $cfg_cols != null { $cfg_cols } else {
        $all_rows | first | columns | where {|c| not ($c | str starts-with "_")}
      }
      $all_rows | render-aligned-lines $cols "rich" $color $state.col_maxes
    } else { [] }

    # Last label values — progress summary printed after the table
    let label_lines = ($state | get labels? | default {} | values)

    if $is_rich_tty and $state.tui != null {
      for entry in $log_entries { print --stderr $entry }
      tui-close $state.tui ($table_lines | append $label_lines)
    } else {
      for line in $table_lines { print $line }
      for line in $label_lines { print $line }
    }
  } else {
    # text/json: output was already live-emitted during stream-step
    for entry in $log_entries { print --stderr $entry }
  }
}

# Clear live block; print full archive table.
# Format dispatch (cfg.output.format or cfg.format):
#   rich  — close the TUI (tui-close), then render accumulated rows via render-aligned-lines
#   text  — no-op (rows were already emitted live during stream-step)
#   json  — no-op (records were already emitted as jsonl during stream-step)
export def "stream finalize" [cfg: record, acc: record] {
  match (effective-format $cfg).format {
    "rich" => {
      let rs   = ($acc | get _render? | default (fold-state))
      if $rs.tui != null { tui-close $rs.tui [] }
      if ($rs.slots.log | is-not-empty) {
        $rs.slots.log | each {|e| print --stderr $"[($e.level)] ($e.text)"} | ignore
      }
      if ($rs.slots.archive.rows | is-not-empty) {
        let cols = get-cols $cfg ($rs.slots.archive.rows | first)
        $rs.slots.archive.rows | render-aligned-lines $cols "rich" $rs.tty $rs.slots.archive.col_widths | each { print $in } | ignore
      }
    }
    _ => {}
  }
}
