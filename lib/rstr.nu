# rstr.nu — region-marked string library
#
# Public surface (closed-world): rstr of, rstr tag, rstr concat, rstr cat,
#   rstr len, rstr plain, rstr trim, rstr trim-lhs, rstr fill, rstr to-str,
#   rstr from-str, rstr regions, rstr map-text, rstr str, rstr display-len,
#   rstr flatten, rstr to-ansi. Rstr values are list<region-record>;
#   consumers operate on them via the listed verbs only (record-via-pipeline
#   api). Tags are abstract style atoms — format-specific resolution belongs
#   in render, not in rstr or its consumers.
#
# IO contract: mostly pure — all functions operate on rstr values (list<record>) via pipeline.
# Exception: rstr to-ansi reads tui-is-tty and applies ANSI styles via styles.nu / tui.nu.
#
# Type:
#   rstr = list<rstr-node>
#   rstr-node = {t: string}                       # text leaf
#             | {r: string, c: list<rstr-node>}   # region node
#
# Serialized form: «name»content«/»  (U+00AB / U+00BB)
# Escape: «« → literal « in text nodes

use ./tui.nu [tui-is-tty]
use ./styles.nu ["styles get" "styles has" tui-atoms]

# Ambiguous UTF-8 codepoints that render as 1 column in most terminals
const DISPLAY_WIDTH: record = {⟳: 1, →: 1, ←: 1, …: 1, —: 1, «: 1, »: 1}

# Return the terminal display width of a single character
def char-dw [c: string]: nothing -> int {
  if ($c | str length --grapheme-clusters) == 0 { return 0 }
  # Check explicit table first (ambiguous codepoints with known 1-column width)
  if ($DISPLAY_WIDTH | get --optional $c) != null {
    return ($DISPLAY_WIDTH | get $c)
  }
  # Single-byte -> ASCII -> 1 column.
  let byte_len = ($c | into binary | bytes length)
  if $byte_len == 1 {
    return 1
  }
  # Most four-byte graphemes are emoji/supplementary-plane symbols that occupy
  # two terminal cells. iconv often transliterates them to one placeholder byte,
  # which undercounts table columns such as "🔒".
  if $byte_len >= 4 {
    return 2
  }
  # For other UTF-8 chars use iconv transliteration as a display-width proxy.
  $c | ^iconv -f UTF-8 -t ASCII//TRANSLIT | str length
}

# Return the display width of a string by summing per-character widths.
# Fast path: pure-ASCII strings (byte length == grapheme count) are measured
# with a single native call. The per-character Nu loop fires only for strings
# that contain multi-byte codepoints.
export def "rstr display-len" []: string -> int {
  let s = $in
  let char_len = ($s | str length --grapheme-clusters)
  if ($s | into binary | bytes length) == $char_len {
    return $char_len
  }
  $s | split chars | reduce --fold 0 {|c acc| $acc + (char-dw $c)}
}

# Sum text-leaf lengths for one node (recursive)
def node-len [node: record] {
  if ($node | get t?) != null {
    $node.t | rstr display-len
  } else {
    $node.c | reduce --fold 0 {|child acc| $acc + (node-len $child)}
  }
}

# Serialize one node to string
def node-to-str [node: record] {
  if ($node | get t?) != null {
    # escape « in raw text
    $node.t | str replace -a "«" "««"
  } else {
    let inner = ($node.c | each {|child| node-to-str $child} | str join "")
    $"«($node.r)»($inner)«/»"
  }
}

# Extract all region names depth-first from a node
def node-regions [node: record] {
  if ($node | get t?) != null {
    []
  } else {
    let name = [$node.r]
    let child_names = ($node.c | each {|child| node-regions $child} | flatten)
    $name ++ $child_names
  }
}

