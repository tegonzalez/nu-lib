#!/usr/bin/env nu
# 03-fs/patch.nu — in-place file editing
#
# Demonstrates: fs.nu mutating functions.
# Writes to files — run on copies or use --dry-run first.
# Try:
#   ./patch.nu lines README.md "foo" "bar" --dry-run
#   ./patch.nu section doc.md "Usage" "New body text here."
#   ./patch.nu lines myfile.txt "old" "new"

use ../../fs.nu *

def main [
  command?: string
  --dry-run(-n)   # preview changes without writing
] {
  try {
    if ($command == null) {
      print "Usage: patch.nu <command> [args]

Commands:
  lines <file> <find> <replace>     Replace all occurrences in every line
  section <file> <heading> <body>   Replace a markdown section body

Flags:
  -n, --dry-run   Show what would change without writing"
      return
    }
    error make {msg: "pass subcommand args — see usage above"}
  } catch {|e|
    print $"Error: ($e.msg)"
    exit 1
  }
}

def "main lines" [
  file: path
  find: string
  replace: string
  --dry-run(-n)
] {
  try {
    let original = (open --raw $file | lines)
    let patched  = ($original | each {|l| $l | str replace -a $find $replace})
    let changed  = ($original | zip $patched | where {|pair| $pair.0 != $pair.1} | length)

    if $dry_run {
      print $"Would change ($changed) line(s) in ($file)"
      $original | zip $patched | enumerate | where {|r| $r.item.0 != $r.item.1} | each {|r|
        print $"  line ($r.index + 1):"
        print $"    - ($r.item.0)"
        print $"    + ($r.item.1)"
      }
      return
    }

    edit-lines $file {|l| $l | str replace -a $find $replace}
    print $"Patched ($changed) line(s) in ($file)"
  } catch {|e|
    print $"Error: ($e.msg)"
    exit 1
  }
}

def "main section" [
  file: path
  heading: string
  body: string
  --dry-run(-n)
] {
  try {
    if $dry_run {
      print $"Would replace section '($heading)' in ($file) with:"
      print $body
      return
    }
    edit-section $file $heading $body
    print $"Updated section '($heading)' in ($file)"
  } catch {|e|
    print $"Error: ($e.msg)"
    exit 1
  }
}
