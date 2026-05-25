#!/usr/bin/env nu

use ../../lib/args.nu
use ../../lib/pat.nu *
use ../../lib/render.nu
use ../../lib/rope.nu *
use ../../lib/rstr.nu *

# ── namespace predicate ──────────────────────────────────────────────────────
#
# Test whether a dot-delimited namespace string matches the scope pattern.
# Uses pat match on the full namespace path (pattern built with delim=".").
# Returns true only when the namespace fully satisfies the scope pattern.
#
# Caller must pass `$scope` as a dot-delimited pattern (delim = '.').
def ns-matches-scope [scope: record, ns: string] {
  if (pat any $scope) { return true }
  let result = (pat match $scope [{path: $ns, item: null}])
  if ($result | is-empty) { return false }
  ($result | first).emit
}

# ── spec ─────────────────────────────────────────────────────────────────────

def cg-spec [] {
  {
    name: "cg"
    description: "TypeScript callgraph builder — function-level edges via ast-grep"
    default_command: "lf"
    global_flags: [
      {name: format,  short: f, default: "rich", description: "Output format: rich | text | json  (default: rich)"}
      {name: debug,   short: d, value: "N",      default: "0",  description: "Log verbosity: 1=info 2=debug 3=trace  (default: 0=warn)"}
      {name: verbose, short: v, bool: true,       description: "Show line numbers (deduplication off)"}
    ]
    commands: [
      {
        name: lf
        args: ["pat?", "path?"]
        description: "List+filter callgraph edges; pat: scope filters by file namespace (LIKE % = grouped), expr matches caller"
        examples: [
          "cg lf src/                  — all edges (flat)"
          "cg lf % src/               — all edges grouped by file namespace"
          "cg lf src/ api.:            — callers in api namespace (flat)"
          "cg lf src/:ls%              — callers whose name starts with ls (flat)"
        ]
      }
      {
        name: seq
        args: ["path", "pat?"]
        description: "Show call sequence with BFS level assignment; pat seeds BFS from matching callers (dot delimiter)"
      }
      {
        name: tree
        args: ["path", "pat?"]
        description: "Render call tree from DFS roots selected by pat (dot delimiter); no positional root arg"
      }
    ]
  }
}

# ── sg helper ─────────────────────────────────────────────────────────────────

# sg exits 1 on zero matches; | complete captures exit code without pipeline error.
def sg-json [pattern: string, path: string] {
  let r = (do { sg run -p $pattern --json -l ts $path } | complete)
  if $r.exit_code == 0 { $r.stdout | from json } else { [] }
}

# Split "fs/path/glob%:pat_filter" on first ":" into {path, pat}.
# pat is null when no ":" is present.
def split-path-pat [raw: string] {
  if ($raw | str contains ":") {
    let parts = ($raw | split row ":")
    # Keep ":" prefix so pat-parse treats the suffix as expr (scope="*")
    {path: ($parts | first), pat: (":" + ($parts | skip 1 | str join ":"))}
  } else {
    {path: $raw, pat: null}
  }
}

# ── sg passes ────────────────────────────────────────────────────────────────

def cg-funcs [path: string] {
  [
    (sg-json 'function $FUNC($$$): $RETURN {$$$}' $path)
    (sg-json 'function $FUNC($$$) {$$$}'           $path)
  ]
  | flatten
  | uniq-by text
  | each {|m| {
      name:  $m.metaVariables.single.FUNC.text
      slug:  ($m.file | path basename | str replace --regex '\.[^.]+$' '')
      file:  $m.file
      start: $m.range.start.line
      end:   $m.range.end.line
      text:  $m.text
    }}
}

def cg-calls-raw [path: string] {
  sg-json '$CALLEE($$$)' $path
  | each {|m| {
      callee: $m.metaVariables.single.CALLEE.text
      file:   $m.file
      line:   $m.range.start.line
    }}
  | where ($it.callee =~ '^[a-zA-Z_$][a-zA-Z0-9_$.]*$')
}

def cg-var-types [path: string] {
  [
    (sg-json 'const $VAR: $TYPE = $$$' $path)
    (sg-json 'let $VAR: $TYPE = $$$'   $path)
  ]
  | flatten
  | each {|m| {
      name: $m.metaVariables.single.VAR.text
      type: $m.metaVariables.single.TYPE.text
      file: $m.file
      line: $m.range.start.line
    }}
}

