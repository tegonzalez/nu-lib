#!/usr/bin/env nu

use ../test.nu *
use ../render.nu
use ../rstr.nu *

def rows [] { [
  {name: "alpha",   status: "pass",  count: 1,  active: true,  notes: "short"}
  {name: "beta",    status: "fail",  count: 42, active: false, notes: "a slightly longer note here"}
  {name: "gamma",   status: "pass",  count: 7,  active: true,  notes: ""}
  {name: "delta",   status: "skip",  count: 0,  active: false, notes: "this note is quite a bit longer than the others to stress column width"}
  {name: "epsilon", status: "error", count: 99, active: true,  notes: "medium length note"}
  {name: "zeta",    status: "pass",  count: 3,  active: false, notes: "another short one"}
  {name: "eta",     status: "fail",  count: 18, active: true,  notes: "the longest note value in this dataset by a significant margin for testing purposes"}
] }

# ── Canonical fixture helpers ─────────────────────────────────────────────────
# The fixture: directory src containing files a.nu and b.nu.

def fixture-rows [] {
  [
    {id: 1, name: "src",      type: "dir",  size: "4.0 kB"}
    {id: 2, name: "src/a.nu", type: "file", size: "1KB",    parent_id: 1}
    {id: 3, name: "src/b.nu", type: "file", size: "2KB",    parent_id: 1}
  ]
}

def fixture-tree [] {
  {
    label: {name: "src"}
    fields: {type: "dir", size: "4.0 kB"}
    children: [
      {label: {name: "a.nu"} fields: {type: "file", size: "1KB"}}
      {label: {name: "b.nu"} fields: {type: "file", size: "2KB"}}
    ]
  }
}

def fixture-mdtable [] {
  {
    label: {name: "src"}
    fields: {type: "dir"}
    children: [
      {label: {name: "a.nu"} fields: {type: "file", size: "1KB"}}
      {label: {name: "b.nu"} fields: {type: "file", size: "2KB"}}
    ]
  }
}

def cases [] { [

  # ── current stream.nu API sentinels ────────────────────────────────────────
  # Streaming ownership lives in stream.nu. These cases intentionally exercise
  # stream open / stream step / stream close through the exported stream module
  # while render walk remains covered separately below.

  {name: "tail-full-buffer"
   iut: {|_|
     # 5 rows into a height-4 window; FORCE_TTY=0+text emits all rows live
     # stream close must not truncate already-emitted text output.
     let script = "use nu-lib/lib/stream.nu *; let s0 = (stream open {format: 'text'} [{name: 'data', kind: 'tail', height: 4}]); let s1 = (stream step $s0 {_channel: 'data', item: 'r1'}); let s2 = (stream step $s1 {_channel: 'data', item: 'r2'}); let s3 = (stream step $s2 {_channel: 'data', item: 'r3'}); let s4 = (stream step $s3 {_channel: 'data', item: 'r4'}); let s5 = (stream step $s4 {_channel: 'data', item: 'r5'}); stream close $s5"
     let out = (with-env {FORCE_TTY: "0"} {
       ^nu -c $script
     } | complete).stdout
     ($out | str contains "r5") and ($out | str contains "r1")
   }
   input: null
   expected: true
   runner: "value"}

  {name: "label-absent"
   iut: {|_|
     # In text mode, labels are emitted by stream step; stream close must not
     # re-emit label content as tail/table scrollback.
     let script = "use nu-lib/lib/stream.nu *; let s0 = (stream open {format: 'text'} [{name: 'status', kind: 'label'}, {name: 'data', kind: 'tail', height: 4}]); let s1 = (stream step $s0 {_channel: 'status', value: 'sentinel-label-value'}); let s2 = (stream step $s1 {_channel: 'data', item: 'row1'}); stream close $s2"
     let result = (with-env {FORCE_TTY: "0"} {
       ^nu -c $script
     } | complete)
     ($result.stdout | str contains "row1") and (($result.stdout | split row "sentinel-label-value" | length) == 2)
   }
   input: null
   expected: true
   runner: "value"}

  {name: "log-to-stderr"
   iut: {|_|
     let script = "use nu-lib/lib/stream.nu *; let s0 = (stream open {format: 'text'} [{name: 'log', kind: 'log', height: 4}]); let s1 = (stream step $s0 {_channel: 'log', level: 'info', text: 'log-sentinel'}); stream close $s1"
     let result = (with-env {FORCE_TTY: "0"} {
       ^nu -c $script
     } | complete)
     $result.stderr | str contains "log-sentinel"
   }
   input: null
   expected: true
   runner: "value"}

  {name: "stream-open-log-default"
   iut: {|_|
     # stream open with no log channel auto-appends a log channel last;
     # channels length == 2; last channel name == "log"
     let script = "use nu-lib/lib/stream.nu *; let state = (stream open {format: 'text'} [{name: 'data', kind: 'tail', height: 4}]); let ch = ($state | get channels); print (($ch | length) == 2 and (($ch | last | get name) == 'log'))"
     let out = (with-env {FORCE_TTY: "0"} {
       ^nu -c $script
     } | complete).stdout
     $out | str trim
   }
   input: null
   expected: "true"
   runner: "value"}

  {name: "absent-channel-errors"
   nu_src: "use nu-lib/lib/stream.nu *; let state = (stream open {format: 'text'} [{name: 'data', kind: 'tail', height: 4}]); stream step $state {item: 'no channel field'}"
   expected: 1
   runner: "exit"}

  {name: "tail-scrollback"
   iut: {|_|
     let script = "use nu-lib/lib/stream.nu *; let s0 = (stream open {format: 'text'} [{name: 'out', kind: 'tail', height: 4}]); let s1 = (stream step $s0 {_channel: 'out', item: 'tail-sentinel-row'}); stream close $s1"
     let out = (with-env {FORCE_TTY: "0"} {
       ^nu -c $script
     } | complete).stdout
     $out | str contains "tail-sentinel-row"
   }
   input: null
   expected: true
   runner: "value"}

  {name: "undeclared-channel-errors"
   nu_src: "use nu-lib/lib/stream.nu *; let state = (stream open {format: 'text'} [{name: 'data', kind: 'tail', height: 4}]); stream step $state {_channel: 'undeclared', item: 'x'}"
   expected: 1
   runner: "exit"}

  {name: "label-event-routing"
   iut: {|_|
     # label channel events are printed live in text mode (name  value format)
     let script = "use nu-lib/lib/stream.nu *; let s0 = (stream open {format: 'text'} [{name: 'status', kind: 'label'}]); let s1 = (stream step $s0 {_channel: 'status', value: 'label-routed-value'}); stream close $s1"
     let out = (with-env {FORCE_TTY: "0"} {
       ^nu -c $script
     } | complete).stdout
     $out | str contains "label-routed-value"
   }
   input: null
   expected: true
   runner: "value"}

  {name: "log-event-stderr-text"
   iut: {|_|
     # log channel in text mode emits to stderr immediately via stream step.
     let script = "use nu-lib/lib/stream.nu *; let s0 = (stream open {format: 'text'} [{name: 'log', kind: 'log'}]); let s1 = (stream step $s0 {_channel: 'log', level: 'info', text: 'log-text-sentinel'}); stream close $s1"
     let result = (with-env {FORCE_TTY: "0"} {
       ^nu -c $script
     } | complete)
     $result.stderr | str contains "log-text-sentinel"
   }
   input: null
   expected: true
   runner: "value"}

  {name: "result-color-tty"
   iut: {|_|
     let script = "use nu-lib/lib/stream.nu *; use nu-lib/lib/rstr.nu *; let r = ('pass' | rstr of | rstr tag 'ok' | rstr to-str); let s0 = (stream open {format: 'rich'} [{name: 'results', kind: 'tail', height: 4}]); let s1 = (stream step $s0 {_channel: 'results', result: $r, name: 'foo'}); stream close $s1"
     let out = (with-env {FORCE_TTY: "1"} {
       ^nu -c $script
     } | complete).stdout
     $out | str contains "\u{1b}"
   }
   input: null
   expected: true
   runner: "value"}

  {name: "result-color-nocolor"
   iut: {|_|
     let script = "use nu-lib/lib/stream.nu *; use nu-lib/lib/rstr.nu *; let r = ('pass' | rstr of | rstr tag 'ok' | rstr to-str); let s0 = (stream open {format: 'rich'} [{name: 'results', kind: 'tail', height: 4}]); let s1 = (stream step $s0 {_channel: 'results', result: $r, name: 'foo'}); stream close $s1"
     let out = (with-env {FORCE_TTY: "0"} {
       ^nu -c $script
     } | complete).stdout
     not ($out | str contains "\u{1b}")
   }
   input: null
   expected: true
   runner: "value"}

  {name: "rn-walk-text"
   iut: {|_|
     let script = "use nu-lib/lib/render.nu; {_fields: [{k: 'name' v: [{t: 'root'}]}], _children: [{_fields: [{k: 'name' v: [{t: 'child-a'}]}]}, {_fields: [{k: 'name' v: [{t: 'child-b'}]}], _children: [{_fields: [{k: 'name' v: [{t: 'grandchild'}]}]}]}]} | render walk {format: 'text'}"
     let out = (with-env {FORCE_TTY: "0"} { ^nu -c $script } | complete).stdout
     $out | str contains "root"
   }
   input: null
   expected: true
   runner: "value"}

  {name: "rn-walk-rich-non-tty"
   iut: {|_|
     let script = "use nu-lib/lib/render.nu; {_fields: [{k: 'name' v: [{t: 'root'}]}], _children: [{_fields: [{k: 'name' v: [{t: 'child-a'}]}]}, {_fields: [{k: 'name' v: [{t: 'child-b'}]}], _children: [{_fields: [{k: 'name' v: [{t: 'grandchild'}]}]}]}]} | render walk {format: 'rich'}"
     let out = (with-env {FORCE_TTY: "0"} { ^nu -c $script } | complete).stdout
     ($out | str contains "root") and not ($out | str contains "\u{1b}")
   }
   input: null
   expected: true
   runner: "value"}

  {name: "rn-walk-json"
   iut: {|_|
     let script = "use nu-lib/lib/render.nu; {_fields: [{k: 'name' v: [{t: 'root'}]}], _children: [{_fields: [{k: 'name' v: [{t: 'child-a'}]}]}, {_fields: [{k: 'name' v: [{t: 'child-b'}]}], _children: [{_fields: [{k: 'name' v: [{t: 'grandchild'}]}]}]}]} | render walk {format: 'json'}"
     let out = (with-env {FORCE_TTY: "0"} { ^nu -c $script } | complete).stdout
     let parsed = ($out | from json)
     (($parsed | describe) =~ "^list" or ($parsed | describe) =~ "^table") and (($parsed | first | columns) | any {|c| $c == "name"})
   }
   input: null
   expected: true
   runner: "value"}

  {name: "rn-format-value-selects-exact-format-before-stream-fallback"
   iut: {|_|
     let script = "use nu-lib/lib/render.nu; let rope = {_fields: [{k: 'name' v: {_fmt: {rich: [{t: 'rich-lock'}], utf8: [{t: 'utf8-lock'}], plain: 'plain-lock', text: 'text-lock', json: 'json-lock'}}}]}; let rich = ($rope | render walk {format: 'rich'} | ansi strip); let utf8 = ($rope | render walk {format: 'utf8'}); let plain = ($rope | render walk {format: 'plain'}); let text = ($rope | render walk {format: 'text'}); let json = ($rope | render walk {format: 'json'} | from json | first | get name); [$rich $utf8 $plain $text $json] | to json"
     let out = (with-env {FORCE_TTY: "0"} { ^nu -c $script } | complete).stdout | from json
     $out == ["rich-lock" "utf8-lock" "plain-lock" "text-lock" "json-lock"]
   }
   input: null
   expected: true
   runner: "value"}

  {name: "rn-walk-connector"
   iut: {|_|
     let script = "use nu-lib/lib/render.nu; {_fields: [{k: 'name' v: [{t: 'root'}]}], _children: [{_fields: [{v: [{t: '├──▶ '}]} {k: 'name' v: [{t: 'child-a'}]}]}, {_fields: [{v: [{t: '└──▶ '}]} {k: 'name' v: [{t: 'child-b'}]}], _children: [{_fields: [{v: [{t: '      └──▶ '}]} {k: 'name' v: [{t: 'grandchild'}]}]}]}]} | render walk {format: 'rich'}"
     let out = (with-env {FORCE_TTY: "1"} { ^nu -c $script } | complete).stdout
     $out | str contains "──▶"
   }
   input: null
   expected: true
   runner: "value"}

  {name: "rn-walk-rejects-list-input"
   iut: {|_|
     let script = "use nu-lib/lib/render.nu; [{_fields: [{k: 'node' v: [{t: 'x'}]}]}] | render walk {format: 'text'}"
     let result = (with-env {FORCE_TTY: "0"} { ^nu -c $script } | complete)
     let combined = ($result.stdout + $result.stderr)
     ($result.exit_code != 0) and ($combined | str contains "single rope record")
   }
   input: null
   expected: true
   runner: "value"}

  {name: "rn-default-policy-no-separator"
   iut: {|_|
     # Two adjacent shape-1 value nodes under default policy (no _flat)
     # text: both values concatenated with zero separator bytes
     let text_script = "use nu-lib/lib/render.nu; use nu-lib/lib/rstr.nu *; {_fields: [{v: ('foo' | rstr of)}, {v: ('bar' | rstr of)}]} | render walk {format: 'text'}"
     let text_out = (with-env {FORCE_TTY: "0"} { ^nu -c $text_script } | complete).stdout | str trim
     # rich: same rope, no separator
     let rich_script = "use nu-lib/lib/render.nu; use nu-lib/lib/rstr.nu *; {_fields: [{v: ('foo' | rstr of)}, {v: ('bar' | rstr of)}]} | render walk {format: 'rich'}"
     let rich_out = (with-env {FORCE_TTY: "0"} { ^nu -c $rich_script } | complete).stdout | str trim
     ($text_out == "foobar") and ($rich_out == "foobar")
   }
   input: null
   expected: true
   runner: "value"}

  {name: "rn-sep-override"
   iut: {|_|
     # _sep in _flat is now rejected (render-walk-flat-spec-alignment); _flat must not contain _sep.
     # Case 1: _flat with _sep causes an error (exit code != 0)
     let s1 = "use nu-lib/lib/render.nu; {_flat: {_sep: '| ', a: {justify: 'left', weight: 1}, b: {justify: 'left', weight: 1}}, _fields: [{k: 'a', v: [{t: 'alpha'}]}, {k: 'b', v: [{t: 'beta'}]}]} | render walk {format: 'text'}"
     let r1 = (with-env {FORCE_TTY: "0"} { ^nu -c $s1 } | complete)
     # Case 2: _flat with no _sep defaults to two-space separator (still valid)
     let s2 = "use nu-lib/lib/render.nu; {_flat: {a: {justify: 'left', weight: 1}, b: {justify: 'left', weight: 1}}, _fields: [{k: 'a', v: [{t: 'alpha'}]}, {k: 'b', v: [{t: 'beta'}]}]} | render walk {format: 'text'}"
     let out2 = (with-env {FORCE_TTY: "0"} { ^nu -c $s2 } | complete).stdout
     ($r1.exit_code != 0) and ($out2 | str contains "  ")
   }
   input: null
   expected: true
   runner: "value"}

  {name: "rn-no-depth-indentation"
   iut: {|_|
     # 3 nesting levels; default policy; text lines must not begin with whitespace
     let script = "use nu-lib/lib/render.nu; {_fields: [{k: 'level', v: [{t: '1'}]}], _children: [{_fields: [{k: 'level', v: [{t: '2'}]}], _children: [{_fields: [{k: 'level', v: [{t: '3'}]}]}]}]} | render walk {format: 'text'}"
     let out = (with-env {FORCE_TTY: "0"} { ^nu -c $script } | complete).stdout
     let lines = ($out | lines | where {|l| ($l | str trim) != ""})
     $lines | all {|l| not ($l | str starts-with " ")}
   }
   input: null
   expected: true
   runner: "value"}

  {name: "rn-layout-key-rejected"
   iut: {|_|
     let script = "use nu-lib/lib/render.nu; {_fields: [{k: 'x', v: [{t: 'y'}]}], _layout: 'tree'} | render walk {format: 'rich'}"
     let result = (with-env {FORCE_TTY: "0"} { ^nu -c $script } | complete)
     $result.exit_code != 0
   }
   input: null
   expected: true
   runner: "value"}


  # topology key in cfg must now error
  {name: "rn-walk-topology-errors"
   iut: {|_|
     let script = "use nu-lib/lib/render.nu; {_fields: [{k: 'name' v: [{t: 'root'}]}], _children: []} | render walk {format: 'json', topology: 'nested'}"
     let result = (with-env {FORCE_TTY: "0"} { ^nu -c $script } | complete)
     $result.exit_code != 0
   }
   input: null
   expected: true
   runner: "value"}

  # absent _layout → nested JSON with children arrays
  {name: "rn-walk-nested-json"
   iut: {|_|
     let script = "use nu-lib/lib/render.nu; {_fields: [{k: 'name' v: [{t: 'root'}]}], _children: [{_fields: [{k: 'name' v: [{t: 'child-a'}]}], _children: []}, {_fields: [{k: 'name' v: [{t: 'child-b'}]}], _children: []}]} | render walk {format: 'json'}"
     let out = (with-env {FORCE_TTY: "0"} { ^nu -c $script } | complete).stdout
     let parsed = ($out | from json)
     # parsed is a list; first element must have a children key
     let is_list = (($parsed | describe) =~ "^list" or ($parsed | describe) =~ "^table")
     $is_list and (($parsed | first | columns) | any {|c| $c == "children"})
   }
   input: null
   expected: true
   runner: "value"}

  # _layout:"table" must now error (no longer a valid layout)
  {name: "rn-walk-layout-table-errors"
   iut: {|_|
     let script = "use nu-lib/lib/render.nu; {_fields: [{k: 'h' v: [{t: 'h'}]}], _layout: 'table', _children: []} | render walk {format: 'rich'}"
     let result = (with-env {FORCE_TTY: "0"} { ^nu -c $script } | complete)
     $result.exit_code != 0
   }
   input: null
   expected: true
   runner: "value"}

  # _layout:"table" errors for json format too
  {name: "rn-walk-layout-table-json-errors"
   iut: {|_|
     let script = "use nu-lib/lib/render.nu; {_fields: [{k: 'h' v: [{t: 'h'}]}], _layout: 'table', _children: []} | render walk {format: 'json'}"
     let result = (with-env {FORCE_TTY: "0"} { ^nu -c $script } | complete)
     $result.exit_code != 0
   }
   input: null
   expected: true
   runner: "value"}

  # _layout:"tree" is also invalid (only "flat" or absent are valid)
  {name: "rn-walk-layout-tree-errors"
   iut: {|_|
     let script = "use nu-lib/lib/render.nu; {_fields: [{k: 'name' v: [{t: 'root'}]}], _layout: 'tree', _children: []} | render walk {format: 'json'}"
     let result = (with-env {FORCE_TTY: "0"} { ^nu -c $script } | complete)
     $result.exit_code != 0
   }
   input: null
   expected: true
   runner: "value"}

  {name: "rn-walk-value-node-rich"
   iut: {|_|
     let script = "use nu-lib/lib/render.nu; {_fields: [{v: [{t: 'val-only'}]}]} | render walk {format: 'rich'}"
     let out = (with-env {FORCE_TTY: "0"} { ^nu -c $script } | complete).stdout
     $out | str trim | str contains "val-only"
   }
   input: null
   expected: true
   runner: "value"}

  {name: "rn-walk-keyed-node-rich"
   iut: {|_|
     let script = "use nu-lib/lib/render.nu; {_fields: [{k: 'mykey' v: [{t: 'myval'}]}]} | render walk {format: 'rich'}"
     let out = (with-env {FORCE_TTY: "0"} { ^nu -c $script } | complete).stdout
     ($out | str trim | str contains "myval") and (not ($out | str contains "mykey"))
   }
   input: null
   expected: true
   runner: "value"}

  {name: "rn-walk-keyed-node-json"
   iut: {|_|
     let script = "use nu-lib/lib/render.nu; {_fields: [{v: [{t: 'invisible'}]} {k: 'name' v: [{t: 'visible'}]}]} | render walk {format: 'json'}"
     let out = (with-env {FORCE_TTY: "0"} { ^nu -c $script } | complete).stdout
     let j = ($out | str trim | from json | first)
     ($j | get name?) == "visible" and not ($j | columns | any {|c| $c == "invisible"})
   }
   input: null
   expected: true
   runner: "value"}

  # ── Canonical OT tests ─────────────────────────────────────────────────────

  {name: "sample-ot-rich"
   iut: {|_|
     let ot = "use nu-lib/lib/render.nu; let ot = {_flat: {}, _fields: [{k: 'id', v: 1}, {k: 'name', v: [{t: '/src'}]}, {k: 'type', v: [{t: 'dir'}]}, {k: 'size', v: [{t: '12KB'}]}, {k: 'parent_id', v: null, q: 'text'}], _children: [{_fields: [{v: [{t: '├──▶'}], q: 'visual'}, {k: 'id', v: 2}, {k: 'name', v: [{t: '/src/lib'}]}, {k: 'type', v: [{t: 'dir'}]}, {k: 'size', v: [{t: '4.2KB'}]}, {k: 'parent_id', v: 1, q: 'text'}], _children: [{_fields: [{v: [{t: '│     └──▶'}], q: 'visual'}, {k: 'id', v: 3}, {k: 'name', v: [{t: '/src/lib/utils.nu'}]}, {k: 'type', v: [{t: 'file'}]}, {k: 'size', v: [{t: '1.1KB'}]}, {k: 'parent_id', v: 2, q: 'text'}], _children: []}]}, {_fields: [{v: [{t: '└──▶'}], q: 'visual'}, {k: 'id', v: 4}, {k: 'name', v: [{t: '/src/menu.nu'}]}, {k: 'type', v: [{t: 'file'}]}, {k: 'size', v: [{t: '2.3KB'}]}, {k: 'parent_id', v: 1, q: 'text'}], _children: []}]}; $ot | render walk {format: 'rich'}"
     let out = (with-env {FORCE_TTY: "0"} { ^nu -c $ot } | complete).stdout
     # flat rich now renders a bordered table (spec-aligned); data cols id/name/type/size present;
     # parent_id (q:"data") excluded; box borders present
     let stripped = ($out | ansi strip | str trim)
     ($stripped | str contains "id") and ($stripped | str contains "name") and ($stripped | str contains "type") and ($stripped | str contains "size") and ($stripped | str contains "─") and ($stripped | str contains "/src") and ($stripped | str contains "/src/lib/utils.nu") and ($stripped | str contains "/src/menu.nu") and not ($stripped | str contains "parent_id")
   }
   input: null
   expected: true
   runner: "value"}

  {name: "sample-ot-text"
   iut: {|_|
     let ot = "use nu-lib/lib/render.nu; let ot = {_flat: {}, _fields: [{k: 'id', v: 1}, {k: 'name', v: [{t: '/src'}]}, {k: 'type', v: [{t: 'dir'}]}, {k: 'size', v: [{t: '12KB'}]}, {k: 'parent_id', v: null, q: 'text'}], _children: [{_fields: [{v: [{t: '├──▶'}], q: 'visual'}, {k: 'id', v: 2}, {k: 'name', v: [{t: '/src/lib'}]}, {k: 'type', v: [{t: 'dir'}]}, {k: 'size', v: [{t: '4.2KB'}]}, {k: 'parent_id', v: 1, q: 'text'}], _children: [{_fields: [{v: [{t: '│     └──▶'}], q: 'visual'}, {k: 'id', v: 3}, {k: 'name', v: [{t: '/src/lib/utils.nu'}]}, {k: 'type', v: [{t: 'file'}]}, {k: 'size', v: [{t: '1.1KB'}]}, {k: 'parent_id', v: 2, q: 'text'}], _children: []}]}, {_fields: [{v: [{t: '└──▶'}], q: 'visual'}, {k: 'id', v: 4}, {k: 'name', v: [{t: '/src/menu.nu'}]}, {k: 'type', v: [{t: 'file'}]}, {k: 'size', v: [{t: '2.3KB'}]}, {k: 'parent_id', v: 1, q: 'text'}], _children: []}]}; $ot | render walk {format: 'text'}"
     let out = (with-env {FORCE_TTY: "0"} { ^nu -c $ot } | complete).stdout
     # flat text always emits a blank separator line after the header row (spec-aligned)
     let expected = "id  name               type  size   parent_id\n\n1   /src               dir   12KB\n2   /src/lib           dir   4.2KB  1\n3   /src/lib/utils.nu  file  1.1KB  2\n4   /src/menu.nu       file  2.3KB  1"
     ($out | str trim) == $expected
   }
   input: null
   expected: true
   runner: "value"}

  {name: "sample-ot-json-flat"
   iut: {|_|
     # Flat-in-flat: all nodes carry _flat: {} so the entire tree collapses to a
     # single flat JSON array (DFS pre-order) with no nested children keys.
     let ot = "use nu-lib/lib/render.nu; let ot = {_flat: {}, _fields: [{k: 'id', v: 1}, {k: 'name', v: [{t: '/src'}]}, {k: 'type', v: [{t: 'dir'}]}, {k: 'size', v: [{t: '12KB'}]}, {k: 'parent_id', v: null, q: 'text'}], _children: [{_flat: {}, _fields: [{k: 'id', v: 2}, {k: 'name', v: [{t: '/src/lib'}]}, {k: 'type', v: [{t: 'dir'}]}, {k: 'size', v: [{t: '4.2KB'}]}, {k: 'parent_id', v: 1, q: 'text'}], _children: [{_flat: {}, _fields: [{k: 'id', v: 3}, {k: 'name', v: [{t: '/src/lib/utils.nu'}]}, {k: 'type', v: [{t: 'file'}]}, {k: 'size', v: [{t: '1.1KB'}]}, {k: 'parent_id', v: 2, q: 'text'}], _children: []}]}, {_flat: {}, _fields: [{k: 'id', v: 4}, {k: 'name', v: [{t: '/src/menu.nu'}]}, {k: 'type', v: [{t: 'file'}]}, {k: 'size', v: [{t: '2.3KB'}]}, {k: 'parent_id', v: 1, q: 'text'}], _children: []}]}; $ot | render walk {format: 'json'}"
     let out = (with-env {FORCE_TTY: "0"} { ^nu -c $ot } | complete).stdout
     let rows = ($out | from json)
     # flat array of 4 objects with exact field types: id=int, name=string, type=string, size=string, parent_id=int|null
     let r0 = ($rows | get 0)
     let r1 = ($rows | get 1)
     let r2 = ($rows | get 2)
     let r3 = ($rows | get 3)
     let ok0 = ($r0.id == 1) and ($r0.name == "/src") and ($r0.type == "dir") and ($r0.size == "12KB")
     let ok1 = ($r1.id == 2) and ($r1.parent_id == 1)
     let ok2 = ($r2.id == 3) and ($r2.parent_id == 2)
     let ok3 = ($r3.id == 4) and ($r3.parent_id == 1)
     let ok4 = not ("children" in ($r0 | columns)) and (($rows | length) == 4)
     $ok0 and $ok1 and $ok2 and $ok3 and $ok4
   }
   input: null
   expected: true
   runner: "value"}

  # ── 20 Conformance Cases (4 composers × 5 formats) ───────────────────────

  # ── rope table ───────────────────────────────────────────────────────────

  {name: "conf-rope-table-rich"
   # rope table rich: q:"text" columns (id, parent_id) hidden; ANSI style on headers
   # Compare ANSI-stripped output against the spec's verbatim shape
   nu_src: "use nu-lib/lib/render.nu; use nu-lib/lib/rope.nu *; [{id: 1, name: 'src', type: 'dir', size: '4.0 kB'}, {id: 2, name: 'src/a.nu', type: 'file', size: '1KB', parent_id: 1}, {id: 3, name: 'src/b.nu', type: 'file', size: '2KB', parent_id: 1}] | rope table --columns {id: {q: 'text'}, parent_id: {q: 'text'}} | render walk {format: 'rich'} | ansi strip"
   expected: "╭──────────┬──────┬────────╮\n│ name     │ type │ size   │\n├──────────┼──────┼────────┤\n│ src      │ dir  │ 4.0 kB │\n│ src/a.nu │ file │ 1KB    │\n│ src/b.nu │ file │ 2KB    │\n╰──────────┴──────┴────────╯"
   runner: "stdio"}

  {name: "conf-rope-table-utf8"
   # rope table utf8: identical shape to rich; no ANSI escape sequences; UTF-8 borders kept
   nu_src: "use nu-lib/lib/render.nu; use nu-lib/lib/rope.nu *; [{id: 1, name: 'src', type: 'dir', size: '4.0 kB'}, {id: 2, name: 'src/a.nu', type: 'file', size: '1KB', parent_id: 1}, {id: 3, name: 'src/b.nu', type: 'file', size: '2KB', parent_id: 1}] | rope table --columns {id: {q: 'text'}, parent_id: {q: 'text'}} | render walk {format: 'utf8'}"
   expected: "╭──────────┬──────┬────────╮\n│ name     │ type │ size   │\n├──────────┼──────┼────────┤\n│ src      │ dir  │ 4.0 kB │\n│ src/a.nu │ file │ 1KB    │\n│ src/b.nu │ file │ 2KB    │\n╰──────────┴──────┴────────╯"
   runner: "stdio"}

  {name: "conf-rope-table-plain"
   # rope table plain: q:"text" columns hidden; no borders; space-aligned; blank line after header
   nu_src: "use nu-lib/lib/render.nu; use nu-lib/lib/rope.nu *; [{id: 1, name: 'src', type: 'dir', size: '4.0 kB'}, {id: 2, name: 'src/a.nu', type: 'file', size: '1KB', parent_id: 1}, {id: 3, name: 'src/b.nu', type: 'file', size: '2KB', parent_id: 1}] | rope table --columns {id: {q: 'text'}, parent_id: {q: 'text'}} | render walk {format: 'plain'}"
   expected: "name      type  size\n\nsrc       dir   4.0 kB\nsrc/a.nu  file  1KB\nsrc/b.nu  file  2KB"
   runner: "stdio"}

  {name: "conf-rope-table-text"
   # rope table text: q:"text" columns appear (id, parent_id); all columns; natural width; blank line after header
   nu_src: "use nu-lib/lib/render.nu; use nu-lib/lib/rope.nu *; [{id: 1, name: 'src', type: 'dir', size: '4.0 kB'}, {id: 2, name: 'src/a.nu', type: 'file', size: '1KB', parent_id: 1}, {id: 3, name: 'src/b.nu', type: 'file', size: '2KB', parent_id: 1}] | rope table --columns {id: {q: 'text'}, parent_id: {q: 'text'}} | render walk {format: 'text'}"
   expected: "id  name      type  size    parent_id\n\n1   src       dir   4.0 kB\n2   src/a.nu  file  1KB     1\n3   src/b.nu  file  2KB     1"
   runner: "stdio"}

  {name: "conf-rope-table-json"
   # rope table json: flat form (_flat present) — one array, one object per row; all kv field-nodes
   nu_src: "use nu-lib/lib/render.nu; use nu-lib/lib/rope.nu *; [{id: 1, name: 'src', type: 'dir', size: '4.0 kB'}, {id: 2, name: 'src/a.nu', type: 'file', size: '1KB', parent_id: 1}, {id: 3, name: 'src/b.nu', type: 'file', size: '2KB', parent_id: 1}] | rope table --columns {id: {q: 'text'}, parent_id: {q: 'text'}} | render walk {format: 'json'} | from json | to json"
   expected: "[{\"id\":1,\"name\":\"src\",\"type\":\"dir\",\"size\":\"4.0 kB\"},{\"id\":2,\"name\":\"src/a.nu\",\"type\":\"file\",\"size\":\"1KB\",\"parent_id\":1},{\"id\":3,\"name\":\"src/b.nu\",\"type\":\"file\",\"size\":\"2KB\",\"parent_id\":1}]"
   runner: "stdio"
   assert: {|actual expected|
     let a = ($actual | from json)
     let e = ($expected | from json)
     $a == $e
   }}

  # ── rope tree ────────────────────────────────────────────────────────────

  {name: "conf-rope-tree-rich"
   # rope tree rich: connector tree; names styled via rstr; no id/parent_id minted
   # Compare ANSI-stripped output
   nu_src: "use nu-lib/lib/render.nu; use nu-lib/lib/rope.nu *; {label: {name: 'src'}, fields: {type: 'dir', size: '4.0 kB'}, children: [{label: {name: 'a.nu'}, fields: {type: 'file', size: '1KB'}}, {label: {name: 'b.nu'}, fields: {type: 'file', size: '2KB'}}]} | rope tree | render walk {format: 'rich'} | ansi strip"
   expected: "src dir 4.0 kB\n├──▶ a.nu file 1KB\n└──▶ b.nu file 2KB"
   runner: "stdio"}

  {name: "conf-rope-tree-utf8"
   # rope tree utf8: identical to rich; rstr renders to plain text (no ANSI)
   nu_src: "use nu-lib/lib/render.nu; use nu-lib/lib/rope.nu *; {label: {name: 'src'}, fields: {type: 'dir', size: '4.0 kB'}, children: [{label: {name: 'a.nu'}, fields: {type: 'file', size: '1KB'}}, {label: {name: 'b.nu'}, fields: {type: 'file', size: '2KB'}}]} | rope tree | render walk {format: 'utf8'}"
   expected: "src dir 4.0 kB\n├──▶ a.nu file 1KB\n└──▶ b.nu file 2KB"
   runner: "stdio"}

  {name: "conf-rope-tree-plain"
   # rope tree plain: identical to utf8; tree mode has no renderer-supplied borders
   nu_src: "use nu-lib/lib/render.nu; use nu-lib/lib/rope.nu *; {label: {name: 'src'}, fields: {type: 'dir', size: '4.0 kB'}, children: [{label: {name: 'a.nu'}, fields: {type: 'file', size: '1KB'}}, {label: {name: 'b.nu'}, fields: {type: 'file', size: '2KB'}}]} | rope tree | render walk {format: 'plain'}"
   expected: "src dir 4.0 kB\n├──▶ a.nu file 1KB\n└──▶ b.nu file 2KB"
   runner: "stdio"}

  {name: "conf-rope-tree-text"
   # rope tree text: name qualified to full path; fields as key=value; no id/parent_id
   nu_src: "use nu-lib/lib/render.nu; use nu-lib/lib/rope.nu *; {label: {name: 'src'}, fields: {type: 'dir', size: '4.0 kB'}, children: [{label: {name: 'a.nu'}, fields: {type: 'file', size: '1KB'}}, {label: {name: 'b.nu'}, fields: {type: 'file', size: '2KB'}}]} | rope tree | render walk {format: 'text'}"
   expected: "src type=dir size=4.0 kB\nsrc/a.nu type=file size=1KB\nsrc/b.nu type=file size=2KB"
   runner: "stdio"}

  {name: "conf-rope-tree-json"
   # rope tree json: tree form (no _flat) — nested children; no id/parent_id
   nu_src: "use nu-lib/lib/render.nu; use nu-lib/lib/rope.nu *; {label: {name: 'src'}, fields: {type: 'dir', size: '4.0 kB'}, children: [{label: {name: 'a.nu'}, fields: {type: 'file', size: '1KB'}}, {label: {name: 'b.nu'}, fields: {type: 'file', size: '2KB'}}]} | rope tree | render walk {format: 'json'} | from json | to json"
   expected: "[{\"name\":\"src\",\"type\":\"dir\",\"size\":\"4.0 kB\",\"children\":[{\"name\":\"a.nu\",\"type\":\"file\",\"size\":\"1KB\"},{\"name\":\"b.nu\",\"type\":\"file\",\"size\":\"2KB\"}]}]"
   runner: "stdio"
   assert: {|actual expected|
     let a = ($actual | from json)
     let e = ($expected | from json)
     $a == $e
   }}

  # ── rope md ──────────────────────────────────────────────────────────────

  {name: "conf-rope-md-rich"
   # rope md rich: markdown outline; headings have ANSI style; no id/parent_id
   nu_src: "use nu-lib/lib/render.nu; use nu-lib/lib/rope.nu *; {label: {name: 'src'}, fields: {type: 'dir', size: '4.0 kB'}, children: [{label: {name: 'a.nu'}, fields: {type: 'file', size: '1KB'}}, {label: {name: 'b.nu'}, fields: {type: 'file', size: '2KB'}}]} | rope md | render walk {format: 'rich'} | ansi strip"
   expected: "# src\n\n- type: dir\n- size: 4.0 kB\n\n## a.nu\n\n- type: file\n- size: 1KB\n\n## b.nu\n\n- type: file\n- size: 2KB"
   runner: "stdio"}

  {name: "conf-rope-md-utf8"
   # rope md utf8: identical to rich; rstr renders to plain text (no ANSI)
   nu_src: "use nu-lib/lib/render.nu; use nu-lib/lib/rope.nu *; {label: {name: 'src'}, fields: {type: 'dir', size: '4.0 kB'}, children: [{label: {name: 'a.nu'}, fields: {type: 'file', size: '1KB'}}, {label: {name: 'b.nu'}, fields: {type: 'file', size: '2KB'}}]} | rope md | render walk {format: 'utf8'}"
   expected: "# src\n\n- type: dir\n- size: 4.0 kB\n\n## a.nu\n\n- type: file\n- size: 1KB\n\n## b.nu\n\n- type: file\n- size: 2KB"
   runner: "stdio"}

  {name: "conf-rope-md-plain"
   # rope md plain: identical to utf8; tree mode no renderer-supplied borders
   nu_src: "use nu-lib/lib/render.nu; use nu-lib/lib/rope.nu *; {label: {name: 'src'}, fields: {type: 'dir', size: '4.0 kB'}, children: [{label: {name: 'a.nu'}, fields: {type: 'file', size: '1KB'}}, {label: {name: 'b.nu'}, fields: {type: 'file', size: '2KB'}}]} | rope md | render walk {format: 'plain'}"
   expected: "# src\n\n- type: dir\n- size: 4.0 kB\n\n## a.nu\n\n- type: file\n- size: 1KB\n\n## b.nu\n\n- type: file\n- size: 2KB"
   runner: "stdio"}

  {name: "conf-rope-md-text"
   # rope md text: multi-line outline; heading on own line; fields as - key=value; no id/parent_id
   nu_src: "use nu-lib/lib/render.nu; use nu-lib/lib/rope.nu *; {label: {name: 'src'}, fields: {type: 'dir', size: '4.0 kB'}, children: [{label: {name: 'a.nu'}, fields: {type: 'file', size: '1KB'}}, {label: {name: 'b.nu'}, fields: {type: 'file', size: '2KB'}}]} | rope md | render walk {format: 'text'}"
   expected: "# src\n- type=dir\n- size=4.0 kB\n\n## a.nu\n- type=file\n- size=1KB\n\n## b.nu\n- type=file\n- size=2KB"
   runner: "stdio"}

  {name: "conf-rope-md-json"
   # rope md json: tree form — nested children; no id/parent_id
   nu_src: "use nu-lib/lib/render.nu; use nu-lib/lib/rope.nu *; {label: {name: 'src'}, fields: {type: 'dir', size: '4.0 kB'}, children: [{label: {name: 'a.nu'}, fields: {type: 'file', size: '1KB'}}, {label: {name: 'b.nu'}, fields: {type: 'file', size: '2KB'}}]} | rope md | render walk {format: 'json'} | from json | to json"
   expected: "[{\"name\":\"src\",\"type\":\"dir\",\"size\":\"4.0 kB\",\"children\":[{\"name\":\"a.nu\",\"type\":\"file\",\"size\":\"1KB\"},{\"name\":\"b.nu\",\"type\":\"file\",\"size\":\"2KB\"}]}]"
   runner: "stdio"
   assert: {|actual expected|
     let a = ($actual | from json)
     let e = ($expected | from json)
     $a == $e
   }}

  # ── rope md-table ────────────────────────────────────────────────────────

  {name: "conf-rope-md-table-rich"
   # rope md-table rich: heading + bullets + embedded table with UTF-8 borders; no id/parent_id
   nu_src: "use nu-lib/lib/render.nu; use nu-lib/lib/rope.nu *; {label: {name: 'src'}, fields: {type: 'dir'}, children: [{label: {name: 'a.nu'}, fields: {type: 'file', size: '1KB'}}, {label: {name: 'b.nu'}, fields: {type: 'file', size: '2KB'}}]} | rope md-table | render walk {format: 'rich'} | ansi strip"
   expected: "# src\n\n- type: dir\n╭──────┬──────┬──────╮\n│ name │ type │ size │\n├──────┼──────┼──────┤\n│ a.nu │ file │ 1KB  │\n│ b.nu │ file │ 2KB  │\n╰──────┴──────┴──────╯"
   runner: "stdio"}

  {name: "conf-rope-md-table-utf8"
   # rope md-table utf8: identical to rich; rstr renders to plain text (no ANSI); UTF-8 borders kept
   nu_src: "use nu-lib/lib/render.nu; use nu-lib/lib/rope.nu *; {label: {name: 'src'}, fields: {type: 'dir'}, children: [{label: {name: 'a.nu'}, fields: {type: 'file', size: '1KB'}}, {label: {name: 'b.nu'}, fields: {type: 'file', size: '2KB'}}]} | rope md-table | render walk {format: 'utf8'}"
   expected: "# src\n\n- type: dir\n╭──────┬──────┬──────╮\n│ name │ type │ size │\n├──────┼──────┼──────┤\n│ a.nu │ file │ 1KB  │\n│ b.nu │ file │ 2KB  │\n╰──────┴──────┴──────╯"
   runner: "stdio"}

  {name: "conf-rope-md-table-plain"
   # rope md-table plain: heading/bullets unchanged (tree mode, visual items visible);
   # embedded table uses space alignment; no borders
   nu_src: "use nu-lib/lib/render.nu; use nu-lib/lib/rope.nu *; {label: {name: 'src'}, fields: {type: 'dir'}, children: [{label: {name: 'a.nu'}, fields: {type: 'file', size: '1KB'}}, {label: {name: 'b.nu'}, fields: {type: 'file', size: '2KB'}}]} | rope md-table | render walk {format: 'plain'}"
   expected: "# src\n\n- type: dir\nname  type  size\n\na.nu  file  1KB\nb.nu  file  2KB"
   runner: "stdio"}

  {name: "conf-rope-md-table-text"
   # rope md-table text: heading + text bullets + embedded table (space-aligned, no borders)
   nu_src: "use nu-lib/lib/render.nu; use nu-lib/lib/rope.nu *; {label: {name: 'src'}, fields: {type: 'dir'}, children: [{label: {name: 'a.nu'}, fields: {type: 'file', size: '1KB'}}, {label: {name: 'b.nu'}, fields: {type: 'file', size: '2KB'}}]} | rope md-table | render walk {format: 'text'}"
   expected: "# src\n- type=dir\nname  type  size\n\na.nu  file  1KB\nb.nu  file  2KB"
   runner: "stdio"}

  {name: "conf-rope-md-table-json"
   # rope md-table json: tree form with embedded table as flat sub-array inside children
   nu_src: "use nu-lib/lib/render.nu; use nu-lib/lib/rope.nu *; {label: {name: 'src'}, fields: {type: 'dir'}, children: [{label: {name: 'a.nu'}, fields: {type: 'file', size: '1KB'}}, {label: {name: 'b.nu'}, fields: {type: 'file', size: '2KB'}}]} | rope md-table | render walk {format: 'json'} | from json | to json"
   expected: "[{\"name\":\"src\",\"type\":\"dir\",\"children\":[[{\"name\":\"a.nu\",\"type\":\"file\",\"size\":\"1KB\"},{\"name\":\"b.nu\",\"type\":\"file\",\"size\":\"2KB\"}]]}]"
   runner: "stdio"
   assert: {|actual expected|
     let a = ($actual | from json)
     let e = ($expected | from json)
     $a == $e
   }}

  # ── Format-acceptance tests ────────────────────────────────────────────────

  {name: "format-accept-rich"
   # render walk accepts format: rich
   nu_src: "use nu-lib/lib/render.nu; {_fields: [{k: 'name', v: 'test'}]} | render walk {format: 'rich'}"
   expected: 0
   runner: "exit"}

  {name: "format-accept-utf8"
   # render walk accepts format: utf8
   nu_src: "use nu-lib/lib/render.nu; {_fields: [{k: 'name', v: 'test'}]} | render walk {format: 'utf8'}"
   expected: 0
   runner: "exit"}

  {name: "format-accept-plain"
   # render walk accepts format: plain
   nu_src: "use nu-lib/lib/render.nu; {_fields: [{k: 'name', v: 'test'}]} | render walk {format: 'plain'}"
   expected: 0
   runner: "exit"}

  {name: "format-accept-text"
   # render walk accepts format: text
   nu_src: "use nu-lib/lib/render.nu; {_fields: [{k: 'name', v: 'test'}]} | render walk {format: 'text'}"
   expected: 0
   runner: "exit"}

  {name: "format-accept-json"
   # render walk accepts format: json
   nu_src: "use nu-lib/lib/render.nu; {_fields: [{k: 'name', v: 'test'}]} | render walk {format: 'json'}"
   expected: 0
   runner: "exit"}

  {name: "format-reject-ansi"
   # render walk rejects format: ansi
   nu_src: "use nu-lib/lib/render.nu; {_fields: [{k: 'name', v: 'test'}]} | render walk {format: 'ansi'}"
   expected: 1
   runner: "exit"}

  {name: "format-reject-nested-cfg"
   # render walk rejects nested cfg form {output: {format: ...}} with generic error
   iut: {|_|
     let script = "use nu-lib/lib/render.nu; {_fields: [{k: 'name', v: 'test'}]} | render walk {output: {format: 'rich'}}"
     let result = (^nu -c $script | complete)
     let combined = ($result.stdout + $result.stderr)
     ($result.exit_code != 0) and ($combined | str contains "render walk:")
   }
   input: null
   expected: true
   runner: "value"}

  # ── q value validation tests ───────────────────────────────────────────────

  {name: "q-absent-accepted"
   # field-node with q absent is accepted
   nu_src: "use nu-lib/lib/render.nu; {_fields: [{k: 'name', v: 'test'}]} | render walk {format: 'text'}"
   expected: 0
   runner: "exit"}

  {name: "q-visual-accepted"
   # field-node with q: visual is accepted
   nu_src: "use nu-lib/lib/render.nu; {_fields: [{k: 'name', v: 'test', q: 'visual'}]} | render walk {format: 'text'}"
   expected: 0
   runner: "exit"}

  {name: "q-text-accepted"
   # field-node with q: text is accepted
   nu_src: "use nu-lib/lib/render.nu; {_fields: [{k: 'name', v: 'test', q: 'text'}]} | render walk {format: 'text'}"
   expected: 0
   runner: "exit"}

  {name: "q-rich-rejected"
   # q: rich is invalid — render walk errors
   nu_src: "use nu-lib/lib/render.nu; {_fields: [{k: 'name', v: 'test', q: 'rich'}]} | render walk {format: 'text'}"
   expected: 1
   runner: "exit"}

  {name: "q-data-rejected"
   # q: data is invalid — render walk errors
   nu_src: "use nu-lib/lib/render.nu; {_fields: [{k: 'name', v: 'test', q: 'data'}]} | render walk {format: 'text'}"
   expected: 1
   runner: "exit"}

  {name: "q-none-rejected"
   # q: none is invalid — render walk errors
   nu_src: "use nu-lib/lib/render.nu; {_fields: [{k: 'name', v: 'test', q: 'none'}]} | render walk {format: 'text'}"
   expected: 1
   runner: "exit"}

  {name: "q-json-rejected"
   # q: json is invalid — render walk errors
   nu_src: "use nu-lib/lib/render.nu; {_fields: [{k: 'name', v: 'test', q: 'json'}]} | render walk {format: 'text'}"
   expected: 1
   runner: "exit"}

  {name: "q-list-rejected"
   # q as a list is invalid — render walk errors
   nu_src: "use nu-lib/lib/render.nu; {_fields: [{k: 'name', v: 'test', q: ['visual']}]} | render walk {format: 'text'}"
   expected: 1
   runner: "exit"}

  # ── Unknown-key rejection tests ────────────────────────────────────────────
  # All node unknown keys must error with one generic message (not enumerate legacy names)

  {name: "unknown-key-layout-errors"
   # _layout on a node is rejected with generic error
   iut: {|_|
     let script = "use nu-lib/lib/render.nu; {_fields: [{k: 'name', v: 'test'}], _layout: 'flat'} | render walk {format: 'text'}"
     let result = (^nu -c $script | complete)
     let combined = ($result.stdout + $result.stderr)
     let ok = ($result.exit_code != 0) and ($combined | str contains "render walk:")
     let no_legacy = not ($combined | str contains "_headers") and not ($combined | str contains "_fill") and not ($combined | str contains "_sep") and not ($combined | str contains "topology")
     $ok and $no_legacy
   }
   input: null
   expected: true
   runner: "value"}

  {name: "unknown-key-topology-errors"
   # topology on a node is rejected with generic error (not enumerating legacy names)
   iut: {|_|
     let script = "use nu-lib/lib/render.nu; {_fields: [{k: 'name', v: 'test'}], topology: 'nested'} | render walk {format: 'text'}"
     let result = (^nu -c $script | complete)
     let combined = ($result.stdout + $result.stderr)
     let ok = ($result.exit_code != 0) and ($combined | str contains "render walk:")
     let no_legacy = not ($combined | str contains "_headers") and not ($combined | str contains "_fill") and not ($combined | str contains "_sep") and not ($combined | str contains "_layout")
     $ok and $no_legacy
   }
   input: null
   expected: true
   runner: "value"}

  {name: "unknown-key-headers-errors"
   # _headers on a node is rejected with generic error
   iut: {|_|
     let script = "use nu-lib/lib/render.nu; {_fields: [{k: 'name', v: 'test'}], _headers: ['a', 'b']} | render walk {format: 'text'}"
     let result = (^nu -c $script | complete)
     let combined = ($result.stdout + $result.stderr)
     ($result.exit_code != 0) and ($combined | str contains "render walk:")
   }
   input: null
   expected: true
   runner: "value"}

  {name: "unknown-key-fill-errors"
   # _fill on a node is rejected with generic error
   iut: {|_|
     let script = "use nu-lib/lib/render.nu; {_fields: [{k: 'name', v: 'test'}], _fill: ' '} | render walk {format: 'text'}"
     let result = (^nu -c $script | complete)
     let combined = ($result.stdout + $result.stderr)
     ($result.exit_code != 0) and ($combined | str contains "render walk:")
   }
   input: null
   expected: true
   runner: "value"}

  {name: "unknown-key-sep-errors"
   # _sep on a node is rejected with generic error
   iut: {|_|
     let script = "use nu-lib/lib/render.nu; {_fields: [{k: 'name', v: 'test'}], _sep: '  '} | render walk {format: 'text'}"
     let result = (^nu -c $script | complete)
     let combined = ($result.stdout + $result.stderr)
     ($result.exit_code != 0) and ($combined | str contains "render walk:")
   }
   input: null
   expected: true
   runner: "value"}

  {name: "unknown-key-foo-errors"
   # arbitrary key _foo on a node is rejected with generic error
   iut: {|_|
     let script = "use nu-lib/lib/render.nu; {_fields: [{k: 'name', v: 'test'}], _foo: 'bar'} | render walk {format: 'text'}"
     let result = (^nu -c $script | complete)
     let combined = ($result.stdout + $result.stderr)
     ($result.exit_code != 0) and ($combined | str contains "render walk:")
   }
   input: null
   expected: true
   runner: "value"}

  {name: "flat-utf8-wide-emoji-cell-aligns-border"
   iut: {|_|
     let script = "use nu-lib/lib/render.nu; use nu-lib/lib/rope.nu *; [{key: 'emf/ 🔒🔒', value: 'EMF language and tooling project'}] | rope table --columns {key: {justify: 'left', weight: 2}, value: {justify: 'left', weight: 4, clip: 'rhs'}} | render walk {format: 'utf8'}"
     let out = (^nu -c $script | complete).stdout | str trim
     let expected = "╭───────────┬──────────────────────────────────╮
│ key       │ value                            │
├───────────┼──────────────────────────────────┤
│ emf/ 🔒🔒 │ EMF language and tooling project │
╰───────────┴──────────────────────────────────╯"
     $out == $expected
   }
   input: null
   expected: true
   runner: "value"}

  # ── Visual-class parity test ───────────────────────────────────────────────

  {name: "visual-parity-leaves"
   # rich, utf8, plain share the visual byte stream — same visible field-node values
   # Use rope tree fixture; strip ANSI from rich; compare leaf text content
   iut: {|_|
     let script_rich  = "use nu-lib/lib/render.nu; use nu-lib/lib/rope.nu *; {label: {name: 'src'}, fields: {type: 'dir', size: '4.0 kB'}, children: [{label: {name: 'a.nu'}, fields: {type: 'file', size: '1KB'}}, {label: {name: 'b.nu'}, fields: {type: 'file', size: '2KB'}}]} | rope tree | render walk {format: 'rich'} | ansi strip"
     let script_utf8  = "use nu-lib/lib/render.nu; use nu-lib/lib/rope.nu *; {label: {name: 'src'}, fields: {type: 'dir', size: '4.0 kB'}, children: [{label: {name: 'a.nu'}, fields: {type: 'file', size: '1KB'}}, {label: {name: 'b.nu'}, fields: {type: 'file', size: '2KB'}}]} | rope tree | render walk {format: 'utf8'}"
     let script_plain = "use nu-lib/lib/render.nu; use nu-lib/lib/rope.nu *; {label: {name: 'src'}, fields: {type: 'dir', size: '4.0 kB'}, children: [{label: {name: 'a.nu'}, fields: {type: 'file', size: '1KB'}}, {label: {name: 'b.nu'}, fields: {type: 'file', size: '2KB'}}]} | rope tree | render walk {format: 'plain'}"
     let out_rich  = (^nu -c $script_rich  | complete).stdout | str trim
     let out_utf8  = (^nu -c $script_utf8  | complete).stdout | str trim
     let out_plain = (^nu -c $script_plain | complete).stdout | str trim
     # All three must produce the same plain-text content
     ($out_rich == $out_utf8) and ($out_utf8 == $out_plain)
   }
   input: null
   expected: true
   runner: "value"}

  # ── Text TTY-independence test ─────────────────────────────────────────────

  {name: "text-tty-independence"
   # text format produces byte-identical output regardless of FORCE_TTY and COLUMNS
   iut: {|_|
     let script = "use nu-lib/lib/render.nu; use nu-lib/lib/rope.nu *; {label: {name: 'src'}, fields: {type: 'dir', size: '4.0 kB'}, children: [{label: {name: 'a.nu'}, fields: {type: 'file', size: '1KB'}}, {label: {name: 'b.nu'}, fields: {type: 'file', size: '2KB'}}]} | rope tree | render walk {format: 'text'}"
     let out_tty0   = (with-env {FORCE_TTY: "0"} { ^nu -c $script } | complete).stdout
     let out_tty1   = (with-env {FORCE_TTY: "1"} { ^nu -c $script } | complete).stdout
     let out_col30  = (with-env {FORCE_TTY: "0", COLUMNS: "30"} { ^nu -c $script } | complete).stdout
     let out_col60  = (with-env {FORCE_TTY: "0", COLUMNS: "60"} { ^nu -c $script } | complete).stdout
     let out_col90  = (with-env {FORCE_TTY: "0", COLUMNS: "90"} { ^nu -c $script } | complete).stdout
     ($out_tty0 == $out_tty1) and ($out_tty0 == $out_col30) and ($out_tty0 == $out_col60) and ($out_tty0 == $out_col90)
   }
   input: null
   expected: true
   runner: "value"}

  # ── Null-cols natural-widths test ──────────────────────────────────────────

  {name: "null-cols-natural-widths"
   # rich with FORCE_TTY=0 (tui-columns returns null) produces same output as COLUMNS=999
   # Both should use natural widths (Case 1 — no-op fit)
   iut: {|_|
     let script = "use nu-lib/lib/render.nu; use nu-lib/lib/rope.nu *; [{id: 1, name: 'src', type: 'dir', size: '4.0 kB'}, {id: 2, name: 'src/a.nu', type: 'file', size: '1KB', parent_id: 1}, {id: 3, name: 'src/b.nu', type: 'file', size: '2KB', parent_id: 1}] | rope table --columns {id: {q: 'text'}, parent_id: {q: 'text'}} | render walk {format: 'rich'} | ansi strip"
     # FORCE_TTY=0 → tui-is-tty false → cols = null → Case 1 natural widths
     let out_null_cols = (with-env {FORCE_TTY: "0"} { ^nu -c $script } | complete).stdout
     # COLUMNS=999 with non-TTY → same path
     let out_999_cols = (with-env {FORCE_TTY: "0", COLUMNS: "999"} { ^nu -c $script } | complete).stdout
     $out_null_cols == $out_999_cols
   }
   input: null
   expected: true
   runner: "value"}

  # ── Structural tests ───────────────────────────────────────────────────────

  {name: "single-tty-site"
   # tui-is-tty and tui-columns must be called only by render-env.
   iut: {|_|
     let call_lines = (open nu-lib/lib/render.nu | lines
       | where {|l| not (($l | str trim) | str starts-with "#")}
       | where {|l| ($l | str contains "tui-is-tty") or ($l | str contains "tui-columns")}
       | where {|l| not ($l | str contains "def render-env")}
     )
     let count_ok = (($call_lines | length) == 2)
     let is_tty_ok = ($call_lines | any {|l| $l | str contains "let is_tty = tui-is-tty"})
     let cols_ok = ($call_lines | any {|l| $l | str contains "tui-columns"})
     $count_ok and $is_tty_ok and $cols_ok
   }
   input: null
   expected: true
   runner: "value"}

  {name: "col-budgets-elastic-expands-past-min"
   # Regression: col-budgets Case 2 previously collapsed every elastic column to its
   # min_w because the line `[$nat_w $share] | math min | [($min_w)] | math max`
   # constructs a fresh list literal that discards the upstream math min result.
   # With a narrow terminal and one elastic column whose natural width exceeds its
   # share, the value column must consume the available budget — not collapse to
   # the header label's length.
   iut: {|_|
     let script = "use nu-lib/lib/render.nu; use nu-lib/lib/rope.nu *; [{key: 'short', value: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'}] | rope table --columns {value: {weight: 1}} | render walk {format: 'rich'} | ansi strip"
     let out = (with-env {FORCE_TTY: "1", COLUMNS: "80"} { ^nu -c $script } | complete).stdout
     # Top border line indicates the rendered table width. With a 145-char value
     # and a 5-char key, Case 2 must fit within 80 cols by clipping the value
     # column to fill the budget — not collapse it to min_w = 5.
     let border = ($out | lines | first)
     ($border | str length) > 30
   }
   input: null
   expected: true
   runner: "value"}

  {name: "visual-template-budget-format-values-fit-selected-branches"
   # Exact _fmt branch selection happens before visual flat-mode width planning.
   # The rich, utf8, and plain branches intentionally have different display
   # lengths; with forced TTY each selected branch must fit the fixed budget and
   # the neighboring elastic notes column must clip under the same renderer path.
   iut: {|_|
     let script = "use nu-lib/lib/render.nu; let rope = {_flat: {mode: {weight: 0}, label: {weight: 0}, notes: {weight: 1, clip: 'rhs'}}, _fields: [{k: 'mode', v: 'pick'}, {k: 'label', v: {_fmt: {rich: 'R5', utf8: 'UTF8-branch', plain: 'P'}}}, {k: 'notes', v: 'abcdefghijklmnopqrstuvwxyz0123456789'}]}; let rich = (with-env {FORCE_TTY: '1', COLUMNS: '30'} { $rope | render walk {format: 'rich'} } | ansi strip); let utf8 = (with-env {FORCE_TTY: '1', COLUMNS: '30'} { $rope | render walk {format: 'utf8'} }); let plain = (with-env {FORCE_TTY: '1', COLUMNS: '30'} { $rope | render walk {format: 'plain'} }); {rich: $rich, utf8: $utf8, plain: $plain} | to json"
     let out = (with-env {FORCE_TTY: "0"} { ^nu -c $script } | complete).stdout | from json
     let rich = $out.rich
     let utf8 = $out.utf8
     let plain = $out.plain
     let rich_lines_fit = ($rich | lines | all {|l| ($l | rstr display-len) <= 30})
     let utf8_lines_fit = ($utf8 | lines | all {|l| ($l | rstr display-len) <= 30})
     let plain_lines_fit = ($plain | lines | all {|l| ($l | rstr display-len) <= 30})
     let rich_selected = ($rich | str contains "R5") and not ($rich | str contains "UTF8-branch") and not ($rich | str contains " P ")
     let utf8_selected = ($utf8 | str contains "UTF8-branch") and not ($utf8 | str contains "R5") and not ($utf8 | str contains " P ")
     let plain_selected = ($plain | str contains " P ") and not ($plain | str contains "R5") and not ($plain | str contains "UTF8-branch")
     let clipped = ([$rich $utf8 $plain] | all {|s| ($s | str contains "abcd…") and not ($s | str contains "abcdefghijklmnopqrstuvwxyz0123456789")})
     $rich_lines_fit and $utf8_lines_fit and $plain_lines_fit and $rich_selected and $utf8_selected and $plain_selected and $clipped
   }
   input: null
   expected: true
   runner: "value"}

  {name: "column-sacrifice-drops-lowest-weight-first"
   # Case 4: when shrinking cannot fit all visual columns, the lowest weighted
   # droppable column is sacrificed and a right-edge sentinel remains visible.
   iut: {|_|
     let script = "use nu-lib/lib/render.nu; let rope = {_flat: {keep: {weight: 0, clip: 'rhs'}, drop_a: {weight: 1, clip: 'rhs'}, drop_b: {weight: 2, clip: 'rhs'}}, _fields: [{k: 'keep', v: 'anchored'}, {k: 'drop_a', v: 'aa'}, {k: 'drop_b', v: 'bbbbbbbb'}]}; with-env {FORCE_TTY: '1', COLUMNS: '24'} { $rope | render walk {format: 'utf8'} }"
     let out = (with-env {FORCE_TTY: "0"} { ^nu -c $script } | complete).stdout
     let lines_fit = ($out | lines | all {|l| ($l | rstr display-len) <= 24})
     $lines_fit and ($out | str contains "keep") and ($out | str contains "drop_b") and ($out | str contains "…") and not ($out | str contains "drop_a")
   }
   input: null
   expected: true
   runner: "value"}

  {name: "column-sacrifice-keeps-protected-until-droppable-gone"
   # Case 4: protected weight-0 columns are considered after droppable weighted
   # columns, so a very narrow budget sacrifices both weighted columns first.
   iut: {|_|
     let script = "use nu-lib/lib/render.nu; let rope = {_flat: {keep: {weight: 0, clip: 'rhs'}, drop_a: {weight: 1, clip: 'rhs'}, drop_b: {weight: 2, clip: 'rhs'}}, _fields: [{k: 'keep', v: 'anchored'}, {k: 'drop_a', v: 'aa'}, {k: 'drop_b', v: 'bbbbbbbb'}]}; with-env {FORCE_TTY: '1', COLUMNS: '20'} { $rope | render walk {format: 'utf8'} }"
     let out = (with-env {FORCE_TTY: "0"} { ^nu -c $script } | complete).stdout
     let lines_fit = ($out | lines | all {|l| ($l | rstr display-len) <= 20})
     $lines_fit and ($out | str contains "keep") and ($out | str contains "anchored") and ($out | str contains "…") and not ($out | str contains "drop_a") and not ($out | str contains "drop_b")
   }
   input: null
   expected: true
   runner: "value"}

  {name: "no-hardcoded-width-fallback"
   # No hardcoded width fallback (default 80, default 100, default 120) in render.nu or tui.nu
   iut: {|_|
     let count_str = (do { grep -nE 'default 80|default 100|default 120' nu-lib/lib/render.nu nu-lib/lib/tui.nu | wc -l } | complete).stdout | str trim
     ($count_str | into int) == 0
   }
   input: null
   expected: true
   runner: "value"}

] }

def main [
  --filter(-f): string = ""
  --tag(-t):    string = ""
  --format:     string = "text"
  --list(-l)
] {
  if $list {
    cases | list-cases | to json | print
    return
  }
  cases | run --filter $filter --tag $tag | report --format $format
}
