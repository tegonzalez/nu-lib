# tui.nu — terminal mechanics module
# Pure ANSI primitives: escape application, cursor movement, panel drawing.
# No semantic knowledge of styles, roles, or document structure.
# Callers (render.nu) own all style→attribute mappings.
#
# Consumer surface (closed-world): tui-is-tty, tui-columns, tui-init, tui-set,
# tui-append, tui-label, tui-draw, tui-close, tui-ansi, tui-truncate,
# tui-col-widths. tui-is-tty and tui-columns are the ONLY functions in nu-lib
# that query terminal/TTY state — they are consumed exclusively by render.nu's
# render-env. Tools never call tui directly. tui-is-tty honors FORCE_TTY=1 to
# enable TTY-path rendering when stdout would otherwise be captured.
#
# Panel record shape:
#   {
#     name:    string          # identity key
#     content: record          # {type: "lines", data: list<string>}
#                              # OR {type: "styled", data: list<list<{text: string, style?: string}>>}
#     height:  int | null      # null = content-driven; int = minimum lines (pads with blank lines)
#   }
#
# Tui state record (opaque to caller):
#   {prev: int}   # total lines drawn in last block; used for erase
#
# API:
#   tui-init  []                                    -> record
#   tui-draw  [state: record, panels: list<record>] -> record
#   tui-close [state: record, lines: list<string>]
#   tui-ansi  [attrs: record, text: string]         -> string

# Initialise tui state; no draw.
# When called with no args (or empty list), returns the legacy {prev: 0} state.
# When called with panel declarations, builds a richer state with panels and width.
# Panel declaration shape: {name: string, type: string, height?: int}
#   type: "flat" | "tail" | "label"
export def tui-init [decls?: list<record>] {
  let panel_list = ($decls | default [])
  if ($panel_list | is-empty) {
    {prev: 0}
  } else {
    let w = (tui-columns)
    let built = ($panel_list | each {|p|
      let base = {
        name: $p.name
        type: $p.type
        content: []
        rendered_lines: 0
        screen_lines: 0
        dirty: false
      }
      if ($p | get height? | default null) != null {
        $base | upsert height $p.height
      } else {
        $base
      }
    })
    {prev: 0, width: $w, panels: $built}
  }
}

# Update a flat panel's content; replace entirely; mark dirty.
# Errors when name is not found.
export def tui-set [state: record, name: string, lines: list<string>] {
  let idx = ($state.panels | enumerate | where {|e| $e.item.name == $name} | get index? | first | default null)
  if $idx == null {
    error make {msg: $"tui-set: unknown panel '($name)'"}
  }
  let updated = ($state.panels | enumerate | each {|e|
    if $e.item.name == $name {
      $e.item | upsert content $lines | upsert dirty true
    } else {
      $e.item
    }
  })
  $state | upsert panels $updated
}

# Append a line to a tail panel; trim ring to panel height; mark dirty.
# Errors when name is not found.
export def tui-append [state: record, name: string, line: string] {
  let panel = ($state.panels | where {|p| $p.name == $name} | first | default null)
  if $panel == null {
    error make {msg: $"tui-append: unknown panel '($name)'"}
  }
  let new_content = ($panel.content | append $line)
  let height = ($panel | get height? | default null)
  let trimmed = if $height != null and ($new_content | length) > $height {
    $new_content | last $height
  } else {
    $new_content
  }
  let updated = ($state.panels | each {|p|
    if $p.name == $name {
      $p | upsert content $trimmed | upsert dirty true
    } else {
      $p
    }
  })
  $state | upsert panels $updated
}

# Set a label panel's content to [value]; mark dirty.
# Errors when name is not found.
export def tui-label [state: record, name: string, value: string] {
  let idx = ($state.panels | where {|p| $p.name == $name} | first | default null)
  if $idx == null {
    error make {msg: $"tui-label: unknown panel '($name)'"}
  }
  let updated = ($state.panels | each {|p|
    if $p.name == $name {
      $p | upsert content [$value] | upsert dirty true
    } else {
      $p
    }
  })
  $state | upsert panels $updated
}

