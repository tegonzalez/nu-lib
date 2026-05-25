# cg

TypeScript callgraph builder — extracts function-level call edges via ast-grep.

## Concept

`cg` performs a two-pass analysis of TypeScript source trees:

1. **Function pass** — finds all named function declarations and their line ranges.
2. **Call pass** — finds all call expressions; joins each call site to its enclosing function by line range.

Callees are namespaced when they resolve to a known project function; otherwise kept as raw identifiers. Method calls are partially type-resolved using parameter type annotations and explicitly-typed `const`/`let` declarations within the function's range.

## Requirements

- `sg` (ast-grep) on PATH — used for all source analysis passes.
- TypeScript source files (`.ts`); `.d.ts` declaration files are skipped by ast-grep.

## Namespace

Every function is identified as `namespace.funcName`. The namespace is derived from the source file's basename, relative to all other files in the analyzed path:

| Condition | Namespace |
|-----------|-----------|
| Unique basename | `basename-without-ext` |
| Basename collision | Path segments below the common ancestor joined by `.` |

**Example collision resolution:**
- `cli-args/src/reindex-cli.ts` → `cli-args.src.reindex-cli`
- `cli/src/reindex-cli.ts` → `cli.src.reindex-cli`

## Commands

```
cg [ls] <path> [pat] [-f format]
```

`ls` is the default command — it can be omitted when the first argument is a path.

### `ls <path> [pat]`

Analyzes the TypeScript files under `<path>` and emits two tables:

1. **File → namespace** mapping (which files are in scope).
2. **Call edges** — `caller`, `callee`, `line` (call site line, not function start).

Functions with no outgoing calls appear in the edges table with an empty `callee`.

**`pat`** is an optional pat-spec filter with two independent slots:

| Form | Effect |
|------|--------|
| `scope/` | Narrows to files whose namespace matches `scope` (regex); edges filtered to callers in those namespaces |
| `expr` | Greps edges where caller or callee matches `expr` (regex) |
| `scope/,expr` | Both filters applied |

Both slots are optional and can be combined. A bare word with no `/` is treated as an `expr` match.

**Examples:**

```sh
# All edges in the core package
cg done/parch/parch/core/src

# Edges from the sort namespace only
cg done/parch/parch/ sort/

# Edges involving sortDiagnostics anywhere (caller or callee)
cg done/parch/parch/ sortDiagnostics

# Sort namespace, only edges mentioning compareAscii
cg done/parch/parch/ "sort/,compareAscii"

# Full corpus, JSON output
cg done/parch/parch/ -f json
```

## Output

Output is rendered through rope composers and `render walk`:

- **`lf` (file→namespace table) and `seq` (edges table):** use `rope table | render walk` — flat column-aligned table output.
- **`tree` (call tree):** uses `rope tree | render walk` — indented tree output.

**Default (`rich`):** two bordered tables printed sequentially (file map + edges).

**`-f text`:** plain column-aligned text, no borders.

**`-f json`):** edges only, as a JSON array. Suitable for pipeline composability:

```sh
cg done/parch/parch/core/src -f json | from json | where callee == ""
```

## Known Limitations

- **Arrow functions** are not captured — only named `function` declarations.
- **Method call type resolution** is best-effort: parameter types and explicitly-typed locals are resolved; inferred types are not.
- **Single function name wins** in the namespace map when the same name appears in multiple files — cross-file dispatch resolution requires import analysis, which `cg` does not perform.
- **`sg` patterns match one structure per pass** — deeply nested or chained calls may not fully resolve.
