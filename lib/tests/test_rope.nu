#!/usr/bin/env nu

use ../test.nu *
use ../rope.nu *
use ../rstr.nu *
use ../render.nu

# ── Fixture helpers ───────────────────────────────────────────────────────────

# Standard 2-level fixture: root + 2 children + 1 grandchild under first child
def two-level-fixture [] {
  {
    label:    {heading: "root"}
    fields:   {name: "root-node"}
    children: [
      {
        label:    {heading: "child-a"}
        fields:   {name: "child-a-node"}
        children: [
          {
            label:    {heading: "grandchild"}
            fields:   {name: "gc-node"}
            children: []
          }
        ]
      }
      {
        label:    {heading: "child-b"}
        fields:   {name: "child-b-node"}
        children: []
      }
    ]
  }
}

# DFS-walk an OT node tree; return a flat list of all OT nodes in DFS order
def dfs-all [node: record]: nothing -> list {
  let children = ($node | get _children | default [])
  let child_results = ($children | each {|c| dfs-all $c} | flatten)
  [$node] ++ $child_results
}

# Get the label stem field (k="name", v=rstr) from an OT node produced by rope md.
# This is the keyed stem (shape-3) that carries the heading-tagged rstr.
def label-field [node: record] {
  $node | get _fields | where {|f| ($f | get k? | default "") == "name"} | first
}

# ── Cases ─────────────────────────────────────────────────────────────────────

