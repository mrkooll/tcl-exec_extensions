# extended exec procedures
# Copyright (c) 2019 Maksym Tiurin <mrkooll@bungarus.info>
#
# See the file "license.terms" for information on usage and redistribution
# of this file, and for a DISCLAIMER OF ALL WARRANTIES.

namespace eval ::exec_extensions {
	variable version 1.1
	# Milliseconds between SIGTERM and SIGKILL when a child outlives its limit.
	variable kill_grace 200
	# Serial number feeding the per-call state key.
	variable serial 0
	# Per-call state, keyed "<token>,<field>".
	#
	# An array rather than a dict because vwait can only watch a scalar or an
	# array element: a dict element cannot be traced at all, and watching the
	# whole dict would wake the wait on every chunk of output the child writes.
	# The "<token>,done" element is what ttlexec waits on.
	variable state
	array set state {}
	namespace export ttlexec
}

package provide exec_extensions $::exec_extensions::version

# ::exec_extensions::_token -- unique key for one ttlexec call (internal)
proc ::exec_extensions::_token {} {
	variable serial
	return "[pid]_[incr serial]"
}

# ::exec_extensions::_descendants -- pids plus everything below them (internal)
#
# Killing a pipeline's own processes is not enough when one of them is a shell:
# its children are re-parented to init and keep running. Walk the process table
# downwards so the whole subtree can be signalled. A process table we cannot
# read leaves the caller with the pids it already had.
proc ::exec_extensions::_descendants {pids} {
	if {[catch {exec ps -Ao pid=,ppid=} listing]} {
		return $pids
	}
	set children [dict create]
	foreach line [split $listing "\n"] {
		set fields [regexp -all -inline {\S+} $line]
		if {[llength $fields] < 2} {
			continue
		}
		lassign $fields pid ppid
		dict lappend children $ppid $pid
	}
	set all $pids
	set queue $pids
	while {[llength $queue]} {
		set next [list]
		foreach pid $queue {
			if {![dict exists $children $pid]} {
				continue
			}
			foreach child [dict get $children $pid] {
				if {$child ni $all} {
					lappend all $child
					lappend next $child
				}
			}
		}
		set queue $next
	}
	return $all
}

# ::exec_extensions::terminate -- stop a set of processes and their children (public)
# terminate pids ?grace?
#
# Send SIGTERM to every pid and to every process descended from it, wait grace
# milliseconds, then send SIGKILL to the same set. Signalling a process that
# already exited is a harmless no-op, and the exec calls themselves make Tcl
# reap its detached children. This process is never signalled, so a caller that
# passes its own pid by accident cannot kill the interpreter.
#
# Arguments:
# pids   - list of process IDs
# ?grace - milliseconds to wait before SIGKILL (default $::exec_extensions::kill_grace)
#
# Side Effects:
# Signals the processes. Blocks for grace milliseconds when pids is not empty.
#
# Results:
# Empty string.
proc ::exec_extensions::terminate {pids {grace ""}} {
	if {![llength $pids]} {
		return
	}
	if {$grace eq ""} {
		variable kill_grace
		set grace $kill_grace
	}
	set targets [list]
	foreach pid [_descendants $pids] {
		if {($pid != [pid]) && ($pid > 1)} {
			lappend targets $pid
		}
	}
	if {![llength $targets]} {
		return
	}
	# Deepest first: a child that outlives its parent would otherwise be
	# re-parented to init between the two signals.
	set targets [lreverse $targets]
	foreach pid $targets {
		catch {exec kill -TERM $pid}
	}
	if {$grace > 0} {
		after $grace
	}
	foreach pid $targets {
		catch {exec kill -KILL $pid}
	}
	return
}

# ::exec_extensions::_collect -- drain the child's stdout (internal)
proc ::exec_extensions::_collect {token} {
	variable state
	set chan $state($token,chan)
	# read (not gets) so that empty lines and a missing final newline survive.
	append state($token,result) [read $chan]
	if {[eof $chan]} {
		_finish $token
	}
	return
}

# ::exec_extensions::_finish -- the child closed its output: reap it (internal)
proc ::exec_extensions::_finish {token} {
	variable state
	set chan $state($token,chan)
	after cancel $state($token,timer)
	catch {fileevent $chan readable {}}
	# End of file means the child is done writing, so a blocking close cannot
	# hang here - and only a blocking close reports the exit status.
	catch {fconfigure $chan -blocking 1}
	if {[catch {close $chan} msg]} {
		set state($token,error) $msg
		set state($token,errorcode) $::errorCode
	}
	set state($token,done) 1
	return
}

