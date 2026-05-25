#!/usr/bin/env nu

use ../test.nu *
use ../pat.nu *

def cases [] { [

  # ── pat parse — empty input → universal on both channels ────────────────────

  {
    name: "v2-parse-01-empty-scope-is-any"
    iut:  {|_i| let r = (pat parse "" {delim: "/"}); pat any $r.scope}
    input:    null
    expected: true
  }
  {
    name: "v2-parse-02-empty-expr-is-any"
    iut:  {|_i| let r = (pat parse "" {delim: "/"}); pat any $r.expr}
    input:    null
    expected: true
  }
  {
    name: "v2-parse-03-empty-scope-not-literal"
    iut:  {|_i| let r = (pat parse "" {delim: "/"}); pat literal $r.scope}
    input:    null
    expected: false
  }
  {
    name: "v2-parse-04-empty-scope-stem-is-empty"
    iut:  {|_i| let r = (pat parse "" {delim: "/"}); pat stem $r.scope}
    input:    null
    expected: ""
  }

  # ── pat parse — bare token → scope exact, expr universal ────────────────────

  {
    name: "v2-parse-05-bare-token-scope-literal"
    iut:  {|_i| let r = (pat parse "scope" {delim: "/"}); pat literal $r.scope}
    input:    null
    expected: true
  }
  {
    name: "v2-parse-06-bare-token-scope-not-any"
    iut:  {|_i| let r = (pat parse "scope" {delim: "/"}); pat any $r.scope}
    input:    null
    expected: false
  }
  {
    name: "v2-parse-07-bare-token-scope-stem"
    iut:  {|_i| let r = (pat parse "scope" {delim: "/"}); pat stem $r.scope}
    input:    null
    expected: "scope"
  }
  {
    name: "v2-parse-08-bare-token-expr-is-any"
    iut:  {|_i| let r = (pat parse "scope" {delim: "/"}); pat any $r.expr}
    input:    null
    expected: true
  }

  # ── pat parse — leading colon → scope universal, expr has pattern ────────────

  {
    name: "v2-parse-09-leading-colon-scope-is-any"
    iut:  {|_i| let r = (pat parse ":expr" {delim: "/"}); pat any $r.scope}
    input:    null
    expected: true
  }
  {
    name: "v2-parse-10-leading-colon-expr-literal"
    iut:  {|_i| let r = (pat parse ":expr" {delim: "/"}); pat literal $r.expr}
    input:    null
    expected: true
  }
  {
    name: "v2-parse-11-leading-colon-expr-stem"
    iut:  {|_i| let r = (pat parse ":expr" {delim: "/"}); pat stem $r.expr}
    input:    null
    expected: "expr"
  }

  # ── pat parse — trailing colon → scope has pattern, expr universal ────────────

  {
    name: "v2-parse-12-trailing-colon-scope-literal"
    iut:  {|_i| let r = (pat parse "scope:" {delim: "/"}); pat literal $r.scope}
    input:    null
    expected: true
  }
  {
    name: "v2-parse-13-trailing-colon-scope-stem"
    iut:  {|_i| let r = (pat parse "scope:" {delim: "/"}); pat stem $r.scope}
    input:    null
    expected: "scope"
  }
  {
    name: "v2-parse-14-trailing-colon-expr-is-any"
    iut:  {|_i| let r = (pat parse "scope:" {delim: "/"}); pat any $r.expr}
    input:    null
    expected: true
  }

  # ── pat parse — scope:expr form ───────────────────────────────────────────────

  {
    name: "v2-parse-15-scope-expr-scope-literal"
    iut:  {|_i| let r = (pat parse "scope:expr" {delim: "/"}); pat literal $r.scope}
    input:    null
    expected: true
  }
  {
    name: "v2-parse-16-scope-expr-scope-stem"
    iut:  {|_i| let r = (pat parse "scope:expr" {delim: "/"}); pat stem $r.scope}
    input:    null
    expected: "scope"
  }
  {
    name: "v2-parse-17-scope-expr-expr-literal"
    iut:  {|_i| let r = (pat parse "scope:expr" {delim: "/"}); pat literal $r.expr}
    input:    null
    expected: true
  }
  {
    name: "v2-parse-18-scope-expr-expr-stem"
    iut:  {|_i| let r = (pat parse "scope:expr" {delim: "/"}); pat stem $r.expr}
    input:    null
    expected: "expr"
  }

  # ── pat parse — trailing-slash promotion ─────────────────────────────────────

  # "nu-lib/%/" → scope raw promoted to "nu-lib/%/%" (wildcard, not literal, not any)
  {
    name: "v2-parse-19-trailing-slash-not-literal"
    iut:  {|_i| let r = (pat parse "nu-lib/%/" {delim: "/"}); pat literal $r.scope}
    input:    null
    expected: false
  }
  {
    name: "v2-parse-20-trailing-slash-not-any"
    iut:  {|_i| let r = (pat parse "nu-lib/%/" {delim: "/"}); pat any $r.scope}
    input:    null
    expected: false
  }
  {
    name: "v2-parse-21-trailing-slash-stem"
    iut:  {|_i| let r = (pat parse "nu-lib/%/" {delim: "/"}); pat stem $r.scope}
    input:    null
    expected: "nu-lib"
  }

  # "%/" → "%/%" (wildcard, not literal, not any)
  {
    name: "v2-parse-22-pct-trailing-slash-not-literal"
    iut:  {|_i| let r = (pat parse "%/" {delim: "/"}); pat literal $r.scope}
    input:    null
    expected: false
  }
  {
    name: "v2-parse-23-pct-trailing-slash-not-any"
    iut:  {|_i| let r = (pat parse "%/" {delim: "/"}); pat any $r.scope}
    input:    null
    expected: false
  }
  {
    name: "v2-parse-24-pct-trailing-slash-stem-empty"
    iut:  {|_i| let r = (pat parse "%/" {delim: "/"}); pat stem $r.scope}
    input:    null
    expected: ""
  }

  # "%%" (top-level) → universal
  {
    name: "v2-parse-25-pctpct-is-any"
    iut:  {|_i| let r = (pat parse "%%" {delim: "/"}); pat any $r.scope}
    input:    null
    expected: true
  }

  # "%%/" → "%%/%" (wildcard after promotion, not any because %% + / strips and adds %)
  {
    name: "v2-parse-26-pctpct-trailing-slash-not-any"
    iut:  {|_i| let r = (pat parse "%%/" {delim: "/"}); pat any $r.scope}
    input:    null
    expected: false
  }
  {
    name: "v2-parse-27-pctpct-trailing-slash-not-literal"
    iut:  {|_i| let r = (pat parse "%%/" {delim: "/"}); pat literal $r.scope}
    input:    null
    expected: false
  }

  # ── pat parse — anchor_descend promotion ────────────────────────────────────

  # "." with anchor_descend=true, anchors=["."] → promotes to "./%"
  {
    name: "v2-parse-28-anchor-descend-dot-not-literal"
    iut:  {|_i|
      let r = (pat parse "." {delim: "/", anchors: [".", ".."], anchor_descend: true})
      pat literal $r.scope
    }
    input:    null
    expected: false
  }
  {
    name: "v2-parse-29-anchor-descend-dot-not-any"
    iut:  {|_i|
      let r = (pat parse "." {delim: "/", anchors: [".", ".."], anchor_descend: true})
      pat any $r.scope
    }
    input:    null
    expected: false
  }
  {
    name: "v2-parse-30-anchor-descend-dot-stem"
    iut:  {|_i|
      let r = (pat parse "." {delim: "/", anchors: [".", ".."], anchor_descend: true})
      pat stem $r.scope
    }
    input:    null
    expected: "."
  }

  # "." without anchor_descend → "." is exact (literal=true)
  {
    name: "v2-parse-31-no-anchor-descend-dot-literal"
    iut:  {|_i|
      let r = (pat parse "." {delim: "/", anchors: [], anchor_descend: false})
      pat literal $r.scope
    }
    input:    null
    expected: true
  }
  {
    name: "v2-parse-32-no-anchor-descend-dot-stem"
    iut:  {|_i|
      let r = (pat parse "." {delim: "/", anchors: [], anchor_descend: false})
      pat stem $r.scope
    }
    input:    null
    expected: "."
  }

  # empty with anchor_descend=true → promotes to "%" (wildcard/filtered, NOT universal)
  # The promotion rule: empty → <prefix> + delim + % where empty prefix → just "%"
  {
    name: "v2-parse-33-anchor-descend-empty-promotes-to-filtered"
    iut:  {|_i|
      let r = (pat parse "" {delim: "/", anchors: [".", ".."], anchor_descend: true})
      # Promoted to "%" → wildcard, so neither any nor literal
      (not (pat any $r.scope)) and (not (pat literal $r.scope))
    }
    input:    null
    expected: true
  }

  # ── pat stem — spec §10 table ────────────────────────────────────────────────

  # "" → stem ""
  {
    name: "v2-stem-01-empty"
    iut:  {|_i| let r = (pat parse "" {delim: "/"}); pat stem $r.scope}
    input:    null
    expected: ""
  }
  # "lib" → stem "lib"
  {
    name: "v2-stem-02-bare-literal"
    iut:  {|_i| let r = (pat parse "lib" {delim: "/"}); pat stem $r.scope}
    input:    null
    expected: "lib"
  }
  # "lib/args.nu" → stem "lib/args.nu"
  {
    name: "v2-stem-03-multi-literal"
    iut:  {|_i| let r = (pat parse "lib/args.nu" {delim: "/"}); pat stem $r.scope}
    input:    null
    expected: "lib/args.nu"
  }
  # "lib/%%" → stem "lib"
  {
    name: "v2-stem-04-literal-then-wildcard"
    iut:  {|_i| let r = (pat parse "lib/%%" {delim: "/"}); pat stem $r.scope}
    input:    null
    expected: "lib"
  }
  # "%%/X" → stem ""
  {
    name: "v2-stem-05-wildcard-first"
    iut:  {|_i| let r = (pat parse "%%/X" {delim: "/"}); pat stem $r.scope}
    input:    null
    expected: ""
  }
  # "%/X" → stem ""
  {
    name: "v2-stem-06-single-wildcard-first"
    iut:  {|_i| let r = (pat parse "%/X" {delim: "/"}); pat stem $r.scope}
    input:    null
    expected: ""
  }

  # ── pat literal / pat any — mutually exclusive ────────────────────────────────

  # fully literal pattern: literal=true, any=false
  {
    name: "v2-accessor-01-literal-true-any-false"
    iut:  {|_i|
      let r = (pat parse "lib/args.nu" {delim: "/"})
      [(pat literal $r.scope) (pat any $r.scope)]
    }
    input:    null
    expected: [true false]
  }
  # universal pattern: literal=false, any=true
  {
    name: "v2-accessor-02-literal-false-any-true"
    iut:  {|_i|
      let r = (pat parse "" {delim: "/"})
      [(pat literal $r.scope) (pat any $r.scope)]
    }
    input:    null
    expected: [false true]
  }
  # filtered (wildcard) pattern: literal=false, any=false
  {
    name: "v2-accessor-03-filtered-both-false"
    iut:  {|_i|
      let r = (pat parse "lib/%" {delim: "/"})
      [(pat literal $r.scope) (pat any $r.scope)]
    }
    input:    null
    expected: [false false]
  }

  # ── pat match — PK-3 emit/expand table ───────────────────────────────────────

  # Row: path="" seed against universal → emit=true, expand=true
  {
    name: "v2-match-01-seed-universal-emit-true-expand-true"
    iut:  {|_i|
      let r = (pat parse "" {delim: "/"})
      let results = (pat match $r.scope [{path: "", item: "root"}])
      let first = ($results | first)
      {emit: $first.emit, expand: $first.expand}
    }
    input:    null
    expected: {emit: true, expand: true}
  }

  # Row: path="" seed against filtered → emit=false, expand=true
  {
    name: "v2-match-02-seed-filtered-emit-false-expand-true"
    iut:  {|_i|
      let r = (pat parse "lib/%" {delim: "/"})
      let results = (pat match $r.scope [{path: "", item: "root"}])
      let first = ($results | first)
      {emit: $first.emit, expand: $first.expand}
    }
    input:    null
    expected: {emit: false, expand: true}
  }

  # Row: literal pattern — seed with path=stem (not path="") emits, no expand
  # PK-3: literal + empty seed → expand=true (empty always extensible); match only at stem path
  {
    name: "v2-match-03-literal-stem-path-emit-no-expand"
    iut:  {|_i|
      let r = (pat parse "lib" {delim: "/"})
      # Tool seeds at path=stem="lib", not path=""
      let results = (pat match $r.scope [{path: "lib", item: "lib-item"}])
      let first = ($results | first)
      {emit: $first.emit, expand: $first.expand}
    }
    input:    null
    expected: {emit: true, expand: false}
  }

  # Row: prefix of filtered pattern → emit=false, expand=true
  {
    name: "v2-match-04-prefix-filtered-emit-false-expand-true"
    iut:  {|_i|
      let r = (pat parse "lib/%" {delim: "/"})
      let results = (pat match $r.scope [{path: "lib", item: "lib-item"}])
      let first = ($results | first)
      {emit: $first.emit, expand: $first.expand}
    }
    input:    null
    expected: {emit: false, expand: true}
  }

  # Row: full match against filtered (single-wildcard, depth 2) → emit=true
  {
    name: "v2-match-05-full-match-filtered-emit-true"
    iut:  {|_i|
      let r = (pat parse "lib/%" {delim: "/"})
      let results = (pat match $r.scope [{path: "lib/args.nu", item: "args"}])
      let first = ($results | first)
      $first.emit
    }
    input:    null
    expected: true
  }

  # Row: mismatch against filtered → emit=false, expand=false (prune)
  {
    name: "v2-match-06-mismatch-filtered-prune"
    iut:  {|_i|
      let r = (pat parse "lib/%" {delim: "/"})
      let results = (pat match $r.scope [{path: "tests/x.nu", item: "x"}])
      let first = ($results | first)
      {emit: $first.emit, expand: $first.expand}
    }
    input:    null
    expected: {emit: false, expand: false}
  }

  # Row: any path against universal → emit=true, expand=true
  {
    name: "v2-match-07-any-path-universal-emit-expand-true"
    iut:  {|_i|
      let r = (pat parse "" {delim: "/"})
      let results = (pat match $r.scope [{path: "projects/nu-lib", item: "some"}])
      let first = ($results | first)
      {emit: $first.emit, expand: $first.expand}
    }
    input:    null
    expected: {emit: true, expand: true}
  }

  # Row: %% pattern — full match also expands (can go deeper)
  {
    name: "v2-match-08-pctpct-tail-emit-and-expand"
    iut:  {|_i|
      let r = (pat parse "projects/%%" {delim: "/"})
      let results = (pat match $r.scope [{path: "projects/foo", item: "foo"}])
      let first = ($results | first)
      $first.emit
    }
    input:    null
    expected: true
  }

  # Row: %% matches zero segments (path == "projects" for pattern "projects/%%")
  {
    name: "v2-match-09-pctpct-zero-segments"
    iut:  {|_i|
      let r = (pat parse "projects/%%" {delim: "/"})
      let results = (pat match $r.scope [{path: "projects", item: "p"}])
      let first = ($results | first)
      $first.emit
    }
    input:    null
    expected: true
  }

  # Batch: pat match processes multiple records at once
  {
    name: "v2-match-10-batch-multiple-records"
    iut:  {|_i|
      let r = (pat parse "lib/%" {delim: "/"})
      let records = [
        {path: "lib/args.nu", item: "args"}
        {path: "lib/pat.nu",  item: "pat"}
        {path: "tests/x.nu",  item: "x"}
      ]
      let results = (pat match $r.scope $records)
      $results | where emit | length
    }
    input:    null
    expected: 2
  }

  # pat match return shape: each result has {record, emit, expand}
  {
    name: "v2-match-11-return-shape"
    iut:  {|_i|
      let r = (pat parse "lib" {delim: "/"})
      let results = (pat match $r.scope [{path: "lib", item: "x"}])
      let first = ($results | first)
      ($first | columns | sort)
    }
    input:    null
    expected: ["emit" "expand" "record"]
  }

  # pat match: record field preserves the original input record
  {
    name: "v2-match-12-record-field-preserved"
    iut:  {|_i|
      let r = (pat parse "lib" {delim: "/"})
      let input_rec = {path: "lib", item: "lib-item"}
      let results = (pat match $r.scope [$input_rec])
      let first = ($results | first)
      $first.record
    }
    input:    null
    expected: {path: "lib", item: "lib-item"}
  }

  # ── pat match — additional emit/expand table coverage ────────────────────────

  # %%/X: path "X" — emit=true (%%  consuming 0 then X matches)
  {
    name: "v2-match-13-pctpct-x-zero-consume-emit"
    iut:  {|_i|
      let r = (pat parse "%%/X" {delim: "/"})
      let results = (pat match $r.scope [{path: "X", item: "x-item"}])
      let first = ($results | first)
      $first.emit
    }
    input:    null
    expected: true
  }

  # %%/X: path "a/b/X" — emit=true (%% consumes a/b, X matches)
  {
    name: "v2-match-14-pctpct-x-multi-consume-emit"
    iut:  {|_i|
      let r = (pat parse "%%/X" {delim: "/"})
      let results = (pat match $r.scope [{path: "a/b/X", item: "x-item"}])
      let first = ($results | first)
      $first.emit
    }
    input:    null
    expected: true
  }

  # %%/X: path "a/b/X/Y" — emit=false (unconsumed Y after X)
  {
    name: "v2-match-15-pctpct-x-trailing-prune"
    iut:  {|_i|
      let r = (pat parse "%%/X" {delim: "/"})
      let results = (pat match $r.scope [{path: "a/b/X/Y", item: "y-item"}])
      let first = ($results | first)
      $first.emit
    }
    input:    null
    expected: false
  }

  # lib/%%: path "lib/args/extra" — emit=true (%% consumes args/extra)
  {
    name: "v2-match-16-lib-pctpct-deep-emit"
    iut:  {|_i|
      let r = (pat parse "lib/%%" {delim: "/"})
      let results = (pat match $r.scope [{path: "lib/args/extra", item: "e"}])
      let first = ($results | first)
      $first.emit
    }
    input:    null
    expected: true
  }

  # lib/%: path "lib/args/extra" — emit=false (single % can't cross delim)
  {
    name: "v2-match-17-lib-pct-rejects-deep"
    iut:  {|_i|
      let r = (pat parse "lib/%" {delim: "/"})
      let results = (pat match $r.scope [{path: "lib/args/extra", item: "e"}])
      let first = ($results | first)
      $first.emit
    }
    input:    null
    expected: false
  }

  # ── pat filter ────────────────────────────────────────────────────────────────

  # Basic: filter with --value closure; matching records have emit=true
  # Use colon form ":args.nu" to get a non-universal expr pattern
  {
    name: "v2-filter-01-basic-match"
    iut:  {|_i|
      let q = (pat parse ":args.nu" {delim: "/"}).expr
      let records = [
        {path: "lib/args.nu", item: "args.nu"}
        {path: "lib/pat.nu",  item: "pat.nu"}
      ]
      let results = (pat filter $q $records --value {|r| $r.item})
      $results | where emit | length
    }
    input:    null
    expected: 1
  }

  # --value closure receives the whole record (not just item)
  {
    name: "v2-filter-02-value-closure-receives-whole-record"
    iut:  {|_i|
      let q = (pat parse "lib/args.nu" {delim: "/"}).scope
      let records = [{path: "lib/args.nu", item: "args.nu"}]
      let results = (pat filter $q $records --value {|r| $r.path})
      ($results | first).emit
    }
    input:    null
    expected: true
  }

  # --value closure returns a string used as canonical identifier
  # Use colon form ":pat.nu" to get a non-universal expr pattern
  {
    name: "v2-filter-03-value-returns-string-match"
    iut:  {|_i|
      let q = (pat parse ":pat.nu" {delim: "/"}).expr
      let records = [
        {path: "lib/pat.nu", item: "pat.nu"}
        {path: "lib/args.nu", item: "args.nu"}
      ]
      let results = (pat filter $q $records --value {|r| $r.item})
      let emitted = ($results | where emit)
      ($emitted | length) == 1 and (($emitted | first).record.item == "pat.nu")
    }
    input:    null
    expected: true
  }

  # pat filter return shape: each result has {record, emit}; no expand field
  {
    name: "v2-filter-04-return-shape-no-expand"
    iut:  {|_i|
      let q = (pat parse "x" {delim: "/"}).expr
      let records = [{path: "x", item: "x"}]
      let results = (pat filter $q $records --value {|r| $r.item})
      let first = ($results | first)
      let cols = ($first | columns | sort)
      ("expand" not-in $cols) and ("emit" in $cols) and ("record" in $cols)
    }
    input:    null
    expected: true
  }

  # Missing --value raises an error
  {
    name: "v2-filter-05-missing-value-errors"
    runner: "throws"
    iut:  {|_i|
      let q = (pat parse "x" {delim: "/"}).expr
      let records = [{path: "x", item: "x"}]
      pat filter $q $records
    }
    input:    null
    expected: "--value is required"
    assert:   {|actual expected| $actual | str contains $expected}
  }

  # pat filter: universal expr pattern emits everything
  {
    name: "v2-filter-06-universal-emits-all"
    iut:  {|_i|
      let q = (pat parse "" {delim: "/"}).expr
      let records = [
        {path: "a", item: "alpha"}
        {path: "b", item: "beta"}
        {path: "c", item: "gamma"}
      ]
      let results = (pat filter $q $records --value {|r| $r.item})
      $results | where emit | length
    }
    input:    null
    expected: 3
  }

  # pat filter: one annotated record per input (length matches input length)
  # Use a concrete scope pattern (no colon) and filter via scope channel
  {
    name: "v2-filter-07-one-result-per-input"
    iut:  {|_i|
      let q = (pat parse ":%" {delim: "/"}).expr
      let records = [
        {path: "a", item: "alpha"}
        {path: "b", item: "beta"}
      ]
      let results = (pat filter $q $records --value {|r| $r.item})
      $results | length
    }
    input:    null
    expected: 2
  }

  # pat filter: wildcard pattern matches appropriate items
  # Use colon form ":pa%" to get a non-universal wildcard expr pattern
  {
    name: "v2-filter-08-wildcard-pattern-match"
    iut:  {|_i|
      let q = (pat parse ":pa%" {delim: "/"}).expr
      let records = [
        {path: "a", item: "pat.nu"}
        {path: "b", item: "parser.nu"}
        {path: "c", item: "args.nu"}
      ]
      let results = (pat filter $q $records --value {|r| $r.item})
      $results | where emit | length
    }
    input:    null
    expected: 2
  }

] }

def main [
  --filter(-f): string = ""
  --tag(-t):    string = ""
  --format:     string = "text"
  --list(-l)
] {
  if $list { cases | list-cases | to json | print; return }
  cases | run --filter $filter --tag $tag | report --format $format --file $env.CURRENT_FILE
}
