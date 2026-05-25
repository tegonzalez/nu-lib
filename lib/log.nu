# log.nu — diagnostic logging to stderr
# Level hierarchy (ascending verbosity): error warn info debug trace
# Controlled by $env.NU_LOG_LEVEL (default: "warn"); stdout is never touched.
# Set via script flag: myscript.nu --debug debug

export def level-int [lvl: string] {
  match $lvl {
    "error" => 1
    "warn"  => 2
    "info"  => 3
    "debug" => 4
    "trace" => 5
    _       => 0
  }
}

def emit [lvl: string, msg: string] {
  let configured = ($env | get NU_LOG_LEVEL? | default "warn")
  if (level-int $lvl) <= (level-int $configured) {
    print -e $"[($lvl | str upcase)] ($msg)"
  }
}

export def "log error" [msg: string] { emit "error" $msg }
export def "log warn"  [msg: string] { emit "warn"  $msg }
export def "log info"  [msg: string] { emit "info"  $msg }
export def "log debug" [msg: string] { emit "debug" $msg }
export def "log trace" [msg: string] { emit "trace" $msg }
