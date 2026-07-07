#!/usr/bin/env nu
# tools/runner.nu — test discovery and execution CLI
#
# Discovers test files matching **/test_*.nu and runs them as subprocesses.
# Each test file must implement:
#   def main [--filter --tag --format --list]
#
# Commands:
#   run [scope[:expr]]   discover + run; output DTO: list<result-record>
#   lf  [scope[:expr]]   list cases;    output DTO: grouped by folder, columns: file, name

use ../../lib/log.nu *
use ../../lib/test.nu *
use ../../lib/render.nu
use ../../lib/stream.nu *
use ../../lib/args.nu
use ../../lib/pat.nu *
use ../../lib/rstr.nu *
use ../../lib/pool.nu *
use ../../lib/rope.nu *
use ../../lib/path.nu *

# ── Runner CLI spec (private — A-005: app-specific config lives in the app) ──

# Authoritative runner spec: commands, global flags, defaults, default command.
# Adding a new output format requires updating global_flags here and render.nu only.
def runner-spec [] {
  {
    name:            "runner.nu"
    description:     "Discover and run Nu test files"
    default_command: "run"
    global_flags: [
      {name: help,    short: h, bool: true,                    description: "Show this help"}
      {name: format,  short: f, value: "fmt", default: "rich", description: "Output format: rich | text | json | terminal  (default: rich)"}
      {name: verbose, short: v, bool: true,                    description: "Show extra columns (duration_ms)"}
      {name: debug,   short: d, value: "N",     default: "0",  description: "Log verbosity: 1=info 2=debug 3=trace  (default: 0=warn)"}
      {name: jobs,    short: j, value: "N",     default: "0",  description: "Max parallel workers; 0 = nproc  (default: 0)"}
    ]
    commands: [
      {
        name: run
        args: ["pat?"]
        description: "Discover and run test files; scope is a literal file or folder, :expr filters case names"
        flags: [
          {name: tag, short: t, default: "", description: "Tag filter"}
        ]
      }
      {name: lf, args: ["pat?"], description: "List test cases grouped by folder; scope is a literal file or folder, :expr filters by name"}
    ]
  }
}

# ── Discovery ────────────────────────────────────────────────────────────────

# ntst-specific argument split: the first channel is a literal filesystem scope,
# not a pat.nu pattern. Only the optional expr channel is parsed by pat.nu.
def ntst-split [raw: any] {
  let s = if $raw == null or ($raw | is-empty) { "." } else { $raw }
  let has_expr = ($s | str contains ":")
  let scope = if $has_expr {
    let i = ($s | str index-of ":")
    $s | str substring 0..<$i
  } else { $s }
  let expr = if $has_expr {
    let i = ($s | str index-of ":")
    $s | str substring ($i + 1)..
  } else { "" }

  {scope: (if ($scope | is-empty) { "." } else { $scope }), expr: $expr}
}

def ntst-expr [expr: string, cfg: record] {
  (pat parse $":($expr)" $cfg).expr
}

def is-test-file [entry: record] {
  if $entry.type != "file" { return false }
  let basename = ($entry.name | path basename)
  ($basename | str starts-with "test_") and ($basename | str ends-with ".nu")
}

# Discover test files under a literal filesystem scope. File scopes select that
# file only; directory scopes recurse below the directory.
def discover-with-base [scope: string, invocation_base: record] {
  let root_path = (resolve-path $scope --base $invocation_base)
  let root_type = if $root_path.identity == null { null } else { $root_path.identity | path type }
  if $root_type == null {
    error make {msg: $"ntst: scope not found: ($scope)"}
  }
  let root_entry = {name: $root_path.logical_abs, type: $root_type}

  if $root_entry.type == "file" {
    if (is-test-file $root_entry) { return [$root_path.logical_abs] }
    return []
  }

  if $root_entry.type != "dir" { return [] }

  mut frontier = [$root_entry]
  mut found = []

  while ($frontier | is-not-empty) {
    mut next_frontier = []
    for rec in $frontier {
      if (is-test-file $rec) {
        $found = ($found | append (resolve-path $rec.name --base $invocation_base).logical_abs)
      } else if $rec.type == "dir" {
        let children = try { ls $rec.name | sort-by type name } catch { [] }
        $next_frontier = ($next_frontier ++ $children)
      }
    }
    $frontier = $next_frontier
  }
  $found | sort
}