# ── parameter type extraction ─────────────────────────────────────────────────

def parse-param [p: string] {
  let t  = ($p | str trim)
  let ci = ($t | str index-of ":")
  if $ci <= 0 { return {} }
  let name = ($t | str substring 0..<$ci | str trim | str replace "?" "" | str replace "..." "")
  let raw_type = ($t | str substring ($ci + 1).. | str trim)
  let type = ($raw_type | str replace --regex '\s+=\s+[^>].*$' "" | str replace "readonly " "" | str trim)
  if ($name | str length) == 0 or ($type | str length) == 0 { return {} }
  {($name): $type}
}

# Walk chars to find outermost () and split on top-level commas.
# Handles function-type params like `compare: (a: T, b: T) => number`.
def extract-param-types [func_text: string] {
  let chars = ($func_text | split chars)

  mut depth = 0
  mut ps    = -1
  mut pe    = -1
  mut i     = 0
  for ch in $chars {
    if $ch == "(" {
      if $depth == 0 { $ps = $i }
      $depth = ($depth + 1)
    } else if $ch == ")" {
      $depth = ($depth - 1)
      if $depth == 0 { $pe = $i; break }
    }
    $i = ($i + 1)
  }
  if $ps < 0 or $pe <= $ps { return {} }

  let params_str = ($chars | skip ($ps + 1) | first ($pe - $ps - 1) | str join '')

  mut result = {}
  mut buf    = ""
  mut d      = 0
  for ch in ($params_str | split chars) {
    if $ch in ["(" "<" "["] {
      $d   = ($d + 1); $buf = ($buf + $ch)
    } else if $ch in [")" ">" "]"] {
      $d   = ($d - 1); $buf = ($buf + $ch)
    } else if $ch == "," and $d == 0 {
      $result = ($result | merge (parse-param $buf)); $buf = ""
    } else {
      $buf = ($buf + $ch)
    }
  }
  if ($buf | str trim | str length) > 0 { $result = ($result | merge (parse-param $buf)) }
  $result
}

# ── namespace ─────────────────────────────────────────────────────────────────

def common-prefix-len [paths: list] {
  let parts_list = ($paths | each {|p| $p | path split})
  let min_len    = ($parts_list | each {|p| $p | length} | math min)
  mut len = 0
  for i in 0..<$min_len {
    let vals = ($parts_list | each {|p| $p | get $i} | uniq)
    if ($vals | length) == 1 { $len = ($i + 1) } else { break }
  }
  $len
}

def file-slug-below [file: string, prefix_len: int] {
  let parts  = ($file | path split)
  let suffix = ($parts | skip $prefix_len)
  let stem   = ($suffix | enumerate | each {|e|
    if $e.index == (($suffix | length) - 1) {
      $e.item | str replace --regex '\.[^.]+$' ''
    } else {
      $e.item
    }
  })
  $stem | str join '.'
}

def cg-ns-map [funcs: list] {
  let slug_groups = (
    $funcs | select slug file | uniq
    | group-by slug
    | transpose slug entries
    | each {|r| {slug: $r.slug, files: ($r.entries | get file | uniq)}}
  )

  let file_slug_list = ($slug_groups | each {|g|
    if ($g.files | length) == 1 {
      [{file: ($g.files | first), effective_slug: $g.slug}]
    } else {
      let prefix_len = (common-prefix-len $g.files)
      $g.files | each {|f| {file: $f, effective_slug: (file-slug-below $f $prefix_len)}}
    }
  } | flatten)

  let still_colliding = (
    $file_slug_list
    | group-by effective_slug
    | transpose slug entries
    | each {|r| {slug: $r.slug, files: ($r.entries | get file | uniq)}}
    | where ($it.files | length) > 1
  )
  if ($still_colliding | is-not-empty) {
    let detail = ($still_colliding | each {|c| $"  ($c.slug): ($c.files | str join ', ')"} | str join "\n")
    error make {msg: $"namespace collision unresolvable:\n($detail)"}
  }

  let resolved = ($funcs | each {|f|
    let hit = ($file_slug_list | where file == $f.file)
    let effective_slug = if ($hit | is-not-empty) { $hit | first | get effective_slug } else { $f.slug }
    $f | merge {effective_slug: $effective_slug}
  })

  let file_slugs  = ($resolved | select file effective_slug | rename file namespace | uniq | sort-by file)
  let ns_map      = ($resolved | each {|f| {($f.name): $"($f.effective_slug).($f.name)"}} | reduce --fold {} {|item acc| $acc | merge $item})
  let all_callers = ($resolved | each {|f| {caller: $"($f.effective_slug).($f.name)", file: $f.file, line: $f.start}})
  {ns_map: $ns_map, file_slugs: $file_slugs, all_callers: $all_callers}
}

