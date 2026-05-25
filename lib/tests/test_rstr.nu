#!/usr/bin/env nu

use ../test.nu *
use ../rstr.nu *

def cases [] { [

  # ── rstr of ──────────────────────────────────────────────────────────────────

  {name: "of-01-plain-string-becomes-text-node"
   iut: {|i| $i | rstr of}
   input: "hello"
   expected: [{t: "hello"}]}

  {name: "of-02-escapes-guillemet-in-input"
   iut: {|i| $i | rstr of | rstr to-str}
   input: "a«b"
   expected: "a««b"}

  {name: "of-03-empty-string-produces-empty-text-node"
   iut: {|i| $i | rstr of}
   input: ""
   expected: [{t: ""}]}

  # ── rstr tag ─────────────────────────────────────────────────────────────────

  {name: "tag-01-wraps-in-region-node-with-correct-name"
   iut: {|i| $i | rstr of | rstr tag "bold" | get 0 | get r}
   input: "hi"
   expected: "bold"}

  {name: "tag-02-children-match-inner-rstr"
   iut: {|i| $i | rstr of | rstr tag "dim" | get 0 | get c}
   input: "hi"
   expected: [{t: "hi"}]}

  {name: "tag-03-result-is-list-of-length-one"
   iut: {|i| $i | rstr of | rstr tag "x" | length}
   input: "hi"
   expected: 1}

  # ── rstr concat ──────────────────────────────────────────────────────────────

  {name: "concat-01-joins-multiple-rstrings"
   iut: {|i| [("a" | rstr of), ("b" | rstr of), ("c" | rstr of)] | rstr concat | length}
   input: null
   expected: 3}

  {name: "concat-02-preserves-node-structure"
   iut: {|i| [("a" | rstr of), ("b" | rstr of | rstr tag "x")] | rstr concat | get 1}
   input: null
   expected: {r: "x", c: [{t: "b"}]}}

  {name: "concat-03-single-item-list-is-identity"
   iut: {|i| [("hello" | rstr of)] | rstr concat}
   input: null
   expected: [{t: "hello"}]}

  # ── rstr len ─────────────────────────────────────────────────────────────────

  {name: "len-01-counts-text-leaf-chars"
   iut: {|i| $i | rstr of | rstr len}
   input: "hello"
   expected: 5}

  {name: "len-02-counts-through-region-node"
   iut: {|i| $i | rstr of | rstr tag "dim" | rstr len}
   input: "hello"
   expected: 5}

  {name: "len-03-counts-multiple-text-nodes"
   iut: {|i| [("ab" | rstr of), ("cd" | rstr of)] | rstr concat | rstr len}
   input: null
   expected: 4}

  {name: "len-04-empty-rstr-is-zero"
   iut: {|i| $i | rstr of | rstr len}
   input: ""
   expected: 0}

  {name: "len-05-does-not-count-region-marker-chars"
   iut: {|i| $i | rstr of | rstr tag "longregionname" | rstr len}
   input: "ab"
   expected: 2}

  # ── rstr display-len (ambiguous UTF-8) ───────────────────────────────────────

  {name: "display-len-cyclic"
   iut: {|i| $i | rstr display-len}
   input: "⟳"
   expected: 1}

  {name: "display-len-arrow"
   iut: {|i| $i | rstr display-len}
   input: "→"
   expected: 1}

  {name: "display-len-ellipsis"
   iut: {|i| $i | rstr display-len}
   input: "…"
   expected: 1}

  {name: "display-len-mixed"
   iut: {|i| $i | rstr display-len}
   input: "abc⟳"
   expected: 4}

  {name: "display-len-lock-emoji-is-wide"
   iut: {|i| $i | rstr display-len}
   input: "emf/ 🔒🔒"
   expected: 9}

  {name: "rstr-len-unicode"
   iut: {|i| $i | rstr of | rstr len}
   input: "⟳"
   expected: 1}

  # ── rstr plain ───────────────────────────────────────────────────────────────

  {name: "plain-01-strips-single-region"
   iut: {|i| $i | rstr from-str | rstr plain}
   input: "«x»hi«/»"
   expected: "hi"}

  {name: "plain-02-strips-nested-regions"
   iut: {|i| $i | rstr from-str | rstr plain}
   input: "«a»«b»hello«/»«/»"
   expected: "hello"}

  {name: "plain-03-plain-text-unchanged"
   iut: {|i| $i | rstr of | rstr plain}
   input: "hello"
   expected: "hello"}

  {name: "plain-04-mixed-text-and-region"
   iut: {|i| $i | rstr from-str | rstr plain}
   input: "pre«r»mid«/»post"
   expected: "premidpost"}

  # ── rstr trim ────────────────────────────────────────────────────────────────

  {name: "trim-01-string-within-width-is-unchanged"
   iut: {|i| $i | rstr of | rstr trim 10 | rstr plain}
   input: "hello"
   expected: "hello"}

  {name: "trim-02-truncates-at-display-offset"
   iut: {|i| $i | rstr of | rstr trim 5 | rstr plain}
   input: "hello world"
   expected: "hell…"}

  {name: "trim-03-appends-ellipsis-node"
   iut: {|i| $i | rstr of | rstr trim 5 | last | get t}
   input: "hello world"
   expected: "…"}

  {name: "trim-04-does-not-split-region-open"
   iut: {|i|
     let r = ("hi" | rstr of | rstr tag "bold")
     let prefix = ("aa" | rstr of)
     [$prefix, $r] | rstr concat | rstr trim 3 | rstr plain}
   input: null
   expected: "aa…"}

  {name: "trim-05-zero-width-returns-ellipsis-only"
   iut: {|i| "abc" | rstr of | rstr trim 0 | rstr plain}
   input: null
   expected: "…"}

  # ── rstr trim-lhs ────────────────────────────────────────────────────────────

  {name: "trim-lhs-01-string-within-width-is-unchanged"
   iut: {|i| $i | rstr of | rstr trim-lhs 10 | rstr plain}
   input: "hello"
   expected: "hello"}

  {name: "trim-lhs-02-keeps-tail-with-ellipsis-at-left"
   iut: {|i| $i | rstr of | rstr trim-lhs 5 | rstr plain}
   input: "hello world"
   expected: "…orld"}

  {name: "trim-lhs-03-prepends-ellipsis-node"
   iut: {|i| $i | rstr of | rstr trim-lhs 5 | first | get t}
   input: "hello world"
   expected: "…"}

  {name: "trim-lhs-04-zero-width-returns-ellipsis-only"
   iut: {|i| "abc" | rstr of | rstr trim-lhs 0 | rstr plain}
   input: null
   expected: "…"}

  {name: "trim-lhs-05-exact-width-is-unchanged"
   iut: {|i| $i | rstr of | rstr trim-lhs 5 | rstr plain}
   input: "hello"
   expected: "hello"}

  {name: "trim-lhs-06-tail-width-is-budget-minus-one"
   iut: {|i| $i | rstr of | rstr trim-lhs 4 | rstr len}
   input: "hello world"
   expected: 4}

  # ── clip none / wrap pass-through (rstr primitive level) ─────────────────────
  # clip: "none" and clip: "wrap" (deferred = same as none) both leave content
  # unclipped — the rstr primitives rstr trim / rstr trim-lhs are simply not
  # called; content narrower than width is the same result as no-op.

  {name: "clip-none-narrower-content-unchanged"
   iut: {|i| $i | rstr of | rstr len}
   input: "short"
   expected: 5}

  {name: "clip-none-at-width-boundary-unchanged"
   iut: {|i| $i | rstr of | rstr trim 10 | rstr plain}
   input: "short"
   expected: "short"}

  {name: "clip-wrap-deferred-same-as-none"
   iut: {|i|
     # wrap is not yet implemented; verify content is returned unmodified
     # (i.e., rstr trim is not called when clip == "wrap").
     # We model this directly: call neither trim nor trim-lhs — plain rstr of.
     $i | rstr of | rstr plain}
   input: "some content"
   expected: "some content"}

  # ── rstr fill ────────────────────────────────────────────────────────────────

  {name: "fill-01-left-align-pads-on-right"
   iut: {|i| $i | rstr of | rstr fill 6 "left" | rstr plain}
   input: "hi"
   expected: "hi    "}

  {name: "fill-02-right-align-pads-on-left"
   iut: {|i| $i | rstr of | rstr fill 6 "right" | rstr plain}
   input: "hi"
   expected: "    hi"}

  {name: "fill-03-center-align-splits-padding"
   iut: {|i| $i | rstr of | rstr fill 6 "center" | rstr plain}
   input: "hi"
   expected: "  hi  "}

  {name: "fill-04-default-align-is-left"
   iut: {|i| $i | rstr of | rstr fill 6 | rstr plain}
   input: "hi"
   expected: "hi    "}

  {name: "fill-05-no-pad-when-already-at-width"
   iut: {|i| $i | rstr of | rstr fill 5 | rstr len}
   input: "hello"
   expected: 5}

  {name: "fill-06-no-pad-when-longer-than-width"
   iut: {|i| $i | rstr of | rstr fill 3 | rstr plain}
   input: "hello"
   expected: "hello"}

  # ── rstr to-str / from-str round-trip ────────────────────────────────────────

  {name: "rt-01-plain-text-round-trips"
   iut: {|i| $i | rstr of | rstr to-str | rstr from-str | rstr plain}
   input: "hello"
   expected: "hello"}

  {name: "rt-02-single-region-round-trips"
   iut: {|i|
     let original = ("hi" | rstr of | rstr tag "bold")
     let wire = ($original | rstr to-str)
     let parsed = ($wire | rstr from-str)
     $parsed == $original}
   input: null
   expected: true}

  {name: "rt-03-nested-region-round-trips"
   iut: {|i|
     let original = ("hi" | rstr of | rstr tag "inner" | rstr tag "outer")
     let wire = ($original | rstr to-str)
     let parsed = ($wire | rstr from-str)
     $parsed == $original}
   input: null
   expected: true}

  {name: "rt-04-text-with-escaped-guillemet-round-trips"
   iut: {|i|
     let original = ("a«b" | rstr of)
     let wire = ($original | rstr to-str)
     let parsed = ($wire | rstr from-str)
     $parsed == $original}
   input: null
   expected: true}

  {name: "rt-05-mixed-text-and-region-round-trips"
   iut: {|i|
     let original = ([("pre" | rstr of), ("mid" | rstr of | rstr tag "r"), ("post" | rstr of)] | rstr concat)
     let wire = ($original | rstr to-str)
     let parsed = ($wire | rstr from-str)
     $parsed == $original}
   input: null
   expected: true}

  # ── rstr from-str ─────────────────────────────────────────────────────────────

  {name: "fs-01-bare-text-parses-to-text-node"
   iut: {|i| $i | rstr from-str}
   input: "hello"
   expected: [{t: "hello"}]}

  {name: "fs-02-open-region-parses-correctly"
   iut: {|i| $i | rstr from-str | get 0 | get r}
   input: "«dim»text«/»"
   expected: "dim"}

  {name: "fs-03-escaped-guillemet-parses-to-literal"
   iut: {|i| $i | rstr from-str | get 0 | get t}
   input: "a««b"
   expected: "a«b"}

  {name: "fs-04-unclosed-region-errors"
   runner: "throws"
   iut: {|i| "«open»text" | rstr from-str}
   input: null
   expected: "unclosed"
   assert: {|actual expected| $actual | str contains $expected}}

  # ── rstr regions ─────────────────────────────────────────────────────────────

  {name: "regions-01-returns-names-depth-first"
   iut: {|i| $i | rstr from-str | rstr regions}
   input: "«outer»«inner»hi«/»«/»"
   expected: ["outer" "inner"]}

  {name: "regions-02-flat-regions-returned-in-order"
   iut: {|i| $i | rstr from-str | rstr regions}
   input: "«a»x«/»«b»y«/»"
   expected: ["a" "b"]}

  {name: "regions-03-plain-text-returns-empty"
   iut: {|i| $i | rstr of | rstr regions}
   input: "hello"
   expected: []}

  {name: "regions-04-single-region-returns-single-name"
   iut: {|i| $i | rstr of | rstr tag "bold" | rstr regions}
   input: "hi"
   expected: ["bold"]}

  # ── rstr str ─────────────────────────────────────────────────────────────────

  {name: "str-01-named-close-plain"
   iut: {|i| $i | rstr str | rstr plain}
   input: "<b>text</b>"
   expected: "text"}

  {name: "str-02-named-close-regions"
   iut: {|i| $i | rstr str | rstr regions}
   input: "<b>text</b>"
   expected: ["b"]}

  {name: "str-03-generic-close-plain"
   iut: {|i| $i | rstr str | rstr plain}
   input: "<b>text</>"
   expected: "text"}

  {name: "str-04-generic-close-regions"
   iut: {|i| $i | rstr str | rstr regions}
   input: "<b>text</>"
   expected: ["b"]}

  {name: "str-05-self-closing-to-str"
   iut: {|i| $i | rstr str | rstr to-str}
   input: "<dim note />"
   expected: "«dim»note«/»"}

  {name: "str-06-mixed-plain-and-styled"
   iut: {|i| $i | rstr str | rstr plain}
   input: "prefix <b>bold</b> suffix"
   expected: "prefix bold suffix"}

  {name: "str-07-nested-regions-depth-first"
   iut: {|i| $i | rstr str | rstr regions}
   input: "<h1><b>x</b></h1>"
   expected: ["h1" "b"]}

  {name: "str-08-escape-double-lt"
   iut: {|i| $i | rstr str | rstr plain}
   input: "a <<b"
   expected: "a <b"}

  {name: "str-09-unclosed-best-effort"
   iut: {|i| "<b>text" | rstr str | rstr plain}
   input: null
   expected: "<b>text"}

  {name: "str-10-mismatch-error"
   runner: "throws"
   iut: {|i| "<b>text</u>" | rstr str}
   input: null
   expected: "rstr str: expected </b> got </u>"
   assert: {|actual expected| $actual == $expected}}

  # ── rstr map-text ─────────────────────────────────────────────────────────────

  {name: "mt-01-applies-closure-to-text-leaf"
   iut: {|i| $i | rstr of | rstr map-text {|s| $s | str upcase} | rstr plain}
   input: "hello"
   expected: "HELLO"}

  {name: "mt-02-applies-closure-to-nested-text-leaf"
   iut: {|i| $i | rstr of | rstr tag "dim" | rstr map-text {|s| $s | str upcase} | rstr plain}
   input: "hello"
   expected: "HELLO"}

  {name: "mt-03-preserves-region-structure"
   iut: {|i| $i | rstr of | rstr tag "bold" | rstr map-text {|s| $s} | get 0 | get r}
   input: "hi"
   expected: "bold"}

  {name: "mt-04-applies-to-every-leaf-in-mixed-rstr"
   iut: {|i|
     let r = ([("aa" | rstr of), ("bb" | rstr of | rstr tag "x")] | rstr concat)
     $r | rstr map-text {|s| $s | str upcase} | rstr plain}
   input: null
   expected: "AABB"}

  # ── rstr flatten / rstr to-ansi ──────────────────────────────────────────────

  # rstr flatten true: styled rstr (ok region) must contain ANSI escape sequences
  {name: "test-flatten-color-on"
   iut: {|i|
     let r = ("done" | rstr of | rstr tag "ok")
     let s = ($r | rstr flatten true)
     # ESC byte (0x1b) is present when ANSI styling was applied
     ($s | into binary | bytes index-of 0x[1b]) >= 0}
   input: null
   expected: true}

  # rstr flatten false: same rstr must return plain text with no ANSI escapes
  {name: "test-flatten-color-off"
   iut: {|i|
     let r = ("done" | rstr of | rstr tag "ok")
     let s = ($r | rstr flatten false)
     # No ESC byte and plain text is preserved verbatim
     let no_esc = (($s | into binary | bytes index-of 0x[1b]) == -1)
     let has_text = ($s | str contains "done")
     $no_esc and $has_text}
   input: null
   expected: true}

  # rstr to-ansi parity with rstr flatten when FORCE_TTY=1 (TTY state = true)
  # to-ansi must equal rstr flatten true when tui-is-tty returns true
  {name: "test-to-ansi-parity-tty-on"
   runner: "stdio"
   nu_src: "
use nu-lib/lib/rstr.nu *
let r = (\"done\" | rstr of | rstr tag \"ok\")
let via_flatten = ($r | rstr flatten true)
let via_to_ansi = (with-env {FORCE_TTY: \"1\"} { $r | rstr to-ansi })
print ($via_flatten == $via_to_ansi)
"
   expected: "true"}

  # rstr to-ansi parity with rstr flatten when FORCE_TTY=0 (TTY state = false)
  # to-ansi must equal rstr flatten false when tui-is-tty returns false
  {name: "test-to-ansi-parity-tty-off"
   runner: "stdio"
   nu_src: "
use nu-lib/lib/rstr.nu *
let r = (\"done\" | rstr of | rstr tag \"ok\")
let via_flatten = ($r | rstr flatten false)
let via_to_ansi = (with-env {FORCE_TTY: \"0\"} { $r | rstr to-ansi })
print ($via_flatten == $via_to_ansi)
"
   expected: "true"}

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