# Erase previous block, draw all panels top-to-bottom, return new state.
# Uses dirty-flag partial erase when state.panels exists.
export def tui-draw [state: record] {
  if ($state | get -o panels | default [] | is-not-empty) {
    # ── New single-arg dirty-flag path ───────────────────────────────────────
    let state_panels = $state.panels

    # Tail fast-path: only the last panel is dirty, it's a tail panel, grew by 1, below capacity
    let last_idx = (($state_panels | length) - 1)
    let last_panel = ($state_panels | last)
    let others_clean = if $last_idx == 0 { true } else { $state_panels | slice 0..<$last_idx | all {|p| not $p.dirty } }
    let last_dirty = $last_panel.dirty
    let content_len = ($last_panel.content | length)
    let prev_rendered = $last_panel.rendered_lines
    let height = ($last_panel | get height? | default null)
    let below_capacity = if $height != null { $content_len <= $height } else { true }
    let grew_by_one = ($content_len == ($prev_rendered + 1))
    let is_tail = ($last_panel.type == "tail")

    if $last_dirty and $others_clean and $is_tail and $grew_by_one and $below_capacity {
      # Fast-path: just print the new line, no erase
      let new_line = ($last_panel.content | last)
      print $new_line
      let updated_panels = ($state_panels | enumerate | each {|e|
        if $e.index == $last_idx {
          $e.item | upsert rendered_lines $content_len | upsert screen_lines ($e.item.screen_lines + 1) | upsert dirty false
        } else {
          $e.item
        }
      })
      let new_total = ($state.prev + 1)
      $state | upsert panels $updated_panels | upsert prev $new_total
    } else {
      # Full dirty-flag partial erase path
      # Find index of first dirty panel
      let first_dirty_idx = ($state_panels | enumerate | where {|e| $e.item.dirty } | get index? | first | default null)

      if $first_dirty_idx == null {
        # Nothing dirty, no-op
        $state
      } else {
        # Sum actual drawn lines of panels above first dirty panel
        # (drawn lines = max(content_len, height) to account for padding)
        let lines_above = if $first_dirty_idx == 0 {
          0
        } else {
          $state_panels | slice 0..<$first_dirty_idx | each {|p|
            $p.screen_lines
          } | math sum
        }
        let prev_total = $state.prev
        let lines_to_erase = ($prev_total - $lines_above)

        # Move cursor up and clear down from that point
        if $lines_to_erase > 0 {
          print -n $"\e[($lines_to_erase)A\e[0J"
        }

        # Redraw from first dirty panel to end; update rendered_lines and clear dirty
        # lines_above is already computed using panel-drawn-height (content clamped to min height)
        mut new_total = $lines_above
        mut updated_panels = $state_panels
        for idx in $first_dirty_idx..<($state_panels | length) {
          let panel = ($state_panels | get $idx)
          let content = $panel.content
          let content_len = ($content | length)
          for line in $content {
            print $line
          }
          let panel_height = ($panel | get height? | default null)
          let drawn_lines = if $panel_height != null {
            let pad = ([$panel_height $content_len] | math max) - $content_len
            if $pad > 0 {
              for _i in 0..<$pad {
                print ""
              }
            }
            [$panel_height $content_len] | math max
          } else {
            $content_len
          }
          $new_total = $new_total + $drawn_lines
          # rendered_lines = content length (not padded), per spec
          # screen_lines = actual lines on screen (including padding)
          let final_content_len = $content_len
          let final_drawn_lines = $drawn_lines
          let cur_idx = $idx
          $updated_panels = ($updated_panels | enumerate | each {|e|
            if $e.index == $cur_idx {
              $e.item | upsert rendered_lines $final_content_len | upsert screen_lines $final_drawn_lines | upsert dirty false
            } else {
              $e.item
            }
          })
        }

        $state | upsert panels $updated_panels | upsert prev $new_total
      }
    }
  } else {
    # No panels in state and no panels arg — no-op, return state unchanged
    $state
  }
}

# Exit panel mode: erase block, print lines linearly into scrollback.
export def tui-close [state: record, lines: list<string>] {
  # 1. Erase previous block if any lines were drawn
  if $state.prev > 0 {
    print -n $"\e[($state.prev)A\e[0J"
  }

  # 2. Print each line linearly
  for line in $lines {
    print $line
  }
}

# Apply raw visual attributes {fg, bold?, underline?, italic?} to text.
export def tui-ansi [attrs: record, text: string] {
  let bold_on      = if ($attrs | get bold?      | default false) { (ansi attr_bold)      } else { "" }
  let underline_on = if ($attrs | get underline? | default false) { (ansi attr_underline) } else { "" }
  let italic_on    = if ($attrs | get italic?    | default false) { (ansi attr_italic)    } else { "" }
  let fg           = (ansi ($attrs.fg))
  $"($bold_on)($underline_on)($italic_on)($fg)($text)(ansi reset)"
}

# Returns true when stdout is a TTY.
# FORCE_TTY=1 → always true; FORCE_TTY=0 → always false; unset → auto-detect.
export def tui-is-tty []: nothing -> bool {
  let override = ($env | get FORCE_TTY? | default null)
  if $override != null {
    $override == "1"
  } else {
    is-terminal --stdout
  }
}

# Returns the terminal column width, or null when width is unknown.
# Explicit $env.COLUMNS wins (always returns int).
# Falls back to (term size).columns; returns null when <= 0 (unknown).
export def tui-columns [] {
  let explicit = ($env | get COLUMNS? | default null)
  if $explicit != null { return ($explicit | into int) }
  let detected = ((term size).columns | into int)
  if $detected > 0 { $detected } else { null }
}

# Truncate a plain string to fit within width characters.
# Appends "…" (1 char) when the string exceeds width; otherwise returns unchanged.
# Uses character count (str length) — caller should pass already-stripped plain strings.
export def tui-truncate [str: string, width: int]: nothing -> string {
  let len = ($str | str length)
  if $len > $width {
    ($str | str substring 0..<($width - 1)) + "…"
  } else {
    $str
  }
}

# Compute proportionally-clamped column widths from a record of max widths.
# maxes:     record mapping col name → max observed content width
# cols:      ordered list of column names to include
# available: total pixel budget to distribute
# Returns a record mapping col name → clamped int width (min 4 per col).
export def tui-col-widths [maxes: record, cols: list<string>, available: int]: nothing -> record {
  let widths = ($cols | each {|col| $maxes | get $col })
  let sum_w  = ($widths | math sum)
  let result = ($cols | zip $widths | each {|p|
    let col   = $p.0
    let w     = $p.1
    let min_w = 4
    if $sum_w == 0 {
      $min_w
    } else {
      let scaled = ($w * $available / $sum_w) | into int
      [$scaled $min_w] | math max
    }
  })
  $cols | zip $result | reduce --fold {} {|p acc| $acc | upsert $p.0 $p.1 }
}