# ── method call type resolution ───────────────────────────────────────────────

def resolve-obj-type [obj: string, params: record, var_types: list, file: string, start: int, end: int] {
  let from_params = ($params | get --optional $obj)
  if $from_params != null { return $from_params }
  let hits = ($var_types | where file == $file and line >= $start and line <= $end and name == $obj)
  if ($hits | is-not-empty) { return ($hits | get type | first) }
  $obj
}

# ── edge building ─────────────────────────────────────────────────────────────

def cg-edges [path: string] {
  let paths = if ($path | str contains "%") {
    glob ($path | str replace --all "%" "*") | where ($it | path type) == "dir"
  } else {
    if not ($path | path exists) {
      print --stderr $"cg: path not found: ($path)"
      exit 1
    }
    [$path]
  }
  let funcs       = ($paths | each {|p| cg-funcs $p}     | flatten)
  let ns_result   = (cg-ns-map $funcs)
  let ns_map      = $ns_result.ns_map
  let file_slugs  = $ns_result.file_slugs
  let all_callers = $ns_result.all_callers
  let calls       = ($paths | each {|p| cg-calls-raw $p} | flatten)
  let var_types   = ($paths | each {|p| cg-var-types $p} | flatten)
  let pt_list     = ($funcs | each {|f| {key: $"($f.file):($f.start)", params: (extract-param-types $f.text)}})

  let edges = ($calls | each {|c|
    let owners = ($funcs | where file == $c.file and start <= $c.line and end >= $c.line)
    if ($owners | is-not-empty) {
      let owner  = ($owners | last)
      let caller = ($ns_map | get --optional $owner.name | default $"($owner.slug).($owner.name)")
      let p_key  = $"($owner.file):($owner.start)"
      let p_hits = ($pt_list | where key == $p_key)
      let params = if ($p_hits | is-not-empty) { $p_hits | get params | first } else { {} }

      let callee = if ($c.callee | str contains '.') {
        let parts  = ($c.callee | split row '.')
        let obj    = ($parts | first)
        let method = ($parts | skip 1 | str join '.')
        let typ    = (resolve-obj-type $obj $params $var_types $owner.file $owner.start $owner.end)
        $"($typ).($method)"
      } else {
        $ns_map | get --optional $c.callee | default $c.callee
      }

      {caller: $caller, callee: $callee, file: $owner.file, line: $c.line}
    }
  }
  | compact
  | where ($it.callee =~ '^[a-zA-Z_$][a-zA-Z0-9_$.]*$')
  | uniq
  | sort-by caller callee)

  let caller_set = ($edges | get caller | uniq)
  let leaf_rows  = (
    $all_callers
    | where not ($it.caller in $caller_set)
    | each {|f| {caller: $f.caller, callee: "", file: $f.file, line: $f.line}}
  )
  let full_edges = ($edges | append $leaf_rows | sort-by caller callee)

  {file_slugs: $file_slugs, edges: $full_edges}
}

# ── lf ────────────────────────────────────────────────────────────────────────

def lf-edges-display [edges_s: list, format: string] {
  let edges_display = $edges_s | each {|r|
    $r | transpose k v | reduce --fold {} {|p acc|
      let cell = match $p.k {
        "level"  => ($p.v | into string | rstr of | rstr tag "muted")
        "caller" => ($p.v | into string | rstr of | rstr tag "key")
        "callee" => {
          let s = ($p.v | into string)
          if ($s | is-empty) {
            ""
          } else if not ($s | str contains ".") {
            $s | rstr of | rstr tag "muted"
          } else {
            $s
          }
        }
        _ => ($p.v | into string)
      }
      $acc | insert $p.k $cell
    }
  }
  print ($edges_display | rope table | render walk {format: $format})
}

