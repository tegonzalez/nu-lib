# test.nu — unit test harness for Nu script modules
#
# IO contract:
#   Pure:  assert-eq, assert-contains, run, summarize
#   IO:    report — prints results + calls exit; do not use in composable pipelines
#
# Test record shape (NUON):
#   {
#     name:     string           # required — kebab-case slug (e.g. "mod-01-brief-slug")
#     iut:      closure          # required for runner "value"/"throws" — {|input| ...} wraps the fn under test
#     input:    any              # required for runner "value"/"throws" — DTO passed to iut
#     expected: any              # required — expected output DTO (see runner table below)
#     runner?:  string           # optional — "value" (default) | "throws" | "stdio" | "exit"
#     nu_src?:  string           # required for runner "stdio"/"exit" — Nu source string passed to ^nu -c
#     tags?:    list<string>     # optional — for --tag selection
#     assert?:  closure          # optional — {|actual expected| bool}; overrides assert-eq
#     skip?:    bool             # optional
#   }
#
# Runner types:
#   runner    actual                          expected              required fields
#   ────────  ──────────────────────────────  ────────────────────  ────────────────────────
#   value     return value of iut(input)      any value             name, iut, input, expected
#   throws    error message (string)          error msg substring   name, iut, expected
#             (iut must throw; pass if error  (compared via         (input? optional)
#              is thrown and msg matches)      assert-eq or assert?)
#   stdio     stdout of ^nu -c nu_src         string (trimmed       name, nu_src, expected
#             trimmed to a single string       stdout)
#   exit      exit code of ^nu -c nu_src      int (exit code)       name, nu_src, expected
#             as an integer
#
# Internal dispatch (private — not exported): run-value, run-throws, run-stdio, run-exit
# These are invoked by run-one based on the runner? field; do not call them directly.
#
# Test file convention (*.test.nu):
#   use ./lib/nu/test.nu *
#   def cases [] { [...] }
#   def main [--filter(-f): string = "", --tag(-t): string = "", --format: string = "text"] {
#     cases | run --filter $filter --tag $tag | report --format $format
#   }
#
# Streaming (jsonl) convention — runner calls ^nu $f --format jsonl.
# report --format jsonl uses `for r in $in` which collects $in before printing.
# For true per-record streaming, bypass report and use each at the call site:
#   def main [...] {
#     let failures = (
#       cases | run --filter $filter --tag $tag
#       | each {|r| print ($r | to nuon); if $r.status in ["fail" "error"] { 1 } else { 0 }}
#       | math sum
#     )
#     if $failures > 0 { exit 1 }
#   }

# ── Pure ─────────────────────────────────────────────────────────────────────

# Project test cases to {name, tags, skip} for --list output.
export def list-cases [] {
  $in | each {|c| {
    name: ($c | get name? | default "<unnamed>")
    tags: ($c | get tags? | default [])
    skip: ($c | get skip? | default false)
  }}
}

# Deep structural equality.
export def assert-eq [actual: any, expected: any] {
  $actual == $expected
}

# Partial match: every key in expected must exist in actual with equal value. Recurses.
export def assert-contains [actual: any, expected: any] {
  let t = ($expected | describe)
  if not ($t | str starts-with "record") { return ($actual == $expected) }
  $expected | columns | all {|k|
    let ev = ($expected | get $k)
    let av = ($actual | get --optional $k)
    if ($ev | describe | str starts-with "record") {
      assert-contains $av $ev
    } else {
      $av == $ev
    }
  }
}

def compare-outcome [rec: record, actual: any] {
  let ok = if ("assert" in ($rec | columns)) {
    do $rec.assert $actual $rec.expected
  } else {
    assert-eq $actual $rec.expected
  }
  {status: (if $ok { "pass" } else { "fail" }), actual: $actual, message: ""}
}

def run-value [rec: record] {
  try {
    let actual = (do $rec.iut $rec.input)
    compare-outcome $rec $actual
  } catch {|e|
    {status: "error", actual: null, message: $e.msg}
  }
}

def run-throws [rec: record] {
  try {
    do $rec.iut ($rec | get input? | default null)
    {status: "fail", actual: null, message: "expected error, none thrown"}
  } catch {|e|
    compare-outcome $rec $e.msg
  }
}

def run-stdio [rec: record] {
  try {
    let actual = (^nu -c $rec.nu_src | str trim)
    compare-outcome $rec $actual
  } catch {|e|
    {status: "error", actual: null, message: $e.msg}
  }
}

def run-exit [rec: record] {
  try {
    let result = (do { ^nu -c $rec.nu_src } | complete)
    let actual = $result.exit_code
    compare-outcome $rec $actual
  } catch {|e|
    {status: "error", actual: null, message: $e.msg}
  }
}

def run-one [rec: record] {
  let runner = ($rec | get runner? | default "value")

  # Validate required fields per runner type
  let base_fields = ["name" "expected"]
  let runner_fields = match $runner {
    "value"  => ["iut" "input"]
    "throws" => ["iut"]
    "stdio"  => ["nu_src"]
    "exit"   => ["nu_src"]
    _        => ["iut" "input"]
  }
  for field in ($base_fields ++ $runner_fields) {
    if not ($field in ($rec | columns)) {
      return {
        name:        ($rec | get name? | default "<unnamed>")
        status:      "error"
        actual:      null
        expected:    null
        message:     $"missing required field: ($field)"
        duration_ms: 0
      }
    }
  }

  if ($rec | get skip? | default false) {
    return {
      name:        $rec.name
      status:      "skip"
      actual:      null
      expected:    null
      message:     ""
      duration_ms: 0
    }
  }

  let t0 = (date now)

  let outcome = match $runner {
    "value"  => (run-value $rec)
    "throws" => (run-throws $rec)
    "stdio"  => (run-stdio $rec)
    "exit"   => (run-exit $rec)
    _        => (run-value $rec)
  }

  let ms = ((date now) - $t0) / 1ms | into int

  {
    name:        $rec.name
    status:      $outcome.status
    actual:      $outcome.actual
    expected:    $rec.expected
    message:     $outcome.message
    duration_ms: $ms
    line:        ($rec | get line? | default null)
  }
}

# Run a list of test records. Input via $in. Yields a {status: "running"} record before
# each test, then the result record after. Downstream (report --format jsonl) prints each
# as it arrives so the runner subprocess can stream results line-by-line.
export def run [
  --filter(-f): string = ""
  --tag(-t):    string = ""
] {
  let tests = $in
  $tests
  | where {|r|
      let name_ok = ($filter | is-empty) or ($r.name | str contains $filter)
      let tag_ok  = ($tag | is-empty) or (($r | get tags? | default []) | any {|t| $t == $tag})
      $name_ok and $tag_ok
    }
  | each {|r|
      [
        {name: $r.name, status: "running", actual: null, expected: null, message: "", duration_ms: 0}
        (run-one $r)
      ]
    }
  | flatten
}

# Summarize a result list. Input via $in.
export def summarize [] {
  let rs = $in
  {
    total:    ($rs | length)
    passed:   ($rs | where status == "pass"  | length)
    failed:   ($rs | where status == "fail"  | length)
    skipped:  ($rs | where status == "skip"  | length)
    errored:  ($rs | where status == "error" | length)
    failures: ($rs | where {|r| $r.status in ["fail" "error"]})
  }
}

# ── IO ───────────────────────────────────────────────────────────────────────

# Print results and a summary line. Exits non-zero on any fail or error.
# --format json  emits raw JSON for machine consumption (e.g. runner subprocess)
# --file         source path shown as file:line on fail/error lines
# Input: list<result-record> via $in
export def report [
  --format: string = "text"
  --file:   string = ""
] {
  # jsonl streams $in directly — must not collect first
  if $format == "jsonl" {
    mut n_fail = 0
    mut n_err  = 0
    for r in $in {
      print ($r | to json --raw)
      if $r.status == "fail"  { $n_fail += 1 }
      if $r.status == "error" { $n_err  += 1 }
    }
    if ($n_fail + $n_err) > 0 { exit 1 }
    return
  }

  let results = $in

  if $format == "json" {
    let completed = ($results | where status != "running")
    print ($completed | to json)
    let sum = ($completed | summarize)
    if ($sum.failed + $sum.errored) > 0 { exit 1 }
    return
  }

  let sum = ($results | summarize)

  for r in $results {
    let icon = match $r.status {
      "pass"  => "  PASS"
      "fail"  => "  FAIL"
      "skip"  => "  SKIP"
      "error" => " ERROR"
    }
    let ms = if $r.duration_ms > 0 { $"  ($r.duration_ms)ms" } else { "" }
    print $"($icon)  ($r.name)($ms)"

    if $r.status in ["fail" "error"] {
      let src = if ($file | is-not-empty) { $file } else { ($r | get file? | default "") }
      if ($src | is-not-empty) {
        let line = ($r | get line? | default "?")
        print $"        → ($src):($line)"
      }
      if ($r.message | is-not-empty) {
        print $"        ($r.message)"
      }
      if $r.status == "fail" {
        print $"        expected: ($r.expected | to nuon)"
        print $"        actual:   ($r.actual   | to nuon)"
      }
    }
  }

  print ""
  print $"($sum.total) tests  ($sum.passed) passed  ($sum.failed) failed  ($sum.errored) errored  ($sum.skipped) skipped"

  if ($sum.failed + $sum.errored) > 0 { exit 1 }
}
