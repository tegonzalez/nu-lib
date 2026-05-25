#!/usr/bin/env nu

use ../test.nu *
use ../pool.nu *

# ── Tests ─────────────────────────────────────────────────────────────────────
#
# Tests that spawn actual Nu jobs use runner "stdio": the nu_src string is
# passed to ^nu -c, which sets up temp fixture scripts, calls pool-run, and
# prints the result as NUON.  The test compares trimmed stdout to the expected
# NUON string.
#
# The empty-files test uses runner "value" because no child processes are
# needed — pool-run returns the init acc immediately.

def cases [] { [

  # ── seq-01: sequential (--jobs 1) correctness ─────────────────────────────
  # Three fixture scripts print 1, 2, 3.  Expected accumulated sum = 6.
  {
    name: "seq-01-jobs-1-correct-sum"
    runner: "stdio"
    nu_src: "use nu-lib/lib/pool.nu *; let dir = (mktemp -d); let fa = ($dir | path join 'a.nu'); let fb = ($dir | path join 'b.nu'); let fc = ($dir | path join 'c.nu'); \"#!/usr/bin/env nu\\ndef main [--format: string = 'jsonl'] { print 1 }\" | save --force $fa; \"#!/usr/bin/env nu\\ndef main [--format: string = 'jsonl'] { print 2 }\" | save --force $fb; \"#!/usr/bin/env nu\\ndef main [--format: string = 'jsonl'] { print 3 }\" | save --force $fc; [$fa $fb $fc] | each {|f| chmod +x $f} | ignore; let parse = {|file out| if $out.exit_code != 0 { [{kind: 'error', file: $file}] } else { [{kind: 'value', n: ($out.stdout | str trim | into int)}] } }; let step = {|acc ev| if $ev.kind == 'value' { $acc | upsert sum ($acc.sum + $ev.n) } else { $acc | upsert errors ($acc.errors + 1) } }; let result = pool-run [$fa $fb $fc] [] $step --jobs 1 --init {sum: 0, errors: 0} --parse $parse; print ($result | to nuon); rm -rf $dir"
    expected: "{sum: 6, errors: 0}"
  }

  # ── par-01: parallel (--jobs 4) produces same result as --jobs 1 ──────────
  # Same three fixture scripts, run with 4 parallel slots.
  # Counters are order-independent; expected sum = 6.
  {
    name: "par-01-jobs-4-same-as-jobs-1"
    runner: "stdio"
    nu_src: "use nu-lib/lib/pool.nu *; let dir = (mktemp -d); let fa = ($dir | path join 'a.nu'); let fb = ($dir | path join 'b.nu'); let fc = ($dir | path join 'c.nu'); \"#!/usr/bin/env nu\\ndef main [--format: string = 'jsonl'] { print 1 }\" | save --force $fa; \"#!/usr/bin/env nu\\ndef main [--format: string = 'jsonl'] { print 2 }\" | save --force $fb; \"#!/usr/bin/env nu\\ndef main [--format: string = 'jsonl'] { print 3 }\" | save --force $fc; [$fa $fb $fc] | each {|f| chmod +x $f} | ignore; let parse = {|file out| if $out.exit_code != 0 { [{kind: 'error', file: $file}] } else { [{kind: 'value', n: ($out.stdout | str trim | into int)}] } }; let step = {|acc ev| if $ev.kind == 'value' { $acc | upsert sum ($acc.sum + $ev.n) } else { $acc | upsert errors ($acc.errors + 1) } }; let result = pool-run [$fa $fb $fc] [] $step --jobs 4 --init {sum: 0, errors: 0} --parse $parse; print ($result | to nuon); rm -rf $dir"
    expected: "{sum: 6, errors: 0}"
  }

  # ── fault-01: worker exits 1 → error event; pool-run completes normally ───
  # One fixture script calls `exit 1`.  The parse closure maps non-zero exit
  # to an error event.  pool-run must not itself error; errors counter = 1.
  {
    name: "fault-01-worker-exit-1-produces-error-event"
    runner: "stdio"
    nu_src: "use nu-lib/lib/pool.nu *; let dir = (mktemp -d); let ff = ($dir | path join 'fail.nu'); \"#!/usr/bin/env nu\\ndef main [--format: string = 'jsonl'] { exit 1 }\" | save --force $ff; chmod +x $ff; let parse = {|file out| if $out.exit_code != 0 { [{kind: 'error', file: $file}] } else { [{kind: 'value', n: ($out.stdout | str trim | into int)}] } }; let step = {|acc ev| if $ev.kind == 'value' { $acc | upsert sum ($acc.sum + $ev.n) } else { $acc | upsert errors ($acc.errors + 1) } }; let result = pool-run [$ff] [] $step --jobs 1 --init {sum: 0, errors: 0} --parse $parse; print ($result | to nuon); rm -rf $ff"
    expected: "{sum: 0, errors: 1}"
  }

  # ── empty-01: empty files list → init acc returned unchanged ──────────────
  # No jobs are spawned; pool-run returns the init accumulator as-is.
  # Uses runner "value" — no child processes needed.
  {
    name: "empty-01-empty-files-returns-init-unchanged"
    iut: {|i|
      let parse = {|file out| [{kind: "value", n: 0}]}
      let step  = {|acc ev| $acc | upsert sum ($acc.sum + $ev.n)}
      pool-run $i.files $i.extra $step --jobs 1 --init $i.init --parse $parse
    }
    input: {
      files: []
      extra: []
      init:  {sum: 42, errors: 0}
    }
    expected: {sum: 42, errors: 0}
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