def lf-impl [dto: record, global: record] {
  let verbose = $global.verbose
  let raw_pat = $dto.args.pat
  let raw_path = $dto.args.path

  # Resolve filesystem path and effective pat:
  # - Two args: pat=raw_pat, path=raw_path
  # - One arg (pat only), scope is filtered (wildcard/regex): path must be explicit (error if missing)
  # - One arg (pat only), scope is fully literal (exact): scope is the filesystem path; use any-scope filter
  let dot_cfg = {delim: ".", expr_delim: null, anchors: [], anchor_descend: false}
  let pat = if $raw_pat != null {
    pat parse $raw_pat $dot_cfg
  } else {
    pat parse "" $dot_cfg
  }
  let scope_is_filtered = not (pat literal $pat.scope) and not (pat any $pat.scope)
  let path = if $raw_path != null {
    $raw_path
  } else if $raw_pat != null {
    # derive path from scope when no explicit path given
    if $scope_is_filtered {
      error make {msg: "lf: LIKE scope requires an explicit path argument (e.g. cg lf \"%\" src/)"}
    } else if (pat any $pat.scope) {
      "."
    } else {
      # scope is the filesystem path (fully literal); clear namespace scope filter
      pat stem $pat.scope
    }
  } else {
    "."
  }
  # When path was derived from scope, drop the scope filter (it's a fs path, not a namespace)
  let pat = if $raw_path == null and $raw_pat != null and not $scope_is_filtered and not (pat any $pat.scope) {
    {scope: (pat parse "" $dot_cfg).scope, expr: $pat.expr}
  } else {
    $pat
  }

  let result  = (cg-edges $path)

  let levels       = ($result.edges | cg-bfs-levels)
  let bfs_node_set = ($levels | columns)

  # scope → filter file table by namespace; filter edges by caller's namespace
  let file_slugs = if not (pat any $pat.scope) {
    $result.file_slugs | where {|r| ns-matches-scope $pat.scope $r.namespace}
  } else {
    $result.file_slugs
  }

  let edges = if not (pat any $pat.scope) {
    $result.edges | where {|r|
      let ns = ($r.caller | split row '.' | drop | str join '.')
      ns-matches-scope $pat.scope $ns
    }
  } else { $result.edges }

  # expr → filter by caller function name (last dot-segment)
  let edges = if not (pat any $pat.expr) {
    $edges | where {|r|
      let fn_name = ($r.caller | split row '.' | last)
      (pat match $pat.expr [{path: $fn_name, item: null}] | first).emit
    }
  } else { $edges }

  let edges_leveled = $edges | each {|e|
    let lv = if ($e.caller in $bfs_node_set) {
      $levels | get --optional $e.caller | default "~" | into string
    } else { "x" }
    $e | merge {level: $lv}
  }

  let extern_leaves = (
    $edges
    | where {|e| $e.callee != "" and not ($e.callee in $bfs_node_set)}
    | get callee | uniq
    | each {|c| {level: "x", caller: $c, callee: "", file: "", line: 0}}
  )

  let edges_all = ($edges_leveled | append $extern_leaves)

  let edges_stripped = if $verbose {
    $edges_all | select level caller callee line
  } else {
    $edges_all | select level caller callee | uniq-by caller callee
  }

  let edges_sorted = (
    $edges_stripped
    | each {|r|
      let s = if $r.level == "x" { 999 } else if $r.level == "~" { 998 } else { $r.level | into int }
      $r | merge {_s: $s}
    }
    | sort-by _s caller callee
    | reject _s
  )

  let edges_plain = ($edges_sorted | each {|r| $r | merge {level: (if $r.level == "x" { "extern" } else { $r.level })}})

  # filtered scope → group by file namespace and render one labeled table per group
  let use_grouped = (not (pat literal $pat.scope) and not (pat any $pat.scope))

  if $global.format == "json" or $global.format == "text" {
    if $use_grouped {
      # grouped: build a logical-node tree — one heading per namespace, leaf rows become embedded table
      let ns_list = ($file_slugs | get namespace | uniq | sort)
      let ns_nodes = ($ns_list | each {|ns|
        let group_edges = ($edges_plain | where {|r|
          let caller_ns = ($r.caller | split row '.' | drop | str join '.')
          $caller_ns == $ns
        })
        if ($group_edges | is-not-empty) {
          {
            label: {namespace: $ns}
            children: ($group_edges | each {|e| {label: {caller: $e.caller}, fields: ($e | reject caller)}})
          }
        } else {
          null
        }
      } | where {|n| $n != null})
      if ($ns_nodes | is-not-empty) {
        print ($ns_nodes | rope md-table | render walk {format: $global.format})
      }
    } else {
      print ($edges_plain | rope table | render walk {format: $global.format})
    }
  } else if $global.format == "rich" {
    if $use_grouped {
      # grouped rich: build a logical-node tree for rope md-table — one heading per namespace
      let ns_list = ($file_slugs | get namespace | uniq | sort)
      let ns_nodes = ($ns_list | each {|ns|
        let group_edges = ($edges_sorted | where {|r|
          let caller_ns = ($r.caller | split row '.' | drop | str join '.')
          $caller_ns == $ns
        })
        if ($group_edges | is-not-empty) {
          {
            label: {namespace: $ns}
            children: ($group_edges | each {|e| {label: {caller: $e.caller}, fields: ($e | reject caller)}})
          }
        } else {
          null
        }
      } | where {|n| $n != null})
      if ($ns_nodes | is-not-empty) {
        print ($ns_nodes | rope md-table | render walk {format: "rich"})
      }
    } else {
      let files_display = $file_slugs | each {|r|
        $r | transpose k v | reduce --fold {} {|p acc|
          let cell = match $p.k {
            "namespace" => ($p.v | into string | rstr of | rstr tag "key")
            _           => ($p.v | into string | rstr of | rstr tag "muted")
          }
          $acc | insert $p.k $cell
        }
      }
      print ($files_display | rope table | render walk {format: "rich"})
      lf-edges-display $edges_sorted "rich"
    }
  } else {
    print ($edges_plain | rope table | render walk {format: $global.format})
  }
}