def cases [] { [

  # ── 01: depth-1 plain-string label produces shape-1 v tagged "h1" (no q) ──
  {name: "rope-md-01-plain-label-tags-h1"
   iut: {|_|
     let node = {label: {heading: "My Title"} children: []}
     # rope md returns the node directly (not wrapped in a transparent root)
     let result = ($node | rope md)
     let lf = (label-field $result)
     # shape-1: no q key; v is rstr tagged h1
     not ($lf | columns | any {|c| $c == "q"}) and (($lf | get v | rstr regions) == ["h1"])
   }
   input: null
   expected: true}

  # ── 02: depth-3 plain-string label produces shape-1 v tagged "h3" (no q) ──
  {name: "rope-md-02-plain-label-tags-h3"
   iut: {|_|
     # nest 3 levels deep to get depth=3
     let node = {
       label: {h: "lv1"}
       children: [{
         label: {h: "lv2"}
         children: [{
           label: {h: "lv3"}
           children: []
         }]
       }]
     }
     # rope md returns the root node (lv1) directly; navigate _children to reach lv3
     let result = ($node | rope md)
     let ch2 = ($result | get _children | first)
     let ch3 = ($ch2 | get _children | first)
     let lf = (label-field $ch3)
     # shape-1: no q key; v is rstr tagged h3
     not ($lf | columns | any {|c| $c == "q"}) and (($lf | get v | rstr regions) == ["h3"])
   }
   input: null
   expected: true}

  # ── 03: pre-built rstr label passes through verbatim as shape-1 (no q) ────
  {name: "rope-md-03-rstr-label-preserved"
   iut: {|_|
     let pre_rstr = ("section" | rstr of | rstr tag "h2")
     let node = {label: {heading: $pre_rstr} children: []}
     # rope md returns the node directly
     let result = ($node | rope md)
     let lf = (label-field $result)
     # shape-1: no q key; v must equal the original rstr verbatim
     not ($lf | columns | any {|c| $c == "q"}) and ($lf | get v) == $pre_rstr
   }
   input: null
   expected: true}

  # ── 04: pre-built rstr field value passes through verbatim ────────────────
  {name: "rope-md-04-rstr-field-preserved"
   iut: {|_|
     let pre_rstr = ("my-value" | rstr of | rstr tag "ok")
     let node = {label: {h: "title"} fields: {status: $pre_rstr} children: []}
     # rope md returns the node directly
     let result = ($node | rope md)
     let fields = ($result | get _fields)
     # shape-3 caller field for status: {k, v} — no q key
     let status_field = ($fields | where {|f| ($f | get k? | default "") == "status"} | first)
     not ($status_field | columns | any {|c| $c == "q"}) and ($status_field | get v) == $pre_rstr
   }
   input: null
   expected: true}

  # ── 05: no id or parent_id in rope md _fields (not minted by composer) ─────
  {name: "rope-md-05-no-auto-id-or-parent-id"
   iut: {|_|
     let rope = (two-level-fixture | rope md)
     # rope md returns the root node directly; DFS from the root itself
     let all_nodes = (dfs-all $rope)
     # No node should carry {k:"id"} or {k:"parent_id"} — rope md does not mint them
     let any_has_id = ($all_nodes | any {|n|
       $n | get _fields | any {|f| ($f | get k? | default "") == "id"}
     })
     let any_has_parent_id = ($all_nodes | any {|n|
       $n | get _fields | any {|f| ($f | get k? | default "") == "parent_id"}
     })
     (not $any_has_id) and (not $any_has_parent_id)
   }
   input: null
   expected: true}

  # ── 06: no id or parent_id in rope md — single node and child ─────────────
  {name: "rope-md-06-no-id-in-root-or-child"
   iut: {|_|
     let rope = (two-level-fixture | rope md)
     # rope md returns root node directly; children are in _children
     let root_ot = $rope
     let child_ot = ($root_ot | get _children | first)

     # Neither root nor child should have id or parent_id in _fields
     let root_has_id        = ($root_ot  | get _fields | any {|f| ($f | get k? | default "") == "id"})
     let root_has_parent_id = ($root_ot  | get _fields | any {|f| ($f | get k? | default "") == "parent_id"})
     let child_has_id       = ($child_ot | get _fields | any {|f| ($f | get k? | default "") == "id"})
     let child_has_parent_id = ($child_ot | get _fields | any {|f| ($f | get k? | default "") == "parent_id"})

     (not $root_has_id) and (not $root_has_parent_id) and (not $child_has_id) and (not $child_has_parent_id)
   }
   input: null
   expected: true}

  # ── 07: no depth field emitted — rope md does not include depth in _fields ──
  {name: "rope-md-07-no-depth-field"
   iut: {|_|
     let rope = (two-level-fixture | rope md)
     # rope md returns root directly; navigate to root, child, grandchild
     let root_ot  = $rope
     let child_ot = ($root_ot | get _children | first)
     let gc_ot    = ($child_ot | get _children | first)

     # None of the nodes should have a depth field in _fields
     let root_no_depth  = not ($root_ot  | get _fields | any {|f| ($f | get k? | default "") == "depth"})
     let child_no_depth = not ($child_ot | get _fields | any {|f| ($f | get k? | default "") == "depth"})
     let gc_no_depth    = not ($gc_ot    | get _fields | any {|f| ($f | get k? | default "") == "depth"})

     $root_no_depth and $child_no_depth and $gc_no_depth
   }
   input: null
   expected: true}

  # ── 08: depth clamps at h6 for depth-8 input ─────────────────────────────
  {name: "rope-md-08-depth-clamps-at-6"
   iut: {|_|
     let node = {
       label: {h: "lv1"}
       children: [{label: {h: "lv2"} children: [{
         label: {h: "lv3"} children: [{
           label: {h: "lv4"} children: [{
             label: {h: "lv5"} children: [{
               label: {h: "lv6"} children: [{
                 label: {h: "lv7"} children: [{
                   label: {h: "lv8"} children: []
                 }]
               }]
             }]
           }]
         }]
       }]
     }]
     }
     let rope = ($node | rope md)
     # rope md returns lv1 node directly; navigate down to lv8 via 7 _children steps
     let c1 = ($rope | get _children | first)
     let c2 = ($c1 | get _children | first)
     let c3 = ($c2 | get _children | first)
     let c4 = ($c3 | get _children | first)
     let c5 = ($c4 | get _children | first)
     let c6 = ($c5 | get _children | first)
     let c7 = ($c6 | get _children | first)
     # c7 is lv8 (depth 8); its label must be clamped to h6
     let lf = (label-field $c7)
     ($lf | get v | rstr regions) == ["h6"]
   }
   input: null
   expected: true}

  # ── 09: list input — 2-element list returns an empty-_fields root record ────
  {name: "rope-md-09-list-input-wraps"
   iut: {|_|
     let nodes = [
       {label: {h: "a"} children: []}
       {label: {h: "b"} children: []}
     ]
     let rope = ($nodes | rope md)
     # Multiple top-level nodes → wrapped in empty-_fields root record, not a bare list
     let desc = ($rope | describe)
     (($desc | str starts-with "record") and
      (($rope | get _fields | length) == 0) and
      (($rope | get _children | length) == 2))
   }
   input: null
   expected: true}

  # ── 10: caller fields {a, b, c} appear in _fields in that order ───────────
  {name: "rope-md-10-fields-key-order"
   iut: {|_|
     let node = {label: {h: "title"} fields: {a: "x", b: "y", c: "z"} children: []}
     # rope md returns the node directly
     let rope = ($node | rope md)
     let fields = ($rope | get _fields)
     # Collect keys of caller fields in the order they appear
     let caller_keys = ($fields | where {|f| ($f | get k? | default "") in ["a", "b", "c"]} | get k)
     $caller_keys == ["a", "b", "c"]
   }
   input: null
   expected: true}

  # ── 11: label key does NOT produce shape-4 with k="heading" ───────────────
  {name: "rope-md-11-label-no-auto-field"
   iut: {|_|
     let node = {label: {heading: "x"} children: []}
     # rope md returns the node directly
     let rope = ($node | rope md)
     let fields = ($rope | get _fields)
     # Must NOT have a data field with k="heading"
     not ($fields | any {|f| ($f | get k? | default "") == "heading" and ($f | get q? | default "") == "data"})
   }
   input: null
   expected: true}

  # ── 12: render walk utf8 — verbatim locked output ─────────────────────────
  # Uses utf8 (same visual structure as rich, no ANSI codes) for exact-eq assertion.
  {name: "rope-md-12-render-walk-rich"
   iut: {|_|
     let script = "use nu-lib/lib/rope.nu *; use nu-lib/lib/render.nu; {label: {heading: 'root'}, fields: {name: 'root-node'}, children: [{label: {heading: 'child-a'}, fields: {name: 'child-a-node'}, children: [{label: {heading: 'grandchild'}, fields: {name: 'gc-node'}, children: []}]}, {label: {heading: 'child-b'}, fields: {name: 'child-b-node'}, children: []}]} | rope md | render walk {format: 'utf8'}"
     let out = (with-env {FORCE_TTY: "0"} { ^nu -c $script } | complete).stdout | str trim
     # utf8: heading prefix, name bullet, then bullet fields; blank lines between nodes.
     # No id or parent_id (not minted by rope md). No depth field.
     let expected = "# root\n\n- name: root-node\n\n## child-a\n\n- name: child-a-node\n\n### grandchild\n\n- name: gc-node\n\n## child-b\n\n- name: child-b-node"
     assert-eq $out $expected
   }
   input: null
   expected: true}

  # ── 13: render walk text — verbatim locked output ────────────────────────
  {name: "rope-md-13-render-walk-text"
   iut: {|_|
     let script = "use nu-lib/lib/rope.nu *; use nu-lib/lib/render.nu; {label: {heading: 'root'}, fields: {name: 'root-node'}, children: [{label: {heading: 'child-a'}, fields: {name: 'child-a-node'}, children: [{label: {heading: 'grandchild'}, fields: {name: 'gc-node'}, children: []}]}, {label: {heading: 'child-b'}, fields: {name: 'child-b-node'}, children: []}]} | rope md | render walk {format: 'text'}"
     let out = (with-env {FORCE_TTY: "0"} { ^nu -c $script } | complete).stdout | str trim
     # text: heading on its own line; fields as "- key=value" bullets.
     # No id or parent_id (not minted by rope md). No depth field.
     let expected = "# root\n- name=root-node\n\n## child-a\n- name=child-a-node\n\n### grandchild\n- name=gc-node\n\n## child-b\n- name=child-b-node"
     assert-eq $out $expected
   }
   input: null
   expected: true}

  # ── 14: render walk json — tree-shaped, caller fields only, no id/parent_id ─
  {name: "rope-md-14-render-walk-json"
   iut: {|_|
     let script = "use nu-lib/lib/rope.nu *; use nu-lib/lib/render.nu; {label: {heading: 'root'}, fields: {name: 'root-node'}, children: [{label: {heading: 'child-a'}, fields: {name: 'child-a-node'}, children: [{label: {heading: 'grandchild'}, fields: {name: 'gc-node'}, children: []}]}, {label: {heading: 'child-b'}, fields: {name: 'child-b-node'}, children: []}]} | rope md | render walk {format: 'json'}"
     let out = (with-env {FORCE_TTY: "0"} { ^nu -c $script } | complete).stdout | str trim
     # Tree-shaped JSON: caller fields included; no id or parent_id (not minted by rope md).
     # No depth field. children key omitted on leaf nodes.
     let expected = "[
  {
    \"name\": \"root-node\",
    \"children\": [
      {
        \"name\": \"child-a-node\",
        \"children\": [
          {
            \"name\": \"gc-node\"
          }
        ]
      },
      {
        \"name\": \"child-b-node\"
      }
    ]
  }
]"
     assert-eq $out $expected
   }
   input: null
   expected: true}

  # ── new-1: output has no _flat at any level ───────────────────────────────
  {name: "rope-md-new1-no-flat-anywhere"
   iut: {|_|
     let rope = (two-level-fixture | rope md)
     # Check root and all descendant nodes for absence of _flat
     let root_has_flat = ("_flat" in ($rope | columns))
     let all_nodes = ($rope | get _children | each {|c| dfs-all $c} | flatten)
     let any_node_has_flat = ($all_nodes | any {|n| "_flat" in ($n | columns)})
     (not $root_has_flat) and (not $any_node_has_flat)
   }
   input: null
   expected: true}

  # ── new-2: embedded rope placed verbatim in _children ────────────────────
  {name: "rope-md-new2-embedded-rope-verbatim"
   iut: {|_|
     # Build a pre-built rope to embed as a child
     let embedded = {_fields: [{k: "info", v: "meta", q: "text"}], _children: []}
     let node = {
       label: {heading: "parent"}
       fields: {name: "p-node"}
       children: [$embedded]
     }
     # rope md returns the parent node directly
     let rope = ($node | rope md)
     let parent_ot = $rope
     # The embedded rope must appear verbatim as the sole child of parent_ot
     let child = ($parent_ot | get _children | first)
     $child == $embedded
   }
   input: null
   expected: true}

  # ── new-3: invalid child (non-record, non-rope) produces build error ──────
  {name: "rope-md-new3-invalid-child-error"
   iut: {|_|
     let node = {
       label: {heading: "root"}
       children: ["not-a-record"]
     }
     try {
       $node | rope md
       false
     } catch {
       true
     }
   }
   input: null
   expected: true}

  {name: "rope-md-body-text-slot"
   iut: {|_|
     let out = ({label: {heading: "root"}, body: "hello", fields: {kind: "branch"}, children: []} | rope md | render walk {format: "text"} | str trim)
     let expected = "# root\nhello\n- kind=branch"
     assert-eq $out $expected
   }
   input: null
   expected: true}

  {name: "rope-md-body-fields-body-still-named"
   iut: {|_|
     let out = ({label: {heading: "root"}, fields: {body: "hello", kind: "branch"}, children: []} | rope md | render walk {format: "text"} | str trim)
     let expected = "# root\n- body=hello\n- kind=branch"
     assert-eq $out $expected
   }
   input: null
   expected: true}

  {name: "rope-md-body-json-preserved"
   iut: {|_|
     let out = ({label: {heading: "root"}, body: "hello", children: []} | rope md | render walk {format: "json"} | str trim)
     let parsed = ($out | from json)
     (($parsed | first | get body?) == "hello")
   }
   input: null
   expected: true}

  # ── new-4: rope md text conformance exact ────────────────────────────────
  # Fixture: src (dir) → { a.nu (file, 1KB), b.nu (file, 2KB) }
  # Expected: heading on its own line; caller fields as "- key=value" bullets.
  # No id or parent_id — not minted by rope md.
  {name: "rope-md-new4-text-conformance-exact"
   iut: {|_|
     let script = "use nu-lib/lib/rope.nu *; use nu-lib/lib/render.nu; {label: {name: 'src'}, fields: {type: 'dir'}, children: [{label: {name: 'a.nu'}, fields: {type: 'file', size: '1KB'}, children: []}, {label: {name: 'b.nu'}, fields: {type: 'file', size: '2KB'}, children: []}]} | rope md | render walk {format: 'text'}"
     let out = (with-env {FORCE_TTY: "0"} { ^nu -c $script } | complete).stdout | str trim
     let expected = "# src\n- type=dir\n\n## a.nu\n- type=file\n- size=1KB\n\n## b.nu\n- type=file\n- size=2KB"
     assert-eq $out $expected
   }
   input: null
   expected: true}

  # ── new-5: rope md json conformance exact ────────────────────────────────
  # Fixture: src (dir) → { a.nu (file, 1KB), b.nu (file, 2KB) }
  # Expected: nested tree, caller fields only, no id/parent_id (not minted).
  {name: "rope-md-new5-json-conformance-exact"
   iut: {|_|
     let script = "use nu-lib/lib/rope.nu *; use nu-lib/lib/render.nu; {label: {name: 'src'}, fields: {type: 'dir'}, children: [{label: {name: 'a.nu'}, fields: {type: 'file', size: '1KB'}, children: []}, {label: {name: 'b.nu'}, fields: {type: 'file', size: '2KB'}, children: []}]} | rope md | render walk {format: 'json'}"
     let out = (with-env {FORCE_TTY: "0"} { ^nu -c $script } | complete).stdout | str trim
     # Parse and compare structurally — field order may vary but values must match
     let parsed = ($out | from json)
     let src = ($parsed | first)
     let children = ($src | get children? | default [])
     let a = ($children | get 0)
     let b = ($children | get 1)
     (($src | get name?) == "src"
       and ($src | get type?) == "dir"
       and not ("id" in ($src | columns))
       and not ("parent_id" in ($src | columns))
       and not ("depth" in ($src | columns))
       and ($a | get name?) == "a.nu"
       and ($a | get type?) == "file"
       and ($a | get size?) == "1KB"
       and not ("id" in ($a | columns))
       and not ("parent_id" in ($a | columns))
       and not ("depth" in ($a | columns))
       and ($b | get name?) == "b.nu"
       and ($b | get type?) == "file"
       and ($b | get size?) == "2KB"
       and not ("id" in ($b | columns))
       and not ("parent_id" in ($b | columns))
       and not ("depth" in ($b | columns)))
   }
   input: null
   expected: true}

  # ── new-6: rope md utf8 structural test ──────────────────────────────────
  # Uses utf8 (same visual structure as rich, no ANSI) for line-level assertions.
  # heading prefix #/## per depth; fields as "- key: value" bullets.
  # No id or parent_id (not minted by rope md).
  {name: "rope-md-new6-rich-structural"
   iut: {|_|
     let script = "use nu-lib/lib/rope.nu *; use nu-lib/lib/render.nu; {label: {name: 'src'}, fields: {type: 'dir'}, children: [{label: {name: 'a.nu'}, fields: {type: 'file', size: '1KB'}, children: []}, {label: {name: 'b.nu'}, fields: {type: 'file', size: '2KB'}, children: []}]} | rope md | render walk {format: 'utf8'}"
     let out = (with-env {FORCE_TTY: "0"} { ^nu -c $script } | complete).stdout | str trim
     let lines = ($out | lines)
     # heading lines (blank lines separate entries)
     let src_line = ($lines | get 0)
     let a_matches = ($lines | where {|l| $l == "## a.nu"})
     let b_matches = ($lines | where {|l| $l == "## b.nu"})
     # src: "# src"; a.nu: "## a.nu"; b.nu: "## b.nu"
     let src_ok = ($src_line == "# src")
     let a_ok   = ($a_matches | is-not-empty)
     let b_ok   = ($b_matches | is-not-empty)
     # bullet fields present; id/parent_id absent (not minted)
     let has_type_dir    = ($out | str contains "- type: dir")
     let has_type_file   = ($out | str contains "- type: file")
     let no_id_bullet    = not ($out | str contains "- id:")
     let no_parent_id    = not ($out | str contains "- parent_id:")
     let no_depth_bullet = not ($out | str contains "- depth:")
     $src_ok and $a_ok and $b_ok and $has_type_dir and $has_type_file and $no_id_bullet and $no_parent_id and $no_depth_bullet
   }
   input: null
   expected: true}

  # ── 15: rope table OT structure ───────────────────────────────────────────
  # _flat must NOT contain _headers (header row is intrinsic in render walk T2).
  {name: "rope-table-15-ot-structure"
   iut: {|_|
     let result = ([{name: "a" v: 1}] | rope table)
     let no_headers_ok = ($result | get _flat | get _headers?) == null
     let fields_len_ok = ($result | get _fields | length) == 2
     let children_len_ok = ($result | get _children | length) == 0
     $no_headers_ok and $fields_len_ok and $children_len_ok
   }
   input: null
   expected: true}

  # ── 16: rope table default policy ─────────────────────────────────────────
  {name: "rope-table-16-default-policy"
   iut: {|_|
     let result = ([{name: "a"}] | rope table)
     let policy = ($result | get _flat | get name)
     ($policy | get justify) == "left" and ($policy | get weight) == 0 and ($policy | get clip) == "rhs"
   }
   input: null
   expected: true}

  # ── 17: rope table columns override ───────────────────────────────────────
  {name: "rope-table-17-columns-override"
   iut: {|_|
     let result = ([{name: "a"}] | rope table --columns {name: {justify: "right", weight: 2, clip: "rhs"}})
     let policy = ($result | get _flat | get name)
     ($policy | get justify) == "right" and ($policy | get weight) == 2
   }
   input: null
   expected: true}

  # ── 18: render walk utf8 ───────────────────────────────────────────────────
  # Uses utf8 (same visual structure as rich, no ANSI codes) for exact-eq assertion.
  {name: "rope-table-18-render-walk-rich"
   iut: {|_|
     let script = "use nu-lib/lib/rope.nu *; use nu-lib/lib/render.nu; [{name: \"alpha\" status: \"ok\"} {name: \"beta\" status: \"warn\"}] | rope table | render walk {format: \"utf8\"}"
     let out = (with-env {FORCE_TTY: "0"} { ^nu -c $script } | complete).stdout | str trim
     let expected = "╭───────┬────────╮\n│ name  │ status │\n├───────┼────────┤\n│ alpha │ ok     │\n│ beta  │ warn   │\n╰───────┴────────╯"
     assert-eq $out $expected
   }
   input: null
   expected: true}

  # ── 19: render walk text ───────────────────────────────────────────────────
  {name: "rope-table-19-render-walk-text"
   iut: {|_|
     let script = "use nu-lib/lib/rope.nu *; use nu-lib/lib/render.nu; [{name: \"alpha\" status: \"ok\"} {name: \"beta\" status: \"warn\"}] | rope table | render walk {format: \"text\"}"
     let out = (with-env {FORCE_TTY: "0"} { ^nu -c $script } | complete).stdout | str trim
     let expected = "name   status\n\nalpha  ok\nbeta   warn"
     assert-eq $out $expected
   }
   input: null
   expected: true}

  # ── 20: render walk json ───────────────────────────────────────────────────
  {name: "rope-table-20-render-walk-json"
   iut: {|_|
     let script = "use nu-lib/lib/rope.nu *; use nu-lib/lib/render.nu; [{name: \"alpha\" status: \"ok\"} {name: \"beta\" status: \"warn\"}] | rope table | render walk {format: \"json\"}"
     let out = (with-env {FORCE_TTY: "0"} { ^nu -c $script } | complete).stdout | str trim
     let expected = "[\n  {\n    \"name\": \"alpha\",\n    \"status\": \"ok\"\n  },\n  {\n    \"name\": \"beta\",\n    \"status\": \"warn\"\n  }\n]"
     assert-eq $out $expected
   }
   input: null
   expected: true}

  # ── rope tree tests ────────────────────────────────────────────────────────

  # ── 21: root has no connector rstr (no q:"visual" leaf on root) ──────────
  {name: "rope-tree-21-root-connector-absent"
   iut: {|_|
     let node = {label: {heading: "root"} children: [
       {label: {heading: "only-child"} children: []}
     ]}
     let rope = ($node | rope tree)
     # Single top-level node → rope IS the root node directly (has _fields)
     let root_fields = ($rope | get _fields)
     # Root must have no connector — no q:"visual" leaf in root _fields
     # (connectors are q:"visual" leaves carrying a connector-tagged rstr)
     let visual_leaves = ($root_fields | where {|f|
       ($f | get q? | default "") == "visual" and not ($f | columns | any {|c| $c == "k"})
     })
     ($visual_leaves | is-empty)
   }
   input: null
   expected: true}

  # ── 22: sole child carries └──▶; multi-sibling first ├──▶ last └──▶ ──────
  {name: "rope-tree-22-connector-glyphs-by-sibling-position"
   iut: {|_|
     let node = {label: {heading: "root"} children: [
       {label: {heading: "child-a"} children: []}
       {label: {heading: "child-b"} children: []}
     ]}
     let sole_node = {label: {heading: "root-sole"} children: [
       {label: {heading: "only-child"} children: []}
     ]}
     # Multi-sibling: first child ├──▶, last child └──▶
     # Single top-level node → rope IS the root node directly (has _fields)
     let rope = ($node | rope tree)
     let child_a_ot = ($rope | get _children | first)
     let child_b_ot = ($rope | get _children | last)
     let ca_connector = ($child_a_ot | get _fields | where {|f| ($f | get q? | default "") == "visual"} | first | get v | first | get c | first | get t)
     let cb_connector = ($child_b_ot | get _fields | where {|f| ($f | get q? | default "") == "visual"} | first | get v | first | get c | first | get t)
     # Sole child: only child must carry └──▶
     let sole_rope = ($sole_node | rope tree)
     let sole_child_ot = ($sole_rope | get _children | first)
     let sole_connector = ($sole_child_ot | get _fields | where {|f| ($f | get q? | default "") == "visual"} | first | get v | first | get c | first | get t)
     ($ca_connector == "├──▶ ") and ($cb_connector == "└──▶ ") and ($sole_connector == "└──▶ ")
   }
   input: null
   expected: true}

  # ── 23: grandchild under non-last parent carries │ in connector prefix ───
  {name: "rope-tree-23-ancestor-continuation-bar"
   iut: {|_|
     let node = {label: {heading: "root"} children: [
       {label: {heading: "child-a"} children: [
         {label: {heading: "grandchild"} children: []}
       ]}
       {label: {heading: "child-b"} children: []}
     ]}
     # Single top-level node → rope IS the root node directly (has _fields)
     let rope = ($node | rope tree)
     let child_a_ot = ($rope | get _children | first)
     let gc_ot = ($child_a_ot | get _children | first)
     # Grandchild connector must start with │ (ancestor bar for non-last child-a)
     let gc_connector_text = ($gc_ot | get _fields | where {|f| ($f | get q? | default "") == "visual"} | first | get v | first | get c | first | get t)
     $gc_connector_text == "│   └──▶ "
   }
   input: null
   expected: true}

  # ── 24: output has no _flat at any level ──────────────────────────────────
  {name: "rope-tree-24-no-flat-anywhere"
   iut: {|_|
     let node = {label: {heading: "root"} fields: {name: "root-node"} children: [
       {label: {heading: "child-a"} fields: {name: "child-a-node"} children: [
         {label: {heading: "grandchild"} fields: {name: "gc-node"} children: []}
       ]}
       {label: {heading: "child-b"} fields: {name: "child-b-node"} children: []}
     ]}
     # Single top-level node → rope IS the root node directly (has _fields)
     let rope = ($node | rope tree)
     let root_has_flat = ("_flat" in ($rope | columns))
     let all_nodes = [$rope] ++ ($rope | get _children | each {|c| dfs-all $c} | flatten)
     let any_node_has_flat = ($all_nodes | any {|n| "_flat" in ($n | columns)})
     (not $root_has_flat) and (not $any_node_has_flat)
   }
   input: null
   expected: true}

  # ── 25: no id/parent_id in rope tree _fields; no depth field ─────────────
  {name: "rope-tree-25-no-id-parent-id-no-depth"
   iut: {|_|
     let node = {label: {heading: "root"} children: [
       {label: {heading: "child"} children: []}
     ]}
     # Single top-level node → rope IS the root node directly (has _fields)
     let rope = ($node | rope tree)
     let child_ot = ($rope | get _children | first)
     # rope tree does not mint id or parent_id — assert absence on all nodes
     let all_nodes = [$rope] ++ ($rope | get _children | each {|c| dfs-all $c} | flatten)
     let no_id = ($all_nodes | all {|n|
       not ($n | get _fields | any {|f| ($f | get k? | default "") == "id"})
     })
     let no_parent_id = ($all_nodes | all {|n|
       not ($n | get _fields | any {|f| ($f | get k? | default "") == "parent_id"})
     })
     let no_depth = ($all_nodes | all {|n|
       not ($n | get _fields | any {|f| ($f | get k? | default "") == "depth"})
     })
     $no_id and $no_parent_id and $no_depth
   }
   input: null
   expected: true}

  # ── 26: embedded rope placed verbatim in _children ────────────────────────
  {name: "rope-tree-26-embedded-rope-verbatim"
   iut: {|_|
     let embedded = {_fields: [{k: "info", v: "meta", q: "text"}], _children: []}
     let node = {
       label: {heading: "parent"}
       fields: {name: "p-node"}
       children: [$embedded]
     }
     # Single top-level node → rope IS the root (parent) node directly
     let rope = ($node | rope tree)
     let child = ($rope | get _children | first)
     $child == $embedded
   }
   input: null
   expected: true}

  # ── 27: render walk utf8 — verbatim locked output ─────────────────────────
  # Uses utf8 (same visual structure as rich, no ANSI codes) for exact-eq assertion.
  {name: "rope-tree-27-render-walk-rich"
   iut: {|_|
     let script = "use nu-lib/lib/rope.nu *; use nu-lib/lib/render.nu; {label: {dir: 'src'}, fields: {type: 'dir'}, children: [{label: {file: 'a.nu'}, fields: {type: 'file', size: '1KB'}}, {label: {file: 'b.nu'}, fields: {type: 'file', size: '2KB'}}]} | rope tree | render walk {format: 'utf8'}"
     let out = (with-env {FORCE_TTY: "0"} { ^nu -c $script } | complete).stdout | str trim
     # utf8: connector + short-name + caller fields inline. No id or parent_id (not minted).
     let expected = "src dir\n├──▶ a.nu file 1KB\n└──▶ b.nu file 2KB"
     assert-eq $out $expected
   }
   input: null
   expected: true}

  # ── 28: render walk text — verbatim locked output ─────────────────────────
  {name: "rope-tree-28-render-walk-text"
   iut: {|_|
     let script = "use nu-lib/lib/rope.nu *; use nu-lib/lib/render.nu; {label: {dir: 'src'}, fields: {type: 'dir'}, children: [{label: {file: 'a.nu'}, fields: {type: 'file', size: '1KB'}}, {label: {file: 'b.nu'}, fields: {type: 'file', size: '2KB'}}]} | rope tree | render walk {format: 'text'}"
     let out = (with-env {FORCE_TTY: "0"} { ^nu -c $script } | complete).stdout | str trim
     # text: connector hidden; base+stem fuse (src/a.nu); caller fields key=value.
     # No id or parent_id (not minted by rope tree). One flat line per node.
     let expected = "src type=dir\nsrc/a.nu type=file size=1KB\nsrc/b.nu type=file size=2KB"
     assert-eq $out $expected
   }
   input: null
   expected: true}

  # ── 29: render walk json — keyed name/type/size only, no id/parent_id/depth
  {name: "rope-tree-29-render-walk-json"
   iut: {|_|
     let script = "use nu-lib/lib/rope.nu *; use nu-lib/lib/render.nu; {label: {dir: 'src'}, fields: {type: 'dir'}, children: [{label: {file: 'a.nu'}, fields: {type: 'file', size: '1KB'}}, {label: {file: 'b.nu'}, fields: {type: 'file', size: '2KB'}}]} | rope tree | render walk {format: 'json'}"
     let out = (with-env {FORCE_TTY: "0"} { ^nu -c $script } | complete).stdout | str trim
     let parsed = ($out | from json)
     # The stem renders as keyed "name"; caller fields "type"/"size" keyed.
     # No id, parent_id, or depth (not minted by rope tree).
     let src_node = ($parsed.0)
     let a_node = ($src_node.children.0)
     let b_node = ($src_node.children.1)
     let no_id     = (not ($out | str contains "\"id\""))
     let no_pid    = (not ($out | str contains "\"parent_id\""))
     let no_depth  = (not ($out | str contains "\"depth\""))
     (
       ($src_node.name == "src") and ($src_node.type == "dir") and
       not ("id" in ($src_node | columns)) and not ("parent_id" in ($src_node | columns)) and
       ($a_node.name == "a.nu") and ($a_node.type == "file") and ($a_node.size == "1KB") and
       not ("id" in ($a_node | columns)) and not ("parent_id" in ($a_node | columns)) and
       ($b_node.name == "b.nu") and
       not ("id" in ($b_node | columns)) and not ("parent_id" in ($b_node | columns)) and
       $no_depth
     )
   }
   input: null
   expected: true}

  # ── Conformance exact-eq tests: src → {a.nu, b.nu} ───────────────────────
  # Fixture matches render-spec.md §Conformance — rope tree.

  # ── 30: rope tree utf8 conformance — exact locked output ──────────────────
  # Uses utf8 (same visual structure as rich, no ANSI codes) for exact-eq assertion.
  {name: "rope-tree-30-rich-conformance-exact"
   iut: {|_|
     let script = "use nu-lib/lib/rope.nu *; use nu-lib/lib/render.nu; {label: {dir: 'src'}, fields: {type: 'dir'}, children: [{label: {file: 'a.nu'}, fields: {type: 'file', size: '1KB'}}, {label: {file: 'b.nu'}, fields: {type: 'file', size: '2KB'}}]} | rope tree | render walk {format: 'utf8'}"
     let out = (with-env {FORCE_TTY: "0"} { ^nu -c $script } | complete).stdout | str trim
     # render-spec.md §Conformance — rope tree — utf8 (same structure as rich, no ANSI):
     #   src dir
     #   ├──▶a.nu file 1KB
     #   └──▶b.nu file 2KB
     # No id or parent_id (not minted by rope tree per spec).
     let expected = "src dir\n├──▶ a.nu file 1KB\n└──▶ b.nu file 2KB"
     assert-eq $out $expected
   }
   input: null
   expected: true}

  # ── 31: rope tree text conformance — exact locked output ──────────────────
  {name: "rope-tree-31-text-conformance-exact"
   iut: {|_|
     let script = "use nu-lib/lib/rope.nu *; use nu-lib/lib/render.nu; {label: {dir: 'src'}, fields: {type: 'dir'}, children: [{label: {file: 'a.nu'}, fields: {type: 'file', size: '1KB'}}, {label: {file: 'b.nu'}, fields: {type: 'file', size: '2KB'}}]} | rope tree | render walk {format: 'text'}"
     let out = (with-env {FORCE_TTY: "0"} { ^nu -c $script } | complete).stdout | str trim
     # render-spec.md §Conformance — rope tree — text:
     #   src type=dir
     #   src/a.nu type=file size=1KB
     #   src/b.nu type=file size=2KB
     # No id or parent_id (not minted by rope tree per spec).
     let expected = "src type=dir\nsrc/a.nu type=file size=1KB\nsrc/b.nu type=file size=2KB"
     assert-eq $out $expected
   }
   input: null
   expected: true}

  # ── 32: rope tree json conformance — exact locked output ──────────────────
  {name: "rope-tree-32-json-conformance-exact"
   iut: {|_|
     let script = "use nu-lib/lib/rope.nu *; use nu-lib/lib/render.nu; {label: {dir: 'src'}, fields: {type: 'dir'}, children: [{label: {file: 'a.nu'}, fields: {type: 'file', size: '1KB'}}, {label: {file: 'b.nu'}, fields: {type: 'file', size: '2KB'}}]} | rope tree | render walk {format: 'json'}"
     let out = (with-env {FORCE_TTY: "0"} { ^nu -c $script } | complete).stdout | str trim
     # render-spec.md §Conformance — rope tree — json (tree form, no outer wrapper):
     #   [
     #     {"name": "src", "type": "dir", "children": [
     #       {"name": "a.nu", "type": "file", "size": "1KB"},
     #       {"name": "b.nu", "type": "file", "size": "2KB"}
     #     ]}
     #   ]
     # No id or parent_id (not minted by rope tree per spec).
     let expected = "[\n  {\n    \"name\": \"src\",\n    \"type\": \"dir\",\n    \"children\": [\n      {\n        \"name\": \"a.nu\",\n        \"type\": \"file\",\n        \"size\": \"1KB\"\n      },\n      {\n        \"name\": \"b.nu\",\n        \"type\": \"file\",\n        \"size\": \"2KB\"\n      }\n    ]\n  }\n]"
     assert-eq $out $expected
   }
   input: null
   expected: true}

  # ── 33: rope table text conformance — exact locked output ─────────────────
  # Fixture: [{id:1,name:"src",type:"dir",size:"-"},{id:2,...,parent_id:1},{id:3,...,parent_id:1}]
  # parent_id absent from first row → omitted from root _fields; present in child rows.
  # Text: header row with blank line separator; src row has no trailing whitespace.
  {name: "rope-table-33-text-conformance-exact"
   iut: {|_|
     let script = "use nu-lib/lib/rope.nu *; use nu-lib/lib/render.nu; [{id:1,name:'src',type:'dir',size:'-'},{id:2,name:'src/a.nu',type:'file',size:'1KB',parent_id:1},{id:3,name:'src/b.nu',type:'file',size:'2KB',parent_id:1}] | rope table | render walk {format: 'text'}"
     let out = (with-env {FORCE_TTY: "0"} { ^nu -c $script } | complete).stdout | str trim
     # render-spec.md §Conformance — rope table — text:
     #   id  name      type  size  parent_id
     #
     #   1   src       dir   -
     #   2   src/a.nu  file  1KB   1
     #   3   src/b.nu  file  2KB   1
     let expected = "id  name      type  size  parent_id\n\n1   src       dir   -\n2   src/a.nu  file  1KB   1\n3   src/b.nu  file  2KB   1"
     assert-eq $out $expected
   }
   input: null
   expected: true}

  # ── 34: rope table json conformance — exact locked output ─────────────────
  # Flat form: one array, one object per row. Root row omits parent_id key.
  # Native int ids (not strings).
  {name: "rope-table-34-json-conformance-exact"
   iut: {|_|
     let script = "use nu-lib/lib/rope.nu *; use nu-lib/lib/render.nu; [{id:1,name:'src',type:'dir',size:'-'},{id:2,name:'src/a.nu',type:'file',size:'1KB',parent_id:1},{id:3,name:'src/b.nu',type:'file',size:'2KB',parent_id:1}] | rope table | render walk {format: 'json'}"
     let out = (with-env {FORCE_TTY: "0"} { ^nu -c $script } | complete).stdout | str trim
     # render-spec.md §Conformance — rope table — json:
     #   [{"id":1,"name":"src","type":"dir","size":"-"},
     #    {"id":2,"name":"src/a.nu","type":"file","size":"1KB","parent_id":1},
     #    {"id":3,"name":"src/b.nu","type":"file","size":"2KB","parent_id":1}]
     let expected = "[\n  {\n    \"id\": 1,\n    \"name\": \"src\",\n    \"type\": \"dir\",\n    \"size\": \"-\"\n  },\n  {\n    \"id\": 2,\n    \"name\": \"src/a.nu\",\n    \"type\": \"file\",\n    \"size\": \"1KB\",\n    \"parent_id\": 1\n  },\n  {\n    \"id\": 3,\n    \"name\": \"src/b.nu\",\n    \"type\": \"file\",\n    \"size\": \"2KB\",\n    \"parent_id\": 1\n  }\n]"
     assert-eq $out $expected
   }
   input: null
   expected: true}

  # ── 35: rope table rich structural ───────────────────────────────────────
  # Box-bordered table: top border (╭), header row with column names, data rows with values.
  {name: "rope-table-35-rich-structural"
   iut: {|_|
     let script = "use nu-lib/lib/rope.nu *; use nu-lib/lib/render.nu; [{id:1,name:'src',type:'dir',size:'-'},{id:2,name:'src/a.nu',type:'file',size:'1KB',parent_id:1},{id:3,name:'src/b.nu',type:'file',size:'2KB',parent_id:1}] | rope table | render walk {format: 'rich'}"
     let out = (with-env {FORCE_TTY: "0"} { ^nu -c $script } | complete).stdout | str trim
     # Top border present (box-draw character)
     let has_top_border   = ($out | str contains "╭")
     # Header row contains all column names
     let has_col_id       = ($out | str contains "id")
     let has_col_name     = ($out | str contains "name")
     let has_col_type     = ($out | str contains "type")
     let has_col_size     = ($out | str contains "size")
     let has_col_parentid = ($out | str contains "parent_id")
     # Data rows contain representative values
     let has_val_src      = ($out | str contains "src")
     let has_val_dir      = ($out | str contains "dir")
     let has_val_file     = ($out | str contains "file")
     $has_top_border and $has_col_id and $has_col_name and $has_col_type and $has_col_size and $has_col_parentid and $has_val_src and $has_val_dir and $has_val_file
   }
   input: null
   expected: true}

  # ── multi-root coverage ────────────────────────────────────────────────────

  # ── rope-tree-multi-root: two-root list → record with empty _fields and two _children ──
  {name: "rope-tree-multi-root"
   iut: {|_|
     let nodes = [
       {label: {h: "alpha"} children: []}
       {label: {h: "beta"}  children: []}
     ]
     let rope = ($nodes | rope tree)
     let desc = ($rope | describe)
     (($desc | str starts-with "record") and
      (($rope | get _fields | length) == 0) and
      (($rope | get _children | length) == 2))
   }
   input: null
   expected: true}

  # ── rope-md-multi-root: two-root list → record with empty _fields and two _children ──
  {name: "rope-md-multi-root"
   iut: {|_|
     let nodes = [
       {label: {h: "alpha"} children: []}
       {label: {h: "beta"}  children: []}
     ]
     let rope = ($nodes | rope md)
     let desc = ($rope | describe)
     (($desc | str starts-with "record") and
      (($rope | get _fields | length) == 0) and
      (($rope | get _children | length) == 2))
   }
   input: null
   expected: true}

  # ── rope-mdtable-multi-root: two-root list → record with empty _fields and two _children ──
  {name: "rope-mdtable-multi-root"
   iut: {|_|
     let nodes = [
       {label: {h: "alpha"} children: []}
       {label: {h: "beta"}  children: []}
     ]
     let rope = ($nodes | rope md-table)
     let desc = ($rope | describe)
     (($desc | str starts-with "record") and
      (($rope | get _fields | length) == 0) and
      (($rope | get _children | length) == 2))
   }
   input: null
   expected: true}

  # ── new-q-text-1: rope table --columns {col: {q:"text"}} accepted; kv carries q:"text" ──
  {name: "rope-table-q-text-accepted"
   iut: {|_|
     let result = ([{name: "alpha", status: "ok"} {name: "beta", status: "warn"}] | rope table --columns {name: {q: "text"}})
     # _flat must exist (flat mode)
     let has_flat = ("_flat" in ($result | columns))
     # First row _fields: name kv carries q:"text", status kv carries no q
     let name_field   = ($result | get _fields | where {|f| ($f | get k? | default "") == "name"} | first)
     let status_field = ($result | get _fields | where {|f| ($f | get k? | default "") == "status"} | first)
     let name_q_ok   = ($name_field | get q? | default "") == "text"
     let status_q_ok = not ($status_field | columns | any {|c| $c == "q"})
     # Rendering: rich hides name (q:"text"); status visible
     let script = "use nu-lib/lib/rope.nu *; use nu-lib/lib/render.nu; [{name: 'alpha', status: 'ok'} {name: 'beta', status: 'warn'}] | rope table --columns {name: {q: 'text'}} | render walk {format: 'rich'}"
     let rich_out = (with-env {FORCE_TTY: "0"} { ^nu -c $script } | complete).stdout | str trim
     let rich_shows_status = ($rich_out | str contains "status")
     let rich_hides_name   = not ($rich_out | str contains "name")
     $has_flat and $name_q_ok and $status_q_ok and $rich_shows_status and $rich_hides_name
   }
   input: null
   expected: true}

  # ── new-q-data-rejected: rope table --columns {col: {q:"data"}} errors ───
  {name: "rope-table-q-data-rejected"
   iut: {|_|
     try {
       [{name: "alpha"}] | rope table --columns {name: {q: "data"}}
       false
     } catch {|e|
       # The rendered error chain must name "data" as rejected
       ($e.rendered | str contains "data")
     }
   }
   input: null
   expected: true}

  # ── new-q-md-table-passthrough: rope md-table --columns propagates q:"text" ─
  {name: "rope-md-table-q-text-passthrough"
   iut: {|_|
     # src has leaf children a.nu and b.nu; they are grouped into an embedded rope table
     let result = ({
       label: {name: "src"}
       fields: {type: "dir"}
       children: [
         {label: {name: "a.nu"} fields: {type: "file", size: "1KB"} children: []}
         {label: {name: "b.nu"} fields: {type: "file", size: "2KB"} children: []}
       ]
     } | rope md-table --columns {name: {q: "text"}})
     # The embedded table is in _children of the root heading node
     let table_rope = ($result | get _children | first)
     # table_rope is a flat-mode rope; its _fields (first row) should carry name with q:"text"
     let name_field = ($table_rope | get _fields | where {|f| ($f | get k? | default "") == "name"} | first)
     ($name_field | get q? | default "") == "text"
   }
   input: null
   expected: true}

  # ── new-single-node-direct-root: rope tree single node returns root directly ─
  # Verifies the rope-tree-single-node-is-root learning: _fields at root, no wrapper.
  # Root _fields must contain no {k:"id"} or {k:"parent_id"} leaves.
  {name: "rope-tree-single-node-direct-root"
   iut: {|_|
     let node = {label: {name: "only"} fields: {type: "file"} children: []}
     let rope = ($node | rope tree)
     # Must be a record (not a list) with _fields directly at root
     let is_record  = (($rope | describe) | str starts-with "record")
     let has_fields = ("_fields" in ($rope | columns))
     # _fields must not contain id or parent_id
     let no_id       = not ($rope | get _fields | any {|f| ($f | get k? | default "") == "id"})
     let no_parent_id = not ($rope | get _fields | any {|f| ($f | get k? | default "") == "parent_id"})
     # Must carry the name stem kv
     let has_name = ($rope | get _fields | any {|f| ($f | get k? | default "") == "name"})
     $is_record and $has_fields and $no_id and $no_parent_id and $has_name
   }
   input: null
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
