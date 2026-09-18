# tcl-exec_extensions

Extended variants of the Tcl `exec` procedure.

## ttlexec - run a command with a time-to-live

```tcl
package require exec_extensions

set out [ttlexec 5000 aws ssm send-command --instance-ids i-123]
```

`ttlexec ?switches? ms args...` runs `args` like `exec` does, but gives it at
most `ms` milliseconds. It returns the command's standard output with a single
trailing newline stripped, and raises an error when the command cannot be
started, writes to standard error, exits with a non-zero status, or outlives the
limit. The error carries what the command said, composed the way `exec` composes
it: the output first, then standard error, and `child process exited abnormally`
only when standard error was silent.

### Switches

The switches `exec` takes, with the same meanings, in the same place - before
everything else:

```tcl
set out [ttlexec -keepnewline 5000 git log -1 --format=%H]
set out [ttlexec -ignorestderr 5000 curl -sS https://example.com]
```

* `-keepnewline` keeps the trailing newline instead of stripping it.
* `-ignorestderr` stops output on standard error from counting as a failure; it
  is passed through to the interpreter's own standard error rather than
  captured, again as `exec` does.
* `--` ends the switches, for a command whose name starts with a minus.

A negative time to live is still a time to live and not a bad switch: like zero,
it disables the limit.

### Redirections

`ttlexec` redirects standard error for its own bookkeeping, so a redirection it
appended would be the last one and would win. When the command already routes
standard error - `2>`, `2>>`, `2>@`, `2>@1`, `>&`, `>>&` or `|&`, with the
operator written separately or glued to the file name - nothing is appended and
nothing is captured, and the text goes where the caller sent it:

```tcl
set out [ttlexec 5000 mycmd 2> /tmp/mycmd.log]   ;# stderr to the log, not an error
set out [ttlexec 5000 mycmd 2>@1]                ;# stderr folded into the result
```

A redirected standard error never counts as a failure, the same as for `exec`; a
non-zero exit status still does. Standard output cannot be redirected, because
it is the pipe `ttlexec` reads.

On expiry the error message leads with the limit rather than with standard
error, because what stands at the top of that output is usually a shell
reporting the job this package has just killed. The error code is
`PIPE ETIMEOUT <message>`, and the child process
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
`tests/`: `loading`, `output`, `switches`, `redirect`, `errors`, `timeout`,
`terminate`, `cleanup`.

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