# ── BFS level assignment ─────────────────────────────────────────────────────

def cg-bfs-levels []: list -> record {
  let edges            = $in
  let all_callers      = ($edges | get caller | uniq)
  let internal_callees = ($edges | where callee != "" | where {|e| $e.callee in $all_callers} | get callee | uniq)
  let entry_points     = ($all_callers | where {|f| not ($f in $internal_callees)})

  mut levels = ($all_callers | each {|f| {($f): null}} | reduce --fold {} {|item acc| $acc | merge $item})
  for ep in $entry_points {
    $levels = ($levels | merge {($ep): 0})
  }

  mut queue = $entry_points
  while ($queue | is-not-empty) {
    let node      = ($queue | first)
    $queue        = ($queue | skip 1)
    let cur_level = ($levels | get $node)

    let neighbors = (
      $edges
      | where caller == $node and callee != ""
      | where {|e| $e.callee in $all_callers}
      | get callee
      | uniq
      | where {|c| ($levels | get $c) == null}
    )

    for nb in $neighbors {
      $levels = ($levels | merge {($nb): ($cur_level + 1)})
      $queue  = ($queue | append $nb)
    }
  }

  $levels
}

# ── sequence DTO ─────────────────────────────────────────────────────────────

export def cg-seq-dto [levels: record]: list -> list {
  let edges       = $in
  let all_callers = ($edges | get caller | uniq)

  let edge_rows = (
    $edges
    | where callee != ""
    | each {|e|
        let caller_level = ($levels | get --optional $e.caller)
        let callee_level = ($levels | get --optional $e.callee)

        let kind = if not ($e.callee in $all_callers) {
          "extern"
        } else if $e.caller == $e.callee {
          "self"
        } else if $callee_level == null or $callee_level < ($caller_level | default 0) {
          "cycle"
        } else {
          "forward"
        }

        {
          caller:   $e.caller
          callee:   $e.callee
          level:    $caller_level
          line:     $e.line
          kind:     $kind
          external: (not ($e.callee in $all_callers))
        }
      }
  )

  # Include callers that have no outgoing edges (exist in namespace but call nothing tracked)
  let callers_with_edges = ($edge_rows | get caller | uniq)
  let leaf_caller_rows = (
    $all_callers
    | where {|c| not ($c in $callers_with_edges)}
    | each {|c| {
        caller:   $c
        callee:   ""
        level:    ($levels | get --optional $c)
        line:     ($edges | where caller == $c | first | get line)
        kind:     "leaf"
        external: false
      }}
  )

  let rows = ($edge_rows | append $leaf_caller_rows)
  let with_sort_key = ($rows | each {|r| $r | merge {_level_sort: ($r.level | default 999999)}})
  $with_sort_key | sort-by _level_sort caller callee | reject _level_sort
}