def discover [scope: string] {
  discover-with-base $scope (resolve-path (pwd))
}

# ── run ──────────────────────────────────────────────────────────────────────

# Parse complete output from one test file into a list of event records.
# Skips non-JSON lines and applies the pattern filter.
# Returns list<record> where each record has _channel/fn/result/name/file/line/duration_ms/message/expected/actual.
def parse-file-output [f: string, out: record, expr_pat: record, invocation_base: record] {
  let rel     = (relative-display (resolve-path $f --base $invocation_base) $invocation_base)
  let fn_name = (file-to-stem $f)
  if $out.exit_code != 0 and ($out.stdout | str trim | is-empty) {
    return [{
      _channel:    "results"
      fn:          $fn_name
      result:      "error"
      name:        "<file-load>"
      file:        $rel
      line:        "?"
      duration_ms: 0
      message:     ($out.stderr | str trim)
      expected:    null
      actual:      null
    }]
  }
  $out.stdout
  | lines
  | where {|l| ($l | str trim | is-not-empty)}
  | reduce --fold [] {|line acc|
      let res = try { $line | from json } catch {|e|
        log debug $"ntst: skipping non-JSON line: ($e.msg)"
        null
      }
      let is_result = $res != null and ($res | describe | str starts-with "record") and "status" in ($res | columns) and "name" in ($res | columns)
      if not $is_result { $acc
      } else {
        let matches = (pat any $expr_pat) or ((pat filter $expr_pat [{path: $res.name, item: $res}] --value {|r| $r.path}) | where emit | is-not-empty)
        if not $matches { $acc
        } else if $res.status == "running" {
          let ev = {_channel: "progress", value: $"\u{21bb} ($res.name)"}
          $acc | append $ev
        } else {
          let ev = {
            _channel:    "results"
            fn:          $fn_name
            result:      $res.status
            name:        $res.name
            file:        $rel
            line:        ($res | get line?        | default "?")
            duration_ms: ($res | get duration_ms? | default 0)
            message:     ($res | get message?     | default "")
            expected:    ($res | get expected?    | default null)
            actual:      ($res | get actual?      | default null)
          }
          $acc | append $ev
        }
      }
    }
}

# Initial accumulator: domain counters only (_rs is upserted by run-impl after stream-open).
def run-fold [cfg: record] {
  {pass: 0, fail: 0, skip: 0, error: 0, failures: []}
}

def run-summary [acc: record] {
  [
    $"($acc.pass) pass"
    $"($acc.fail) fail"
    $"($acc.error) error"
    $"($acc.skip) skip"
  ] | str join "  "
}

def failure-detail-rows [acc: record, verbose: bool] {
  $acc.failures
  | where {|r| $r.result == "fail" or $r.result == "error"}
  | each {|r|
      let base = {
        fn:       ($r | get fn?       | default "" | into string)
        name:     ($r | get name?     | default "" | into string)
        result:   ($r | get result?   | default "" | into string)
        message:  ($r | get message?  | default "" | into string)
        expected: ($r | get expected? | default "" | into string)
        actual:   ($r | get actual?   | default "" | into string)
        file:     ($r | get file?     | default "" | into string)
      }
      if $verbose {
        $base | insert duration_ms ($r | get duration_ms? | default "" | into string)
      } else {
        $base
      }
    }
}

def print-failure-details [acc: record, global: record] {
  let verbose = ($global | get verbose? | default false)
  let rows = (failure-detail-rows $acc $verbose)
  if ($rows | is-empty) { return }

  let columns = {
    fn: {weight: 0}
    name: {weight: 1}
    result: {weight: 0}
    message: {weight: 2}
    expected: {weight: 1}
    actual: {weight: 1}
    file: {weight: 1}
  }
  let columns = if $verbose { $columns | insert duration_ms {weight: 0} } else { $columns }
  print ($rows | rope table --columns $columns | render walk {format: $global.format})
}

