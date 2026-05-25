# fs.nu — filesystem queries and in-place editing
#
# IO contract:
#   Query functions (glob-files, find, grep): read-only IO — safe to compose in pipelines.
#   Mutating functions (edit-lines, edit-section): write IO — clearly noted, not composable.
#
# External deps: rg (ripgrep), fd — both expected on PATH.

# Find files matching a glob pattern. Returns structured metadata.
# Output: table of {path, name, ext, dir, type}
#
# Example:
#   fs glob-files "**/*.md"
#   fs glob-files "**/*.nu" --exclude "**/examples/**"
export def glob-files [
  pattern: string       # glob pattern e.g. "**/*.md"
  --exclude: string     # glob pattern to exclude
] {
  let results = if ($exclude | is-not-empty) {
    glob $pattern --exclude [$exclude]
  } else {
    glob $pattern
  }
  $results
  | each {|p|
      let parsed = ($p | path parse)
      {
        path: $p
        name: ($p | path basename)
        ext:  $parsed.extension
        dir:  ($p | path dirname)
        type: ($p | path type)
      }
    }
}

# Find files by name pattern using fd. Returns structured list.
# Output: table of {path, name, type}
#
# Example:
#   fs find "args" . --type f
#   fs find "" principles --ext md
export def find [
  pattern: string = ""  # filename pattern (empty = all)
  dir: string = "."     # root directory to search
  --type(-t): string = "f"   # f=file d=dir l=symlink
  --ext(-e): string          # filter by extension (without dot)
  --hidden(-H)               # include hidden files
] {
  let ext_args    = if ($ext | is-not-empty) { [--extension $ext] } else { [] }
  let hidden_args = if $hidden { [--hidden] } else { [] }

  ^fd --type $type ...$ext_args ...$hidden_args $pattern $dir
  | lines
  | where {|p| $p | is-not-empty}
  | each {|p|
      {
        path: $p
        name: ($p | path basename)
        type: ($p | path type)
      }
    }
}

# Search file contents using rg. Returns structured match records.
# Output: table of {file, line, text, matches}
#
# rg exit 0 = matches found, exit 1 = no matches (not an error), exit 2 = error.
#
# Example:
#   fs grep "export def" lib/nu
#   fs grep "TODO" . --glob "*.nu"
#   fs grep "pattern" . --case-insensitive
export def grep [
  pattern: string        # search pattern (regex)
  ...paths: string       # files or directories to search (default: .)
  --glob(-g): string     # restrict to files matching this glob e.g. "*.md"
  --case-insensitive(-i) # ignore case
  --fixed(-F)            # treat pattern as literal string, not regex
] {
  let glob_args = if ($glob | is-not-empty) { [--glob $glob] } else { [] }
  let ci_args   = if $case_insensitive { [--ignore-case] } else { [] }
  let fx_args   = if $fixed { [--fixed-strings] } else { [] }
  let path_args = if ($paths | is-empty) { ["."] } else { $paths }

  let result = (^rg --json ...$glob_args ...$ci_args ...$fx_args $pattern ...$path_args | complete)
  if $result.exit_code == 2 {
    error make {msg: $"rg error: ($result.stderr | str trim)"}
  }
  if $result.exit_code == 1 { return [] }

  $result.stdout
  | lines
  | where {|l| $l | is-not-empty}
  | each {|l| $l | from json}
  | where {|r| $r.type == "match"}
  | each {|r|
      {
        file:    $r.data.path.text
        line:    $r.data.line_number
        text:    ($r.data.lines.text | str trim)
        matches: ($r.data.submatches | each {|s| $s.match.text})
      }
    }
}

# [MUTATING IO] Transform each line of a file in-place via a closure.
# The closure receives a string and must return a string.
# A trailing newline is preserved.
#
# Example:
#   fs edit-lines myfile.txt {|l| $l | str replace "foo" "bar"}
export def edit-lines [
  file: path
  transform: closure   # {|line: string| -> string}
] {
  let original = (open --raw $file)
  let trailing  = if ($original | str ends-with "\n") { "\n" } else { "" }
  $original
  | lines
  | each $transform
  | str join "\n"
  | $"($in)($trailing)"
  | save --force $file
}

# [MUTATING IO] Replace the body of a named markdown section in-place.
# Finds the first heading whose title matches exactly, replaces content
# up to (but not including) the next heading at equal or higher level.
#
# Example:
#   fs edit-section README.md "Usage" "Run `./tool.nu help` to get started."
export def edit-section [
  file: path
  heading: string   # exact heading title text (without # marks)
  content: string   # replacement body (leading/trailing whitespace stripped)
] {
  let lines = (open --raw $file | lines)
  let re    = '^(?P<marks>#{1,6})\s+(?P<title>.*)$'

  let target = (
    $lines
    | enumerate
    | where {|r|
        let m = ($r.item | parse -r $re | if ($in | is-empty) { null } else { first })
        ($m != null) and ($m.title == $heading)
      }
    | if ($in | is-empty) { null } else { first }
  )

  if $target == null {
    error make {msg: $"Heading not found in ($file): ($heading)"}
  }

  let target_idx   = $target.index
  let target_marks = ($lines | get $target_idx | parse -r $re | first).marks
  let target_level = ($target_marks | str length)

  let next_idx = (
    $lines
    | enumerate
    | skip ($target_idx + 1)
    | where {|r|
        let m = ($r.item | parse -r $re | if ($in | is-empty) { null } else { first })
        ($m != null) and (($m.marks | str length) <= $target_level)
      }
    | if ($in | is-empty) { null } else { first }
  )

  let end_idx    = if $next_idx != null { $next_idx.index } else { $lines | length }
  let before     = if $target_idx > 0 { $lines | first $target_idx } else { [] }
  let after      = if $end_idx < ($lines | length) { $lines | skip $end_idx } else { [] }
  let heading_ln = ($lines | get $target_idx)
  let body       = ($content | str trim | lines)

  $before ++ [$heading_ln ""] ++ $body ++ [""] ++ $after
  | str join "\n"
  | save --force $file
}