# Apply a text-transform closure to every text leaf in a node
def node-map-text [node: record, f: closure] {
  if ($node | get t?) != null {
    {t: (do $f $node.t)}
  } else {
    {r: $node.r, c: ($node.c | each {|child| node-map-text $child $f})}
  }
}

# Trim a list of nodes to a display width; returns {nodes: list, remaining: int}
def nodes-trim [nodes: list, width: int] {
  if $width <= 0 { return {nodes: [], remaining: 0} }
  $nodes | reduce --fold {nodes: [], remaining: $width} {|node acc|
    if $acc.remaining <= 0 {
      $acc
    } else if ($node | get t?) != null {
      let s = $node.t
      let len = ($s | rstr display-len)
      if $len <= $acc.remaining {
        {nodes: ($acc.nodes | append $node), remaining: ($acc.remaining - $len)}
      } else {
        let cut = ($s | split chars | first $acc.remaining | str join)
        {nodes: ($acc.nodes | append {t: $cut}), remaining: 0}
      }
    } else {
      let inner = (nodes-trim $node.c $acc.remaining)
      let trimmed_node = {r: $node.r, c: $inner.nodes}
      {nodes: ($acc.nodes | append $trimmed_node), remaining: $inner.remaining}
    }
  }
}

# --- Public API ---

# Escape a piped string and return as a single-node rstr
#
# Example:
#   "hello" | rstr of
export def "rstr of" []: string -> list {
  [{t: $in}]
}

# Wrap the input rstr in a named region node
#
# Example:
#   "hello" | rstr of | rstr tag "dim"
export def "rstr tag" [name: string] {
  let inner = $in
  [{r: $name, c: $inner}]
}

# Flatten a list<rstr> to one rstr
#
# Example:
#   [("a" | rstr of), ("b" | rstr of)] | rstr concat
export def "rstr concat" [] {
  $in | flatten
}

# Append rstr b to the input rstr
#
# Example:
#   "a" | rstr of | rstr cat ("b" | rstr of)
export def "rstr cat" [b: list] {
  $in ++ $b
}

# Return the total display length (sum of text leaf string lengths)
#
# Example:
#   "hello" | rstr of | rstr tag "dim" | rstr len
export def "rstr len" [] {
  let nodes = $in
  $nodes | reduce --fold 0 {|node acc| $acc + (node-len $node)}
}

# Extract plain text from a single node (recursive helper)
def node-plain [node: record] {
  if ($node | get t?) != null {
    $node.t
  } else {
    $node.c | each {|child| node-plain $child} | str join ""
  }
}

# Return all text leaf content joined as a plain string (strips region markers)
#
# Example:
#   "«x»hi«/»" | rstr from-str | rstr plain
export def "rstr plain" [] {
  $in | each {|node| node-plain $node} | str join ""
}

# Truncate to display width; append "…" text node at the cut point
#
# Example:
#   "hello world" | rstr of | rstr trim 5
export def "rstr trim" [width: int] {
  if $width <= 0 { return [{t: "…"}] }
  let nodes = $in
  let total = ($nodes | rstr len)
  if $total <= $width { return $nodes }
  let result = (nodes-trim $nodes ($width - 1))
  $result.nodes ++ [{t: "…"}]
}

# Truncate from the left to display width; prepend "…" text node at the cut point.
# Keeps the tail of the content (the rightmost characters).
#
# Example:
#   "hello world" | rstr of | rstr trim-lhs 5
export def "rstr trim-lhs" [width: int] {
  if $width <= 0 { return [{t: "…"}] }
  let nodes = $in
  let total = ($nodes | rstr len)
  if $total <= $width { return $nodes }
  # Keep the tail: we need (width - 1) chars from the right, then prepend "…"
  let keep_w = ($width - 1)
  let result = (nodes-trim-lhs $nodes $keep_w)
  [{t: "…"}] ++ $result.nodes
}

