#!/usr/bin/env nu

use ../../../lib/test.nu *

let cg_nu = ($env.CURRENT_FILE | path dirname | path join "../cg.nu" | path expand)
let fixture = ($env.CURRENT_FILE | path dirname | path join "fixture" | path expand)

# Run `cg <cmd> [args…]` from the repo root and return stdout.
def cg [...args: string] {
    let arg_str = ($args | each {|a| $"'($a)'"} | str join " ")
    let cmd = $"nu ($cg_nu) ($arg_str) 2>/dev/null"
    ^bash -c $cmd
}

def cases [] { [

    # cg-lf-namespace-match: `cg lf 'net.ipv4.%%'` returns net.ipv4 subset only
    # Expects both net.ipv4.tcp.impl and net.ipv4.udp.impl callers in output,
    # and no db.query callers.
    {name: "cg-lf-namespace-match"
     iut: {|_|
         let out = (cg "lf" $"net.ipv4.%%" $fixture "--format" "text")
         let has_tcp    = ($out | str contains "net.ipv4.tcp")
         let has_udp    = ($out | str contains "net.ipv4.udp")
         let no_db      = not ($out | str contains "db.query")
         $has_tcp and $has_udp and $no_db
     }
     input:    null
     expected: true
     runner:   "value"}

    # cg-lf-fn-match: `cg lf ':connect'` matches caller by function name
    # The :connect expr filter should return only rows where the caller is connect.
    # callee may be dial (connect calls dial), but no other callers (send, run) appear.
    {name: "cg-lf-fn-match"
     iut: {|_|
         let out = (cg "lf" ":connect" $fixture "--format" "text")
         let has_connect  = ($out | str contains "connect")
         let no_send_caller = not ($out | str contains "net.ipv4.udp")
         let no_db_caller   = not ($out | str contains "db.query")
         $has_connect and $no_send_caller and $no_db_caller
     }
     input:    null
     expected: true
     runner:   "value"}

    # cg-seq-runs: `cg seq <path>` produces sequence output without error
    # Expects caller column and kind column (forward/leaf) in output.
    {name: "cg-seq-runs"
     iut: {|_|
         let out = (cg "seq" $fixture "--format" "text")
         let has_caller  = ($out | str contains "caller")
         let has_kind    = ($out | str contains "kind")
         let has_content = ($out | str contains "forward")
         $has_caller and $has_kind and $has_content
     }
     input:    null
     expected: true
     runner:   "value"}

    # cg-tree-runs: `cg tree <path>` produces tree output without error
    # Expects at least one level-0 entry point in the tree output.
    {name: "cg-tree-runs"
     iut: {|_|
         let out = (cg "tree" $fixture "--format" "text")
         # tree text output lists roots; expect at least one known root
         let has_connect = ($out | str contains "connect")
         let has_run     = ($out | str contains "run")
         let has_send    = ($out | str contains "send")
         $has_connect and $has_run and $has_send
     }
     input:    null
     expected: true
     runner:   "value"}

    # cg-dot-namespace: dot-delimited pattern resolves correctly
    # `cg lf 'db.query.%'` must return only db.query callers, not net.
    {name: "cg-dot-namespace"
     iut: {|_|
         let out = (cg "lf" "db.query.%" $fixture "--format" "text")
         let has_db  = ($out | str contains "db.query")
         let no_net  = not ($out | str contains "net.ipv4")
         $has_db and $no_net
     }
     input:    null
     expected: true
     runner:   "value"}

    # cg-lf-percent-immediate: `cg lf 'net.ipv4.%'` returns only immediate children of net.ipv4
    # % matches exactly one segment; net.ipv4.tcp.impl and net.ipv4.udp.impl are 4-segment
    # namespaces, so no 3-segment namespace exists under net.ipv4 in the fixture.
    # Immediate-child count == 0.
    {name: "cg-lf-percent-immediate"
     iut: {|_|
         let out = (cg "lf" $"net.ipv4.%" $fixture "--format" "json")
         let count = if ($out | str trim | is-empty) { 0 } else { $out | from json | length }
         $count == 0
     }
     input:    null
     expected: true
     runner:   "value"}

    # cg-lf-percent-percent-recursive: `cg lf 'net.ipv4.%%'` returns the full subtree under net.ipv4
    # %% matches any number of segments; returns both net.ipv4.tcp.impl and net.ipv4.udp.impl.
    # Recursive count (2) > immediate count (0).
    {name: "cg-lf-percent-percent-recursive"
     iut: {|_|
         let out_pct    = (cg "lf" $"net.ipv4.%" $fixture "--format" "json")
         let out_pctpct = (cg "lf" $"net.ipv4.%%" $fixture "--format" "json")
         let immediate  = if ($out_pct    | str trim | is-empty) { 0 } else { $out_pct    | from json | length }
         let recursive  = if ($out_pctpct | str trim | is-empty) { 0 } else { $out_pctpct | from json | length }
         $recursive > $immediate
     }
     input:    null
     expected: true
     runner:   "value"}

    # cg-latency-budget: single-% lf pattern completes within 2000ms
    # Measures wall-clock time of `cg lf 'net.ipv4.%'` against the fixture.
    # The pattern prunes immediately (no 3-segment namespaces exist), so the
    # walk is short; 2000ms is a generous budget that catches runaway traversal.
    {name: "cg-latency-budget"
     iut: {|_|
         let t0  = (date now)
         let _   = (cg "lf" $"net.ipv4.%" $fixture "--format" "json")
         let t1  = (date now)
         let ms  = (($t1 - $t0) / 1ms)
         $ms < 2000
     }
     input:    null
     expected: true
     runner:   "value"}

    # cg-visit-count-budget: namespace visit count is bounded by actual match count
    # `cg lf 'net.ipv4.%%'` returns exactly 2 namespace groups (tcp.impl, udp.impl).
    # Asserts result length == 2, confirming the walk does not over-visit or
    # duplicate namespace groups beyond what the fixture actually contains.
    {name: "cg-visit-count-budget"
     iut: {|_|
         let out   = (cg "lf" $"net.ipv4.%%" $fixture "--format" "json")
         let count = if ($out | str trim | is-empty) { 0 } else { $out | from json | length }
         $count == 2
     }
     input:    null
     expected: true
     runner:   "value"}

    # cg-no-multi-field-value: cg.nu must not use multi-field value-list anti-pattern with pat-scan
    # Verifies via rg that no --value closure returns a list co-feeding multiple record fields.
    # Multi-field co-feeding corrupts segment-boundary discrimination (see pat-spec §13.3).
    {name: "cg-no-multi-field-value"
     iut: {|_|
         let r = (^bash -c $"rg --count -- '--value \\{.*\\[.*\\$\\w+\\.\\w+.*\\$\\w+\\.\\w+' ($cg_nu) 2>/dev/null; echo done" | str trim)
         # rg exits 1 (no output / empty before "done") when zero matches
         $r == "done"
     }
     input:    null
     expected: true
     runner:   "value"}

    # pipeline-shape-grep: cg.nu uses the v2 pat/rope/render pipeline
    # Verifies via rg that: args parse-chain exists, pat parse (v2) is called with
    # delim '.', rope is used, and render walk is used.
    {name: "pipeline-shape-grep"
     iut: {|_|
         let src = ($cg_nu | open --raw)
         let has_parse_chain  = ($src | str contains "args parse-chain")
         let has_pat_parse    = ($src | str contains "pat parse ")
         let has_delim_dot    = ($src | str contains "delim: \".\"")
         let has_rope         = ($src | str contains "rope table")
         let has_render_walk  = ($src | str contains "render walk")
         $has_parse_chain and $has_pat_parse and $has_delim_dot and $has_rope and $has_render_walk
     }
     input:    null
     expected: true
     runner:   "value"}

    # cg-lf-fqn: `cg lf <fqn> <path>` filters to exactly one namespace
    # When a fully-qualified literal namespace (no wildcards) is given alongside an
    # explicit path, only callers whose namespace equals that literal are returned.
    # net.ipv4.tcp.impl has connect+dial; net.ipv4.udp.impl and db.query.impl must not appear.
    {name: "cg-lf-fqn"
     iut: {|_|
         let out = (cg "lf" "net.ipv4.tcp.impl" $fixture "--format" "json")
         let rows = if ($out | str trim | is-empty) { [] } else { $out | from json }
         let callers = ($rows | get --optional caller | default [] | each {|c| $c | into string})
         let has_connect = ("net.ipv4.tcp.impl.connect" in $callers)
         let has_dial    = ("net.ipv4.tcp.impl.dial" in $callers)
         let no_udp      = not ($callers | any {|c| $c | str contains "udp"})
         let no_db       = not ($callers | any {|c| $c | str contains "db"})
         $has_connect and $has_dial and $no_udp and $no_db
     }
     input:    null
     expected: true
     runner:   "value"}

    # cg-seq-fqn-caller: `cg seq <path> :<caller>` seeds BFS from matching caller only
    # :connect restricts BFS seeds to callers whose function name is "connect".
    # Output must contain connect as a caller and must NOT contain "send" or "run"
    # (which are entry points in other namespaces).
    {name: "cg-seq-fqn-caller"
     iut: {|_|
         let out = (cg "seq" $fixture ":connect" "--format" "json")
         let rows = if ($out | str trim | is-empty) { [] } else { $out | from json }
         let callers = ($rows | get --optional caller | default [] | each {|c| $c | into string})
         let has_connect = ($callers | any {|c| $c | str contains "connect"})
         let no_send     = not ($callers | any {|c| $c | str contains "send"})
         let no_run      = not ($callers | any {|c| $c | str contains "run"})
         $has_connect and $no_send and $no_run
     }
     input:    null
     expected: true
     runner:   "value"}

    # cg-seq-ns-caller: `cg seq <path> <ns>.%%:<caller>` restricts both namespace and caller
    # net.ipv4.%%:connect seeds BFS only from callers whose namespace is under net.ipv4
    # and whose function name is connect. Only net.ipv4.tcp.impl.connect (and its callees)
    # should appear; db.query and net.ipv4.udp callers must be absent.
    {name: "cg-seq-ns-caller"
     iut: {|_|
         let out = (cg "seq" $fixture "net.ipv4.%%:connect" "--format" "json")
         let rows = if ($out | str trim | is-empty) { [] } else { $out | from json }
         let callers = ($rows | get --optional caller | default [] | each {|c| $c | into string})
         let has_connect = ($callers | any {|c| $c | str contains "connect"})
         let no_db       = not ($callers | any {|c| $c | str contains "db.query"})
         let no_udp      = not ($callers | any {|c| $c | str contains "udp.impl.send"})
         $has_connect and $no_db and $no_udp
     }
     input:    null
     expected: true
     runner:   "value"}

    # cg-tree-ns-filter: `cg tree <path> <ns>.%%:<filter>` roots the tree at matching callers
    # net.ipv4.%%:connect selects net.ipv4.tcp.impl.connect as the DFS root.
    # Tree output (json) must have a root named net.ipv4.tcp.impl.connect with at least one child.
    # send (udp) and run (db) must not appear as roots.
    {name: "cg-tree-ns-filter"
     iut: {|_|
         let out = (cg "tree" $fixture "net.ipv4.%%:connect" "--format" "json")
         let roots = if ($out | str trim | is-empty) { [] } else { $out | from json }
         let root_names = ($roots | get --optional name | default [])
         let has_connect_root = ("net.ipv4.tcp.impl.connect" in $root_names)
         let no_send_root     = not ("net.ipv4.udp.impl.send" in $root_names)
         let no_run_root      = not ("db.query.impl.run" in $root_names)
         let connect_has_children = (
             $roots
             | where {|r| ($r | get --optional name | default "") == "net.ipv4.tcp.impl.connect"}
             | get --optional children
             | default []
             | flatten
             | length
         ) > 0
         $has_connect_root and $no_send_root and $no_run_root and $connect_has_children
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
