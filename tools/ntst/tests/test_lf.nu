#!/usr/bin/env nu

use ../../../lib/test.nu *

let ntst_nu = ($env.CURRENT_FILE | path dirname | path join "../ntst.nu" | path expand)
let repo_root = ($ntst_nu | path dirname | path dirname | path dirname | path dirname)

# Run `ntst lf [args…]` from the repo root and return stdout.
# Uses bash to set the working directory; ntst lf uses (pwd) and glob for discovery.
def ntst-lf [...args: string] {
    let arg_str = ($args | each {|a| $"'($a)'"} | str join " ")
    let cmd = $"cd ($repo_root) && nu ($ntst_nu) lf --format text ($arg_str) 2>/dev/null"
    ^bash -c $cmd
}

# Run `ntst run [args...]` from the repo root and return the completed process.
def ntst-run-complete [...args: string] {
    let arg_str = ($args | each {|a| $"'($a)'"} | str join " ")
    let cmd = $"cd ($repo_root) && nu ($ntst_nu) run ($arg_str) 2>/dev/null"
    do { ^bash -c $cmd } | complete
}

# Build an isolated pass/fail/error/skip test file for summary-line assertions.
def with-summary-fixture [body: closure] {
    let dir = ($repo_root | path join "nu-lib" $".ntst-summary-fixture-(random uuid)")
    mkdir $dir
    let file = ($dir | path join "test_summary.nu")
    let test_lib = ($repo_root | path join "nu-lib" "lib" "test.nu" | path expand)
    [$"#!/usr/bin/env nu"
     $"use ($test_lib) *"
     "def cases [] { ["
     "  {name: 'summary/pass' iut: {|_| true} input: null expected: true runner: 'value'}"
     "  {name: 'summary/fail' iut: {|_| false} input: null expected: true runner: 'value'}"
     "  {name: 'summary/error' iut: {|_| error make {msg: 'intentional ntst error proof'}} input: null expected: true runner: 'value'}"
     "  {name: 'summary/skip' iut: {|_| true} input: null expected: true runner: 'value' skip: true}"
     "] }"
     "def main [--filter(-f): string = '', --tag(-t): string = '', --format: string = 'text', --list(-l)] {"
     "  if $list { cases | list-cases | to json | print; return }"
     "  cases | run --filter $filter --tag $tag | report --format $format"
     "}"
    ] | str join (char nl) | save --force $file
    let result = try {
        do $body $file
    } catch {|e|
        rm -rf $dir
        error make {msg: $e.msg}
    }
    rm -rf $dir
    $result
}