# Trim a list of nodes from the left, keeping the rightmost display-width chars.
# Returns {nodes: list, remaining: int} where remaining is unused budget.
def nodes-trim-lhs [nodes: list, width: int] {
  if $width <= 0 { return {nodes: [], remaining: 0} }
  let total = ($nodes | reduce --fold 0 {|node acc| $acc + (node-len $node)})
  let skip_w = ($total - $width)
  # Walk through nodes, skipping skip_w chars from the left
  $nodes | reduce --fold {nodes: [], to_skip: $skip_w} {|node acc|
    if $acc.to_skip <= 0 {
      # Already past the skip zone — keep this node whole
      {nodes: ($acc.nodes | append $node), to_skip: 0}
    } else if ($node | get t?) != null {
      let s = $node.t
      let len = ($s | rstr display-len)
      if $len <= $acc.to_skip {
        # Skip entire text node
        {nodes: $acc.nodes, to_skip: ($acc.to_skip - $len)}
      } else {
        # Partial skip: drop first to_skip chars
        let keep = ($s | split chars | skip $acc.to_skip | str join)
        {nodes: ($acc.nodes | append {t: $keep}), to_skip: 0}
      }
    } else {
      let inner = (nodes-trim-lhs $node.c $acc.to_skip)
      let trimmed_node = {r: $node.r, c: $inner.nodes}
      {nodes: ($acc.nodes | append $trimmed_node), to_skip: 0}
    }
  }
}

# Pad the rstr to the given width with space text nodes.
# align: "left" (default) pads on right; "right" pads on left; "center" splits padding.
#
# Example:
#   "hi" | rstr of | rstr fill 5
export def "rstr fill" [width: int, align?: string] {
  let nodes = $in
  let a = ($align | default "left")
  let current = ($nodes | rstr len)
  let diff = ($width - $current)
  let pad = if $diff > 0 { $diff } else { 0 }
  if $pad == 0 { return $nodes }
  let space = {t: ("" | fill -c " " -w $pad)}
  if $a == "right" {
    [$space] ++ $nodes
  } else if $a == "center" {
    let left_pad  = ($pad // 2)
    let right_pad = ($pad - $left_pad)
    let lsp = {t: ("" | fill -c " " -w $left_pad)}
    let rsp = {t: ("" | fill -c " " -w $right_pad)}
    [$lsp] ++ $nodes ++ [$rsp]
  } else {
    $nodes ++ [$space]
  }
}

# Serialize the rstr to the «name»...«/» wire format
#
# Example:
#   "a" | rstr of | rstr tag "x" | rstr to-str
export def "rstr to-str" [] {
  $in | each {|node| node-to-str $node} | str join ""
}

# Parse a «name»...«/» wire-format string into an rstr
#
# Example:
#   "«x»hi«/»" | rstr from-str
export def "rstr from-str" [] {
  let s = $in
  let chars = ($s | split chars)
  let n = ($chars | length)

  # Build token list: {kind: "text", val: string} | {kind: "open", name: string} | {kind: "close"}
  let token_state = ($chars | enumerate | reduce --fold {tokens: [], buf: "", skip: 0, in_tag: false} {|item, st|
    let i = $item.index
    let c = $item.item

    if $st.skip > 0 {
      $st | upsert skip ($st.skip - 1)
    } else if $st.in_tag {
      # reading tag name until »
      if $c == "»" {
        let name = $st.buf
        let new_tokens = if $name == "/" {
          $st.tokens ++ [{kind: "close"}]
        } else {
          $st.tokens ++ [{kind: "open", name: $name}]
        }
        $st | upsert tokens $new_tokens | upsert buf "" | upsert in_tag false
      } else {
        $st | upsert buf ($st.buf + $c)
      }
    } else if $c == "«" {
      # look ahead: next char also «? → escaped literal «
      let next = if ($i + 1) < $n { $chars | get ($i + 1) } else { "" }
      if $next == "«" {
        $st | upsert buf ($st.buf + "«") | upsert skip 1
      } else {
        # flush buf as text token, then enter tag-reading mode
        let new_tokens = if ($st.buf | str length) > 0 {
          $st.tokens ++ [{kind: "text", val: $st.buf}]
        } else {
          $st.tokens
        }
        $st | upsert tokens $new_tokens | upsert buf "" | upsert in_tag true
      }
    } else {
      $st | upsert buf ($st.buf + $c)
    }
  })

  # Flush remaining buf
  let tokens = if ($token_state.buf | str length) > 0 {
    $token_state.tokens ++ [{kind: "text", val: $token_state.buf}]
  } else {
    $token_state.tokens
  }

  # Build tree from tokens using a stack
  # Stack entries: {name: string, nodes: list}
  let tree_state = ($tokens | reduce --fold {stack: [], result: []} {|tok, st|
    match $tok.kind {
      "text" => {
        let node = {t: $tok.val}
        if ($st.stack | is-empty) {
          $st | upsert result ($st.result ++ [$node])
        } else {
          let top = ($st.stack | last)
          let new_top = ($top | upsert nodes ($top.nodes ++ [$node]))
          let new_stack = ($st.stack | take (($st.stack | length) - 1)) ++ [$new_top]
          $st | upsert stack $new_stack
        }
      }
      "open" => {
        $st | upsert stack ($st.stack ++ [{name: $tok.name, nodes: []}])
      }
      "close" => {
        if ($st.stack | is-empty) {
          error make {msg: "rstr from-str: unexpected close marker «/» with no open region"}
        }
        let top = ($st.stack | last)
        let region_node = {r: $top.name, c: $top.nodes}
        let new_stack = ($st.stack | take (($st.stack | length) - 1))
        if ($new_stack | is-empty) {
          $st | upsert stack [] | upsert result ($st.result ++ [$region_node])
        } else {
          let parent = ($new_stack | last)
          let new_parent = ($parent | upsert nodes ($parent.nodes ++ [$region_node]))
          let final_stack = ($new_stack | take (($new_stack | length) - 1)) ++ [$new_parent]
          $st | upsert stack $final_stack
        }
      }
      _ => $st
    }
  })

  if ($tree_state.stack | is-not-empty) {
    let unclosed = ($tree_state.stack | each {|f| $f.name} | str join ", ")
    error make {msg: $"rstr from-str: unclosed regions: ($unclosed)"}
  }

  $tree_state.result
}

# Return all region names depth-first
#
# Example:
#   "«x»«y»hi«/»«/»" | rstr from-str | rstr regions
export def "rstr regions" [] {
  $in | each {|node| node-regions $node} | flatten
}

# Apply a closure to every text leaf string
#
# Example:
#   "hello" | rstr of | rstr map-text {|s| $s | str upcase}
export def "rstr map-text" [f: closure] {
  $in | each {|node| node-map-text $node $f}
}

# Parse an HTML-like styled string into an rstr tree.
#
# Three tag forms:
#   <name>content</name>   — named open + named close (error if names mismatch)
#   <name>content</>       — named open + generic close
#   <name content />       — self-closing; first whitespace-delimited token is the
#                            style name, remainder up to ' />' is the text content
#
# Escape: '<<' anywhere in content produces a literal '<' text leaf character.
#
# Error conditions:
#   "rstr str: unclosed tag: <name>"
#   "rstr str: expected </name> got </other>"
#
# Examples:
#   "<b>bold</b>"   | rstr str | rstr plain      # → "bold"
#   "<b>text</>"    | rstr str | rstr regions     # → [b]
#   "<dim note />"  | rstr str | rstr to-str      # → «dim»note«/»
#   "a <<b"         | rstr str | rstr plain       # → "a <b"
#   "<h1><b>x</b></h1>" | rstr str | rstr regions # → [h1 b]
# Parse a tag body string (contents between < and >) into a token record
def rstr-str-parse-tag [body: string] {
  if ($body | str starts-with "/") {
    let close_name = ($body | str substring 1..)
    {kind: "close", name: $close_name}
  } else if ($body | str ends-with " /") {
    let inner = ($body | str substring 0..<(($body | str length) - 2) | str trim)
    let parts = ($inner | split row -r '\s+')
    let tag_name = ($parts | first)
    let content = if ($parts | length) > 1 { $parts | skip 1 | str join " " } else { "" }
    {kind: "self", name: $tag_name, val: $content}
  } else {
    {kind: "open", name: $body}
  }
}

export def "rstr str" []: string -> list {
  let s = $in

  # --- Tokenize by splitting on '<' ---
  # We split the string into segments at every '<'. The first segment is always
  # plain text (possibly empty). Every subsequent segment begins with tag content
  # up to the first '>' followed by text content.
  # Handle '<<' escape: a segment starting with '<' means the original was '<<'.

  # We work on the raw string using index-of to find tags.
  # Strategy: scan left-to-right, accumulate tokens.
  # pos tracks current position in $s (byte/char offset via str substring).

  let len = ($s | str length)

  # Build token list iteratively using a mutable-style fold over positions.
  # State: {tokens: list, pos: int}
  # We loop by reducing over a range; each step either advances past a tag or text.

  # Pre-split approach: split on '<' to get segments.
  # segments[0] = text before first '<'
  # segments[k>0] = text starting right after a '<'; may start with another '<' (escape).
  let segments = ($s | split row "<")

  # State fields:
  #   tokens: list      — accumulated tokens
  #   first: bool       — true only for the very first segment (pure text before first '<')
  #   escape_next: bool — true when the previous segment was empty (meaning '<<' was seen);
  #                       the current segment is the text that follows the escaped '<'
  let tok_state = ($segments | enumerate | reduce --fold {tokens: [], first: true, escape_next: false} {|item, st|
    let seg = $item.item

    if $st.first {
      # First segment: always plain text (before first '<')
      let new_tokens = if ($seg | str length) > 0 {
        $st.tokens ++ [{kind: "text", val: $seg}]
      } else {
        $st.tokens
      }
      $st | upsert tokens $new_tokens | upsert first false
    } else if $st.escape_next {
      # Previous segment was empty ('<<' escape): this segment is plain text after the '<'
      let new_tokens = if ($seg | str length) > 0 {
        $st.tokens ++ [{kind: "text", val: ("<" + $seg)}]
      } else {
        # '<<<' case: another empty segment follows — emit '<' and set escape_next again
        $st.tokens ++ [{kind: "text", val: "<"}]
      }
      $st | upsert tokens $new_tokens | upsert escape_next ($seg | is-empty)
    } else if ($seg | is-empty) {
      # Empty non-first segment: this was '<<' in the source; next segment is the text after '<'
      $st | upsert escape_next true
    } else {
      # Normal segment: find the '>' that closes the tag
      let gt_pos = ($seg | str index-of ">")
      if $gt_pos == -1 {
        # No closing '>'; treat entire segment as text (malformed, best-effort)
        let new_tok = {kind: "text", val: ("<" + $seg)}
        $st | upsert tokens ($st.tokens ++ [$new_tok]) | upsert escape_next false
      } else {
        let body = ($seg | str substring 0..<$gt_pos)
        let after = ($seg | str substring ($gt_pos + 1)..)
        let tag_tok = (rstr-str-parse-tag $body)
        let new_tokens = if ($after | str length) > 0 {
          $st.tokens ++ [$tag_tok, {kind: "text", val: $after}]
        } else {
          $st.tokens ++ [$tag_tok]
        }
        $st | upsert tokens $new_tokens | upsert escape_next false
      }
    }
  })

  let tokens = $tok_state.tokens

  # --- Build tree from tokens using a stack ---
  # Stack entries: {name: string, nodes: list}
  let tree_state = ($tokens | reduce --fold {stack: [], result: []} {|tok, st|
    match $tok.kind {
      "text" => {
        let node = {t: $tok.val}
        if ($st.stack | is-empty) {
          $st | upsert result ($st.result ++ [$node])
        } else {
          let top = ($st.stack | last)
          let new_top = ($top | upsert nodes ($top.nodes ++ [$node]))
          let new_stack = ($st.stack | take (($st.stack | length) - 1)) ++ [$new_top]
          $st | upsert stack $new_stack
        }
      }
      "open" => {
        $st | upsert stack ($st.stack ++ [{name: $tok.name, nodes: []}])
      }
      "close" => {
        if ($st.stack | is-empty) {
          error make {msg: "rstr str: unexpected close tag with no open region"}
        }
        let top = ($st.stack | last)
        # Named close: verify name match
        if ($tok.name | str length) > 0 and $tok.name != $top.name {
          error make {msg: $"rstr str: expected </($top.name)> got </($tok.name)>"}
        }
        let region_node = {r: $top.name, c: $top.nodes}
        let new_stack = ($st.stack | take (($st.stack | length) - 1))
        if ($new_stack | is-empty) {
          $st | upsert stack [] | upsert result ($st.result ++ [$region_node])
        } else {
          let parent = ($new_stack | last)
          let new_parent = ($parent | upsert nodes ($parent.nodes ++ [$region_node]))
          let final_stack = ($new_stack | take (($new_stack | length) - 1)) ++ [$new_parent]
          $st | upsert stack $final_stack
        }
      }
      "self" => {
        let region_node = {r: $tok.name, c: [{t: $tok.val}]}
        if ($st.stack | is-empty) {
          $st | upsert result ($st.result ++ [$region_node])
        } else {
          let top = ($st.stack | last)
          let new_top = ($top | upsert nodes ($top.nodes ++ [$region_node]))
          let new_stack = ($st.stack | take (($st.stack | length) - 1)) ++ [$new_top]
          $st | upsert stack $new_stack
        }
      }
      _ => $st
    }
  })

  # Best-effort: flush unclosed opens as literal text so plain data with
  # angle-bracket patterns (e.g. list<string>, <placeholder>) never errors.
  if ($tree_state.stack | is-empty) {
    $tree_state.result
  } else {
    $tree_state.stack | reduce --fold $tree_state.result {|entry acc|
      $acc ++ [{t: $"<($entry.name)>"}] ++ $entry.nodes
    }
  }
}

# ── rstr-to-ANSI rendering ────────────────────────────────────────────────────

# Recursively render one rstr-node to a plain or styled string.
# When color is true, applies ANSI styles for known style names via tui-atoms.
def rstr-node-ansi [node: record, color: bool] {
  if ($node | get t?) != null {
    $node.t
  } else {
    let joined = ($node.c | each {|child| rstr-node-ansi $child $color} | str join "")
    if $color and (styles has $node.r) {
      tui-atoms (styles get $node.r) $joined
    } else {
      $joined
    }
  }
}

# Flatten an rstr tree to a string. Pure: never inspects terminal state.
# When color is true, applies ANSI styles via the region-to-style mapping.
# When color is false, returns plain text with all region markers stripped.
#
# Example:
#   "hello" | rstr of | rstr tag "ok" | rstr flatten true
export def "rstr flatten" [color: bool]: list -> string {
  $in | each {|node| rstr-node-ansi $node $color} | str join ""
}

# Render an rstr tree to an ANSI string.
# Use --no-color to strip all styling and return plain text.
# Automatically detects whether stdout is a TTY; use rstr flatten for
# explicit color control without terminal-state inspection.
#
# Example:
#   "hello" | rstr of | rstr tag "ok" | rstr to-ansi
export def "rstr to-ansi" [--no-color]: list -> string {
  $in | rstr flatten ((not $no_color) and (tui-is-tty))
}

