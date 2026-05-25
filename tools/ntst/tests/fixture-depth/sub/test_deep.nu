#!/usr/bin/env nu
# fixture: deep case (depth 2 below "module/")
use ../../../../../lib/test.nu *
def cases [] { [
  {name: "module/sub/gamma" iut: {|_| true} input: null expected: true runner: "value"}
] }
def main [--filter(-f): string = "", --tag(-t): string = "", --format: string = "text", --list(-l)] {
  if $list { cases | list-cases | to json | print; return }
  cases | run --filter $filter --tag $tag | report --format $format
}