# ── sequence command ─────────────────────────────────────────────────────────

def cg-seq [edges: list, format: string, verbose: bool] {
  let levels  = ($edges | cg-bfs-levels)
  let dto_raw = if $verbose {
    $edges | cg-seq-dto $levels
  } else {
    $edges | cg-seq-dto $levels | uniq-by caller callee
  }
  let extern_terminals = (
    $dto_raw | where external | get callee | uniq
    | each {|c| {caller: $c, callee: "", level: null, line: null, kind: "extern", external: true}}
  )
  let dto = (
    ($dto_raw | append $extern_terminals)
    | each {|r| $r | merge {_s: ($r.level | default 999999)}}
    | sort-by _s caller
    | reject _s
  )
  let sym_map = {forward: "→", self: "↺", cycle: "⟳", extern: "↗", leaf: "·"}

  let display = ($dto | each {|row|
    let sym_raw = ($sym_map | get $row.kind)
    let level_cell = if $row.external and ($row.callee | is-empty) {
      "x" | rstr of | rstr tag "muted"
    } else {
      $row.level | default "~" | into string | rstr of | rstr tag "muted"
    }
    let kind_cell = match $row.kind {
      "self"   => ($sym_raw | rstr of | rstr tag "warn")
      "cycle"  => ($sym_raw | rstr of | rstr tag "error")
      "extern" => ($sym_raw | rstr of | rstr tag "muted")
      "leaf"   => ($sym_raw | rstr of | rstr tag "muted")
      _        => $sym_raw
    }
    let callee_cell = if $row.external {
      $row.callee | rstr of | rstr tag "muted"
    } else {
      $row.callee
    }
    if $verbose {
      {level: $level_cell, caller: $row.caller, kind: $kind_cell, callee: $callee_cell, line: $row.line, external: $row.external}
    } else {
      {level: $level_cell, caller: $row.caller, kind: $kind_cell, callee: $callee_cell, external: $row.external}
    }
  })

  let cols_json = if $verbose { ["level" "caller" "kind" "callee" "line" "external"] } else { ["level" "caller" "kind" "callee" "external"] }
  let cols_disp = if $verbose { ["level" "caller" "kind" "callee" "line"] } else { ["level" "caller" "kind" "callee"] }
  let plain_dto = ($dto | each {|row|
    let level_plain = if $row.external and ($row.callee | is-empty) { "extern" } else { $row.level | default "~" | into string }
    $row | merge {level: $level_plain}
  })
  match $format {
    "json"  => { print ($plain_dto | each {|r| $r | select --optional ...$cols_json} | rope table | render walk {format: "json"}) }
    "text"  => { print ($plain_dto | each {|r| $r | select --optional ...$cols_disp} | rope table | render walk {format: "text"}) }
    _       => { print ($display   | each {|r| $r | select --optional ...$cols_disp} | rope table | render walk {format: "rich"}) }
  }
}

