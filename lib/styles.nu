# styles.nu — two-tier style API: atoms and named aggregates

# Atoms — primitive ANSI attribute names
const ATOMS = [
  bold dim ul italic
  red green yellow blue magenta purple cyan
  bg-red bg-green bg-yellow bg-blue bg-magenta bg-cyan
]

# Aggregates — named styles composed of atom lists
const AGGREGATES = {
  h1:    [bold ul purple]
  h2:    [bold ul cyan]
  h3:    [bold yellow]
  h4:    [bold]
  h5:    [ul]
  h6:    [italic]
  error: [bold red]
  warn:  [bold yellow]
  ok:    [bold green]
  muted: [dim]
  key:   [bold cyan]
  val:   [dim]
}

# Collision check at module load time (runs when the module is `use`d)
export-env {
  for name in ($AGGREGATES | columns) {
    if $name in $ATOMS {
      error make {msg: $"styles: aggregate name '($name)' collides with an atom name"}
    }
  }
}

# Return the atom list for a style name.
# Atoms return a single-element list of themselves; aggregates return their atom list.
# Errors if the name is not found.
export def "styles get" [name: string] {
  if $name in $ATOMS {
    return [$name]
  }
  if $name in $AGGREGATES {
    return ($AGGREGATES | get $name)
  }
  error make {msg: $"styles: unknown style '($name)'"}
}

# Return true if the name is a known style (atom or aggregate), false otherwise.
export def "styles has" [name: string] {
  ($name in $ATOMS) or ($name in $AGGREGATES)
}

# Return the full style table with columns: name, atoms (list), kind (atom|aggregate).
export def "styles table" [] {
  let atom_rows = ($ATOMS | each {|a| {name: $a, atoms: [$a], kind: "atom"}})
  let agg_rows  = ($AGGREGATES | transpose name atoms | each {|r| {name: $r.name, atoms: $r.atoms, kind: "aggregate"}})
  $atom_rows | append $agg_rows
}

# Named semantic style palette.  Keys are stable names; values are {fg, bold} attribute records.
# tui-apply resolves a name through this record; tui-draw internals are unchanged.
export def tui-styles [] {
  {
    h1:    {fg: "purple",    bold: true}
    h2:    {fg: "blue",      bold: true}
    h3:    {fg: "cyan",      bold: false}
    h4:    {fg: "dark_gray", bold: false}
    dim:   {fg: "dark_gray", bold: false}
    ok:    {fg: "green",     bold: false}
    warn:  {fg: "yellow",    bold: false}
    error: {fg: "red",       bold: true}
  }
}

# Apply a named style to text.  Returns text unchanged (no error) when name is unknown.
export def tui-apply [name: string, text: string] {
  let s = (tui-styles | get -o $name)
  if $s == null { return $text }
  let bold_on = if ($s | get bold? | default false) { (ansi attr_bold) } else { "" }
  $"($bold_on)(ansi ($s.fg))($text)(ansi reset)"
}

# Apply a list of atom name strings as ANSI codes to text.
# Unknown atoms are silently ignored. Empty list returns text unchanged.
export def tui-atoms [atoms: list<string>, text: string] {
  let atom_map = {
    bold:       (ansi attr_bold)
    dim:        (ansi attr_dimmed)
    ul:         (ansi attr_underline)
    italic:     (ansi attr_italic)
    red:        (ansi red)
    green:      (ansi green)
    yellow:     (ansi yellow)
    blue:       (ansi blue)
    magenta:    (ansi magenta)
    purple:     (ansi purple)
    cyan:       (ansi cyan)
    bg-red:     (ansi bg_red)
    bg-green:   (ansi bg_green)
    bg-yellow:  (ansi bg_yellow)
    bg-blue:    (ansi bg_blue)
    bg-magenta: (ansi bg_magenta)
    bg-cyan:    (ansi bg_cyan)
  }
  let codes = ($atoms | each {|a| $atom_map | get -o $a } | compact | str join "")
  if ($codes | is-empty) {
    $text
  } else {
    $"($codes)($text)(ansi reset)"
  }
}
