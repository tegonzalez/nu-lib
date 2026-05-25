# pool.nu — bounded parallel job pool with message-passing
#
# Workers run as Nu jobs (job spawn). The main thread receives results via
# job recv (the main thread is always job ID 0). Workers send back to
# job send 0 when complete. On interrupt (Ctrl-C) the partial accumulator is
# returned with _interrupted: true so callers can do cleanup (e.g. TUI close).
#
# Interrupt design notes:
#   - Nu's interrupt flag stays set after being caught; catch closures cannot
#     mutate outer mut vars; and break/continue/pipelines are re-interrupted.
#   - Solution: catch blocks return plain values (no mutations); mutations happen
#     in the main loop body where simple assignments are safe; loop exits via
#     the while condition (not $interrupted) — no break needed.
#   - job kill is skipped after interrupt: workers are Nu threads and external
#     child processes in the same process group; both self-terminate when the
#     main process exits or when SIGINT is delivered to the group.

# Run a bounded parallel job pool over a list of files.
#
# Each worker spawns a child nu process for one file, captures its output
# via complete, then sends the result back to the main thread.
# The parse closure receives (file, complete-output) and must return a
# list of event records.  The step closure folds each event into the
# accumulator (init → acc₀).
#
# --jobs 0 (default) → use sys cpu | length as the slot count.
# --init  {} (default) → empty record as the zero accumulator.
# --parse must be supplied when the caller needs to handle events; without
#         it, events are ignored and the raw acc is returned unchanged.
#
# Returns the final accumulator record.
# On interrupt the record contains _interrupted: true.
export def pool-run [
    files:      list<string>  # files to process in parallel
    extra_args: list<string>  # extra args forwarded to each child nu invocation
    step:       closure       # {|acc ev| -> acc} — fold one event into the accumulator
    --jobs(-j): int = 0       # max parallel workers; 0 = cpu count
    --init:     record = {}   # zero accumulator
    --parse:    closure       # {|file out| -> list<record>} — parse complete output into events
] {

    # --- resolve slot count ---
    let n = if $jobs <= 0 {
        sys cpu | length
    } else {
        $jobs | into int  # safety net per OQ-1 (T4): value may arrive as string
    }

    # working copies
    mut pending = $files
    mut active_jids: list<int> = []
    mut acc = $init

    # --- inner helpers (closures) ---

    # Spawn one worker for file $f; capture its jid and return it.
    # The worker closure must capture $f and $extra_args by value.
    # try/catch guards prevent job-framework stderr noise when the main thread
    # is killed before receiving the result or when the subprocess is interrupted.
    let spawn_worker = {|f|
        job spawn {
            let jid = (job id)
            let out = try {
                (^nu $f --format jsonl ...$extra_args | complete)
            } catch {|e|
                {exit_code: 130, stdout: "", stderr: $e.msg}
            }
            try { {jid: $jid, file: $f, out: $out} | job send 0 }
        }
    }

    # --- initial slot fill ---
    while (($active_jids | length) < $n) and (($pending | length) > 0) {
        let f = ($pending | first)
        $pending = ($pending | skip 1)
        let jid = (do $spawn_worker $f)
        $active_jids = ($active_jids | append $jid)
    }

    # --- drain loop ---
    # Interrupt handling rules (see module header):
    #   - catch blocks return plain values; mutations happen in the main body.
    #   - No break: while condition (not $interrupted) exits the loop.
    #   - No job kill after interrupt: workers self-terminate on process exit.
    mut interrupted = false

    while (($active_jids | length) > 0) and (not $interrupted) {
        # Block until a worker result arrives.
        # catch returns {ok: false} to signal interrupt; no mutation inside catch.
        let recv_r = try {
            {ok: true, msg: (job recv)}
        } catch {
            {ok: false, msg: null}
        }

        if not $recv_r.ok {
            $interrupted = true
        } else {
            # Remove the completed job from the active list.
            let finished_jid = $recv_r.msg.jid
            $active_jids = ($active_jids | where {|id| $id != $finished_jid})

            # Parse the result into events and fold each one.
            # catch returns false to signal interrupt; $acc mutations inside try are safe.
            if $parse != null {
                let events = (do $parse $recv_r.msg.file $recv_r.msg.out)
                let step_ok = try {
                    for $ev in $events {
                        $acc = (do $step $acc $ev)
                    }
                    true
                } catch {|_| false}
                if not $step_ok { $interrupted = true }
            }

            # Fill the freed slot if pending files remain and not interrupted.
            if not $interrupted and ($pending | length) > 0 {
                let f = ($pending | first)
                $pending = ($pending | skip 1)
                let jid = (do $spawn_worker $f)
                $active_jids = ($active_jids | append $jid)
            }
        }
    }

    if $interrupted { $acc | upsert _interrupted true } else { $acc }
}