def seq-impl [dto: record, global: record] {
  let split  = (split-path-pat $dto.args.path)
  let result = (cg-edges $split.path)

  # Apply pat to restrict BFS seeds; path suffix ":pat" overrides explicit pat? arg
  let dot_cfg  = {delim: ".", expr_delim: null, anchors: [], anchor_descend: false}
  let pat_str  = if $dto.args.pat != null { $dto.args.pat } else { $split.pat }
  let pat      = if $pat_str != null { pat parse $pat_str $dot_cfg } else { pat parse "" $dot_cfg }

  # Filter edges to only callers matching pat before BFS level assignment.
  let edges = if not (pat any $pat.scope) or not (pat any $pat.expr) {
    $result.edges | where {|r|
      let ns      = ($r.caller | split row '.' | drop | str join '.')
      let fn_name = ($r.caller | split row '.' | last)
      let scope_ok = if not (pat any $pat.scope) { ns-matches-scope $pat.scope $ns } else { true }
      let expr_ok  = if not (pat any $pat.expr)  { (pat match $pat.expr [{path: $fn_name, item: null}] | first).emit } else { true }
      $scope_ok and $expr_ok
    }
  } else { $result.edges }

  if $global.format == "rich" {
    let files_display = $result.file_slugs | each {|r|
      $r | transpose k v | reduce --fold {} {|p acc|
        let cell = match $p.k {
          "namespace" => ($p.v | into string | rstr of | rstr tag "key")
          _           => ($p.v | into string | rstr of | rstr tag "muted")
        }
        $acc | insert $p.k $cell
      }
    }
    print ($files_display | rope table | render walk {format: "rich"})
  } else if $global.format != "json" {
    print ($result.file_slugs | rope table | render walk {format: $global.format})
  }

  cg-seq $edges $global.format $global.verbose
}

# ── tree ──────────────────────────────────────────────────────────────────────

# Recursive DFS walk producing logical-nodes for rope tree.
# Returns {nodes: list<record>, new_seen: list<string>}
# Each node is a logical-node: {label, fields?, children?}
# Kinds: back (cycle ↩), diamond (already expanded …), extern (not a caller ↗), forward (normal)
def cg-tree-walk [
  node: string,
  visited: list,
  seen: list,
  all_callers: list,
  adj: record,
  verbose: bool,
] {
  let children_raw = ($adj | get --optional $node | default [])
  let children = ($children_raw | sort-by callee)

  mut nodes: list = []
  mut new_seen = $seen
  mut local_seen: list = []

  for child in $children {
    let callee  = $child.callee
    let line_no = $child.line
    let label   = if $verbose { $"($callee):($line_no)" } else { $callee }

    if $callee in $visited {
      # Back edge / cycle
      let logical = {label: {node: $label}, fields: {kind: ("↩" | rstr of | rstr tag "warn")}}
      $nodes = ($nodes | append $logical)
    } else if $callee in $local_seen {
      # Already expanded in this subtree — only show in verbose mode
      if $verbose {
        let is_extern = not ($callee in $all_callers)
        let logical = if $is_extern {
          {label: {node: $label}, fields: {kind: ("↗" | rstr of | rstr tag "muted")}}
        } else {
          {label: {node: $label}}
        }
        $nodes = ($nodes | append $logical)
      }
    } else if $callee in $new_seen {
      # Already expanded in another subtree — collapsed diamond
      let logical = {label: {node: $label}, fields: {kind: ("…" | rstr of | rstr tag "muted")}}
      $nodes = ($nodes | append $logical)
      $local_seen = ($local_seen | append $callee)
    } else if not ($callee in $all_callers) {
      # External function — leaf with extern marker
      let logical = {label: {node: $label}, fields: {kind: ("↗" | rstr of | rstr tag "muted")}}
      $nodes = ($nodes | append $logical)
      $local_seen = ($local_seen | append $callee)
    } else {
      # Normal forward edge — recurse
      $new_seen = ($new_seen | append $callee)
      $local_seen = ($local_seen | append $callee)
      let child_result = (cg-tree-walk $callee ($visited | append $callee) $new_seen $all_callers $adj $verbose)
      $new_seen = $child_result.new_seen
      let logical = {label: {node: $label}, children: $child_result.nodes}
      $nodes = ($nodes | append $logical)
    }
  }

  {nodes: $nodes, new_seen: $new_seen}
}

