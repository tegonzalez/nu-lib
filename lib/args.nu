# args.nu — argument processing utilities
#
# IO contract: pure (no filesystem access); usage/help may consult render's TTY
# resolver through render walk; cmd-dto may emit usage + exit on validation
# failure (the one permitted stdio in this module).
#
# Consumer surface (record-via-api): dispatch, cmd-dto, cmd-usage, usage,
# cmd-help, usage-rope, cmd-help-rope, global-dto, parse-global, strip-global,
# split-chain, parse-segment, parse-chain. Unlike pat/rope/render/rstr/tui
# (function-only, opaque records),
# args' DTO records ARE the api — fields like dto.args.<positional>,
# dto.flags.<flag>, dto.global.<flag> are the documented consumer interface.
# Field access on DTOs is correct and expected; field access on records
# returned by function-only modules is not.
#
# Patterns:
#   - Native Nu subcommands: prefer `def "main sub"` for known commands at parse time
#   - Dynamic dispatch (this module): use when handlers are data-driven or built at runtime

use ./render.nu
use ./rope.nu *
use ./rstr.nu *

# Dispatch a subcommand name to a handler closure in a record map.
# Each handler receives the remaining args list as its single argument.
#
# Example:
#   let handlers = {
#     add:    {|args| $"Adding ($args | str join ', ')"}
#     remove: {|args| $"Removing ($args | first)"}
#   }
#   dispatch "add" $handlers ["foo" "bar"]
export def dispatch [
  cmd: string        # subcommand name
  handlers: record   # record mapping command name -> closure(list -> any)
  args: list = []    # remaining args passed to the handler
] {
  if $cmd in ($handlers | columns) {
    do ($handlers | get $cmd) $args
  } else {
    error make {msg: $"Unknown command '($cmd)'. Available: ($handlers | columns | str join ', ')"}
  }
}

# Validate a parsed subcommand against its spec entry and return a normalized DTO.
# Exits with usage output if any required positional arg is null.
# Required args: spec entry has no trailing `?`. Optional: trailing `?` (e.g. "path?").
# Returns: {command: string, args: record, global: record}
export def cmd-dto [
  spec:   record  # full CLI spec
  name:   string  # subcommand name
  args:   record  # positional args as a named record {path: $path, ...}
  global: record  # global flags {format, verbose, ...}
] {
  let matches  = ($spec | get commands? | default [] | where name == $name)
  let cmd_spec = if ($matches | is-empty) { null } else { $matches | first }
  if $cmd_spec == null {
    print $"Error: unknown command '($name)'"
    print (usage $spec)
    exit 1
  }
  let required = ($cmd_spec | get args? | default [] | where {|a| not ($a | str ends-with "?")})
  for req in $required {
    if ($args | get $req) == null {
      print (cmd-usage $spec $name)
      exit 1
    }
  }
  {command: $name, args: $args, global: $global}
}

# Produce a single-line usage string for one named command within a spec.
export def cmd-usage [spec: record, name: string] {
  let cmd = ($spec.commands | where name == $name | first)
  let arg_str = ($cmd | get args? | default [] | each {|a| arg-token $a} | str join " ")
  let spc = if ($arg_str | is-not-empty) { " " } else { "" }
  $"Usage: ($spec.name) ($name)($spc)($arg_str)"
}

# Format one positional arg token for usage text.
def arg-token [arg: string] {
  $"<($arg)>"
}

# Format one flag declaration for usage/help tables.
def flag-token [f: record] {
  let short = if ($f | get short? | default "" | is-not-empty) {
    $"-($f.short), --($f.name)"
  } else {
    $"--($f.name)"
  }
  let val = if ($f | get value? | default "" | is-not-empty) {
    $" <($f.value)>"
  } else {
    ""
  }
  $"($short)($val)"
}

# Format one command declaration for usage/help tables.
def command-token [c: record] {
  let arg_str = ($c | get args? | default [] | each {|a| arg-token $a} | str join " ")
  if ($arg_str | is-empty) {
    $c.name
  } else {
    $"($c.name) ($arg_str)"
  }
}

# Format the usage-table fields for one command declaration.
def command-fields [c: record] {
  let flags = ($c | get flags? | default [] | each {|f| flag-token $f} | str join "; ")
  let examples = ($c | get examples? | default [] | str join (char nl))
  let base = {description: $c.description}
  let with_flags = if ($flags | is-empty) { $base } else { $base | insert flags $flags }
  if ($examples | is-empty) { $with_flags } else { $with_flags | insert examples $examples }
}