# ::exec_extensions::_expire -- the child outlived its limit (internal)
proc ::exec_extensions::_expire {token} {
	variable state
	set chan $state($token,chan)
	catch {fileevent $chan readable {}}
	# Kill before closing: a non-blocking close returns without waiting for the
	# child, so closing alone would leave it running with nobody reading it.
	terminate $state($token,pids)
	catch {fconfigure $chan -blocking 0}
	catch {close $chan}
	set state($token,error) [format \
	  "child process %s did not finish within %dms" \
	  $state($token,pids) $state($token,timeout)]
	set state($token,errorcode) [list PIPE ETIMEOUT $state($token,error)]
	set state($token,done) 1
	return
}

# ttlexec -- execute external command with time limit
# ttlexec timeout command ?command_arg ?command_arg ...
#
# Execute external command like 'exec' but with a time limit. The command runs
# in a pipeline whose stderr is captured, and a nested event loop reads its
# output until it finishes or the limit expires; an expired child is terminated
# rather than left running.
#
# Arguments:
# timeout      - execution limit in milliseconds (0 or less disables the limit)
# command      - command to execute
# ?command_arg - command arguments (can be many)
#
# Side Effects:
# Execute external command. Runs a nested event loop, so the caller must not
# invoke it from a handler that is itself inside a vwait on the same variable.
#
# Results:
# The command's standard output with one trailing newline removed, as exec does.
# Raises an error, again as exec does, when the command cannot be started, wrote
# to stderr, exited non-zero, or ran past the limit. The error code is
# {PIPE ETIMEOUT <message>} in the timeout case.
proc ::exec_extensions::ttlexec {args} {
	variable state
	set timeout [lindex $args 0]
	if {([llength $args] < 2) || ![string is integer -strict $timeout]} {
		return -code error -errorcode [list TCL WRONGARGS] \
		  "wrong # args: should be \"ttlexec timeout command ?command_args?\""
	}
	set token [_token]
	set errfile ""
	close [file tempfile errfile "exec_extensions_stderr"]
	set cmd [lrange $args 1 end]
	lappend cmd 2> $errfile
	if {[catch {open |$cmd r} chan]} {
		catch {file delete -- $errfile}
		return -code error -errorcode $::errorCode $chan
	}
	array set state [list \
	  $token,chan $chan \
	  $token,pids [pid $chan] \
	  $token,timeout $timeout \
	  $token,result "" \
	  $token,error "" \
	  $token,errorcode {} \
	  $token,timer "" \
	  $token,done 0]
	fconfigure $chan -blocking 0
	if {$timeout > 0} {
		set state($token,timer) [after $timeout [list ::exec_extensions::_expire $token]]
	}
	fileevent $chan readable [list ::exec_extensions::_collect $token]
	# Waiting on one array element, so only _finish or _expire ends the wait -
	# see the note on the state variable for why this is not a dict.
	vwait ::exec_extensions::state($token,done)
	set result $state($token,result)
	set message $state($token,error)
	set code $state($token,errorcode)
	array unset state "$token,*"
	# stderr was redirected, so close() stayed quiet about it; report it the way
	# exec does - as an error carrying the child's own words.
	set stderr_text ""
	if {[catch {
		set fh [open $errfile r]
		set stderr_text [read $fh]
		close $fh
	} read_error]} {
		set stderr_text ""
	}
	catch {file delete -- $errfile}
	set stderr_text [string trimright $stderr_text "\n"]
	if {($message ne "") || ($stderr_text ne "")} {
		if {$stderr_text ne ""} {
			if {$message ne ""} {
				append stderr_text "\n" $message
			}
			set message $stderr_text
		}
		if {$code eq {}} {
			set code NONE
		}
		return -code error -errorcode $code $message
	}
	# exec strips exactly one trailing newline, no more.
	if {[string index $result end] eq "\n"} {
		set result [string range $result 0 end-1]
	}
	return $result
}

# Keep the pre-1.1 spelling working: the command used to live in the global
# namespace, so scripts written against 1.0 call it unqualified.
interp alias {} ::ttlexec {} ::exec_extensions::ttlexec

# Local Variables:
# mode: tcl
# coding: utf-8-unix
# comment-column: 0
# comment-start: "# "
# comment-end: ""
# End:
