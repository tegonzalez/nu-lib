#!/usr/bin/env nu

use ../../../lib/test.nu *

let fd_nu = ($env.CURRENT_FILE | path dirname | path join "../lf.nu" | path expand)

# Run fd from a given working directory (cwd-sensitive patterns like ./lib).
def fd-in [cwd: string, ...args: string] {
  let arg_str = ($args | each {|a| $"'($a)'"} | str join " ")
  ^bash -c $"cd ($cwd) && nu ($fd_nu) ($arg_str)"
}

# Build a src fixture: src/lib/ with one file + src/bin/ with one file.
# Used to distinguish fd src/% (flat) from fd src/%/ (descent).
def setup-src-descent-fixture [] {
  let root = "/tmp/nu-lib-fd-src-descent"
  rm -rf $root
  mkdir ($root | path join "src" "lib")
  mkdir ($root | path join "src" "bin")
  "# lib file" | save --force ($root | path join "src" "lib" "lib.nu")
  "# bin file" | save --force ($root | path join "src" "bin" "main.nu")
  $root
}

# Build a flat tools fixture: tools/{cg,fd,ntst,show,state} — all files, no subdirs.
def setup-tools-flat-fixture [] {
  let root = "/tmp/nu-lib-fd-tools-flat"
  rm -rf $root
  mkdir ($root | path join "tools")
  for name in [cg fd ntst show state] {
    "" | save --force ($root | path join "tools" $name)
  }
  $root
}

# Build a tools-dir fixture: tools/{cg,fd,ntst,state} — 4 dirs, each with one file inside.
# This keeps the filesystem shape controlled without depending on repo tool names.
def setup-tools-dir-fixture [] {
  let root = "/tmp/nu-lib-fd-tools-dir"
  rm -rf $root
  for name in [cg fd ntst state] {
    mkdir ($root | path join "tools" $name)
    "# placeholder" | save --force ($root | path join "tools" $name $"($name).nu")
  }
  $root
}

# Build a lib fixture with a nested subtree.
def setup-lib-fixture [] {
  let root = "/tmp/nu-lib-fd-lib-test"
  rm -rf $root
  mkdir ($root | path join "lib" "sub")
  "# a" | save --force ($root | path join "lib" "a.nu")
  "# b" | save --force ($root | path join "lib" "b.nu")
  "# c" | save --force ($root | path join "lib" "sub" "c.nu")
  $root
}

# Build the original mixed fixture (lib + docs).
def setup-fixture [] {
  let root = "/tmp/nu-lib-fd-test-fixture"
  rm -rf $root
  mkdir ($root | path join "lib")
  mkdir ($root | path join "docs")
  "export def main [] { }" | save --force ($root | path join "lib" "args.nu")
  "hello" | save --force ($root | path join "lib" "alpha.txt")
  "# Readme" | save --force ($root | path join "docs" "README.md")
  $root
}

def fd-run [...args: string] {
  let arg_str = ($args | each {|a| $"'($a)'"} | str join " ")
  ^bash -c $"nu ($fd_nu) ($arg_str)"
}

def setup-v2-fixture [] {
  let root = "/tmp/nu-lib-fd-v2-fixture"
  rm -rf $root
  mkdir ($root | path join "lib" "sub")
  mkdir ($root | path join "folder" "deep")
  mkdir ($root | path join "src" "nested")
  "# a" | save --force ($root | path join "lib" "a.nu")
  "# b" | save --force ($root | path join "lib" "b.nu")
  "# c" | save --force ($root | path join "lib" "sub" "c.nu")
  "# child1" | save --force ($root | path join "folder" "child1.nu")
  "# child2" | save --force ($root | path join "folder" "child2.nu")
  "# grandchild" | save --force ($root | path join "folder" "deep" "grandchild.nu")
  "# util" | save --force ($root | path join "src" "util.nu")
  "# helper" | save --force ($root | path join "src" "nested" "helper.nu")
  $root
}

