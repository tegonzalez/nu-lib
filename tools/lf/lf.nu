#!/usr/bin/env nu

use ../../lib/args.nu
use ../../lib/pat.nu *
use ../../lib/render.nu
use ../../lib/rope.nu *
use ../../lib/rstr.nu *

def lf-spec [] {
  {
    name: "lf"
    description: "Find filesystem entries by path or file name"
    default_command: "ls"
    global_flags: [
      {name: format, short: f, default: "rich", description: "Output format: rich | utf8 | plain | text | json  (default: rich)"}
    ]
    commands: [
      {
        name: ls
        args: ["pat?"]
        description: "Find entries; pat is a single argument parsed by pat.nu (scope matches the entry's rel-path; expr channel is reserved for future content grep)"
        flags: [
          {name: type, short: t, default: "md-table", description: "Render type: table | tree | md | md-table  (default: md-table)"}
        ]
        examples: [
          "lf                        -- list entries under cwd"
          "lf ./lib                  -- list entries under ./lib"
          "lf 'lib/%%'               -- list everything below lib/"
          "lf '%%/%.nu' -t tree      -- render .nu files anywhere as a tree"
          "lf README.md -f json      -- emit matching entries as JSON"
        ]
      }
    ]
  }
}

# Compute relative path from entry_path to root_abs.
def entry-rel [entry_path: string, root_abs: string] {
  try {
    let rel = ($entry_path | path relative-to $root_abs)
    if ($rel | is-empty) { "." } else { $rel }
  } catch {
    $entry_path
  }
}

# Shape a raw ls entry into a flat row record suitable for rope table or tree node fields.
def entry-row [entry: record, root_abs: string] {
  let rel = (entry-rel $entry.name $root_abs)
  {
    path: $rel
    name: ($entry.name | path basename)
    type: ($entry.type | into string)
    size: ($entry.size | into string)
  }
}

# Compute the display path: strip the seed prefix from an absolute BFS path to get
# the portion relative to the walk root.  The display path is what the user sees.
# Examples:
#   seed=""          abs="lib"          → "lib"
#   seed="nu-lib"    abs="nu-lib/bin"   → "bin"
#   seed="."         abs="./lib"        → "lib"
#   seed="" root="/" abs="/boot"        → "boot"
def lf-display-path [abs_path: string, seed: string, root_abs: string] {
  if ($seed | is-empty) {
    # Universal/root pattern: path is already relative (or "/"-prefixed for root_abs="/")
    if $root_abs == "/" {
      # Strip leading "/"
      if ($abs_path | str starts-with "/") {
        $abs_path | str substring 1..
      } else {
        $abs_path
      }
    } else {
      $abs_path
    }
  } else {
    # Strip seed prefix: "seed/" + rest → rest
    let pfx = $seed + "/"
    if ($abs_path | str starts-with $pfx) {
      $abs_path | str substring ($pfx | str length)..
    } else if $abs_path == $seed {
      # The seed entry itself — display as basename
      $seed | path basename
    } else {
      $abs_path
    }
  }
}

# Compute absolute filesystem path from BFS path and root_abs.
# BFS path is the pattern-matching path; root_abs is the absolute fs path of stem.
# When seed is non-empty: BFS path = "$seed/$rel", fs path = "$root_abs/$rel"
# When seed is empty: BFS path = "$path_prefix$rel", fs path = "$root_abs/$rel"
def lf-abs-path [bfs_path: string, seed: string, root_abs: string] {
  if ($seed | is-empty) {
    # bfs_path is relative (possibly with "/" prefix for root_abs="/")
    let rel = if ($bfs_path | str starts-with "/") {
      $bfs_path | str substring 1..
    } else {
      $bfs_path
    }
    if ($rel | is-empty) {
      $root_abs
    } else {
      [$root_abs $rel] | path join
    }
  } else {
    # bfs_path = "$seed/$rel" or "$seed" (seed itself)
    let pfx = $seed + "/"
    let rel = if ($bfs_path | str starts-with $pfx) {
      $bfs_path | str substring ($pfx | str length)..
    } else {
      ""  # bfs_path is seed itself
    }
    if ($rel | is-empty) {
      $root_abs
    } else {
      [$root_abs $rel] | path join
    }
  }
}