def tree-impl [dto: record, global: record] {
  let split   = (split-path-pat $dto.args.path)
  let pat_arg = $dto.args.pat
  let verbose = $global.verbose

  let result = (cg-edges $split.path)
  let edges  = $result.edges
  let levels = ($edges | cg-bfs-levels)

  # Build adjacency map: {caller -> [{callee, line}]}
  let adj = ($edges
    | where callee != ""
    | group-by caller
    | transpose caller entries
    | each {|r|
        let callees = ($r.entries | each {|e| {callee: $e.callee, line: $e.line}})
        {($r.caller): $callees}
      }
    | reduce --fold {} {|item acc| $acc | merge $item}
  )

  # Also add entries for callers that have no outgoing edges (leaf callers)
  let all_callers = ($edges | get caller | uniq)
  let adj = ($all_callers | reduce --fold $adj {|c acc|
    if ($acc | get --optional $c) == null {
      $acc | insert $c []
    } else {
      $acc
    }
  })

  # Resolve roots using pat
  let all_nodes = ($adj | columns)
  let dot_cfg   = {delim: ".", expr_delim: null, anchors: [], anchor_descend: false}
  let split     = (split-path-pat $dto.args.path)
  let pat_str   = if $pat_arg != null { $pat_arg } else { $split.pat }
  let pat       = if $pat_str != null { pat parse $pat_str $dot_cfg } else { pat parse "" $dot_cfg }

  let roots = if (pat any $pat.scope) and (pat any $pat.expr) {
    # No pat filter — use BFS level-0 entry points
    let zeros = ($levels | transpose k v | where v == 0 | get k
      | where {|n| ($adj | get --optional $n | default [] | length) > 0 })
    if ($zeros | length) == 0 {
      error make {msg: "tree: no level-0 entry point found; use a pat to select roots"}
    }
    $zeros | sort
  } else {
    # Use pat to select matching nodes as DFS roots.
    let matches = ($all_nodes | where {|n|
      let ns      = ($n | split row '.' | drop | str join '.')
      let fn_name = ($n | split row '.' | last)
      let scope_ok = if not (pat any $pat.scope) { ns-matches-scope $pat.scope $ns } else { true }
      let expr_ok  = if not (pat any $pat.expr)  { (pat match $pat.expr [{path: $fn_name, item: null}] | first).emit } else { true }
      $scope_ok and $expr_ok
    })
    if ($matches | length) == 0 {
      error make {msg: $"tree: no node matching pat found"}
    }
    $matches | sort
  }

  mut root_nodes: list = []
  mut seen_across: list = []

  for root in $roots {
    $seen_across = ($seen_across | append $root)
    let walk_result = (cg-tree-walk $root [$root] $seen_across $all_callers $adj $verbose)
    $seen_across = $walk_result.new_seen
    let root_node = {
      label: {node: $root}
      children: $walk_result.nodes
    }
    $root_nodes = ($root_nodes | append $root_node)
  }

  print ($root_nodes | rope tree | render walk {format: $global.format})
}

# ── entry ─────────────────────────────────────────────────────────────────────

def --wrapped main [...rest: string] {
  run-cg $rest
}

export def run-cg [argv: list<string>] {
  let spec = (cg-spec)
  let global = args parse-global $spec $argv
  let rest   = args strip-global $spec $argv

  let _d = ($global.debug | into int)
  let _level = if $_d == 1 { "info" } else if $_d == 2 { "debug" } else if $_d >= 3 { "trace" } else { "" }
  let _level = if ($global | get log_level? | default "" | is-not-empty) { $global.log_level } else { $_level }
  if ($_level | is-not-empty) { $env.NU_LOG_LEVEL = $_level }

  if ($rest | is-empty) {
    print (args usage $spec)
    return
  }

  # prepend default command when first token is not a command name (path shorthand)
  let cg_commands = ((cg-spec).commands | get name)
  let rest = if not (($rest | first) in $cg_commands) { ["lf"] ++ $rest } else { $rest }

  if ($global | get help? | default false) {
    let first = $rest | first
    if $first in $cg_commands {
      print (args cmd-help $spec $first)
    } else {
      print (args usage $spec)
    }
    return
  }

  let chain = args parse-chain $spec $rest
  for cmd in $chain {
    match $cmd.command {
      "lf"   => { lf-impl $cmd $global }
      "seq"  => { seq-impl $cmd $global }
      "tree" => { tree-impl $cmd $global }
      _      => { print $"Error: unknown command ($cmd.command)"; exit 1 }
    }
  }
}
