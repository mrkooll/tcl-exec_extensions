# extended exec procedures
# Copyright (c) 2019 Maksym Tiurin <mrkooll@bungarus.info>
#
# See the file "license.terms" for information on usage and redistribution
# of this file, and for a DISCLAIMER OF ALL WARRANTIES.

namespace eval ::exec_extensions {
	variable version 1.0
	namespace export ttlexec
}

package provide exec_extensions $::exec_extensions::version

proc ::exec_extensions::start_eventloop {exec_namespace} {
	set ::[set exec_namespace]::eventloop 1
	vwait ::[set exec_namespace]::eventloop
	return
}
proc ::exec_extensions::stop_eventloop {exec_namespace} {
	set ::[set exec_namespace]::eventloop 0
	return
}

proc ::exec_extensions::start_timeout {exec_namespace} {
	return [after [set ::[set exec_namespace]::timeout] \
	          [list ::exec_extensions::run_timeout $exec_namespace]];
}
proc ::exec_extensions::run_timeout {exec_namespace} {
	puts stderr [set msg [format \
    "\aclosing (without capturing exit status) pipe to piped child process %ld after timeout of %ldms" \
	                        [set ::[set exec_namespace]::processPID] \
	                        [set ::[set exec_namespace]::timeout] \
	                       ]];
	# turn off blocking and close the pipe to the piped client process
	fconfigure [set ::[set exec_namespace]::processId] -blocking 0
	close [set ::[set exec_namespace]::processId]
	set ::[set exec_namespace]::errorCode [list PIPE ETIMEOUT $msg]
	::exec_extensions::stop_eventloop $exec_namespace
	return
}
proc ::exec_extensions::stop_timeout {exec_namespace} {
	after cancel [set ::[set exec_namespace]::timeoutId]
	::exec_extensions::stop_eventloop $exec_namespace
	return
}
proc ::exec_extensions::collect_output {exec_namespace} {
	if {[gets [set ::[set exec_namespace]::processId] line] > 0} {
		append ::[set exec_namespace]::result $line "\n"
	} elseif {[eof [set ::[set exec_namespace]::processId]]} {
		# without blocking close command doesn't wait until the client finished
		fconfigure [set ::[set exec_namespace]::processId] -blocking 1
		if {[catch {close [set ::[set exec_namespace]::processId]} result]} {
			if {($::errorCode != {}) && ($::errorCode != "NONE")} {
				puts stderr [format \
				               "\apiped child process %d exited abnormaly:\n\n%s\n" \
				               [set ::[set exec_namespace]::processPID] \
				               $::errorCode \
				              ];
			}
		}
		::exec_extensions::stop_timeout $exec_namespace
	}
}
proc ::exec_extensions::namespace_name_gen {} {
	set chars {0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz}
	set chars_count [expr [string length $chars] - 1]
	set res "exec_extensions_[pid]_"
	for {set i 0} {$i < 8} {incr i} {
		append res [string index $chars [expr round(rand()*$chars_count)]]
	}
	return $res
}
# ttlexec -- execute external command with time limit
# ttlexec timeout command ?command_arg ?command_arg ...
#
# Execute external command like 'exec' but with time limit.
#
# Arguments:
# timeout      - execution limit in milliseconds
# command      - command to execute
# ?command_arg - command arguments (can be many)
#
# Side Effects:
# Execute external command.
#
# Results:
# External command output from stdout
# error with command output when timeout or execution error happened
proc ttlexec {args} {
	if {([llength $args] < 2) || ![string is integer [lindex $args 0]]} {
		error "wrong # args: should be \"timeout_exec timeout command ?command_args?\"" \
		  $::errorInfo [list TCL WRONGARGS]
	}
	set exec_namespace [::exec_extensions::namespace_name_gen]
	namespace eval ::[set exec_namespace] {
		variable result ""
		variable eventloop 0
		variable timeoutId ""
		variable processId ""
		variable processPID 0
		variable timeout 0
		variable errorCode {}
	}
	set ::[set exec_namespace]::timeout [lindex $args 0]
	set ::[set exec_namespace]::processId [open |[lrange $args 1 end] r]
	set ::[set exec_namespace]::processPID [pid [set ::[set exec_namespace]::processId]]
	fconfigure [set ::[set exec_namespace]::processId] -buffering line -blocking 0
	set ::[set exec_namespace]::timeoutId [::exec_extensions::start_timeout $exec_namespace]
	fileevent [set ::[set exec_namespace]::processId] readable \
	  [list ::exec_extensions::collect_output $exec_namespace]
	::exec_extensions::start_eventloop $exec_namespace
	set result [set ::[set exec_namespace]::result]
	if {[set ::[set exec_namespace]::errorCode] == {}} {
		namespace delete ::[set exec_namespace]
		return $result
	} else {
		set err [set ::[set exec_namespace]::errorCode]
		namespace delete ::[set exec_namespace]
		error $result $::errorInfo $err
	}
}
# Local Variables:
# mode: tcl
# coding: utf-8-unix
# comment-column: 0
# comment-start: "# "
# comment-end: ""
# End:
