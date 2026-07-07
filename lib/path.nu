# path.nu - resolved path identity helpers
#
# IO contract:
#   Query functions resolve filesystem paths for identity and display. Callers
#   keep user-facing lexical paths for output and use real_abs/identity only for
#   equality and containment decisions.

def is-rooted-path [p: string] {
  ($p | str starts-with "/") or ($p | str starts-with "~")
}

def base-logical-abs [base: any] {
  if $base == null {
    pwd | path expand --no-symlink
  } else if (($base | describe) | str starts-with "record") and ("logical_abs" in ($base | columns)) {
    $base.logical_abs
  } else {
    $base | into string | path expand --no-symlink
  }
}

# Resolve a path once into the two forms callers need:
# - logical_abs/lexical_abs: absolute path preserving the caller's symlink route
# - real_abs/identity: canonical filesystem identity for comparisons
export def resolve-path [
  raw: string
  --base: any
] {
  let raw_s = ($raw | into string)
  let joined = if (is-rooted-path $raw_s) {
    $raw_s
  } else {
    (base-logical-abs $base) | path join $raw_s
  }

  let lexical_abs = try { $joined | path expand --no-symlink } catch { $joined }
  let real_abs = try { $lexical_abs | path expand --strict } catch { null }

  {
    raw: $raw_s
    logical_abs: $lexical_abs
    lexical_abs: $lexical_abs
    real_abs: $real_abs
    identity: $real_abs
  }
}

export def same-path [left: record, right: record] {
  ($left.identity != null) and ($right.identity != null) and ($left.identity == $right.identity)
}

export def contains-path [base: record, target: record] {
  if ($base.identity == null) or ($target.identity == null) {
    return false
  }

  try {
    $target.identity | path relative-to $base.identity | ignore
    true
  } catch {
    false
  }
}

# Display target relative to base. Prefer the caller's lexical/logical route; if
# symlinks make lexical prefixes diverge while real containment still holds, use
# real identity only to compute the same relative display string.
export def relative-display [target: record, base: record] {
  let lexical_rel = try {
    $target.logical_abs | path relative-to $base.logical_abs
  } catch {
    null
  }

  if $lexical_rel != null {
    return $lexical_rel
  }

  if (contains-path $base $target) {
    let real_rel = try {
      $target.identity | path relative-to $base.identity
    } catch {
      null
    }
    if $real_rel != null {
      return $real_rel
    }
  }

  $target.logical_abs
}