# Produce a render-spec rope for global usage from a command specification record.
#
# Spec shape:
#   {
#     name: string
#     description: string
#     global_flags?: list of {name, short?, value?, description}
#     commands?: list of {name, args?: list<string>, description}
#   }
export def usage-rope [spec: record] {
  let global_flags = ($spec | get global_flags? | default [] | each {|f|
    {
      label: {flag: (flag-token $f | rstr of | rstr tag "key")}
      fields: {description: $f.description}
    }
  })

  let commands = ($spec | get commands? | default []
    | where {|c| not ($c | get hidden? | default false)}
    | each {|c|
      {
        label: {command: (command-token $c | rstr of | rstr tag "key")}
        fields: (command-fields $c)
      }
    })

  let children = []
    | append (if ($global_flags | is-empty) { [] } else { [{label: {section: "Global flags"}, children: $global_flags}] })
    | append (if ($commands | is-empty) { [] } else { [{label: {section: "Commands"}, children: $commands}] })

  [{
    label: {name: $spec.name}
    fields: {
      usage: $"($spec.name) [global flags] <command> [command flags]"
      description: $spec.description
    }
    children: $children
  }] | rope md-table --columns {
    flag: {justify: "left", weight: 0, clip: "none"}
    command: {justify: "left", weight: 0, clip: "none"}
    description: {justify: "left", weight: 1, clip: "rhs", min: 20}
    flags: {justify: "left", weight: 1, clip: "rhs", min: 12}
    examples: {justify: "left", weight: 1, clip: "rhs", min: 12}
  }
}

# Produce formatted usage from a command specification record.
export def usage [spec: record, cfg: record = {}] {
  usage-rope $spec | render walk $cfg
}

# Produce a command-level help rope for one named command.
# Pure function — no print, no exit. Callers own print/exit.
# Output contains: purpose line, usage line, flags table (if any), examples (if any).
export def cmd-help-rope [spec: record, name: string] {
  let matches = ($spec | get commands? | default [] | where name == $name)
  if ($matches | is-empty) {
    error make {msg: $"cmd-help: unknown command '($name)'"}
  }
  let cmd = $matches | first

  let flags = ($cmd | get flags? | default [] | each {|f|
    {
      label: {flag: (flag-token $f | rstr of | rstr tag "key")}
      fields: {description: $f.description}
    }
  })

  let examples = ($cmd | get examples? | default [] | each {|ex|
    {label: {example: ($ex | rstr of | rstr tag "muted")}}
  })

  let children = []
    | append (if ($flags | is-empty) { [] } else { [{label: {section: "Flags"}, children: $flags}] })
    | append (if ($examples | is-empty) { [] } else { [{label: {section: "Examples"}, children: $examples}] })

  [{
    label: {name: $cmd.name}
    fields: {
      usage: $"($spec.name) (command-token $cmd) [flags]"
      description: $cmd.description
    }
    children: $children
  }] | rope md-table --columns {
    flag: {justify: "left", weight: 0, clip: "none"}
    example: {justify: "left", weight: 1, clip: "none"}
    description: {justify: "left", weight: 1, clip: "rhs", min: 20}
  }
}

export def cmd-help [spec: record, name: string, cfg: record = {}] {
  cmd-help-rope $spec $name | render walk $cfg
}

# ── Generic spec-driven parsers ───────────────────────────────────────────────

# Normalize Nu-parsed global flag values using the spec's global_flags declarations.
# For each entry in spec.global_flags: if the corresponding key in parsed_globals is
# null or missing and the entry has a default, the default is applied.
# Bool flags (bool: true) resolve to false when absent, not null.
# Returns a flat record with one key per global_flags entry.
# Returns {} when spec has no global_flags key.
export def global-dto [
  spec:           record  # full CLI spec
  parsed_globals: record  # {format: $format, verbose: $verbose, ...}
] {
  let flags = ($spec | get global_flags? | default [])
  if ($flags | is-empty) { return {} }
  $flags | reduce --fold {} {|entry acc|
    let key = $entry.name
    let raw = ($parsed_globals | get --optional $key)
    let is_bool = ($entry | get bool? | default false)
    let val = if $is_bool {
      if ($raw == null or $raw == false) { false } else { $raw }
    } else {
      if $raw == null {
        ($entry | get default? | default null)
      } else {
        $raw
      }
    }
    $acc | insert $key $val
  }
}

