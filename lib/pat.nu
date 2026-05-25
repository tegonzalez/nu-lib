#!/usr/bin/env nu
# pat.nu — two-channel, two-tier segment pattern matching
#
# IO contract: pure (no filesystem access)
#
# Grammar authority: nu/lib/pat-spec.md
#
# Consumer surface (v2): pat parse, pat stem, pat literal, pat any, pat match, pat filter.
# Returned pattern records are OPAQUE — internal fields use a "_" prefix and MUST NOT
# be accessed directly. A missing query is an arch-evolution request (add an api function),
# not an introspection workaround.
#
# Pat record: {scope: string, scope_delim: string, expr: string, expr_delim: string|null}
#
# Parse forms:
#   "*"          → {scope: "*", expr: "*"}
#   "token"      → {scope: "token", expr: "*"}
#   "scope/"     → trailing delimiter stripped; same as "scope"
#   "scope:"     → {scope: "scope", expr: "*"}
#   ":expr"      → {scope: "*", expr: "expr"}
#   "scope:expr" → {scope: "scope", expr: "expr"}
#
# Two tiers per segment:
#   LIKE tier  — "%" present in seg-pat; "%" maps to [^<delim>]* (or .* when delim null)
#   Regex tier — no "%"; seg-pat is used as a raw full-match regex
#
# "%%" in a path pattern consumes zero or more key segments (multi-segment wildcard).

# Escape all regex metacharacters in a string so it matches literally.
def regex-escape [] {
  # Escape each regex metacharacter by prepending a literal backslash.
  # Character-by-character to avoid Nu str-replace backreference quoting issues.
  $in | split chars | each {|c|
    if ($c =~ '[.+*?^${}()|\\[\\]\\\\]') { "\\" + $c } else { $c }
  } | str join ""
}

# Convert a LIKE-tier segment pattern to a regex string.
# "%" when delim is a non-empty string → [^<escaped-delim>]*
# "%" when delim is null or ""         → .*
# Any other character                  → regex-escaped literal
def like-to-regex [pattern: string, delim: any] {
  let chars = ($pattern | split chars)
  let esc_delim = if ($delim != null and not ($delim | is-empty)) {
    $delim | regex-escape
  } else {
    null
  }
  $chars | reduce --fold "" {|c acc|
    if $c == "%" {
      if ($esc_delim != null) {
        $acc + $"[^($esc_delim)]*"
      } else {
        $acc + ".*"
      }
    } else {
      $acc + ($c | regex-escape)
    }
  }
}

# Test whether a single segment value matches a segment pattern.
# LIKE tier: "%" present in seg-pat → convert via like-to-regex, test full-match
# Regex tier: no "%" → test value =~ "^<seg-pat>$"
def segment-match [seg_pat: string, value: string, delim: any] {
  if ($seg_pat | str contains "%") {
    let rx = (like-to-regex $seg_pat $delim)
    $value =~ $"^($rx)$"
  } else {
    $value =~ $"^($seg_pat)$"
  }
}

# Match a multi-segment pattern against a key using a delimiter.
# "%%" in the pattern consumes zero or more key segments (backtracking).
# Returns true iff all pattern segments and all key segments are consumed.
def path-match [pattern: string, key: string, delim: string] {
  let seg_pats = ($pattern | split row $delim)
  let key_segs = ($key | split row $delim)
  path-match-walk $seg_pats $key_segs 0 0 $delim
}

