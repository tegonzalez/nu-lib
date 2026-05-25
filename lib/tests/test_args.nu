#!/usr/bin/env nu

use ../test.nu *
use ../args.nu *

# Spec factory — closures cannot capture module-level `let` in Nu;
# use a def so each test can call it via $i.spec or inline.
def test-spec [] {
  {
    name:        "test-tool"
    description: "test spec"
    global_flags: [
      {name: format,  short: f, bool: false, default: "table", description: "output format"}
      {name: verbose, short: v, bool: true,                    description: "verbose"}
    ]
    commands: [
      {
        name:        "run"
        description: "run tests"
        args:        ["pattern?"]
        flags: [
          {name: glob,    short: g, bool: false, default: "**/*.nu", description: "glob pattern"}
          {name: verbose, short: v, bool: true,                      description: "verbose output"}
        ]
      }
      {
        name:        "ls"
        description: "list tests"
        args:        ["filter?"]
        flags:       []
      }
      {
        name:        "push"
        description: "push branch"
        args:        ["branch"]
        flags:       []
      }
    ]
  }
}


def counted-force-spec [] {
  {
    name:        "test-tool"
    description: "test spec"
    commands: [
      {
        name:        "run"
        description: "run tests"
        args:        []
        flags: [
          {name: verbose, short: v, bool: true, description: "verbose output"}
          {name: force,   short: f, bool: true, counted: true, description: "force"}
        ]
      }
    ]
  }
}

def cat-force-spec [] {
  {
    name:        "test-tool"
    description: "cat force shadowing spec"
    global_flags: [
      {name: format, short: f, bool: false, default: "table", description: "output format"}
    ]
    commands: [
      {
        name:        "cat"
        description: "cat record"
        args:        []
        flags: [
          {name: force,   short: F, bool: true, counted: true, description: "force"}
          {name: verbose, short: v, bool: true,                 description: "verbose output"}
        ]
      }
    ]
  }
}

# Error-capture helper: returns true if the closure errors and message contains fragment.
# The closure receives the spec as its argument to avoid capture issues.
def err-iut [fn: closure, spec: record, fragment: string] {
  try { do $fn $spec; false } catch {|e| $e.msg | str contains $fragment}
}

def cases [] { [

  # ── global-dto ──────────────────────────────────────────────────────────────

  {name: "gd-01-bool-flag-absent-resolves-to-false"
   iut: {|i| global-dto $i.spec $i.globals}
   input: {spec: (test-spec), globals: {format: "table", verbose: null}}
   expected: {format: "table", verbose: false}}

  {name: "gd-02-value-flag-absent-with-default-applies-default"
   iut: {|i| global-dto $i.spec $i.globals}
   input: {spec: (test-spec), globals: {format: null, verbose: false}}
   expected: {format: "table", verbose: false}}

  {name: "gd-03-value-flag-present-uses-provided-value"
   iut: {|i| global-dto $i.spec $i.globals}
   input: {spec: (test-spec), globals: {format: "json", verbose: false}}
   expected: {format: "json", verbose: false}}

  {name: "gd-04-spec-with-no-global-flags-returns-empty-record"
   iut: {|i| global-dto $i.spec $i.globals}
   input: {spec: {name: "x", description: "x", commands: []}, globals: {}}
   expected: {}}

  # ── split-chain ──────────────────────────────────────────────────────────────

  {name: "sc-01-single-segment"
   iut: {|i| split-chain $i}
   input: ["ls"]
   expected: [["ls"]]}

  {name: "sc-02-two-segments"
   iut: {|i| split-chain $i}
   input: ["run" "--glob" "*.nu" "!" "ls"]
   expected: [["run" "--glob" "*.nu"] ["ls"]]}

  {name: "sc-03-empty-argv-returns-empty-list"
   iut: {|i| split-chain $i}
   input: []
   expected: []}

  {name: "sc-04-trailing-separator-dropped"
   iut: {|i| split-chain $i}
   input: ["ls" "!"]
   expected: [["ls"]]}

  # ── parse-segment ────────────────────────────────────────────────────────────

  {name: "ps-01-valid-command-no-flags"
   iut: {|i| parse-segment $i.spec $i.seg}
   input: {spec: (test-spec), seg: ["ls"]}
   expected: {command: "ls", flags: {help: false}, args: {filter: null}}}

  {name: "ps-02-value-flag-long-form"
   iut: {|i| (parse-segment $i.spec $i.seg).flags.glob}
   input: {spec: (test-spec), seg: ["run" "--glob" "src/**"]}
   expected: "src/**"}

  {name: "ps-03-bool-flag-long-form-parsed-as-true"
   iut: {|i| (parse-segment $i.spec $i.seg).flags.verbose}
   input: {spec: (test-spec), seg: ["run" "--verbose"]}
   expected: true}

  {name: "ps-04-short-alias-bool-flag"
   iut: {|i| (parse-segment $i.spec $i.seg).flags.verbose}
   input: {spec: (test-spec), seg: ["run" "-v"]}
   expected: true}

  {name: "ps-05-short-alias-value-flag"
   iut: {|i| (parse-segment $i.spec $i.seg).flags.glob}
   input: {spec: (test-spec), seg: ["run" "-g" "src/**"]}
   expected: "src/**"}

  {name: "ps-06-unknown-flag-errors"
   iut: {|i| err-iut {|s| parse-segment $s ["run" "--unknown"]} $i "unknown flag"}
   input: (test-spec)
   expected: true}

  {name: "ps-07-missing-required-positional-errors"
   iut: {|i| err-iut {|s| parse-segment $s ["push"]} $i "required positional"}
   input: (test-spec)
   expected: true}

  {name: "ps-08-optional-positional-absent-is-null"
   iut: {|i| (parse-segment $i.spec $i.seg).args.pattern}
   input: {spec: (test-spec), seg: ["run"]}
   expected: null}

  {name: "ps-09-bool-flag-absent-defaults-to-false"
   iut: {|i| (parse-segment $i.spec $i.seg).flags.verbose}
   input: {spec: (test-spec), seg: ["run"]}
   expected: false}

  {name: "ps-10-default-applied-for-absent-value-flag"
   iut: {|i| (parse-segment $i.spec $i.seg).flags.glob}
   input: {spec: (test-spec), seg: ["run"]}
   expected: "**/*.nu"}

  {name: "ps-11-combined-short-flag-errors"
   iut: {|i| err-iut {|s| parse-segment $s ["run" "-vg"]} $i "combined short flags"}
   input: (test-spec)
   expected: true}

  {name: "ps-12-inline-flag-value-form-errors"
   iut: {|i| err-iut {|s| parse-segment $s ["run" "--glob=src/**"]} $i "not supported"}
   input: (test-spec)
   expected: true}

  {name: "cf-01-counted-force-absent-resolves-to-zero"
   iut: {|i| (parse-segment $i.spec $i.seg).flags.force}
   input: {spec: (counted-force-spec), seg: ["run"]}
   expected: 0}

  {name: "cf-02-counted-force-short-form-resolves-to-one"
   iut: {|i| (parse-segment $i.spec $i.seg).flags.force}
   input: {spec: (counted-force-spec), seg: ["run" "-f"]}
   expected: 1}

  {name: "cf-03-counted-force-long-form-resolves-to-one"
   iut: {|i| (parse-segment $i.spec $i.seg).flags.force}
   input: {spec: (counted-force-spec), seg: ["run" "--force"]}
   expected: 1}

  {name: "cf-04-counted-force-repeated-short-form-resolves-to-two"
   iut: {|i| (parse-segment $i.spec $i.seg).flags.force}
   input: {spec: (counted-force-spec), seg: ["run" "-ff"]}
   expected: 2}

  {name: "cf-05-counted-force-mixed-short-flags-still-error"
   iut: {|i| err-iut {|s| parse-segment $s ["run" "-vf"]} $i "combined short flags"}
   input: (counted-force-spec)
   expected: true}

  {name: "cf-06-ordinary-bool-short-flag-is-not-counted"
   iut: {|i| err-iut {|s| parse-segment $s ["run" "-vv"]} $i "combined short flags"}
   input: (counted-force-spec)
   expected: true}


  # cat-force: cat -F and cat -FF are command-local force; cat -f json and leading -f json remain global format.
  {name: "cat-force-01-cat -F-parses-as-command-local-force-level-1"
   iut: {|i|
     let global = parse-global $i.spec $i.argv
     let parsed = parse-chain $i.spec (strip-global $i.spec $i.argv)
     {format: $global.format, force: (($parsed | first).flags.force)}
   }
   input: {spec: (cat-force-spec), argv: ["cat" "-F"]}
   expected: {format: "table", force: 1}}

  {name: "cat-force-02-cat -FF-parses-as-command-local-force-level-2"
   iut: {|i|
     let global = parse-global $i.spec $i.argv
     let parsed = parse-chain $i.spec (strip-global $i.spec $i.argv)
     {format: $global.format, force: (($parsed | first).flags.force)}
   }
   input: {spec: (cat-force-spec), argv: ["cat" "-FF"]}
   expected: {format: "table", force: 2}}

  {name: "cat-force-03-cat---format-parses-as-global-format"
   iut: {|i|
     let global = parse-global $i.spec $i.argv
     let parsed = parse-chain $i.spec (strip-global $i.spec $i.argv)
     {format: $global.format, force: (($parsed | first).flags.force)}
   }
   input: {spec: (cat-force-spec), argv: ["cat" "--format" "json"]}
   expected: {format: "json", force: 0}}

  {name: "cat-force-04-cat--f-json-parses-as-global-format"
   iut: {|i|
     let global = parse-global $i.spec $i.argv
     let parsed = parse-chain $i.spec (strip-global $i.spec $i.argv)
     {format: $global.format, force: (($parsed | first).flags.force)}
   }
   input: {spec: (cat-force-spec), argv: ["cat" "-f" "json"]}
   expected: {format: "json", force: 0}}

  {name: "cat-force-05-leading--f-json-parses-as-global-format"
   iut: {|i|
     let global = parse-global $i.spec $i.argv
     let parsed = parse-chain $i.spec (strip-global $i.spec $i.argv)
     {format: $global.format, force: (($parsed | first).flags.force)}
   }
   input: {spec: (cat-force-spec), argv: ["-f" "json" "cat"]}
   expected: {format: "json", force: 0}}

  {name: "cat-force-06-mixed-non-counted-combined-short-flags-still-error"
   iut: {|i| err-iut {|s| parse-chain $s (strip-global $s ["cat" "-vF"])} $i "combined short flags"}
   input: (cat-force-spec)
   expected: true}

  # ── parse-chain ──────────────────────────────────────────────────────────────

  {name: "pc-01-empty-argv-returns-empty-list"
   iut: {|i| parse-chain $i.spec $i.argv}
   input: {spec: (test-spec), argv: []}
   expected: []}

  {name: "pc-02-single-command-returns-length-1-list"
   iut: {|i| parse-chain $i.spec $i.argv | length}
   input: {spec: (test-spec), argv: ["ls"]}
   expected: 1}

  {name: "pc-03-two-command-chain-returns-length-2-list"
   iut: {|i| parse-chain $i.spec $i.argv | length}
   input: {spec: (test-spec), argv: ["run" "!" "ls"]}
   expected: 2}

  # ── fallback_command routing ────────────────────────────────────────────────

  {name: "ps-13-unknown-token-routes-to-fallback-command"
   iut: {|i| (parse-segment $i.spec $i.seg).command}
   input: {spec: {
     name: "t" description: "t" fallback_command: "_default"
     commands: [
       {name: "ls",       args: ["path?"],  description: "list"}
       {name: "_default", hidden: true, args: ["token"], description: ""}
     ]
   }, seg: ["mykey=val"]}
   expected: "_default"}

  {name: "ps-14-fallback-token-becomes-args-token"
   iut: {|i| (parse-segment $i.spec $i.seg).args.token}
   input: {spec: {
     name: "t" description: "t" fallback_command: "_default"
     commands: [
       {name: "ls",       args: ["path?"],  description: "list"}
       {name: "_default", hidden: true, args: ["token"], description: ""}
     ]
   }, seg: ["mykey=val"]}
   expected: "mykey=val"}

  {name: "ps-15-known-command-still-routes-with-fallback-spec"
   iut: {|i| (parse-segment $i.spec $i.seg).command}
   input: {spec: {
     name: "t" description: "t" fallback_command: "_default"
     commands: [
       {name: "ls",       args: ["path?"],  description: "list"}
       {name: "_default", hidden: true, args: ["token"], description: ""}
     ]
   }, seg: ["ls"]}
   expected: "ls"}

  # ── usage hidden:true ───────────────────────────────────────────────────────

  {name: "us-01-hidden-commands-omitted-from-usage-output"
   iut: {|i| usage $i | str contains "_default"}
   input: {
     name: "t" description: "t" fallback_command: "_default"
     commands: [
       {name: "ls",       args: ["path?"],  description: "list"}
       {name: "_default", hidden: true, args: ["token"], description: ""}
     ]
   }
   expected: false}

  # ── flag-then-positional (args-return regression) ──────────────────────────

  {name: "ps-16-positional-after-flag-value-is-captured"
   iut: {|i| (parse-segment $i.spec $i.seg).args.pattern}
   input: {spec: (test-spec), seg: ["run" "--glob" "src/**" "mypattern"]}
   expected: "mypattern"}

  # ── parse-global ─────────────────────────────────────────────────────────────

  {name: "pg-01-bool-flag-long-form-present-resolves-to-true"
   iut: {|i| (parse-global $i.spec $i.argv).verbose}
   input: {spec: (test-spec), argv: ["--verbose" "run"]}
   expected: true}

  {name: "pg-02-bool-flag-absent-resolves-to-false"
   iut: {|i| (parse-global $i.spec $i.argv).verbose}
   input: {spec: (test-spec), argv: ["run"]}
   expected: false}

  {name: "pg-03-value-flag-long-form-parsed"
   iut: {|i| (parse-global $i.spec $i.argv).format}
   input: {spec: (test-spec), argv: ["--format" "json" "run"]}
   expected: "json"}

  {name: "pg-04-value-flag-short-form-parsed"
   iut: {|i| (parse-global $i.spec $i.argv).format}
   input: {spec: (test-spec), argv: ["-f" "json" "run"]}
   expected: "json"}

  {name: "pg-05-bool-flag-short-form-present-resolves-to-true"
   iut: {|i| (parse-global $i.spec $i.argv).verbose}
   input: {spec: (test-spec), argv: ["-v" "run"]}
   expected: true}

  {name: "pg-06-missing-value-flag-applies-default"
   iut: {|i| (parse-global $i.spec $i.argv).format}
   input: {spec: (test-spec), argv: ["run"]}
   expected: "table"}

  {name: "pg-07-set-form-token-not-scanned-for-flags"
   iut: {|i| (parse-global $i.spec $i.argv).verbose}
   input: {spec: (test-spec), argv: ["key=--verbose" "run"]}
   expected: false}

  {name: "pg-08-unknown-flag-passes-through-silently"
   iut: {|i| (parse-global $i.spec $i.argv).format}
   input: {spec: (test-spec), argv: ["--unknown-flag" "run"]}
   expected: "table"}

  {name: "pg-09-value-flag-with-no-following-token-errors"
   iut: {|i| err-iut {|s| parse-global $s ["--format"]} $i "missing value"}
   input: (test-spec)
   expected: true}

  {name: "pg-10-spec-with-no-global-flags-returns-help-only-record"
   iut: {|i| parse-global $i.spec $i.argv}
   input: {spec: {name: "x", description: "x", commands: []}, argv: ["run"]}
   expected: {help: false}}

  # ── strip-global ──────────────────────────────────────────────────────────────

  {name: "sg-01-bool-flag-long-form-removed"
   iut: {|i| strip-global $i.spec $i.argv}
   input: {spec: (test-spec), argv: ["--verbose" "run"]}
   expected: ["run"]}

  {name: "sg-02-bool-flag-short-form-removed"
   iut: {|i| strip-global $i.spec $i.argv}
   input: {spec: (test-spec), argv: ["-v" "run"]}
   expected: ["run"]}

  {name: "sg-03-value-flag-long-form-and-value-removed"
   iut: {|i| strip-global $i.spec $i.argv}
   input: {spec: (test-spec), argv: ["--format" "json" "run"]}
   expected: ["run"]}

  {name: "sg-04-value-flag-short-form-and-value-removed"
   iut: {|i| strip-global $i.spec $i.argv}
   input: {spec: (test-spec), argv: ["-f" "json" "run"]}
   expected: ["run"]}

  {name: "sg-05-unknown-flag-passes-through-untouched"
   iut: {|i| strip-global $i.spec $i.argv}
   input: {spec: (test-spec), argv: ["--unknown" "run"]}
   expected: ["--unknown" "run"]}

  {name: "sg-06-set-form-token-not-stripped"
   iut: {|i| strip-global $i.spec $i.argv}
   input: {spec: (test-spec), argv: ["key=--verbose" "run"]}
   expected: ["key=--verbose" "run"]}

  {name: "sg-07-flag-between-separators-stripped-segments-intact"
   iut: {|i| split-chain (strip-global $i.spec $i.argv)}
   input: {spec: (test-spec), argv: ["run" "--format" "json" "!" "ls"]}
   expected: [["run"] ["ls"]]}

  {name: "sg-08-no-global-flags-argv-unchanged"
   iut: {|i| strip-global $i.spec $i.argv}
   input: {spec: {name: "x", description: "x", commands: []}, argv: ["run" "--flag"]}
   expected: ["run" "--flag"]}

  {name: "sg-09-multiple-global-flags-all-stripped"
   iut: {|i| strip-global $i.spec $i.argv}
   input: {spec: (test-spec), argv: ["-v" "--format" "text" "run"]}
   expected: ["run"]}

  {name: "sg-10-value-flag-with-no-following-token-errors"
   iut: {|i| err-iut {|s| strip-global $s ["--format"]} $i "missing value"}
   input: (test-spec)
   expected: true}

  # ── implicit global help ──────────────────────────────────────────────────────

  {name: "pg-11-implicit-help-long-form-resolves-to-true"
   iut: {|i| (parse-global $i.spec $i.argv).help}
   input: {spec: (test-spec), argv: ["--help"]}
   expected: true}

  {name: "pg-12-implicit-help-short-form-resolves-to-true"
   iut: {|i| (parse-global $i.spec $i.argv).help}
   input: {spec: (test-spec), argv: ["-h" "run"]}
   expected: true}

  {name: "pg-13-implicit-help-absent-resolves-to-false"
   iut: {|i| (parse-global $i.spec $i.argv).help}
   input: {spec: (test-spec), argv: ["run"]}
   expected: false}

  {name: "pg-14-help-present-alongside-other-flags"
   iut: {|i| (parse-global $i.spec $i.argv)}
   input: {spec: (test-spec), argv: ["--help" "-v"]}
   expected: {format: "table", verbose: true, help: true}}

  {name: "pg-15-no-global-flags-spec-still-returns-help-field"
   iut: {|i| (parse-global $i.spec $i.argv).help}
   input: {spec: {name: "x", description: "x", commands: []}, argv: ["--help"]}
   expected: true}

  {name: "pg-16-no-global-flags-spec-help-absent-is-false"
   iut: {|i| (parse-global $i.spec $i.argv).help}
   input: {spec: {name: "x", description: "x", commands: []}, argv: ["run"]}
   expected: false}

  # ── strip-global strips help ──────────────────────────────────────────────────

  {name: "sg-11-implicit-help-long-form-stripped"
   iut: {|i| strip-global $i.spec $i.argv}
   input: {spec: (test-spec), argv: ["--help" "run"]}
   expected: ["run"]}

  {name: "sg-12-implicit-help-short-form-stripped"
   iut: {|i| strip-global $i.spec $i.argv}
   input: {spec: (test-spec), argv: ["-h" "run"]}
   expected: ["run"]}

  {name: "sg-13-help-stripped-no-global-flags-spec"
   iut: {|i| strip-global $i.spec $i.argv}
   input: {spec: {name: "x", description: "x", commands: []}, argv: ["--help" "ls"]}
   expected: ["ls"]}

  # ── implicit cmd help ─────────────────────────────────────────────────────────

  {name: "ps-17-implicit-help-long-form-in-segment"
   iut: {|i| (parse-segment $i.spec $i.seg).flags.help}
   input: {spec: (test-spec), seg: ["run" "--help"]}
   expected: true}

  {name: "ps-18-implicit-help-short-form-in-segment"
   iut: {|i| (parse-segment $i.spec $i.seg).flags.help}
   input: {spec: (test-spec), seg: ["run" "-h"]}
   expected: true}

  {name: "ps-19-help-absent-in-segment-resolves-to-false"
   iut: {|i| (parse-segment $i.spec $i.seg).flags.help}
   input: {spec: (test-spec), seg: ["run"]}
   expected: false}

  {name: "ps-20-help-present-alongside-cmd-flag"
   iut: {|i| (parse-segment $i.spec $i.seg).flags.help}
   input: {spec: (test-spec), seg: ["run" "--help" "--verbose"]}
   expected: true}

  # ── cmd-help renders ─────────────────────────────────────────────────────────

  {name: "ch-01-cmd-help-contains-command-name"
   iut: {|i| cmd-help $i.spec $i.name | str contains $i.name}
   input: {spec: (test-spec), name: "run"}
   expected: true}

  {name: "ch-02-cmd-help-contains-flag-names"
   iut: {|i| cmd-help $i.spec $i.name | str contains "--glob"}
   input: {spec: (test-spec), name: "run"}
   expected: true}

  {name: "ch-03-cmd-help-contains-examples"
   iut: {|i|
     let spec = {
       name: "mytool" description: "test"
       commands: [{
         name: "run" description: "run tests"
         flags: [{name: glob, short: g, bool: false, default: "**/*.nu", description: "glob"}]
         examples: ["mytool run --glob src/**/*.nu  # run against src"]
       }]
     }
     cmd-help $spec "run" | str contains "mytool run --glob"
   }
   input: {}
   expected: true}

  {name: "ch-04-cmd-help-unknown-command-errors"
   iut: {|i| err-iut {|s| cmd-help $s "nonexistent"} $i "unknown command"}
   input: (test-spec)
   expected: true}

  # ── usage renders per-command flags ──────────────────────────────────────────

  {name: "us-02-usage-renders-per-command-flags"
   iut: {|i|
     let spec = {
       name: "mytool" description: "test"
       commands: [{
         name: "run" description: "run tests"
         flags: [{name: glob, short: g, bool: false, default: "**/*.nu", description: "glob pattern"}]
       }]
     }
     usage $spec | str contains "--glob"
   }
   input: {}
   expected: true}

  {name: "us-03-usage-renders-per-command-examples"
   iut: {|i|
     let spec = {
       name: "mytool" description: "test"
       commands: [{
         name: "run" description: "run tests"
         examples: ["mytool run --glob src/**  # run against src"]
       }]
     }
     usage $spec | str contains "mytool run --glob"
   }
   input: {}
   expected: true}

] }

def main [
  --filter(-f): string = ""
  --tag(-t):    string = ""
  --format:     string = "text"
  --list(-l)
] {
  if $list { cases | list-cases | to json | print; return }
  cases | run --filter $filter --tag $tag | report --format $format
}