def is-command-local-counted-short [
  cmd_spec: any
  short_body: string
] {
  if $cmd_spec == null { return false }
  if ($short_body | str length) == 0 { return false }

  let first_short = $short_body | str substring 0..<1
  let same_short = ($short_body | split chars | all {|c| $c == $first_short})
  if not $same_short { return false }

  let matches = ($cmd_spec | get flags? | default [] | where {|f|
    ((($f | get short? | default "") == $first_short)
      and (($f | get bool? | default false))
      and (($f | get counted? | default false)))
  })
  $matches | is-not-empty
}

# Parse global flag values from raw argv using the spec's global_flags declarations.
# Returns a record with one key per global_flags entry, with defaults applied for missing flags.
# Bool flags: presence of the token → true, absence → false.
# Value flags: the token immediately following the flag token is the value.
# Only standalone -x / --flag tokens are matched; set-form tokens (containing =) are ignored.
# Unknown tokens are skipped — they are left for parse-segment.
# Value flag with no following token errors: "missing value for --<name>".
export def parse-global [spec: record, argv: list<string>] {
  let flags = ($spec | get global_flags? | default [])

  # Build lookup maps: long name -> spec entry, short char -> spec entry
  let by_long  = $flags | reduce --fold {} {|f acc| $acc | insert $f.name $f}
  let by_short = $flags | reduce --fold {} {|f acc|
    let s = ($f | get short? | default "")
    if ($s | is-not-empty) { $acc | insert ($s | into string) $f } else { $acc }
  }
  let cmd_by_name = ($spec | get commands? | default [] | reduce --fold {} {|c acc| $acc | insert $c.name $c})

  let n = $argv | length

  # Walk argv collecting global flag values; skip tokens consumed as values
  # Implicit: --help / -h are always recognized without requiring spec declaration
  let collected = $argv | enumerate | reduce --fold {result: {}, skip_next: false, cmd_spec: null} {|item acc|
    if $acc.skip_next { return ($acc | upsert skip_next false) }

    let i   = $item.index
    let tok = $item.item
    let acc = if $tok == "!" {
      $acc | upsert cmd_spec null
    } else if $acc.cmd_spec == null and ($tok in ($cmd_by_name | columns)) {
      $acc | upsert cmd_spec ($cmd_by_name | get $tok)
    } else {
      $acc
    }

    # Set-form tokens (key=value) are never scanned for flags
    if ($tok | str contains "=") { return $acc }

    # Implicit --help / -h
    if $tok == "--help" or $tok == "-h" {
      return ($acc | upsert result ($acc.result | upsert help true))
    }

    if ($tok | str starts-with "--") and ($tok | str length) > 2 {
      let fname = $tok | str replace --regex '^--' ''
      if $fname in ($by_long | columns) {
        let fspec  = $by_long | get $fname
        let is_bool = ($fspec | get bool? | default false)
        if $is_bool {
          $acc | upsert result ($acc.result | upsert $fname true)
        } else {
          let next_idx = $i + 1
          if $next_idx >= $n {
            error make {msg: $"missing value for --($fname)"}
          }
          let next_tok = $argv | get $next_idx
          $acc
          | upsert result ($acc.result | upsert $fname $next_tok)
          | upsert skip_next true
        }
      } else { $acc }
    } else if ($tok | str starts-with "-") and ($tok | str length) == 2 {
      let schar = $tok | str replace --regex '^-' ''
      if (is-command-local-counted-short $acc.cmd_spec $schar) {
        $acc
      } else if $schar in ($by_short | columns) {
        let fspec  = $by_short | get $schar
        let fname  = $fspec.name
        let is_bool = ($fspec | get bool? | default false)
        if $is_bool {
          $acc | upsert result ($acc.result | upsert $fname true)
        } else {
          let next_idx = $i + 1
          if $next_idx >= $n {
            error make {msg: $"missing value for --($fname)"}
          }
          let next_tok = $argv | get $next_idx
          $acc
          | upsert result ($acc.result | upsert $fname $next_tok)
          | upsert skip_next true
        }
      } else { $acc }
    } else { $acc }
  }

  # Apply defaults for any flags not encountered in argv; always include implicit help
  let with_user_flags = if ($flags | is-empty) {
    $collected.result
  } else {
    $flags | reduce --fold $collected.result {|fspec acc|
      let key = $fspec.name
      if $key in ($acc | columns) {
        $acc
      } else {
        let is_bool = ($fspec | get bool? | default false)
        if $is_bool {
          $acc | insert $key false
        } else {
          $acc | insert $key ($fspec | get default? | default null)
        }
      }
    }
  }

  # Ensure help is always present
  if "help" in ($with_user_flags | columns) {
    $with_user_flags
  } else {
    $with_user_flags | insert help false
  }
}

