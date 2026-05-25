#!/usr/bin/env nu

use ../test.nu *
use ../tui.nu *

def cases [] { [

  {name: "tui-is-tty-force-true"
   iut: {|_|
     with-env {FORCE_TTY: "1"} { tui-is-tty }
   }
   input: null
   expected: true
   runner: "value"}

  {name: "tui-is-tty-force-false"
   iut: {|_|
     with-env {FORCE_TTY: "0"} { tui-is-tty }
   }
   input: null
   expected: false
   runner: "value"}

  {name: "tui-is-tty-unset-returns-bool"
   iut: {|_|
     # Without FORCE_TTY, result depends on terminal; just verify it returns a bool
     let result = (with-env {} { tui-is-tty })
     ($result | describe) == "bool"
   }
   input: null
   expected: true
   runner: "value"}

  {name: "tui-columns-env"
   iut: {|_|
     with-env {COLUMNS: "99"} { tui-columns }
   }
   input: null
   expected: 99
   runner: "value"}

  {name: "tui-columns-returns-int-or-null"
   iut: {|_|
     let d = (tui-columns | describe)
     $d == "int" or $d == "nothing"
   }
   input: null
   expected: true
   runner: "value"}

  {name: "tui-truncate-exact-width-unchanged"
   iut: {|_|
     tui-truncate "hello" 5
   }
   input: null
   expected: "hello"
   runner: "value"}

  {name: "tui-truncate-under-width-unchanged"
   iut: {|_|
     tui-truncate "hi" 10
   }
   input: null
   expected: "hi"
   runner: "value"}

  {name: "tui-truncate-over-width-ellipsis"
   iut: {|_|
     tui-truncate "hello world" 8
   }
   input: null
   expected: "hello w…"
   runner: "value"}

  {name: "tui-truncate-over-width-length"
   iut: {|_|
     # tui-truncate uses str length (byte count) internally.
     # "hello world" truncated at 8 → "hello w" (7 bytes) + "…" (3 bytes) = 10 bytes str length,
     # but grapheme count = 8. Verify it appended an ellipsis and the grapheme count is width.
     let result = (tui-truncate "hello world" 8)
     ($result | split chars | length) == 8
   }
   input: null
   expected: true
   runner: "value"}

  {name: "tui-truncate-unicode"
   iut: {|_|
     # Multi-byte chars: "café" is 4 chars; truncate at 3 → "ca…"
     tui-truncate "café" 3
   }
   input: null
   expected: "ca…"
   runner: "value"}

  {name: "tui-truncate-unicode-exact"
   iut: {|_|
     # tui-truncate uses str length (byte count): "café" = 5 bytes (é is 2 bytes).
     # Passing width=5 (byte length) → string fits exactly → unchanged.
     tui-truncate "café" 5
   }
   input: null
   expected: "café"
   runner: "value"}

  {name: "tui-col-widths-proportional"
   iut: {|_|
     let maxes = {a: 10, b: 10, c: 20}
     let result = (tui-col-widths $maxes ["a" "b" "c"] 80)
     # a and b share equal proportion; c is double → c should be about 2× a
     let a = ($result | get a)
     let b = ($result | get b)
     let c = ($result | get c)
     ($a == $b) and ($c > $a)
   }
   input: null
   expected: true
   runner: "value"}

  {name: "tui-col-widths-min-floor"
   iut: {|_|
     # Very narrow available space — each col must still get at least 4
     let maxes = {a: 100, b: 100, c: 100}
     let result = (tui-col-widths $maxes ["a" "b" "c"] 3)
     let a = ($result | get a)
     let b = ($result | get b)
     let c = ($result | get c)
     ($a >= 4) and ($b >= 4) and ($c >= 4)
   }
   input: null
   expected: true
   runner: "value"}

  {name: "tui-col-widths-returns-record"
   iut: {|_|
     let maxes = {x: 20, y: 30}
     let result = (tui-col-widths $maxes ["x" "y"] 100)
     ($result | describe | str starts-with "record") and ("x" in ($result | columns)) and ("y" in ($result | columns))
   }
   input: null
   expected: true
   runner: "value"}

  {name: "tui-init-shape-panels"
   iut: {|_|
     let state = (tui-init [{name: "main", type: "flat"} {name: "log", type: "tail"}])
     "panels" in ($state | columns)
   }
   input: null
   expected: true
   runner: "value"}

  {name: "tui-init-shape-width"
   iut: {|_|
     let state = (with-env {COLUMNS: "80"} {
       tui-init [{name: "main", type: "flat"}]
     })
     $state.width == 80
   }
   input: null
   expected: true
   runner: "value"}

  {name: "tui-init-panel-names"
   iut: {|_|
     let state = (tui-init [{name: "top", type: "flat"} {name: "bottom", type: "tail"}])
     let names = ($state.panels | each {|p| $p.name})
     ("top" in $names) and ("bottom" in $names)
   }
   input: null
   expected: true
   runner: "value"}

  {name: "tui-init-empty-returns-prev"
   iut: {|_|
     let state = (tui-init)
     "prev" in ($state | columns)
   }
   input: null
   expected: true
   runner: "value"}

  {name: "tui-set-replaces-content"
   iut: {|_|
     let state = (tui-init [{name: "main", type: "flat"}])
     let s2 = (tui-set $state "main" ["line one" "line two"])
     let panel = ($s2.panels | where {|p| $p.name == "main"} | first)
     $panel.content == ["line one" "line two"]
   }
   input: null
   expected: true
   runner: "value"}

  {name: "tui-set-marks-dirty"
   iut: {|_|
     let state = (tui-init [{name: "main", type: "flat"}])
     let s2 = (tui-set $state "main" ["hello"])
     let panel = ($s2.panels | where {|p| $p.name == "main"} | first)
     $panel.dirty
   }
   input: null
   expected: true
   runner: "value"}

  {name: "tui-append-appends-content"
   iut: {|_|
     let state = (tui-init [{name: "log", type: "tail", height: 10}])
     let s2 = (tui-append $state "log" "first line")
     let s3 = (tui-append $s2 "log" "second line")
     let panel = ($s3.panels | where {|p| $p.name == "log"} | first)
     ($panel.content | length) == 2 and (($panel.content | last) == "second line")
   }
   input: null
   expected: true
   runner: "value"}

  {name: "tui-append-marks-dirty"
   iut: {|_|
     let state = (tui-init [{name: "log", type: "tail", height: 5}])
     let s2 = (tui-append $state "log" "a line")
     let panel = ($s2.panels | where {|p| $p.name == "log"} | first)
     $panel.dirty
   }
   input: null
   expected: true
   runner: "value"}

  {name: "tui-label-replaces-content"
   iut: {|_|
     let state = (tui-init [{name: "status", type: "label"}])
     let s2 = (tui-label $state "status" "running")
     let panel = ($s2.panels | where {|p| $p.name == "status"} | first)
     $panel.content == ["running"]
   }
   input: null
   expected: true
   runner: "value"}

  {name: "tui-label-marks-dirty"
   iut: {|_|
     let state = (tui-init [{name: "status", type: "label"}])
     let s2 = (tui-label $state "status" "idle")
     let panel = ($s2.panels | where {|p| $p.name == "status"} | first)
     $panel.dirty
   }
   input: null
   expected: true
   runner: "value"}

  {name: "tui-append-ring-buffer"
   iut: {|_|
     # Panel height = 3 — appending 5 lines should leave only last 3
     let state = (tui-init [{name: "log", type: "tail", height: 3}])
     let s2 = (tui-append $state "log" "line1")
     let s3 = (tui-append $s2 "log" "line2")
     let s4 = (tui-append $s3 "log" "line3")
     let s5 = (tui-append $s4 "log" "line4")
     let s6 = (tui-append $s5 "log" "line5")
     let panel = ($s6.panels | where {|p| $p.name == "log"} | first)
     ($panel.content | length) == 3 and ($panel.content | first) == "line3" and ($panel.content | last) == "line5"
   }
   input: null
   expected: true
   runner: "value"}

  {name: "tui-set-unknown-name-error"
   iut: {|_|
     let state = (tui-init [{name: "main", type: "flat"}])
     tui-set $state "nonexistent" ["data"]
   }
   input: null
   expected: "tui-set: unknown panel 'nonexistent'"
   runner: "throws"}

  {name: "tui-append-unknown-name-error"
   iut: {|_|
     let state = (tui-init [{name: "log", type: "tail"}])
     tui-append $state "nonexistent" "data"
   }
   input: null
   expected: "tui-append: unknown panel 'nonexistent'"
   runner: "throws"}

  {name: "tui-label-unknown-name-error"
   iut: {|_|
     let state = (tui-init [{name: "status", type: "label"}])
     tui-label $state "nonexistent" "value"
   }
   input: null
   expected: "tui-label: unknown panel 'nonexistent'"
   runner: "throws"}

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
