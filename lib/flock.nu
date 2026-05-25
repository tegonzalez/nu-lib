# Advisory mutex using atomic mkdir. Lock is a .lock/ directory beside the target file.
# Stale locks are reclaimed by mtime: if the lock dir is older than stale_ms, it is
# removed and the next waiter can acquire. This avoids any TOCTOU window from PID files.
use ../lib/log.nu *

const STALE_MS = 30_000  # reclaim locks held longer than this

# Run closure f under an exclusive lock on file.
# Throws on timeout. Releases lock on exception before re-throwing.
export def with-lock [
    file: path      # file being protected; lock dir is <file>.lock/
    timeout_ms: int # max wait in ms before error
    f: closure      # body to execute under lock
] {
    let lock = $"($file).lock"
    _acquire $lock $timeout_ms
    let result = (try {
        do $f
    } catch {|e|
        _release $lock
        error make {msg: $e.msg, label: {text: "flock acquire failed", span: (metadata $lock).span}}
    })
    _release $lock
    $result
}

def _acquire [lock: path, timeout_ms: int] {
    let deadline = ((date now | into int) + ($timeout_ms * 1_000_000))
    loop {
        if ((^mkdir $lock | complete).exit_code == 0) { return }
        _reclaim-stale $lock
        if ((date now | into int) > $deadline) {
            error make {msg: $"lock: timeout after ($timeout_ms)ms waiting for ($lock)"}
        }
        sleep 50ms
    }
}

def _release [lock: path] {
    try { rm --recursive --force $lock } catch {|e| log warn $"flock: rm lock failed: ($e.msg)" }
}

def _reclaim-stale [lock: path] {
    if not ($lock | path exists) { return }
    let row = (ls -l $lock | first?)
    if $row == null { return }
    let age_ms = (((date now) - ($row | get modified)) / 1ms)
    if $age_ms > $STALE_MS { _release $lock }
}