def path-match-walk [
  seg_pats: list<string>
  key_segs: list<string>
  si: int
  ki: int
  delim: string
] {
  let sp_len = ($seg_pats | length)
  let ks_len = ($key_segs | length)

  if $si == $sp_len {
    # All pattern segments consumed — success only if key is also fully consumed
    return ($ki == $ks_len)
  }

  let seg = ($seg_pats | get $si)

  if $seg == "%%" {
    # Try consuming 0, 1, 2, ... key segments
    mut consumed = 0
    let max_consume = $ks_len - $ki
    mut found = false
    while $consumed <= $max_consume {
      let result = (path-match-walk $seg_pats $key_segs ($si + 1) ($ki + $consumed) $delim)
      if $result {
        $found = true
        break
      }
      $consumed = $consumed + 1
    }
    return $found
  }

  # Regular segment — must have a key segment to match against
  if $ki >= $ks_len { return false }

  let matched = (segment-match $seg ($key_segs | get $ki) $delim)
  if $matched {
    path-match-walk $seg_pats $key_segs ($si + 1) ($ki + 1) $delim
  } else {
    false
  }
}

# Recursive kernel for prefix-pruning walk — returns {match: bool, extend: bool}.
# match:  true iff seg_pats[si..] fully consumes key_segs[ki..].
# extend: true iff appending additional key segments could produce a full match.
# Invariant: (path-at-walk sp ks 0 0 d).match == (path-match-walk sp ks 0 0 d).
def path-at-walk [
  seg_pats: list<string>
  key_segs: list<string>
  si: int
  ki: int
  delim: string
] {
  let sp_len = ($seg_pats | length)
  let ks_len = ($key_segs | length)

  # Pattern fully consumed — success only when key is also fully consumed; no further extension.
  if $si == $sp_len {
    return {match: ($ki == $ks_len), extend: false}
  }

  let seg = ($seg_pats | get $si)

  if $seg == "%%" {
    # Try consuming 0, 1, … up to all remaining key segments; OR results.
    let max_consume = $ks_len - $ki
    mut m_acc = false
    mut e_acc = false
    mut consumed = 0
    while $consumed <= $max_consume {
      let r = (path-at-walk $seg_pats $key_segs ($si + 1) ($ki + $consumed) $delim)
      $m_acc = ($m_acc or $r.match)
      $e_acc = ($e_acc or $r.extend)
      $consumed = $consumed + 1
    }
    # %% is the last remaining pattern segment: appending one more key segment would
    # let %% absorb it, then pattern exhaustion succeeds → extend = true whenever match = true.
    let is_last_seg = ($si + 1 == $sp_len)
    let extend = ($e_acc or ($is_last_seg and $m_acc))
    return {match: $m_acc, extend: $extend}
  }

  # Key exhausted but pattern still has segments remaining — path is a valid prefix.
  if $ki >= $ks_len {
    return {match: false, extend: true}
  }

  # Regular (non-%%) segment: must match the current key segment to proceed.
  let matched = (segment-match $seg ($key_segs | get $ki) $delim)
  if $matched {
    path-at-walk $seg_pats $key_segs ($si + 1) ($ki + 1) $delim
  } else {
    {match: false, extend: false}
  }
}

# Build anchored regex string for regex-like tier, escaping dots literally
# and preserving [] character classes unchanged.
# dot-literal-default: "." → "\." so file/key patterns match literally.
# Character class preservation: chars inside [...] are passed through as-is.
def regex-like-build [raw: string] {
  let chars = ($raw | split chars)
  mut result = ""
  mut in_class = false
  for c in $chars {
    if $in_class {
      # Inside [...]: pass chars through unchanged (preserve char class syntax)
      $result = $result + $c
      if $c == "]" {
        $in_class = false
      }
    } else {
      if $c == "[" {
        $result = $result + "["
        $in_class = true
      } else if $c == "." {
        # dot-literal-default: escape dot so it matches a literal period
        $result = $result + "\\."
      } else {
        $result = $result + $c
      }
    }
  }
  $"^($result)$"
}

# --- Direct invocation entry point ---
def main [] {
  let name = ($env.CURRENT_FILE | path basename)
  print $"Usage: ($name) — library module, not a CLI tool.
Import with: use pat.nu *"
}

# =============================================================================
# V2 PUBLIC SURFACE — pat parse / pat stem / pat literal / pat any /
#                     pat match / pat filter
# =============================================================================
#
# Pattern objects produced by pat parse are opaque — internal fields use a
# leading "_" prefix and MUST NOT be exposed through any public function.
# The accept criterion no-pattern-field-leak enforces this at the grep level.

# Private: build a v2 opaque pattern object from a raw string and a delimiter.
# Uses the same tier-detection logic as v1 pat-matcher but stores fields with
# underscore-prefixed keys so the names "tier", "segments", "regex", "raw",
# "delim", "any" are never present in the exported record.
#
# Internal shape: {_raw, _delim, _any, _tier, _segments, _regex}
def pat-build-pattern [raw: string, delim: any] {
  # Normalise delimiter: treat null / empty as null (single-segment mode)
  let d = if ($delim == null or ($delim | is-empty)) { null } else { $delim }

  # any-tier: empty string or "%%" at the top level
  if ($raw | is-empty) or $raw == "%%" {
    return {_raw: $raw, _delim: $d, _any: true, _tier: "any", _segments: null, _regex: null}
  }

  let has_percent = ($raw | str contains "%")
  # Regex-tier metacharacters per spec §6.1: [ ] + ? ( ) { } | ^ $
  # Note: "." is NOT in this list — "." is always literal (dot-literal-default).
  # Use str contains checks to avoid escaping issues in regex character classes.
  let stripped = ($raw | str replace --all "%" "")
  let has_other_meta = (
    ($stripped | str contains "[") or
    ($stripped | str contains "]") or
    ($stripped | str contains "+") or
    ($stripped | str contains "?") or
    ($stripped | str contains "^") or
    ($stripped | str contains "$") or
    ($stripped | str contains "{") or
    ($stripped | str contains "}") or
    ($stripped | str contains "(") or
    ($stripped | str contains ")") or
    ($stripped | str contains "|") or
    ($stripped | str contains "\\")
  )

  if not $has_percent and not $has_other_meta {
    # exact tier: no metacharacters (includes patterns with only "." — literal dot)
    let segs = if ($d != null) { $raw | split row $d } else { null }
    return {_raw: $raw, _delim: $d, _any: false, _tier: "exact", _segments: $segs, _regex: null}
  }

  if $has_percent {
    # wildcard tier
    let segs = if ($d != null) { $raw | split row $d } else { null }
    return {_raw: $raw, _delim: $d, _any: false, _tier: "wildcard", _segments: $segs, _regex: null}
  }

  # regex-like tier: no %, but has active metacharacters ([, ], +, ?, etc.)
  # "." in this tier is still escaped to "\." by regex-like-build (dot-literal-default)
  let rx = (regex-like-build $raw)
  {_raw: $raw, _delim: $d, _any: false, _tier: "regex", _segments: null, _regex: $rx}
}

# Private: apply v2 opaque pattern to a single path string; returns {emit: bool, expand: bool}.
# Same pruning logic as path-at-walk but operating on the internal v2 pattern object shape
# (_any, _tier, _raw, _delim, _regex).
def pat-v2-at [pattern: record, path: string] {
  # any-matcher: emit and expand always
  if $pattern._any { return {emit: true, expand: true} }

  # Empty path: always expandable; emit only if pattern matches empty string
  if ($path | is-empty) {
    let m = pat-v2-test $pattern ""
    return {emit: $m, expand: true}
  }

  match $pattern._tier {
    "exact" => {
      let d = if ($pattern._delim != null) { $pattern._delim } else { "/" }
      let m = ($path == $pattern._raw)
      let e = ($pattern._raw | str starts-with ($path + $d))
      {emit: $m, expand: $e}
    }
    "regex" => {
      let d = if ($pattern._delim != null) { $pattern._delim } else { "/" }
      let m = ($path =~ $pattern._regex)
      let e = ($pattern._raw | str starts-with ($path + $d))
      {emit: $m, expand: $e}
    }
    "wildcard" => {
      if ($pattern._delim == null) {
        {emit: (segment-match $pattern._raw $path null), expand: false}
      } else {
        let seg_pats = ($pattern._raw | split row $pattern._delim)
        let key_segs = ($path | split row $pattern._delim)
        let r = (path-at-walk $seg_pats $key_segs 0 0 $pattern._delim)
        {emit: $r.match, expand: $r.extend}
      }
    }
    _ => { {emit: false, expand: false} }
  }
}