# Return argv with global flag tokens removed.
# Bool flags: the single flag token is removed.
# Value flags: the flag token and its immediately following value token are removed.
# Set-form tokens (containing =) are never scanned — they pass through untouched.
# Unknown flags pass through untouched — do not error, leave in stream for parse-segment.
# After stripping, the result fed into split-chain produces the same segments as if the
# global flags were never present.
export def strip-global [spec: record, argv: list<string>] {
  let flags = ($spec | get global_flags? | default [])

  # Build lookup maps
  let by_long  = $flags | reduce --fold {} {|f acc| $acc | insert $f.name $f}
  let by_short = $flags | reduce --fold {} {|f acc|
    let s = ($f | get short? | default "")
    if ($s | is-not-empty) { $acc | insert ($s | into string) $f } else { $acc }
  }
  let cmd_by_name = ($spec | get commands? | default [] | reduce --fold {} {|c acc| $acc | insert $c.name $c})

  let n = $argv | length

  # Walk argv; build a set of indices to remove
  # Implicit: --help / -h are always stripped (bool, no following value consumed)
  let scan = $argv | enumerate | reduce --fold {remove: [], skip_next: false, cmd_spec: null} {|item acc|
    if $acc.skip_next { return ($acc | upsert skip_next false | upsert remove ($acc.remove | append $item.index)) }

    let i   = $item.index
    let tok = $item.item
    let acc = if $tok == "!" {
      $acc | upsert cmd_spec null
    } else if $acc.cmd_spec == null and ($tok in ($cmd_by_name | columns)) {
      $acc | upsert cmd_spec ($cmd_by_name | get $tok)
    } else {
      $acc
    }

    # Set-form tokens pass through
    if ($tok | str contains "=") { return $acc }

    # Implicit --help / -h: strip the single token
    if $tok == "--help" or $tok == "-h" {
      return ($acc | upsert remove ($acc.remove | append $i))
    }

    if ($tok | str starts-with "--") and ($tok | str length) > 2 {
      let fname = $tok | str replace --regex '^--' ''
      if $fname in ($by_long | columns) {
        let fspec   = $by_long | get $fname
        let is_bool = ($fspec | get bool? | default false)
        if $is_bool {
          $acc | upsert remove ($acc.remove | append $i)
        } else {
          let next_idx = $i + 1
          if $next_idx >= $n {
            error make {msg: $"missing value for --($fname)"}
          }
          $acc | upsert remove ($acc.remove | append $i) | upsert skip_next true
        }
      } else { $acc }
    } else if ($tok | str starts-with "-") and ($tok | str length) == 2 {
      let schar = $tok | str replace --regex '^-' ''
      if (is-command-local-counted-short $acc.cmd_spec $schar) {
        $acc
      } else if $schar in ($by_short | columns) {
        let fspec   = $by_short | get $schar
        let is_bool = ($fspec | get bool? | default false)
        if $is_bool {
          $acc | upsert remove ($acc.remove | append $i)
        } else {
          let next_idx = $i + 1
          if $next_idx >= $n {
            error make {msg: $"missing value for --($fspec.name)"}
          }
          $acc | upsert remove ($acc.remove | append $i) | upsert skip_next true
        }
      } else { $acc }
    } else { $acc }
  }

  let remove_set = $scan.remove
  $argv | enumerate | where {|item| not ($item.index in $remove_set)} | get item
}