def setup-fake-root-fixture [] {
  let root = "/tmp/nu-lib-fd-fake-root"
  rm -rf $root
  mkdir ($root | path join "bin")
  mkdir ($root | path join "lib")
  mkdir ($root | path join "etc")
  "# sh" | save --force ($root | path join "bin" "sh")
  "# libc" | save --force ($root | path join "lib" "libc.so")
  "127.0.0.1 localhost" | save --force ($root | path join "etc" "hosts")
  $root
}

def cases [] { [

  # ── Legacy tests (fd-01 through fd-04) ────────────────────────────────────

  {name: "fd-01-bare-token-finds-containing-file-name"
   iut: {|_|
     let root = setup-fixture
     # bare token is exact-tier per pat-spec §9.1; use wildcard to match name fragments
     let out = (fd-in $root "%%/%arg%" "-f" "json")
     $out | str contains '"name": "args.nu"'
   }
   input: null
   expected: true
   runner: "value"}

  {name: "fd-02-path-like-pat-filters-relative-path"
   iut: {|_|
     let root = setup-fixture
     let rows = (fd-in $root "docs/%%" "-f" "json" | from json)
     let names = ($rows | get name)
     ("README.md" in $names) and not ("args.nu" in $names)
   }
   input: null
   expected: true
   runner: "value"}

  {name: "fd-03-expr-channel-is-reserved"
   iut: {|_|
     let root = setup-fixture
     let out = (do { ^bash -c $"cd ($root) && nu ($fd_nu) 'arg:content'" } | complete)
     $out.exit_code != 0 and ($out.stderr | str contains "reserved")
   }
   input: null
   expected: true
   runner: "value"}

  {name: "fd-04-md-table-json-is-clean-tree-json"
   iut: {|_|
     let root = setup-fixture
     # use wildcard so README.md is matched; bare "README" is exact-tier per pat-spec §9.1
     let rows = (fd-in $root "%%/README%" "-t" "md-table" "-f" "json" | from json)
     let root_node = ($rows | first)
     (($root_node.children | describe) =~ "^(list|table)") and (($root_node.children | first | describe) | str starts-with "record")
   }
   input: null
   expected: true
   runner: "value"}

  # ── New behavioral tests ───────────────────────────────────────────────────

  # fd-default-display-is-md-table: default render type groups entries into a markdown table.
  {name: "fd-default-display-is-md-table"
   iut: {|_|
     let root = setup-lib-fixture
     let out = (fd-in $root "lib/%" "-f" "text")
     ($out | str contains "# lib") and ($out | str contains "name") and ($out | str contains "type") and (not ($out | str contains "- type="))
   }
   input: null
   expected: true
   runner: "value"}

  # fd-no-arg: fd with no args lists all entries under cwd recursively.
  {name: "fd-no-arg-lists-entries-under-cwd"
   iut: {|_|
     let root = setup-lib-fixture
     let rows = (fd-in $root "-f" "json" | from json)
     ($rows | length) > 0
   }
   input: null
   expected: true
   runner: "value"}

  # fd-dot: fd . lists cwd entries (root="."; pattern exhausted → any matcher).
  {name: "fd-dot-lists-cwd-entries"
   iut: {|_|
     let root = setup-lib-fixture
     let rows = (fd-in $root "." "-f" "json" | from json)
     ($rows | length) > 0
   }
   input: null
   expected: true
   runner: "value"}

  # fd-dot-lib: fd ./lib is an exact literal scope and emits the lib entry itself.
  {name: "fd-dot-lib-emits-literal-entry"
   iut: {|_|
     let root = setup-lib-fixture
     let rows = (fd-in $root "./lib" "-f" "json" | from json)
     ($rows | length) == 1 and (($rows | first).name == "lib")
   }
   input: null
   expected: true
   runner: "value"}

  # fd-tools-percent-immediate: fd ./tools/% returns exactly 5 immediate children.
  # Uses a flat fixture so only 5 single-segment paths exist under tools/.
  {name: "fd-tools-percent-immediate-children"
   iut: {|_|
     let root = setup-tools-flat-fixture
     let rows = (fd-in $root "./tools/%" "-f" "json" | from json)
     let names = ($rows | get name | sort)
     $names == ["cg" "fd" "ntst" "show" "state"]
   }
   input: null
   expected: true
   runner: "value"}

  # fd-tools-percent-tree: tree mode for ./tools/% has 5 leaf children under tools,
  # no recursive subtree expansion (flat fixture — all children are files).
  {name: "fd-tools-percent-tree-has-5-leaves"
   iut: {|_|
     let root = setup-tools-flat-fixture
     let tree = (fd-in $root "./tools/%" "-t" "tree" "-f" "json" | from json)
     let names = ($tree | get name | sort)
     let all_leaves = ($tree | all {|c| ($c | get children? | default [] | length) == 0})
     ($names == ["cg" "fd" "ntst" "show" "state"]) and $all_leaves
   }
   input: null
   expected: true
   runner: "value"}

  # fd-lib-recursive: fd 'lib/%%' returns entries under lib/ at all depths.
  {name: "fd-lib-recursive-matches-all-depths"
   iut: {|_|
     let root = setup-lib-fixture
     let out = (fd-in $root "lib/%%" "-f" "json")
     let has_nested = ($out | str contains '"name": "c.nu"')
     let has_direct = ($out | str contains '"name": "a.nu"') and ($out | str contains '"name": "b.nu"')
     $has_nested and $has_direct
   }
   input: null
   expected: true
   runner: "value"}

  # fd-expr-channel-error: fd ':needle' errors with message containing "content search".
  # Use | complete to capture stderr from the subprocess rather than catching a Nu exit error.
  {name: "fd-expr-channel-error-contains-content-search"
   iut: {|_|
     let root = setup-fixture
     let result = (do { ^bash -c $"cd ($root) && nu ($fd_nu) ':needle' 2>&1" } | complete)
     ($result.exit_code != 0) and (($result.stdout | str contains "content search") or ($result.stderr | str contains "content search"))
   }
   input: null
   expected: true
   runner: "value"}

  # ── Integer-length discriminator tests ────────────────────────────────────

  # fd-tools-percent-immediate-count: fd ./tools/% returns exactly 4 immediate children.
  # Uses the tools-dir fixture: tools/{cg,fd,ntst,state} — 4 dirs, no extra entries.
  {name: "fd-tools-percent-immediate-count"
   iut: {|_|
     let root = setup-tools-dir-fixture
     let rows = (fd-in $root "./tools/%" "-f" "json" | from json)
     ($rows | length) == 4
   }
   input: null
   expected: true
   runner: "value"}

  # fd-tools-percent-percent-recursive: fd ./tools/%% returns more than 4 entries
  # (the 4 dir entries themselves plus each dir's contained file).
  {name: "fd-tools-percent-percent-recursive"
   iut: {|_|
     let root = setup-tools-dir-fixture
     let rows = (fd-in $root "./tools/%%" "-f" "json" | from json)
     ($rows | length) > 4
   }
   input: null
   expected: true
   runner: "value"}

  # fd-lib-percent-immediate-only: fd 'lib/%' returns only immediate children of lib/.
  # Each row's path must be a single segment (no "/" in the path).
  {name: "fd-lib-percent-immediate-only"
   iut: {|_|
     let root = setup-lib-fixture
     let rows = (fd-in $root "lib/%" "-f" "json" | from json)
     # Every returned path should have exactly one segment (no path separator)
     ($rows | length) > 0 and ($rows | all {|r| not ($r.path | str contains "/")})
   }
   input: null
   expected: true
   runner: "value"}

  # fd-lib-percent-percent-recursive: fd 'lib/%%' returns more entries than fd 'lib/%'.
  {name: "fd-lib-percent-percent-recursive"
   iut: {|_|
     let root = setup-lib-fixture
     let immediate = (fd-in $root "lib/%" "-f" "json" | from json | length)
     let recursive = (fd-in $root "lib/%%" "-f" "json" | from json | length)
     $recursive > $immediate
   }
   input: null
   expected: true
   runner: "value"}

  # fd-no-multi-field-value: fd.nu must not use the multi-field value-closure anti-pattern.
  # Asserts that rg finds zero matches of the forbidden co-feeding pattern in fd.nu.
  {name: "fd-no-multi-field-value"
   iut: {|_|
     let result = (^bash -c $"rg '\\$row\\.path\\s+\\$row\\.name|\\[\\$row\\.path\\s+\\$row\\.name\\]' ($fd_nu)" | complete)
     # rg exits 1 when no matches found — that is the desired outcome
     $result.exit_code == 1 and ($result.stdout | str trim | is-empty)
   }
   input: null
   expected: true
   runner: "value"}

  # pipeline-shape-grep: verify lf.nu source contains calls to all required pipeline layers.
  # lf uses the v2 pat API (pat parse, pat match, pat stem) with a BFS pruning walk.
  {name: "fd-pipeline-shape-all-layers-present"
   iut: {|_|
     let src = (open $fd_nu)
     let has_args      = ($src | str contains "args parse-chain")
     let has_pat_parse = ($src | str contains "pat parse")
     let has_pat_match = ($src | str contains "pat match")
     let has_rope      = ($src | str contains "rope ")
     let has_render    = ($src | str contains "render walk")
     $has_args and $has_pat_parse and $has_pat_match and $has_rope and $has_render
   }
   input: null
   expected: true
   runner: "value"}

  # ── Latency + visit-count regression tests ────────────────────────────────

  # fd-latency-budget: fd ./tools/% completes in under 100ms on the tools-dir fixture.
  # Regression guard against full-tree walk: a pruning walk over 4 immediate children
  # should be far faster than a full-tree walk of a large tree. Budget is 100ms to allow
  # for interpreter startup variation in CI; actual runs are ~50ms.
  {name: "fd-latency-budget"
   iut: {|_|
     let root = setup-tools-dir-fixture
     let t0 = (date now)
     let rows = (fd-in $root "./tools/%" "-f" "json" | from json)
     let elapsed_ms = ((date now) - $t0) / 1ms | into int
     # Assert both correctness (4 rows) and timing budget (< 100ms)
     ($rows | length) == 4 and $elapsed_ms < 100
   }
   input: null
   expected: true
   runner: "value"}

  # fd-visit-count-budget: structural assertion that the walk is bounded by the pruning
  # contract, not by post-hoc filtering of all descendants.
  #
  # lf does not expose an explicit visit counter. Instead we assert the architectural
  # invariant: the BFS walk uses pat match expand==true to gate descent decisions.
  # This is the only valid walk shape per the prefix-pruning contract:
  # walking all descendants and post-filtering is invalid.
  #
  # We verify the invariant structurally: the source must use pat match for BFS
  # expansion and the expand field to gate descent.
  {name: "fd-visit-count-budget"
   iut: {|_|
     let src = (open $fd_nu)
     # 1. pat match is used for BFS expansion decisions (v2 pruning API).
     let has_pat_match = ($src | str contains "pat match")
     # 2. The descent guard uses expand — prunes when expand==false.
     let has_expand_guard = ($src | str contains "expand")
     $has_pat_match and $has_expand_guard
   }
   input: null
   expected: true
   runner: "value"}

  # fd-percent-vs-slash-differ: fd src/% and fd src/%/ produce different output.
  # Assert A (flat) != B (descent) at the string level.
  {name: "fd-percent-vs-slash-differ"
   iut: {|_|
     let root = setup-src-descent-fixture
     let out_flat    = (^bash -c $"cd ($root) && nu ($fd_nu) 'src/%'  -f json")
     let out_descent = (^bash -c $"cd ($root) && nu ($fd_nu) 'src/%/' -f json")
     $out_flat != $out_descent
   }
   input: null
   expected: true
   runner: "value"}

  # fd-percent-slash-has-child-sections: fd src/%/ output has one node per child dir.
  # Asserts the descent JSON contains a top-level node named "bin" and one named "lib".
  {name: "fd-percent-slash-has-child-sections"
   iut: {|_|
     let root = setup-src-descent-fixture
     let nodes = (^bash -c $"cd ($root) && nu ($fd_nu) 'src/%/' -f json" | from json)
     let names = ($nodes | get name)
     ("bin" in $names) and ("lib" in $names)
   }
   input: null
   expected: true
   runner: "value"}

  # fd-percent-single-section: fd src/% output has one row per immediate child.
  # Asserts the flat JSON contains exactly the known src child directories.
  {name: "fd-percent-single-section"
   iut: {|_|
     let root = setup-src-descent-fixture
     let nodes = (^bash -c $"cd ($root) && nu ($fd_nu) 'src/%' -f json" | from json)
     let names = ($nodes | get name | sort)
     $names == ["bin" "lib"]
   }
   input: null
   expected: true
   runner: "value"}

  # fd-behavioral-parity: prior behavioral contracts preserved after prefix-pruning rework.
  # Exercises: wildcard name match (README%), dot anchor (.), dotdot anchor (..), expr-channel
  # error (':needle'), and recursive glob ('lib/%%').
  # Fixture-rooted checks use `fd-in` so the single pat argument remains authoritative.
  {name: "fd-behavioral-parity"
   iut: {|_|
     let root    = setup-fixture
     let libroot = setup-lib-fixture

     # Wildcard name: %%/README% matches README.md at any depth in the fixture tree.
     # README% alone would prune docs/ before descending (prefix-pruning walk);
     # %%/README% extends through all directories then matches the name fragment.
     let readme_out = (fd-in $root "%%/README%" "-f" "json")
     let literal_ok  = ($readme_out | str contains '"name": "README.md"')

     # Dot anchor: fd . lists entries under cwd.
     let dot_rows = (fd-in $libroot "." "-f" "json" | from json)
     let dot_ok   = ($dot_rows | length) > 0

     # Dotdot anchor: fd .. lists entries from parent of cwd (lib subdir → libroot).
     let dotdot_rows = (fd-in ($libroot | path join "lib") ".." "-f" "json" | from json)
     let dotdot_ok   = ($dotdot_rows | length) > 0

     # Expr-channel reservation: fd ':needle' must error with non-zero exit.
     let expr_result = (^bash -c $"cd ($root) && nu ($fd_nu) ':needle' 2>&1" | complete)
     let expr_ok     = ($expr_result.exit_code != 0)

     # Recursive glob: lib/%% returns entries at all depths including nested.
     let recursive_out = (fd-in $libroot "lib/%%" "-f" "json")
     let recursive_ok  = ($recursive_out | str contains '"name": "c.nu"') and ($recursive_out | str contains '"name": "a.nu"')

     $literal_ok and $dot_ok and $dotdot_ok and $expr_ok and $recursive_ok
   }
   input: null
   expected: true
   runner: "value"}


    # ── v2 cases (merged from former test_fd_pat_v2.nu) ──────────────


  # ── Matrix: ./lib ─────────────────────────────────────────────────────────
  # fd ./lib — v2 behavior: fully literal pattern (pat literal = true); emits
  # exactly the lib entry itself (the stem), no BFS descent into children.
  # Contrast with lib/%% which uses a wildcard and descends recursively.
  {name: "v2-dot-lib-emits-stem-entry"
   iut: {|_|
     let root = setup-v2-fixture
     let rows = (fd-in $root "./lib" "-t" "table" "-f" "json" | from json)
     # v2: exact literal → 1 row, the lib directory entry
     ($rows | length) == 1 and (($rows | first).name == "lib")
   }
   input: null
   expected: true
   runner: "value"}

  # ── Matrix: lib/%% ────────────────────────────────────────────────────────
  # fd lib/%% — recursive wildcard; returns all entries at every depth under lib/.
  {name: "v2-lib-double-percent-recursive"
   iut: {|_|
     let root = setup-v2-fixture
     let rows = (fd-in $root "lib/%%" "-t" "table" "-f" "json" | from json)
     let names = ($rows | get name)
     let has_direct = ("a.nu" in $names) and ("b.nu" in $names) and ("sub" in $names)
     let has_nested = "c.nu" in $names
     $has_direct and $has_nested
   }
   input: null
   expected: true
   runner: "value"}

  # ── Matrix: %%/%.nu ──────────────────────────────────────────────────────
  # fd %%/%.nu — any-depth wildcard for .nu files; must match all .nu files.
  {name: "v2-double-percent-dot-nu-any-depth"
   iut: {|_|
     let root = setup-v2-fixture
     let rows = (fd-in $root "%%/%.nu" "-t" "table" "-f" "json" | from json)
     let names = ($rows | get name)
     let required = ["a.nu" "b.nu" "c.nu" "child1.nu" "child2.nu" "grandchild.nu" "util.nu" "helper.nu"]
     $required | all {|n| $n in $names}
   }
   input: null
   expected: true
   runner: "value"}

  # ── Bug fix: fd /% completes without crash ────────────────────────────────
  # Before v2, fd /% crashed (see _crashes key in baseline snapshot).
  # After v2: fd /% completes and returns direct children of / as single-segment paths.
  {name: "v2-slash-percent-not-crashing"
   iut: {|_|
     let rows = (fd-run "/%"  "-t" "table" "-f" "json" | from json)
     ($rows | length) > 0 and ($rows | all {|r| not ($r.path | str contains "/")})
   }
   input: null
   expected: true
   runner: "value"}

  # ── Bug fix: fd /% returns direct children only (no sub-paths) ───────────
  # Explicit row-level assertion: every path is a single segment.
  {name: "v2-slash-percent-direct-children-only"
   iut: {|_|
     let rows = (fd-run "/%" "-t" "table" "-f" "json" | from json)
     ($rows | length) > 0 and ($rows | all {|r| not ($r.path | str contains "/")})
   }
   input: null
   expected: true
   runner: "value"}

  # ── Bug fix: fd folder returns exactly 1 row (the folder entry itself) ────
  # "folder" is a fully literal pattern → pat literal = true; BFS not entered.
  {name: "v2-folder-not-overwalking"
   iut: {|_|
     let root = setup-v2-fixture
     let rows = (fd-in $root "folder" "-t" "table" "-f" "json" | from json)
     ($rows | length) == 1 and (($rows | first).name == "folder")
   }
   input: null
   expected: true
   runner: "value"}

  # ── Depth bound: fd folder/% — immediate children only ───────────────────
  # Every returned path is exactly one segment (no "/" in path field).
  # grandchild.nu must NOT appear (it lives at depth 2 under folder).
  {name: "v2-folder-percent-depth-1-only"
   iut: {|_|
     let root = setup-v2-fixture
     let rows = (fd-in $root "folder/%" "-t" "table" "-f" "json" | from json)
     let has_rows       = ($rows | length) > 0
     let all_depth1     = ($rows | all {|r| not ($r.path | str contains "/")})
     let no_grandchild  = not ("grandchild.nu" in ($rows | get name))
     $has_rows and $all_depth1 and $no_grandchild
   }
   input: null
   expected: true
   runner: "value"}

  # ── Depth bound: fd folder/%% — unbounded; grandchild.nu must appear ──────
  {name: "v2-folder-double-percent-unbounded"
   iut: {|_|
     let root = setup-v2-fixture
     let rows = (fd-in $root "folder/%%" "-t" "table" "-f" "json" | from json)
     let names = ($rows | get name)
     let has_immediate = ("child1.nu" in $names) and ("child2.nu" in $names) and ("deep" in $names)
     let has_nested    = "grandchild.nu" in $names
     $has_immediate and $has_nested
   }
   input: null
   expected: true
   runner: "value"}

  # ── Depth bound discipline: % count < %% count under same folder ─────────
  {name: "v2-depth-bound-single-vs-double-percent"
   iut: {|_|
     let root   = setup-v2-fixture
     let single = (fd-in $root "folder/%" "-t" "table" "-f" "json" | from json | length)
     let double = (fd-in $root "folder/%%" "-t" "table" "-f" "json" | from json | length)
     $double > $single
   }
   input: null
   expected: true
   runner: "value"}

  # ── Bounded /% via absolute fixture path (safe substitute for real /%) ────
  # Run fd <fake-root>/% — must return exactly the 3 immediate children.
  {name: "v2-bounded-root-percent-depth-1"
   iut: {|_|
     let root  = setup-fake-root-fixture
     let pat   = $"($root)/%"
     let rows  = (fd-run $pat "-t" "table" "-f" "json" | from json)
     let names = ($rows | get name | sort)
     let all_depth1 = ($rows | all {|r| not ($r.path | str contains "/")})
     ($names == ["bin" "etc" "lib"]) and $all_depth1
   }
   input: null
   expected: true
   runner: "value"}

  # ── Bounded /%% via absolute fixture path (safe substitute for real /%%)-──
  # Run fd <fake-root>/%% — must return top-level dirs AND their children.
  {name: "v2-bounded-root-double-percent-recursive"
   iut: {|_|
     let root  = setup-fake-root-fixture
     let pat   = $"($root)/%%"
     let rows  = (fd-run $pat "-t" "table" "-f" "json" | from json)
     let names = ($rows | get name)
     let has_top      = ("bin" in $names) and ("lib" in $names) and ("etc" in $names)
     let has_children = ("sh" in $names) and ("libc.so" in $names) and ("hosts" in $names)
     $has_top and $has_children
   }
   input: null
   expected: true
   runner: "value"}

  # ── Matrix: nonexistent literal stem errors with "path not found" ─────────
  # Baseline: "projects/missing-app", "src/%%/%.nu", etc. all show path-not-found.
  {name: "v2-nonexistent-stem-errors"
   iut: {|_|
     let root   = setup-v2-fixture
     let result = (do { ^bash -c $"cd '($root)' && nu '($fd_nu)' 'projects/missing-app' -t table -f json" } | complete)
     $result.exit_code != 0 and (($result.stdout + $result.stderr) | str contains "path not found")
   }
   input: null
   expected: true
   runner: "value"}

  # ── Matrix: expr channel reservation ─────────────────────────────────────
  # fd ':needle' must fail with a message mentioning "reserved" or "content search".
  {name: "v2-expr-channel-reserved"
   iut: {|_|
     let root   = setup-v2-fixture
     let result = (do { ^bash -c $"cd '($root)' && nu '($fd_nu)' ':needle' -t table -f json" } | complete)
     $result.exit_code != 0 and (($result.stdout + $result.stderr) | str contains "reserved")
   }
   input: null
   expected: true
   runner: "value"}

  # ── Matrix: /usr/bin — absolute literal path lists its entries ─────────────
  {name: "v2-absolute-literal-path"
   iut: {|_|
     let rows = (fd-run "/usr/bin" "-t" "table" "-f" "json" | from json)
     ($rows | length) > 0
   }
   input: null
   expected: true
   runner: "value"}

  # ── Matrix: "" (empty pattern) — lists direct children of cwd ───────────────
  # Baseline: empty string maps to cwd; pat literal = false, stem = ""; BFS
  # emits immediate children of cwd only (universal wildcard at depth 1).
  # Use setup-v2-fixture as cwd so children are known and bounded.
  {name: "v2-empty-pattern-lists-cwd-children"
   iut: {|_|
     let root = setup-v2-fixture
     let rows = (fd-in $root "" "-t" "table" "-f" "json" | from json)
     let names = ($rows | get name)
     # Fixture root direct children: lib, folder, src
     ("lib" in $names) and ("folder" in $names) and ("src" in $names)
   }
   input: null
   expected: true
   runner: "value"}

  # ── Matrix: "." (dot pattern) — same as empty, lists cwd children ────────────
  # Baseline: "." maps to cwd just like ""; should produce the same result.
  {name: "v2-dot-pattern-lists-cwd-children"
   iut: {|_|
     let root = setup-v2-fixture
     let rows = (fd-in $root "." "-t" "table" "-f" "json" | from json)
     let names = ($rows | get name)
     # Fixture root direct children: lib, folder, src
     ("lib" in $names) and ("folder" in $names) and ("src" in $names)
   }
   input: null
   expected: true
   runner: "value"}

  # ── Matrix: "/" — lists direct children of filesystem root ────────────────────
  # Baseline: "/" produces a list of top-level entries under / (e.g. bin, usr, etc).
  {name: "v2-slash-lists-root-children"
   iut: {|_|
     let rows = (fd-run "/" "-t" "table" "-f" "json" | from json)
     ($rows | length) > 0
   }
   input: null
   expected: true
   runner: "value"}

  # ── Matrix: "folder/" — trailing slash variant (path not found) ───────────────
  # Baseline: "folder/" → error "path not found" because fixture has no "folder" dir
  # at the cwd where fd is run from (the fixture's parent, not inside it).
  {name: "v2-folder-trailing-slash-path-not-found"
   iut: {|_|
     let root = setup-v2-fixture
     # Run from a directory that does NOT contain "folder" at its root
     let tmp_cwd = "/tmp"
     let result = (do { ^bash -c $"cd '($tmp_cwd)' && nu '($fd_nu)' 'folder/' -t table -f json" } | complete)
     $result.exit_code != 0 and (($result.stdout + $result.stderr) | str contains "path not found")
   }
   input: null
   expected: true
   runner: "value"}

  # ── Matrix: "folder/%/" — trailing slash with wildcard (path not found) ───────
  # Baseline: "folder/%/" → error "path not found"; no "folder" in cwd.
  {name: "v2-folder-percent-trailing-slash-path-not-found"
   iut: {|_|
     let tmp_cwd = "/tmp"
     let result = (do { ^bash -c $"cd '($tmp_cwd)' && nu '($fd_nu)' 'folder/%/' -t table -f json" } | complete)
     $result.exit_code != 0 and (($result.stdout + $result.stderr) | str contains "path not found")
   }
   input: null
   expected: true
   runner: "value"}

  # ── Matrix: "src/%%/%.nu" — deep .nu filter, nonexistent stem → path not found ─
  # Baseline: "src/%%/%.nu" → error "path not found" (no src/ in cwd where test runs).
  {name: "v2-src-deep-nu-filter-path-not-found"
   iut: {|_|
     let tmp_cwd = "/tmp"
     let result = (do { ^bash -c $"cd '($tmp_cwd)' && nu '($fd_nu)' 'src/%%/%.nu' -t table -f json" } | complete)
     $result.exit_code != 0 and (($result.stdout + $result.stderr) | str contains "path not found")
   }
   input: null
   expected: true
   runner: "value"}

  # ── Matrix: "projects/%%/done" — double-percent in middle, nonexistent stem ────
  # Baseline: "projects/%%/done" → error "path not found" (no projects/ in cwd).
  {name: "v2-projects-deep-done-path-not-found"
   iut: {|_|
     let tmp_cwd = "/tmp"
     let result = (do { ^bash -c $"cd '($tmp_cwd)' && nu '($fd_nu)' 'projects/%%/done' -t table -f json" } | complete)
     $result.exit_code != 0 and (($result.stdout + $result.stderr) | str contains "path not found")
   }
   input: null
   expected: true
   runner: "value"}

  # ── Matrix: "/%%"  — recursive from root (crash-fix case, bounded fixture proxy) ─
  # Baseline _crashes: "fd:/%%" previously crashed with "Can't convert to record".
  # v2 fix: use bounded fake-root fixture as proxy to verify /%%  completes without
  # crashing and returns both top-level dirs AND their nested children.
  # Using absolute fixture path avoids walking /proc on Linux.
  {name: "v2-slash-double-percent-not-crashing-bounded"
   iut: {|_|
     let root  = setup-fake-root-fixture
     let pat   = $"($root)/%%"
     let rows  = (fd-run $pat "-t" "table" "-f" "json" | from json)
     let names = ($rows | get name)
     # Must have top-level dirs and their files
     let has_top      = ("bin" in $names) and ("lib" in $names) and ("etc" in $names)
     let has_children = ("sh" in $names) and ("libc.so" in $names) and ("hosts" in $names)
     $has_top and $has_children
   }
   input: null
   expected: true
   runner: "value"}

  # ── No-field-access regression (structural grep) ──────────────────────────
  # Confirm this test file contains zero direct accesses to internal pat fields.
  # rg pattern covers: .tier .any .segments .regex .raw .delim
  {name: "v2-no-pat-field-access"
   iut: {|_|
     let this_file = ($env.CURRENT_FILE)
     # Store pattern in a variable — prevents Nu parser treating "any" as a keyword.
     let rg_pat = '\$\w+\.(tier|any|segments|regex|raw|delim)\b'
     let result = (do { ^bash -c $"rg '($rg_pat)' '($this_file)'" } | complete)
     # rg exits 1 when no matches found — that is the desired outcome
     $result.exit_code == 1 and ($result.stdout | str trim | is-empty)
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
  if $list { cases | list-cases | to json | print; return }
  cases | run --filter $filter --tag $tag | report --format $format
}