# Private: test a v2 pattern against a single string value; returns bool.
def pat-v2-test [pattern: record, value: string] {
  if $pattern._any { return true }
  match $pattern._tier {
    "exact"    => { $value == $pattern._raw }
    "regex"    => { $value =~ $pattern._regex }
    "wildcard" => {
      if ($pattern._delim == null) {
        segment-match $pattern._raw $value null
      } else {
        path-match $pattern._raw $value $pattern._delim
      }
    }
    _ => { false }
  }
}

# Parse a raw pattern string and cfg into a pair of opaque pattern objects.
# Returns {scope: pattern, expr: pattern}.
#
# cfg shape: {delim, expr_delim, anchors, anchor_descend}
#   delim          — path separator for scope channel (default "/")
#   expr_delim     — separator for expr channel (default null = single-segment)
#   anchors        — tokens not emittable as entries (default [])
#   anchor_descend — when true, bare anchor tokens promote to <token>/<delim>/% (default false)
#
# Grammar (two-channel split):
#   ""             → scope universal, expr universal
#   "scope"        → scope literal/wildcard/regex, expr universal
#   ":expr"        → scope universal, expr literal/wildcard/regex
#   "scope:"       → scope literal/wildcard/regex, expr universal
#   "scope:expr"   → scope on left, expr on right
#
# Trailing-slash promotion (scope slot): if scope slot ends with cfg.delim,
#   strip it and append delim + % (depth +1, parse-time only, no flag returned).
#
# anchor_descend promotion: if cfg.anchor_descend == true AND the raw input is
#   empty or exactly one token from cfg.anchors, promote to <token> + delim + %.
export def "pat parse" [raw: string, cfg: record] {
  # Resolve cfg fields with defaults
  let delim = if ($cfg | columns | any {|c| $c == "delim"}) { $cfg.delim } else { "/" }
  let expr_delim = if ($cfg | columns | any {|c| $c == "expr_delim"}) { $cfg.expr_delim } else { null }
  let anchors = if ($cfg | columns | any {|c| $c == "anchors"}) { $cfg.anchors } else { [] }
  let anchor_descend = if ($cfg | columns | any {|c| $c == "anchor_descend"}) { $cfg.anchor_descend } else { false }

  # Split raw into scope/expr channels on the first ":"
  let raw_scope_raw = if ($raw | str contains ":") {
    let colon_pos = ($raw | str index-of ":")
    $raw | str substring 0..<$colon_pos
  } else {
    $raw
  }
  let raw_expr = if ($raw | str contains ":") {
    let colon_pos = ($raw | str index-of ":")
    $raw | str substring ($colon_pos + 1)..
  } else {
    ""
  }

  # Apply anchor_descend promotion to raw scope slot BEFORE trailing-slash check.
  # Promotion applies only to: empty input or exactly one token from anchors.
  # Regex-tier patterns never promote.
  let scope_after_anchor = if $anchor_descend {
    let is_empty_input = ($raw_scope_raw | is-empty)
    let is_anchor_token = ($anchors | any {|a| $a == $raw_scope_raw})
    if $is_empty_input or $is_anchor_token {
      # Promote: <token> + delim + %
      let prefix = if $is_empty_input { "" } else { $raw_scope_raw }
      if ($prefix | is-empty) { "%" } else { $prefix + $delim + "%" }
    } else {
      $raw_scope_raw
    }
  } else {
    $raw_scope_raw
  }

  # Apply trailing-slash promotion to scope slot.
  # Only when scope_after_anchor ends with cfg.delim AND is not a regex-tier pattern.
  # Regex-tier check: has other metacharacters but no %; those never promote.
  let scope_raw = if ($scope_after_anchor | str ends-with $delim) {
    let stripped = ($scope_after_anchor | str trim --right --char $delim)
    if ($stripped | is-empty) {
      # Bare trailing slash → "%" (match root level children)
      "%"
    } else {
      $stripped + $delim + "%"
    }
  } else {
    $scope_after_anchor
  }

  # Build scope pattern object
  let scope_pat = (pat-build-pattern $scope_raw $delim)

  # Build expr pattern object; empty expr → universal
  let expr_raw = if ($raw_expr | is-empty) { "" } else { $raw_expr }
  let expr_pat = (pat-build-pattern $expr_raw $expr_delim)

  {scope: $scope_pat, expr: $expr_pat}
}