# Split raw argv tokens on separator into per-command segments.
# ["run" "--glob" "*.nu" "!" "ls"] -> [["run" "--glob" "*.nu"] ["ls"]]
# Empty argv returns []. Trailing separator with no following tokens: trailing empty segment dropped.
# The separator itself never appears in any returned segment.
export def split-chain [
  argv:      list<string>
  separator: string = "!"
] {
  if ($argv | is-empty) { return [] }
  let segments = $argv | reduce --fold {current: [], result: []} {|token acc|
    if $token == $separator {
      {current: [], result: ($acc.result | append [$acc.current])}
    } else {
      {current: ($acc.current | append $token), result: $acc.result}
    }
  }
  let all = $segments.result | append [$segments.current]
  $all | where {|seg| not ($seg | is-empty)}
}

# Parse one [command_name, ...tokens] segment against the spec. Pure function.
# Output shape: {command: string, flags: record, args: record}
# Errors via error make — no print, no exit.
export def parse-segment [
  spec:    record
  segment: list<string>
] {
  if ($segment | is-empty) {
    error make {msg: "parse-segment: segment is empty"}
  }

  let first_tok  = $segment | first
  let all_cmds   = ($spec | get commands? | default [])
  let cmd_matches = ($all_cmds | where name == $first_tok)

  # When the first token is not a known command, try the fallback command.
  # The fallback command's entire segment (no name token consumed) becomes its positionals.
  let use_fallback = ($cmd_matches | is-empty)
  let fallback_name = if $use_fallback {
    $spec | get fallback_command? | default ($spec | get default_command? | default null)
  } else { null }
  if $use_fallback and $fallback_name == null {
    error make {msg: $"unknown command '($first_tok)'"}
  }

  let cmd_name  = if $use_fallback { $fallback_name } else { $first_tok }
  let fb_matches = if $use_fallback { $all_cmds | where name == $fallback_name } else { [] }
  if $use_fallback and ($fb_matches | is-empty) {
    error make {msg: $"fallback_command '($fallback_name)' not found in spec"}
  }
  let cmd_spec  = if $use_fallback { $fb_matches | first } else { $cmd_matches | first }
  let flag_specs = ($cmd_spec | get flags? | default [])
  let arg_specs  = ($cmd_spec | get args?  | default [])

  # Build lookup maps: long name -> spec, short char -> spec
  let by_long  = $flag_specs | reduce --fold {} {|f acc| $acc | insert $f.name $f}
  let by_short = $flag_specs | reduce --fold {} {|f acc|
    let s = ($f | get short? | default "")
    if ($s | is-not-empty) { $acc | insert $s $f } else { $acc }
  }

  # Walk tokens; for fallback commands the full segment is tokens (no name consumed)
  let tokens = if $use_fallback { $segment } else { $segment | skip 1 }
  let n = $tokens | length

  let parsed = $tokens | enumerate | reduce --fold {flags: {}, pos: [], idx: 0} {|item acc|
    let i = $item.index
    let tok = $item.item
    if $i < $acc.idx {
      $acc
    } else if ($tok | str starts-with "--") {
      # Long flag
      let fname = $tok | str replace --regex '^--' ''
      # Reject --flag=value inline form
      if ($fname | str contains "=") {
        error make {msg: $"--flag=value inline form is not supported: ($tok)"}
      }
      # Implicit --help
      if $fname == "help" {
        return ($acc | upsert flags ($acc.flags | upsert help true) | upsert idx ($i + 1))
      }
      if not ($fname in ($by_long | columns)) {
        error make {msg: $"unknown flag --($fname) for command '($cmd_name)'"}
      }
      let fspec = $by_long | get $fname
      let is_bool = ($fspec | get bool? | default false)
      let is_counted_bool = $is_bool and (($fspec | get counted? | default false)) and (($fspec | get short? | default "" | is-not-empty))
      if $is_bool {
        let val = if $is_counted_bool { 1 } else { true }
        $acc | upsert flags ($acc.flags | insert $fname $val) | upsert idx ($i + 1)
      } else {
        let next_idx = $i + 1
        if $next_idx >= $n {
          error make {msg: $"flag --($fname) requires a value but none was provided"}
        }
        let next = $tokens | get $next_idx
        if ($next | str starts-with "-") {
          error make {msg: $"flag --($fname) requires a value but got '($next)'"}
        }
        $acc | upsert flags ($acc.flags | insert $fname $next) | upsert idx ($next_idx + 1)
      }
    } else if ($tok | str starts-with "-") and ($tok | str length) > 1 {
      # Short flag
      let schar = $tok | str replace --regex '^-' ''
      let short_len = ($schar | str length)
      let first_short = $schar | str substring 0..<1
      let same_short = ($schar | split chars | all {|c| $c == $first_short})
      let counted_fspec = if $first_short in ($by_short | columns) { $by_short | get $first_short } else { null }
      let is_counted_short = (
        $counted_fspec != null
        and (($counted_fspec | get bool? | default false))
        and (($counted_fspec | get counted? | default false))
        and (($counted_fspec | get short? | default "" | is-not-empty))
      )
      # Reject combined short flags like -vf, except same-short counted bools like -ff.
      if ($schar | str length) > 1 {
        if $short_len == 2 and $same_short and $is_counted_short {
          return ($acc | upsert flags ($acc.flags | insert $counted_fspec.name $short_len) | upsert idx ($i + 1))
        } else {
          error make {msg: $"combined short flags are not supported: ($tok)"}
        }
      }
      # Implicit -h (help)
      if $schar == "h" {
        return ($acc | upsert flags ($acc.flags | upsert help true) | upsert idx ($i + 1))
      }
      if not ($schar in ($by_short | columns)) {
        error make {msg: $"unknown flag -($schar) for command '($cmd_name)'"}
      }
      let fspec = $by_short | get $schar
      let fname = $fspec.name
      let is_bool = ($fspec | get bool? | default false)
      let is_counted_bool = $is_bool and (($fspec | get counted? | default false)) and (($fspec | get short? | default "" | is-not-empty))
      if $is_bool {
        let val = if $is_counted_bool { 1 } else { true }
        $acc | upsert flags ($acc.flags | insert $fname $val) | upsert idx ($i + 1)
      } else {
        let next_idx = $i + 1
        if $next_idx >= $n {
          error make {msg: $"flag -($schar) requires a value but none was provided"}
        }
        let next = $tokens | get $next_idx
        if ($next | str starts-with "-") {
          error make {msg: $"flag -($schar) requires a value but got '($next)'"}
        }
        $acc | upsert flags ($acc.flags | insert $fname $next) | upsert idx ($next_idx + 1)
      }
    } else {
      # Positional arg
      $acc | upsert pos ($acc.pos | append $tok) | upsert idx ($i + 1)
    }
  }

  # Apply bool flag defaults (false) and value flag defaults
  let flags_with_defaults = $flag_specs | reduce --fold $parsed.flags {|fspec acc|
    let fname = $fspec.name
    if ($fname in ($acc | columns)) {
      $acc
    } else {
      let is_bool = ($fspec | get bool? | default false)
      if $is_bool {
        let is_counted_bool = (($fspec | get counted? | default false)) and (($fspec | get short? | default "" | is-not-empty))
        let val = if $is_counted_bool { 0 } else { false }
        $acc | insert $fname $val
      } else {
        let def = ($fspec | get default? | default null)
        $acc | insert $fname $def
      }
    }
  }

  # Ensure implicit help is always present in flags output
  let flags_final = if "help" in ($flags_with_defaults | columns) {
    $flags_with_defaults
  } else {
    $flags_with_defaults | insert help false
  }

  # Map positional tokens to arg spec names
  let pos_tokens = $parsed.pos
  let args_record = $arg_specs | enumerate | reduce --fold {} {|item acc|
    let idx = $item.index
    let aname_raw = $item.item
    let is_optional = ($aname_raw | str ends-with "?")
    let aname = if $is_optional { $aname_raw | str replace --regex '\?$' '' } else { $aname_raw }
    let val = $pos_tokens | get --optional $idx
    if $val == null and (not $is_optional) {
      error make {msg: $"required positional arg <($aname)> missing for command '($cmd_name)'"}
    }
    $acc | insert $aname $val
  }

  {command: $cmd_name, flags: $flags_final, args: $args_record}
}

# Compose split-chain and parse-segment. Returns a list of command_dto records.
# Empty argv returns []. Single command returns a list of length 1.
# Stop on first parse-segment failure — the error propagates.
# Uses a for loop (not each) so errors from parse-segment propagate unwrapped.
export def parse-chain [
  spec:      record
  argv:      list<string>
  separator: string = "!"
] {
  if ($argv | is-empty) { return [] }
  let segments = split-chain $argv $separator
  mut result = []
  for seg in $segments {
    $result = ($result | append (parse-segment $spec $seg))
  }
  $result
}