# Build logical node tree from flat BFS rows for rope tree/md/md-table rendering.
# rows: list of {path, name, type, size}  (path = display path, relative to walk root)
# prefix: path prefix for this subtree level (empty string = root level)
# Creates virtual parent nodes for implicit path prefixes when needed.
# Returns list of node records with label, fields, children.
def rows-to-nodes [rows: list, prefix: string] {
  # Compute the relative sub-path below this prefix for each row under this prefix.
  let under = if ($prefix | is-empty) {
    $rows
  } else {
    let pfx = $prefix + "/"
    $rows | where {|r| $r.path | str starts-with $pfx}
  }

  if ($under | is-empty) { return [] }

  # Collect the first segment of each row's sub-path (relative to prefix).
  # Group rows by that first segment to build one node per unique first segment.
  let prefix_len = if ($prefix | is-empty) { 0 } else { ($prefix | str length) + 1 }
  let grouped = $under | each {|r|
    let rel = $r.path | str substring $prefix_len..
    let first_seg = $rel | split row "/" | first
    {seg: $first_seg, row: $r}
  } | group-by seg

  $grouped | transpose seg entries | each {|g|
    let seg = $g.seg
    let seg_path = if ($prefix | is-empty) { $seg } else { $prefix + "/" + $seg }
    # Look for an explicit row for this segment path
    let own = $g.entries | where {|e| $e.row.path == $seg_path} | first 1
    let children = (rows-to-nodes $rows $seg_path)
    if ($own | length) > 0 {
      let row = ($own | first).row
      {
        label: {name: $row.name}
        fields: {
          type: ($row.type | rstr of | rstr tag "type")
          size: ($row.size | rstr of | rstr tag "size")
          path: $row.path
        }
        children: $children
      }
    } else {
      # Virtual parent node for an implicit directory segment
      {
        label: {name: $seg}
        fields: {
          type: ("dir" | rstr of | rstr tag "type")
          size: ("" | rstr of | rstr tag "size")
          path: $seg_path
        }
        children: $children
      }
    }
  }
}

# Build the single section expected by rope md-table: the walk root is the
# heading node, and matched entries are children grouped by the composer.
def rows-to-md-table-root [rows: list, root_entry: record, root_abs: string] {
  let root_label = if $root_abs == "/" {
    "/"
  } else {
    $root_entry.name | path basename
  }

  {
    label: {name: $root_label}
    children: (rows-to-nodes $rows "")
  }
}