def print-final-summary [acc: record, global: record] {
  let value = (run-summary $acc)
  match $global.format {
    "json" | "jsonl" => { print ({_channel: "summary", value: $value} | to json --raw) }
    _ => { print $value }
  }
}

# Route one event: update domain counters for results events; delegate panel update to render.
# render state lives in acc._rs; runner owns pass/fail/skip/error/failures.
def run-step [cfg: record, acc: record, r: record] {
  let channel = ($r | get _channel? | default "results")
  if $channel == "progress" {
    let rs2 = (stream step ($acc._rs) $r)
    return ($acc | upsert _rs $rs2)
  }
  let acc2 = if $channel == "results" {
    $acc
    | upsert pass     ($acc.pass  + (if $r.result == "pass"  { 1 } else { 0 }))
    | upsert fail     ($acc.fail  + (if $r.result == "fail"  { 1 } else { 0 }))
    | upsert skip     ($acc.skip  + (if $r.result == "skip"  { 1 } else { 0 }))
    | upsert error    ($acc.error + (if $r.result == "error" { 1 } else { 0 }))
    | upsert failures (if $r.result != "pass" { $acc.failures | append $r } else { $acc.failures })
    | upsert _r2 $r
  } else { $acc | upsert _r2 $r }
  let r_full = ($acc2 | get _r2)
  let acc3   = ($acc2 | reject _r2)
  # Project to display cols only so the tail channel receives plain-string-compatible fields.
  let display_cols = ($cfg.render.output.cols)
  let r_out = ($display_cols | reduce --fold {_channel: ($r_full._channel)} {|col rec|
    $rec | upsert $col ($r_full | get --optional $col | default "" | into string)
  })
  let r_style  = match $r_full.result { "pass" | "skip" => "ok", _ => "error" }
  let r_styled = ($r_full.result | rstr of | rstr tag $r_style | rstr to-str)
  let r_out    = ($r_out | upsert result $r_styled)
  let summary_ev = {
    _channel: "summary"
    value: (run-summary $acc3)
  }
  let rs2 = (stream step (stream step ($acc3._rs) $r_out) $summary_ev)
  $acc3 | upsert _rs $rs2
}

# Run impl: accepts parsed DTO + global config, executes test discovery and streaming run.
def run-impl [dto: record, global: record] {
  let invocation_base = (resolve-path (pwd))
  let query    = ntst-split $dto.args.pat
  let run_cfg  = {delim: "/", expr_delim: null, anchors: [], anchor_descend: false}
  let expr_pat = ntst-expr $query.expr $run_cfg
  let tag      = $dto.flags.tag
  let run_cols = if $global.verbose { ["fn" "name" "result" "file" "message" "duration_ms"] } else { ["fn" "name" "result"] }
  let render_cfg = {output: {format: $global.format, cols: $run_cols, tail: 8}}
  let cfg = {render: $render_cfg, debug: $global.debug}
  let files    = (discover-with-base $query.scope $invocation_base)
  let tag_args = if ($tag | is-not-empty) { ["--tag" $tag] } else { [] }

  let render_channels = [{name: "results", kind: "tail", height: 12}, {name: "progress", kind: "label"}, {name: "summary", kind: "label"}]
  let init_rs = (stream open $render_cfg $render_channels)
  let init_acc = (run-fold $cfg | upsert _rs $init_rs)

  # pool-run is wrapped in try/catch: if a re-entrant interrupt escapes pool-run's
  # own catch (Nu's interrupt flag persists through if/break/pipelines), we catch it
  # here so stream-close always runs and the TUI is cleaned up before exit.
  # pool-run and stream-close are each wrapped in try/catch: Nu's interrupt flag
  # stays set after the first catch, so any subsequent pipeline or loop op is also
  # re-interrupted. Wrapping each stage individually ensures TUI cleanup runs
  # even when the interrupt flag fires mid-way through cleanup.
  let acc = try {
    pool-run $files $tag_args {|acc ev| run-step $cfg $acc $ev} --jobs ($global | get jobs? | default "0" | into int) --init ($init_acc | upsert last_start null) --parse {|f out| parse-file-output $f $out $expr_pat $invocation_base}
  } catch {|_|
    $init_acc | upsert _interrupted true
  }

  let close_rs = ($acc._rs | upsert labels {})
  try { stream close $close_rs } catch {|_| }

  print-failure-details $acc $global
  print-final-summary $acc $global

  try {
    if ($acc | get _interrupted? | default false) or ($acc.fail + $acc.error) > 0 { exit 1 }
  } catch {|_| exit 1 }
}

# ── lf ───────────────────────────────────────────────────────────────────────

# Derive stem from test filename: test_store.nu → store
def file-to-stem [path: string] {
  $path | path basename | str replace --regex '^test_' '' | str replace '.nu' ''
}

# Collect case metadata from all discovered files, grouped by directory.
# Output: one labeled section per directory (heading + table); columns: file (stem), name
# cfg: delim="/" for fs-shaped scope; expr_delim="/" so case names like "module/alpha"
# are matched depth-aware (% = one segment, %% = any depth).
def lf-impl [dto: record, global: record] {
  let invocation_base = (resolve-path (pwd))
  let query = ntst-split $dto.args.pat
  let lf_cfg  = {delim: "/", expr_delim: "/", anchors: [], anchor_descend: false}
  let expr_pat = ntst-expr $query.expr $lf_cfg

  let files   = (discover-with-base $query.scope $invocation_base)

  # Group files by their relative directory
  let groups = $files | group-by {|f| relative-display (resolve-path ($f | path dirname) --base $invocation_base) $invocation_base}

  let tree = $groups | transpose dir file_list | each {|g|
    let rows = $g.file_list | each {|f|
      let r = (^nu $f --list | complete)
      if $r.exit_code != 0 {
        [{file: (file-to-stem $f), name: "<file-load>", message: ($r.stderr | str trim)}]
      } else if ($r.stdout | str trim | is-empty) {
        []
      } else {
        let cases = ($r.stdout | str trim | from json)
        let filtered = if (pat any $expr_pat) {
          $cases
        } else {
          let recs = ($cases | each {|c| {path: $c.name, item: $c}})
          pat filter $expr_pat $recs --value {|r| $r.path}
          | where emit
          | each {|x| $x.record.item}
        }
        $filtered | each {|c| {file: (file-to-stem $f), name: $c.name}}
      }
    } | flatten

    if ($rows | is-empty) { null } else {
      {
        label: {dir: $g.dir}
        children: ($rows | each {|r| {label: {file: $r.file}, fields: {name: $r.name}}})
      }
    }
  } | where {$in != null}

  if ($tree | is-not-empty) {
    print ($tree | rope md-table | render walk {format: $global.format})
  }
}

# ── Entry point ───────────────────────────────────────────────────────────────
# Called by the bash wrapper with the raw argv list.
# $env.ARGV is not populated by Nu 0.112.2 when invoked via `nu script.nu args…`;
# the bash wrapper serialises $@ as a Nu list literal and calls this def directly.

export def run-ntst [argv: list<string>] {
  let spec   = (runner-spec)
  let global = args parse-global $spec $argv
  let rest   = args strip-global $spec $argv

  let _d = ($global.debug | into int)
  let _level = if $_d == 1 { "info" } else if $_d == 2 { "debug" } else if $_d >= 3 { "trace" } else { "" }
  let _level = if ($global | get log_level? | default "" | is-not-empty) { $global.log_level } else { $_level }
  if ($_level | is-not-empty) { $env.NU_LOG_LEVEL = $_level }
  if ($global | get --optional help | default false) {
    print (args usage $spec)
    return
  }

  # When no subcommand tokens are provided, resolve to the spec's default command.
  let argv2 = if ($rest | is-empty) { [$spec.default_command] } else { $rest }
  let chain = (args parse-chain $spec $argv2)
  $chain | each {|dto|
    match $dto.command {
      "run" => { run-impl $dto $global }
      "lf"  => { lf-impl  $dto $global }
    }
  } | ignore
}

def --wrapped main [...rest: string] {
  run-ntst $rest
}
