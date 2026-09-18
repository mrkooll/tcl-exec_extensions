# tcl-exec_extensions

Extended variants of the Tcl `exec` procedure.

## ttlexec - run a command with a time-to-live

```tcl
package require exec_extensions

set out [ttlexec 5000 aws ssm send-command --instance-ids i-123]
```

`ttlexec ms args...` runs `args` like `exec` does, but gives it at most `ms`
milliseconds. It returns the command's standard output with a single trailing
newline stripped, and raises an error when the command cannot be started,
writes to standard error, exits with a non-zero status, or outlives the limit.

On expiry the error code is `PIPE ETIMEOUT <message>`, and the child process
together with every descendant it left behind is terminated (`SIGTERM`, then
`SIGKILL` after `$::exec_extensions::kill_grace` milliseconds).

The command is also available as `::exec_extensions::ttlexec`; the global
`::ttlexec` is an alias kept for convenience.

`ttlexec` waits inside a nested event loop (`vwait`), so it must not be called
from a handler that is itself running under the same `vwait`.

## exec_extensions::terminate - kill a process tree

```tcl
::exec_extensions::terminate [list $pid1 $pid2]
```

Terminates the given process ids and all of their descendants, deepest first,
with the same `SIGTERM` then `SIGKILL` sequence `ttlexec` uses on expiry.
Useful for cleaning up pipes opened directly with `open |...`.

## Requirements

Tcl 8.6, and a `ps` that understands `ps -Ao pid=,ppid=` (Linux and macOS do)
for the descendant walk. Without it only the direct children are signalled.

## Tests

The suite uses `tcltest`, which ships with Tcl, and is grouped by theme in
`tests/`: `loading`, `output`, `errors`, `timeout`, `terminate`, `cleanup`.

```sh
tclsh tests/all.tcl                    # everything
tclsh tests/all.tcl -file timeout.test # one theme
tclsh tests/all.tcl -match timeout-2.* # one group of cases
tclsh tests/all.tcl -verbose pbst      # show passing cases as well
```

The runner exits non-zero when anything failed. Each file also runs on its own
(`tclsh tests/timeout.test`). The cases that look for surviving processes are
constrained to Unix, and read the process table with `ps`.

## Changes in 1.1

* `pkgIndex.tcl` announced `extexec` while the file provided
  `exec_extensions`, so `package require` could not load the package at all.
* A non-zero exit status and anything the child wrote to standard error are
  now reported to the caller instead of being printed to the terminal, which
  makes `ttlexec` a drop-in replacement for `exec`.
* On expiry the child's descendants are terminated as well; previously the
  pipe was closed and the processes were left running.
* Blank lines are no longer dropped from the output, and output that does not
  end in a newline is no longer truncated.
* `ttlexec` is defined inside the `exec_extensions` namespace (it used to be
  defined globally, which made `namespace export` a no-op), and a global alias
  is installed for backwards compatibility.