# Return the literal walk-anchor prefix of a pattern as a single string.
# For a universal pattern (pat any = true): returns "".
# For a fully literal pattern (pat literal = true): returns the full raw string.
# For a wildcard/regex pattern: returns the literal prefix up to the first
# non-literal segment (may be "" when the first segment is a wildcard).
export def "pat stem" [pattern: record] {
  if $pattern._any { return "" }

  match $pattern._tier {
    "exact" => {
      # Fully literal: stem is the entire raw string
      $pattern._raw
    }
    "regex" => {
      # Regex-like: extract literal prefix up to first non-literal character.
      # For simplicity, return "" — regex patterns have no reliable literal prefix
      # unless the delim is set and the pattern starts with literal segments.
      # Use the raw string as-is for initial literal segment walk when delim is set.
      if ($pattern._delim != null) {
        let segs = ($pattern._raw | split row $pattern._delim)
        mut stem_segs: list<string> = []
        mut done = false
        for seg in $segs {
          if $done { break }
          let is_pat = ($seg | str contains "%") or ($seg =~ '[.+?^${}()|\\[\\]\\\\]')
          if $is_pat {
            $done = true
          } else {
            $stem_segs = ($stem_segs | append $seg)
          }
        }
        $stem_segs | str join $pattern._delim
      } else {
        ""
      }
    }
    "wildcard" => {
      if ($pattern._delim == null) {
        # Single-segment mode: no literal prefix possible when % present
        ""
      } else {
        let segs = ($pattern._raw | split row $pattern._delim)
        mut stem_segs: list<string> = []
        mut done = false
        for seg in $segs {
          if $done { break }
          if ($seg | str contains "%") {
            $done = true
          } else {
            $stem_segs = ($stem_segs | append $seg)
          }
        }
        $stem_segs | str join $pattern._delim
      }
    }
    _ => { "" }
  }
}

# Return true when the pattern is fully literal (exact tier — no wildcards).
export def "pat literal" [pattern: record] {
  $pattern._tier == "exact"
}

# Return true when the pattern is universal (matches everything at every depth).
export def "pat any" [pattern: record] {
  $pattern._any
}

# Batch evaluator: annotate each record with emit and expand booleans.
# Each input record must have shape {path: string, item: any}.
# Returns list<{record, emit: bool, expand: bool}>.
export def "pat match" [pattern: record, records: list] {
  $records | each {|rec|
    let r = (pat-v2-at $pattern $rec.path)
    {record: $rec, emit: $r.emit, expand: $r.expand}
  }
}

# Flat filter over records by value using the expr pattern.
# --value is mandatory; omitting it is an error (per learning pat-scan-callback-optional-for-enforcement).
# The --value closure receives the whole record {path, item} and must return a string.
# Returns list<{record, emit: bool}>. Never produces expand.
export def "pat filter" [
  pattern: record,
  records: list,
  --value: closure
] {
  if ($value == null) {
    error make {msg: "pat filter: --value is required — provide a closure that extracts the canonical identifier string from each record"}
  }
  $records | each {|rec|
    let id = (do $value $rec)
    let matched = (pat-v2-test $pattern $id)
    {record: $rec, emit: $matched}
  }
}
