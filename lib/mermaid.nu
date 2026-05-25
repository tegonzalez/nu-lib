# mermaid.nu — mermaid diagram object tree builders and flatten walker
#
# IO contract: pure — builders return record trees; flatten emits a string.
# No ANSI, no print, no external calls.
#
# Supported diagram types: mindmap
#
# Usage:
#   let diag = (mindmap (node "domains" $children))
#   $diag | flatten

const THEME_INIT = '%%{init: {"theme":"base","themeVariables":{"lineColor":"#999999"},"themeCSS":".mindmap path{stroke-width:1px;} .mindmap line{stroke-width:1px;}"}}%%'

# Create a mindmap node with an optional children list.
# Output: {label: string, children: list}
#
# Example:
#   node "meta" [(node "contract") (node "env")]
export def node [label: string, children: list = []] {
  {label: $label, children: $children}
}

# Wrap a root node into a mindmap diagram record.
# The root node's label renders as root((label)) in the flattened output.
# Output: {type: string, init: string, root: record}
#
# Example:
#   mindmap (node "domains" $children)
export def mindmap [root: record] {
  {type: "mindmap", init: $THEME_INIT, root: $root}
}

# Flatten a mermaid diagram tree to a string ready for fenced code block embedding.
# Input ($in): diagram record from `mindmap`
# Output: string
#
# Example:
#   $diag | flatten
#   $"```mermaid\n($diag | flatten)\n```"
export def flatten [] {
  let d = $in
  [$d.init "mindmap"]
  | append (node-lines $d.root 1 true)
  | str join "\n"
}

# Internal: DFS walker — emits indented lines for a node and its subtree.
def node-lines [nd: record, depth: int, is_root: bool] {
  let indent = ("" | fill -w ($depth * 2))
  let label_str = if $is_root { $"root\(\(($nd.label)\)\)" } else { $nd.label }
  let child_rows = ($nd.children | each {|c| node-lines $c ($depth + 1) false})
  let child_lines = ($child_rows | reduce --fold [] {|r acc| $acc ++ $r})
  [$"($indent)($label_str)"] ++ $child_lines
}