def ls-impl [dto: record, global: record] {
  let render_type = $dto.flags.type
  let raw_pat = $dto.args.pat | default ""

  # pat v2 cfg for filesystem tools (lf-seed-cfg-shape, lf-seed-policy decisions)
  let fd_cfg = {delim: "/", expr_delim: null, anchors: [".", "..", "/"], anchor_descend: true}

  # Parse pattern via pat parse v2
  let channels = (pat parse $raw_pat $fd_cfg)
  let p = $channels.scope
  let q = $channels.expr

  # Expr channel is reserved — error when non-any (lf-expr-channel-reservation)
  if not (pat any $q) {
    error make {msg: "lf: expr channel is reserved for content search; use only the path/name scope channel"}
  }

  # Resolve stem to absolute walk root (lf-seed-policy: "" → cwd, "." → cwd, ".." → parent, "/" → fs root).
  # For patterns starting with "/" where stem is "" (e.g. /%, /%%): detect from raw scope channel.
  let stem = pat stem $p
  let scope_raw = if ($raw_pat | str contains ":") {
    let colon_pos = ($raw_pat | str index-of ":")
    $raw_pat | str substring 0..<$colon_pos
  } else {
    $raw_pat
  }
  let root_abs = if ($stem | is-empty) {
    if ($scope_raw | str starts-with "/") { "/" } else { "." | path expand }
  } else {
    $stem | path expand
  }

  if not ($root_abs | path exists) {
    error make {msg: $"lf: path not found: ($stem)"}
  }

  let root_entry = (ls --directory $root_abs | first)

  # BFS walk driven by pat match (pat-spec.md § 7 Canonical Tool Algorithm).
  # seed_path = $stem so that BFS paths are absolute pattern paths (e.g. "nu-lib/bin"
  # for pattern "nu-lib/%%"). The exception is the "/" root where stem="" but we must
  # prefix child paths with "/" to match patterns like "/%" or "/%%".
  # path_prefix is "/" only when root_abs="/" and stem="" (the fs-root case).
  let path_prefix = if ($stem | is-empty) and $root_abs == "/" { "/" } else { "" }
  let seed_path = $stem  # "" for universal / root-abs; stem value for non-empty stems

  # For a fully-literal pattern (pat literal), the stem IS the exact match — emit directly.
  # Per spec PK-3: literal + seed → emit=true, expand=false. The v2 impl returns expand=true
  # for any empty path, so we handle the literal case without BFS.
  let out = if (pat literal $p) {
    [{path: $seed_path, item: $root_entry}]
  } else {
    mut frontier = [{path: $seed_path, item: $root_entry}]
    mut bfs_out = []

    while ($frontier | is-not-empty) {
      let r = (pat match $p $frontier)
      # Collect emitted records.
      # Skip the root sentinel when stem="" (path=="" means universal root container).
      let emitted = ($r | where emit | each {|x| $x.record}
        | where {|rec| not (($rec.path | is-empty) and ($stem | is-empty))})
      $bfs_out = ($bfs_out ++ $emitted)
      # Expand: only directories
      $frontier = ($r | where expand | each {|x|
        if $x.record.item.type == "dir" {
          let bfs_path = $x.record.path
          let abs_path = (lf-abs-path $bfs_path $stem $root_abs)
          let children = try { ls $abs_path | sort-by type name } catch { [] }
          $children | each {|c|
            let child_name = ($c.name | path basename)
            # Build child BFS path: parent_bfs_path + "/" + child_name
            # When parent is the seed and seed is "", child path = path_prefix + child_name
            let child_path = if ($bfs_path | is-empty) {
              $path_prefix + $child_name
            } else {
              $bfs_path + "/" + $child_name
            }
            {path: $child_path, item: $c}
          }
        } else {
          []
        }
      } | flatten)
    }
    $bfs_out
  }

  # Convert BFS records to flat rows with display paths relative to walk root.
  let rows = ($out | each {|rec|
    let disp = (lf-display-path $rec.path $stem $root_abs)
    {
      path: $disp
      name: ($rec.item.name | path basename)
      type: ($rec.item.type | into string)
      size: ($rec.item.size | into string)
    }
  })

  let cols = {
    path: {justify: "left", weight: 4, clip: "rhs"}
    name: {justify: "left", weight: 2}
    type: {justify: "left", weight: 1}
    size: {justify: "right", weight: 1, min: 6}
  }

  match $render_type {
    "table" => {
      print ($rows | rope table --columns $cols | render walk {format: $global.format})
    }
    "tree" => {
      let nodes = (rows-to-nodes $rows "")
      print ($nodes | rope tree | render walk {format: $global.format})
    }
    "md" => {
      let nodes = (rows-to-nodes $rows "")
      print ($nodes | rope md | render walk {format: $global.format})
    }
    "md-table" => {
      if $global.format == "json" {
        let nodes = (rows-to-nodes $rows "")
        print ($nodes | rope tree | render walk {format: "json"})
      } else {
        let root = (rows-to-md-table-root $rows $root_entry $root_abs)
        print ($root | rope md-table --columns {
          name: {justify: "left", weight: 3}
          type: {justify: "left", weight: 1}
          size: {justify: "right", weight: 1}
          path: {justify: "left", weight: 4}
        } | render walk {format: $global.format})
      }
    }
    _ => { error make {msg: $"lf: invalid --type '($render_type)': must be one of table, tree, md, md-table"} }
  }
}

def --wrapped main [...rest: string] {
  run-fd $rest
}

export def run-fd [argv: list<string>] {
  let spec = (lf-spec)
  let global = args parse-global $spec $argv
  let rest = args strip-global $spec $argv
  let commands = ($spec.commands | get name)

  let rest = if ($rest | is-empty) {
    ["ls"]
  } else if not (($rest | first) in $commands) {
    ["ls"] ++ $rest
  } else {
    $rest
  }

  if ($global | get help? | default false) {
    let first = $rest | first
    if $first in $commands {
      print (args cmd-help $spec $first)
    } else {
      print (args usage $spec)
    }
    return
  }

  let chain = args parse-chain $spec $rest
  for cmd in $chain {
    match $cmd.command {
      "ls" => { ls-impl $cmd $global }
      _ => { print $"Error: unknown command ($cmd.command)"; exit 1 }
    }
  }
}
