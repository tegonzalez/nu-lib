# md.nu — markdown parsing and processing utilities
#
# IO contract: pure — all functions accept raw markdown string via $in and return structured data.
# Callers are responsible for open --raw / save.
#
# Depends on: Nu built-in `from md` (AST) for structural parsing; regex via `parse -r` for line-level work.

const HEADING_RE = '^(?P<marks>#{1,6})\s+(?P<title>.*)$'

# Extract all headings as a structured table.
# Output: table of {line, level, title, slug}
#
# Example:
#   open --raw README.md | md headings
export def headings [] {
  $in
  | lines
  | enumerate
  | where {|row| $row.item =~ '^#{1,6}\s+'}
  | each {|row|
      let m = ($row.item | parse -r $HEADING_RE | first)
      {
        line:  ($row.index + 1)
        level: ($m.marks | str length)
        title: $m.title
        slug:  (
          $m.title
          | str downcase
          | str replace -a -r '[^a-z0-9\s-]' ''
          | str replace -a -r '\s+' '-'
          | str trim --char '-'
        )
      }
    }
}

# Parse YAML frontmatter from the top of a markdown file.
# Returns an empty record if no valid frontmatter block is found.
# Output: record
#
# Example:
#   open --raw doc.md | md frontmatter
export def frontmatter [] {
  let lines = ($in | lines)
  if ($lines | is-empty) or ($lines | first) != "---" { return {} }

  let rest = ($lines | skip 1)
  let close = ($rest | enumerate | where {|r| $r.item == "---"} | if ($in | is-empty) { null } else { first })
  if $close == null { return {} }

  $rest | first $close.index | str join "\n" | from yaml
}

# Split a markdown document into sections — one record per heading.
# Each section contains the heading metadata and its body text (trimmed).
# Output: table of {heading, level, line, content}
#
# Example:
#   open --raw README.md | md sections
export def sections [] {
  let lines = ($in | lines)
  let total = ($lines | length)

  let heading_positions = (
    $lines
    | enumerate
    | where {|r| $r.item =~ '^#{1,6}\s+'}
    | each {|r|
        let m = ($r.item | parse -r $HEADING_RE | first)
        {index: $r.index, line: ($r.index + 1), level: ($m.marks | str length), title: $m.title}
      }
  )

  if ($heading_positions | is-empty) { return [] }

  $heading_positions
  | enumerate
  | each {|h|
      let next_start = if ($h.index + 1) < ($heading_positions | length) {
        ($heading_positions | get ($h.index + 1)).index
      } else {
        $total
      }
      let body_start = $h.item.index + 1
      let body_count = $next_start - $body_start
      let content = if $body_count > 0 {
        $lines | skip $body_start | first $body_count | str join "\n" | str trim
      } else { "" }
      {
        heading: $h.item.title
        level:   $h.item.level
        line:    $h.item.line
        content: $content
      }
    }
}

# Extract fenced code blocks with their language tag and content.
# Output: table of {lang, line, code}
#
# Example:
#   open --raw script.md | md code-blocks
export def code-blocks [] {
  let lines = ($in | lines)

  let state = ($lines | enumerate | reduce --fold {blocks: [], open: null} {|row, s|
    let line = $row.item
    let idx  = $row.index

    if ($line =~ '^```') {
      if $s.open == null {
        let lang = ($line | str replace -r '^```' '' | str trim)
        $s | upsert open {lang: $lang, start_line: ($idx + 2), lines: []}
      } else {
        let block = {lang: $s.open.lang, line: $s.open.start_line, code: ($s.open.lines | str join "\n")}
        $s | upsert blocks ($s.blocks | append $block) | upsert open null
      }
    } else if $s.open != null {
      $s | upsert open ($s.open | upsert lines ($s.open.lines | append $line))
    } else {
      $s
    }
  })

  $state.blocks
}

# Extract all markdown links [text](url) with their line numbers.
# Output: table of {text, url, line}
#
# Example:
#   open --raw README.md | md links
export def links [] {
  $in
  | lines
  | enumerate
  | each {|row|
      $row.item
      | parse -r '\[(?P<text>[^\]]+)\]\((?P<url>[^)]+)\)'
      | each {|m| {text: $m.text, url: $m.url, line: ($row.index + 1)}}
    }
  | flatten
}

# Flatten the Nu `from md` AST to a stream of text node values.
# Useful for full-text extraction without line-level regex.
# Output: list<string>
#
# Example:
#   open --raw README.md | from md | md text-nodes
export def text-nodes [] {
  $in
  | each {|node|
      let self_text = if $node.type == "text" { [$node.attrs.value] } else { [] }
      let child_text = if ($node | get children? | default [] | is-not-empty) {
        $node.children | where {|c| $c.type == "text"} | each {|c| $c.attrs.value}
      } else { [] }
      $self_text ++ $child_text
    }
  | flatten
}

# Extract all **Key:** value pairs from raw markdown.
# Generic — caller owns the key string used for filtering.
# Output: table of {key, value, line}
#
# Example:
#   open --raw principle.md | md monikers | where key == "Brief" | first
export def monikers [] {
  $in | lines | enumerate
  | each {|r|
      $r.item
      | parse -r '^\*\*(?P<key>[^*]+):\*\*\s*(?P<value>.+)$'
      | each {|m| {key: $m.key, value: ($m.value | str trim), line: ($r.index + 1)}}
    }
  | flatten
}