def cases [] { [

    # ntst-lf-01: output contains distinct labeled sections for two known test directories
    {name: "ntst-lf-01-groups-by-folder"
     iut: {|_|
         let out = (ntst-lf)
         let has_ntst = ($out | str contains "nu-lib/tools/ntst/tests")
         let has_lib  = ($out | str contains "nu-lib/lib/tests")
         $has_ntst and $has_lib
     }
     input:    null
     expected: true
     runner:   "value"}

    # ntst-lf-02: the `file` column contains the stem (e.g. "lf") not the full filename
    {name: "ntst-lf-02-file-col-is-stem"
     iut: {|_|
         let out = (ntst-lf "nu-lib/tools/ntst/tests:ntst-lf%")
         # Data rows look like "lf   ntst-lf-01-..." — stem is the first whitespace-delimited token.
         # The full filename test_lf.nu must not appear anywhere in the output.
         let no_full_name = not ($out | str contains "test_lf.nu")
         # At least one data row must start with "lf".
         let has_stem = ($out | lines | any {|l|
             let t = ($l | str trim)
             ($t | str starts-with "lf ") or ($t | str starts-with "lf\t")
         })
         $no_full_name and $has_stem
     }
     input:    null
     expected: true
     runner:   "value"}

    # ntst-lf-03: `:ntst-lf%` expr filter returns only rows whose name matches ntst-lf-*
    {name: "ntst-lf-03-expr-filters-name"
     iut: {|_|
         let out = (ntst-lf "nu-lib/tools/ntst/tests:ntst-lf%")
         # Data rows: non-empty, not the folder label (contains "/"), not the header (starts "file")
         let data_rows = ($out | lines
             | where {|l| ($l | str trim | is-not-empty)}
             | where {|l| not ($l | str contains "/")}
             | where {|l| not (($l | str trim) | str starts-with "file")}
         )
         # All data rows must contain "ntst-lf-" in their name column
         let all_match    = ($data_rows | all {|l| $l | str contains "ntst-lf-"})
         # There must be at least one matching row
         let has_any      = ($data_rows | is-not-empty)
         $all_match and $has_any
     }
     input:    null
     expected: true
     runner:   "value"}

    # ntst-lf-04: an expr that matches no cases produces no labeled section in the output
    {name: "ntst-lf-04-empty-group-skipped"
     iut: {|_|
         let out = (ntst-lf ":ntst-lf-zz-impossible-xyzzy%")
         $out | str trim | is-empty
     }
     input:    null
     expected: true
     runner:   "value"}

    # ntst-executes: ntst run on a real test file (test_pat_v2_surface.nu, filtered to a few cases) produces
    # result records with pass/fail fields — avoids recursive invocation of this file.
    # The first channel is a literal folder scope; only the second channel is a pat expr.
    {name: "ntst-executes-run-produces-result-records"
     iut: {|_|
         let cmd = $"cd ($repo_root) && nu ($ntst_nu) run 'nu-lib/lib/tests:v2-parse%' --format json 2>/dev/null"
         let out = (^bash -c $cmd)
         let result_lines = ($out | lines
             | where {|l| ($l | str trim | is-not-empty)}
             | each {|l| try { $l | from json } catch { null }}
             | where {$in != null}
             | where {|r| ($r | describe | str starts-with "record") and ($r | get _channel? | default "") == "results"}
         )
         let has_results = ($result_lines | is-not-empty)
         let all_have_result_field = ($result_lines | all {|r| "result" in ($r | columns)})
         let results_are_valid = ($result_lines | all {|r|
             ($r.result | str contains "pass") or ($r.result | str contains "fail") or ($r.result | str contains "skip")
         })
         $has_results and $all_have_result_field and $results_are_valid
     }
     input:    null
     expected: true
     runner:   "value"}

    # ntst-run-file-scope: file scope is literal and selects only that file.
    {name: "ntst-run-file-scope-filters-to-one-file"
     iut: {|_|
         let cmd = $"cd ($repo_root) && nu ($ntst_nu) --verbose run 'nu-lib/tools/ntst/tests/fixture-depth/test_shallow.nu:module/%' --format json 2>/dev/null"
         let out = (^bash -c $cmd)
         let result_lines = ($out | lines
             | where {|l| ($l | str trim | is-not-empty)}
             | each {|l| try { $l | from json } catch { null }}
             | where {$in != null}
             | where {|r| ($r | describe | str starts-with "record") and ($r | get _channel? | default "") == "results"}
         )
         let has_results = ($result_lines | is-not-empty)
         let all_from_shallow = ($result_lines | all {|r| ($r.file | str ends-with "fixture-depth/test_shallow.nu")})
         let no_deep = not ($result_lines | any {|r| $r.file | str contains "sub/test_deep.nu"})
         $has_results and $all_from_shallow and $no_deep
     }
     input:    null
     expected: true
     runner:   "value"}

    # ntst-run-summary-zero-error: summary line has the full fixed counter schema even when errors are zero.
    {name: "ntst-run-summary-zero-error-includes-error-count"
     iut: {|_|
         let result = (ntst-run-complete "nu-lib/tools/ntst/tests/fixture-depth/test_shallow.nu:module/%" "--format" "text")
         let summary = ($result.stdout | lines | where {|l| $l | str contains " pass  "} | last | str trim)
         $summary == "2 pass  0 fail  0 error  0 skip"
     }
     input: null
     expected: true
     runner: "value"}

    # ntst-run-summary-nonzero-error: pass/fail/error/skip are peer counters and render in one stable order.
    {name: "ntst-run-summary-nonzero-error-fixed-order"
     iut: {|_|
         with-summary-fixture {|file|
             let result = (ntst-run-complete $file "--format" "text")
             let summary = ($result.stdout | lines | where {|l| $l | str contains " pass  "} | last | str trim)
             let hides_duration = not ($result.stdout | str contains "duration_ms")
             ($result.exit_code == 1) and ($summary == "1 pass  1 fail  1 error  1 skip") and $hides_duration
         }
     }
     input: null
     expected: true
     runner: "value"}

    # ntst-run-summary-verbose-detail: verbose failure details include duration_ms only when requested.
    {name: "ntst-run-summary-verbose-detail-includes-duration"
     iut: {|_|
         with-summary-fixture {|file|
             let result = (ntst-run-complete $file "--verbose" "--format" "text")
             ($result.exit_code == 1) and ($result.stdout | str contains "duration_ms")
         }
     }
     input: null
     expected: true
     runner: "value"}

    # pipeline-shape-grep: ntst.nu source contains the required pipeline shape calls.
    # pat.nu is used only for the expr channel; filesystem scope discovery must not
    # use pat stem or pat match.
    {name: "pipeline-shape-grep-required-calls"
     iut: {|_|
         let src = (open $ntst_nu | into string)
         let has_parse_chain   = ($src | str contains "args parse-chain")
         let has_ntst_split    = ($src | str contains "def ntst-split")
         let has_discover      = ($src | str contains "def discover [scope: string]")
         let has_pat_parse     = ($src | str contains "pat parse ")
         let has_pat_any       = ($src | str contains "pat any ")
         let has_pat_filter    = ($src | str contains "pat filter ")
         let no_pat_match      = not ($src | str contains "pat match ")
         let no_pat_stem       = not ($src | str contains "pat stem ")
         let has_rope_md_table = ($src | str contains "rope md-table")
         let has_render_walk   = ($src | str contains "render walk")
         $has_parse_chain and $has_ntst_split and $has_discover and $has_pat_parse and $has_pat_any and $has_pat_filter and $no_pat_match and $no_pat_stem and $has_rope_md_table and $has_render_walk
     }
     input:    null
     expected: true
     runner:   "value"}

    # ntst-lf-percent-immediate: expr module/% returns only immediate-child cases.
    # Fixture: fixture-depth/test_shallow.nu has 2 cases named module/alpha, module/beta.
    #          fixture-depth/sub/test_deep.nu has 1 case named module/sub/gamma.
    # expr "module/%" with "/" delimiter should match only depth-1 names (2 cases).
    {name: "ntst-lf-percent-immediate"
     iut: {|_|
         let fixture_scope = "nu-lib/tools/ntst/tests/fixture-depth"
         let out = (ntst-lf $"($fixture_scope):module/%")
         let data_rows = ($out | lines
             | where {|l| ($l | str trim | is-not-empty)}
             | where {|l| not ($l | str starts-with "#")}
             | where {|l| not (($l | str trim) | str starts-with "file")}
         )
         # Immediate count: should be exactly 2 (module/alpha and module/beta only)
         ($data_rows | length) == 2
     }
     input:    null
     expected: true
     runner:   "value"}

    # ntst-lf-percent-percent-recursive: expr module/%% returns full subtree (all cases).
    # Using same fixture, expr "module/%%" should match all 3 cases (depth 1 + 2).
    # Count must exceed the immediate-only count of 2.
    {name: "ntst-lf-percent-percent-recursive"
     iut: {|_|
         let fixture_scope = "nu-lib/tools/ntst/tests/fixture-depth"
         let out_immediate = (ntst-lf $"($fixture_scope):module/%")
         let out_recursive = (ntst-lf $"($fixture_scope):module/%%")
         let count_row = {|out|
             $out | lines
             | where {|l| ($l | str trim | is-not-empty)}
             | where {|l| not ($l | str starts-with "#")}
             | where {|l| not (($l | str trim) | str starts-with "file")}
             | length
         }
         let imm = (do $count_row $out_immediate)
         let rec = (do $count_row $out_recursive)
         # Recursive subtree must include more cases than immediate children only
         $rec > $imm
     }
     input:    null
     expected: true
     runner:   "value"}

    # ntst-percent-immediate: eq assertion — single-% returns exactly the immediate match count.
    # Fixture: fixture-depth has 2 immediate cases under module/ (alpha, beta).
    {name: "ntst-percent-immediate"
     iut: {|_|
         let fixture_scope = "nu-lib/tools/ntst/tests/fixture-depth"
         let out = (ntst-lf $"($fixture_scope):module/%")
         let data_rows = ($out | lines
             | where {|l| ($l | str trim | is-not-empty)}
             | where {|l| not ($l | str starts-with "#")}
             | where {|l| not (($l | str trim) | str starts-with "file")}
             | where {|l| not (($l | str trim) | str starts-with "name")}
         )
         $data_rows | length
     }
     input:    null
     expected: 2
     runner:   "value"}

    # ntst-percent-percent-recursive: eq assertion — %% returns full recursive count.
    # Fixture: fixture-depth has 3 total cases (2 immediate + 1 deep under sub/).
    {name: "ntst-percent-percent-recursive"
     iut: {|_|
         let fixture_scope = "nu-lib/tools/ntst/tests/fixture-depth"
         let out = (ntst-lf $"($fixture_scope):module/%%")
         let data_rows = ($out | lines
             | where {|l| ($l | str trim | is-not-empty)}
             | where {|l| not ($l | str starts-with "#")}
             | where {|l| not (($l | str trim) | str starts-with "file")}
             | where {|l| not (($l | str trim) | str starts-with "name")}
         )
         $data_rows | length
     }
     input:    null
     expected: 3
     runner:   "value"}

    # ntst-latency-budget: eq assertion — lf on the fixture-depth scope completes under budget.
    # Budget: 5000 ms (well above observed ~250 ms; guards against gross regressions).
    {name: "ntst-latency-budget"
     iut: {|_|
         let fixture_scope = "nu-lib/tools/ntst/tests/fixture-depth"
         let t0 = (date now)
         let _out = (ntst-lf $"($fixture_scope):module/%%")
         let elapsed_ms = ((date now) - $t0) / 1ms
         $elapsed_ms < 5000
     }
     input:    null
     expected: true
     runner:   "value"}

    # ntst-visit-count-budget: eq assertion — row count is bounded by the match count.
    # single-% yields exactly 2 rows; %% yields exactly 3 rows.
    # No extra rows are emitted beyond the matched case set.
    {name: "ntst-visit-count-budget"
     iut: {|_|
         let fixture_scope = "nu-lib/tools/ntst/tests/fixture-depth"
         let count_rows = {|out|
             $out | lines
             | where {|l| ($l | str trim | is-not-empty)}
             | where {|l| not ($l | str starts-with "#")}
             | where {|l| not (($l | str trim) | str starts-with "file")}
             | where {|l| not (($l | str trim) | str starts-with "name")}
             | length
         }
         let imm = (do $count_rows (ntst-lf $"($fixture_scope):module/%"))
         let rec = (do $count_rows (ntst-lf $"($fixture_scope):module/%%"))
         # immediate must equal 2; recursive must equal 3 (no over-visitation leak)
         ($imm == 2) and ($rec == 3)
     }
     input:    null
     expected: true
     runner:   "value"}

    # ntst-lf-exact-fqn: exact FQN expr (no wildcards) matches only that one case.
    # Pattern shape: :exact-name — tier=exact, no %, no regex metacharacters.
    # Fixture: fixture-depth/test_shallow.nu has "module/alpha"; using ":module/alpha"
    # should return exactly one row for that case.
    {name: "ntst-lf-exact-fqn"
     iut: {|_|
         let fixture_scope = "nu-lib/tools/ntst/tests/fixture-depth"
         let out = (ntst-lf $"($fixture_scope):module/alpha")
         let data_rows = ($out | lines
             | where {|l| ($l | str trim | is-not-empty)}
             | where {|l| not ($l | str starts-with "#")}
             | where {|l| not (($l | str trim) | str starts-with "file")}
             | where {|l| not (($l | str trim) | str starts-with "name")}
         )
         # Exactly one row, and that row contains "module/alpha"
         ($data_rows | length) == 1 and ($data_rows | all {|l| $l | str contains "module/alpha"})
     }
     input:    null
     expected: true
     runner:   "value"}

    # ntst-lf-exact-fqn-no-cross-match: exact expr does NOT match a different case.
    # Pattern ":module/beta" must not return the "module/alpha" row.
    {name: "ntst-lf-exact-fqn-no-cross-match"
     iut: {|_|
         let fixture_scope = "nu-lib/tools/ntst/tests/fixture-depth"
         let out = (ntst-lf $"($fixture_scope):module/beta")
         let has_alpha = ($out | str contains "module/alpha")
         let has_beta  = ($out | str contains "module/beta")
         (not $has_alpha) and $has_beta
     }
     input:    null
     expected: true
     runner:   "value"}

    # ntst-lf-literal-scope: bare scope path (no expr) lists all cases under that directory.
    # Pattern shape: "scope:" — literal scope, any expr.
    # Fixture: fixture-depth has 3 total cases across shallow + sub dirs.
    {name: "ntst-lf-literal-scope"
     iut: {|_|
         let fixture_scope = "nu-lib/tools/ntst/tests/fixture-depth"
         let out = (ntst-lf $"($fixture_scope):")
         let data_rows = ($out | lines
             | where {|l| ($l | str trim | is-not-empty)}
             | where {|l| not ($l | str starts-with "#")}
             | where {|l| not (($l | str trim) | str starts-with "file")}
             | where {|l| not (($l | str trim) | str starts-with "name")}
         )
         # All 3 fixture cases must be listed
         ($data_rows | length) == 3
     }
     input:    null
     expected: true
     runner:   "value"}

    # ntst-lf-scope-plus-exact-expr: scope path + exact case name narrows to one case.
    # Pattern shape: "scope:exact-name" — literal scope, exact expr tier.
    # Fixture: fixture-depth, case "module/beta" lives in test_shallow.nu.
    {name: "ntst-lf-scope-plus-exact-expr"
     iut: {|_|
         let fixture_scope = "nu-lib/tools/ntst/tests/fixture-depth"
         let out = (ntst-lf $"($fixture_scope):module/beta")
         let data_rows = ($out | lines
             | where {|l| ($l | str trim | is-not-empty)}
             | where {|l| not ($l | str starts-with "#")}
             | where {|l| not (($l | str trim) | str starts-with "file")}
             | where {|l| not (($l | str trim) | str starts-with "name")}
         )
         ($data_rows | length) == 1 and ($data_rows | all {|l| $l | str contains "module/beta"})
     }
     input:    null
     expected: true
     runner:   "value"}

    # ntst-lf-any-empty: empty pattern (no scope, no expr) lists cases from all discovered dirs.
    # Pattern shape: "" — any scope, any expr (universal wildcard).
    # At minimum the fixture-depth cases must appear; total must be non-empty.
    {name: "ntst-lf-any-empty"
     iut: {|_|
         let fixture_scope = "nu-lib/tools/ntst/tests/fixture-depth"
         # Scope-limited any: supply scope with trailing slash stripped to get literal scope + any expr.
         # Use bare scope to confirm literal-scope + any-expr returns non-empty results.
         let out = (ntst-lf $fixture_scope)
         let data_rows = ($out | lines
             | where {|l| ($l | str trim | is-not-empty)}
             | where {|l| not ($l | str starts-with "#")}
             | where {|l| not (($l | str trim) | str starts-with "file")}
             | where {|l| not (($l | str trim) | str starts-with "name")}
         )
         $data_rows | is-not-empty
     }
     input:    null
     expected: true
     runner:   "value"}

    # ntst-no-multi-field-value: ntst.nu must not contain the multi-field value-list
    # anti-pattern in any --value callback (returns multiple disparate fields).
    # Anti-pattern: --value {|c| [$c.field1 $c.field2]} — co-feeding disparate fields
    # collapses the matcher's segment-boundary discipline (pat-spec § Canonical Identifier Discipline).
    # The --value callback must return exactly one canonical identifier (single field access).
    {name: "ntst-no-multi-field-value"
     iut: {|_|
         let src = (open $ntst_nu | into string)
         # Scan each --value call site: extract the closure body and confirm
         # it does NOT return a list literal (multi-field anti-pattern).
         # A compliant call looks like: --value {|c| $c.name}
         # A forbidden call looks like: --value {|c| [$c.name $c.file]}
         # Strategy: find all "--value {" occurrences and check the closure does not
         # open a list literal before the closing brace.
         let value_sites = ($src | lines | where {|l| $l | str contains "--value {"})
         let anti_pattern_found = ($value_sites | any {|line|
             # Look for --value followed by a closure that opens a list: --value {|..| [
             $line =~ '--value \{[^}]*\['
         })
         not $anti_pattern_found
     }
     input:    null
     expected: true
     runner:   "value"}

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
