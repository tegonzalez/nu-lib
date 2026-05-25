#!/usr/bin/env nu
# 04-test/test_example.nu — demonstrates the test.nu harness
#
# Run all:            nu test_example.nu
# Filter by name:     nu test_example.nu --filter "safe-div"
# Filter by tag:      nu test_example.nu --tag smoke
# List cases:         nu test_example.nu --list
# Via runner:         nu ../../tools/runner.nu run
#
# The functions under test are defined inline to keep the example self-contained.
# In real use, replace them with: use ../../my-module.nu *

use ../../test.nu *

# ── Module under test (inline) ───────────────────────────────────────────────

def add [a: int, b: int] { $a + $b }

def slugify [s: string] {
  $s | str downcase | str replace --all " " "-"
}

def safe-div [a: float, b: float] {
  if $b == 0 {
    {ok: false, error: "division-by-zero"}
  } else {
    {ok: true, value: ($a / $b)}
  }
}

# ── Test cases ───────────────────────────────────────────────────────────────

def cases [] {[
  # scalar int
  {
    name: "add-two-integers"
    tags: [smoke]
    iut:  {|i| add $i.a $i.b}
    input:    {a: 3, b: 4}
    expected: 7
  }

  # string transform
  {
    name: "slugify-lowercases-and-hyphenates"
    tags: [smoke]
    iut:  {|i| slugify $i.s}
    input:    {s: "Hello World"}
    expected: "hello-world"
  }

  # record output — full match
  {
    name: "safe-div-returns-ok-and-value"
    iut:  {|i| safe-div $i.a $i.b}
    input:    {a: 10.0, b: 4.0}
    expected: {ok: true, value: 2.5}
  }

  # record output — partial match via assert-contains
  {
    name: "safe-div-zero-returns-error-(partial-match)"
    iut:  {|i| safe-div $i.a $i.b}
    input:    {a: 1.0, b: 0.0}
    expected: {ok: false}
    assert:   {|actual expected| assert-contains $actual $expected}
  }

  # intentional failure — shows failure output format
  {
    name: "add-(intentional-failure-demo)"
    iut:  {|i| add $i.a $i.b}
    input:    {a: 1, b: 1}
    expected: 99
  }

  # IUT throws — shows error output format
  {
    name: "iut-error-(intentional-error-demo)"
    iut:  {|i| error make {msg: "something went wrong"}}
    input:    {}
    expected: "unreachable"
  }

  # skipped
  {
    name: "skipped-placeholder"
    iut:  {|i| add $i.a $i.b}
    input:    {a: 0, b: 0}
    expected: 0
    skip:     true
  }

  # slow tests — sleep 200ms each so you can watch them run
  {
    name: "slow:-add-with-delay-alpha"
    tags: [slow]
    iut:  {|i| sleep 200ms; add $i.a $i.b}
    input:    {a: 10, b: 20}
    expected: 30
  }
  {
    name: "slow:-add-with-delay-beta"
    tags: [slow]
    iut:  {|i| sleep 200ms; add $i.a $i.b}
    input:    {a: 100, b: 200}
    expected: 300
  }
  {
    name: "slow:-slugify-with-delay"
    tags: [slow]
    iut:  {|i| sleep 200ms; slugify $i.s}
    input:    {s: "Slow Test"}
    expected: "slow-test"
  }
]}

def main [
  --filter(-f): string = ""
  --tag(-t):    string = ""
  --format:     string = "text"   # text | json  (json used by runner)
  --list(-l)                      # emit case metadata as JSON, no run
] {
  if $list {
    cases | list-cases | to json | print
    return
  }
  # jsonl: stream each record as it completes — must use each at call site,
  # not inside a custom def, because Nu collects $in before def bodies run.
  if $format == "jsonl" {
    let failures = (
      cases | run --filter $filter --tag $tag
      | each {|r|
          print ($r | to json --raw)
          if $r.status in ["fail" "error"] { 1 } else { 0 }
        }
      | math sum
    )
    if $failures > 0 { exit 1 }
    return
  }

  cases | run --filter $filter --tag $tag | report --format $format --file $env.CURRENT_FILE
}
