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

Captured standard error loses **all** of its trailing newlines, not the single
one standard output loses. It is only ever put into an error message, never
handed back as a value, so the blank lines at the end of it would be noise.

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

`SIGKILL` goes only to those processes that are still the same ones that were
sent `SIGTERM`. A descendant is nobody's child of the calling process, so the
system reaps it the moment it dies and its pid can be handed to somebody else
within the grace period; the start time read before the first signal is what
tells the two apart.

## Requirements

Tcl 8.6, which the package asks for itself and will refuse to load without:
`file tempfile`, used to capture standard error, arrived in that release.

Stopping a process and looking at one are not things Tcl can do on its own, so
the package borrows them from the system. Which way it borrows them is decided
once, as the package loads, by trying each candidate rather than by reading the
platform's name - a helper that answers correctly then will answer correctly
later, and one that is missing or speaks another dialect is passed over there
and then instead of failing in the middle of a timeout.

The outcome is left in two variables, for reading and, if need be, for forcing:

```tcl
puts $::exec_extensions::signaller   ;# kill | taskkill | none
puts $::exec_extensions::inspector   ;# proc | ps | tasklist | none
```

| | how it is found | what it gives |
|---|---|---|
| `kill` | `kill -0 <own pid>` succeeds | `SIGTERM`, then `SIGKILL`, over a subtree found by the inspector |
| `taskkill` | Windows, and `taskkill` on the path | `taskkill /PID <pid> /T`, then the same with `/F`; the system resolves the tree itself |
| `proc` | `/proc/<own pid>/stat` parses | parent and start time in clock ticks, and the run state, with nothing to fork |
| `ps` | `ps -Ao pid=,ppid=,lstart=` runs | the same, from `ps`, with the start time to the second |
| `tasklist` | Windows, and `tasklist` on the path | whether a pid is still running; no parent, which `taskkill /T` does not need |

`proc` is preferred over `ps` where both are there: it is a file to read rather
than a process to start, and its start time is precise to a clock tick instead
of to a second.

Either can come out `none`, which is a documented state and not an error. With
no signaller, `terminate` returns without doing anything and an expired command
is not stopped - its pipe is closed and it keeps running. With no inspector, no
descendants are found, a reused pid cannot be told from the process that held
it, and the liveness check answers "finished" for everything, which costs the
limit its hold on one kind of command: one that closes or redirects its own
standard output and then keeps running is waited for to the end, however long
that takes. Commands that hold their standard output open - almost all of them -
still expire on time.

### Windows

The Windows paths are written but **not tested**: no Windows was to hand. They
are reached only where `taskkill` and `tasklist` really are, so they cannot
disturb a Unix, and on Windows they can only improve on what came before them,
which was nothing at all. Reports welcome.

## Tests

The suite uses `tcltest`, which ships with Tcl, and is grouped by theme in
`tests/`: `loading`, `platform`, `output`, `switches`, `redirect`, `errors`,
`timeout`, `terminate`, `cleanup`.

```sh
tclsh tests/all.tcl                    # everything
tclsh tests/all.tcl -file timeout.test # one theme
tclsh tests/all.tcl -match timeout-2.* # one group of cases
tclsh tests/all.tcl -verbose pbst      # show passing cases as well
```

The runner exits non-zero when anything failed. Each file also runs on its own
(`tclsh tests/timeout.test`). The cases that look for surviving processes are
constrained to Unix, and read the process table with `ps`.

## Changes in 2.1

* How to stop a process and how to look at one are settled once, as the package
  loads, by trying what the system offers instead of calling `kill` and `ps` and
  hoping. The choice is readable in `$::exec_extensions::signaller` and
  `$::exec_extensions::inspector`, and either can be forced.
* Windows gets `taskkill` and `tasklist`, where before it silently got nothing -
  written but untested, see above.
* A Linux gets `/proc`, which starts no process to read and dates one to a clock
  tick rather than to a second. On a system that has it, the liveness check
  behind the time limit stops costing a `fork` per call.

## Changes in 2.0

The version is a major one because two things changed under callers rather than
beside them: `terminate` no longer sends the second signal unconditionally, and
the package now refuses to load on an interpreter older than 8.6 instead of
failing later on.

* `ttlexec` takes `-keepnewline`, `-ignorestderr` and `--`, in the place and
  with the meanings `exec` gives them.
* An error raised by `ttlexec` now carries what the command printed, composed
  the way `exec` composes one; the output used to be collected and dropped.
* The limit is enforced against a command that closes its own standard output
  and keeps running. Such a command used to be waited for to the end, with the
  timer already cancelled and the notifier stopped by a blocking close.
* On expiry the message leads with the limit, ahead of a shell's report of the
  job this package has just killed.
* A redirection of standard error written by the caller is left alone instead
  of being overridden by the one `ttlexec` appends.
* A read that fails ends the call with that error, rather than reaching the
  background handler and leaving the wait with nothing to wake it.
* `SIGKILL` reaches only processes that are still the ones `SIGTERM` went to; a
  pid freed during the grace period can already belong to somebody else.
* Captured standard error goes through an open descriptor, so the temporary
  file is never reopened by name.

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
