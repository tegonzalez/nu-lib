#!/usr/bin/env nu

use ../test.nu *
use ../path.nu *

def cleanup-symlink-tree [physical: string, link: string] {
  try { rm -rf $physical } catch {|_| }
  try { rm -f $link } catch {|_| }
}

def with-symlink-tree [body: closure] {
  let id = (random uuid)
  let physical = ("/tmp" | path join $"nu-lib-path-($id)")
  let link = ("/tmp" | path join $"nu-lib-path-link-($id)")
  let base = ($physical | path join "base")
  let sub = ($base | path join "sub")
  let file = ($sub | path join "test_path_fixture.nu")

  mkdir $sub
  "fixture" | save --force $file
  ^ln -s $base $link

  let result = try {
    do $body {physical: $physical, link: $link, base: $base, file: $file, logical_file: ($link | path join "sub" "test_path_fixture.nu")}
  } catch {|e|
    cleanup-symlink-tree $physical $link
    error make {msg: $e.msg}
  }

  cleanup-symlink-tree $physical $link
  $result
}

def cases [] { [

  {name: "path-resolve-preserves-logical-and-real-identity"
   iut: {|_|
     with-symlink-tree {|t|
       let base = (resolve-path $t.link)
       let target = (resolve-path "sub/test_path_fixture.nu" --base $base)
       [
         ($target.raw == "sub/test_path_fixture.nu")
         ($target.logical_abs == $t.logical_file)
         ($target.lexical_abs == $t.logical_file)
         ($target.identity == $t.file)
         ($target.real_abs == $t.file)
       ] | all {|ok| $ok}
     }
   }
   input: null
   expected: true
   runner: "value"}

  {name: "path-resolve-tilde-is-rooted-before-base-join"
   iut: {|_|
     with-symlink-tree {|t|
       let base = (resolve-path $t.link)
       let target = (resolve-path "~/nu-lib-path-tilde-sentinel" --base $base)
       [
         ($target.raw == "~/nu-lib-path-tilde-sentinel")
         ($target.logical_abs == ($env.HOME | path join "nu-lib-path-tilde-sentinel"))
         (not ($target.logical_abs | str starts-with $t.link))
         (not ($target.logical_abs | str contains "/~/"))
       ] | all {|ok| $ok}
     }
   }
   input: null
   expected: true
   runner: "value"}

  {name: "path-same-and-contains-use-real-identity"
   iut: {|_|
     with-symlink-tree {|t|
       let base = (resolve-path $t.link)
       let logical = (resolve-path $t.logical_file)
       let physical = (resolve-path $t.file)
       (same-path $logical $physical) and (contains-path $base $physical)
     }
   }
   input: null
   expected: true
   runner: "value"}

  {name: "path-relative-display-falls-back-to-real-containment"
   iut: {|_|
     with-symlink-tree {|t|
       let base = (resolve-path $t.link)
       let physical = (resolve-path $t.file)
       relative-display $physical $base
     }
   }
   input: null
   expected: "sub/test_path_fixture.nu"
   runner: "value"}

] }

def main [--filter(-f): string = "", --tag(-t): string = "", --format: string = "text", --list(-l)] {
  if $list { cases | list-cases | to json | print; return }
  cases | run --filter $filter --tag $tag | report --format $format
}
