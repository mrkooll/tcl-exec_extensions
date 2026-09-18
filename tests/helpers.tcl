# Shared bootstrap for the exec_extensions test suite.
#
# Every .test file sources this first. It puts the checkout - never an
# installed copy - on auto_path, loads the package under test, and provides the
# probes the timeout and terminate cases need to look for surviving processes.

package require tcltest 2.5

namespace eval ::helpers {
	variable dir [file normalize [file dirname [info script]]]
}

lappend auto_path [file dirname $::helpers::dir]
package require exec_extensions

# Run a script in a fresh interpreter that has the package loaded, and return
# what it printed on standard output.
#
# Its standard error is dropped, which is the point of running it apart: cases
# that exercise -ignorestderr let the command's stderr through, and a case that
# provokes a background error writes a stack trace there. tcltest counts
# anything a test file writes to stderr as a test file error, which would make
# the whole run come back non-zero with every case still passing. Needs a
# /dev/null, hence the unix constraint on the cases that use it.
proc in_child {script} {
	set boot "lappend auto_path [list [file dirname $::helpers::dir]]\n"
	append boot "package require exec_extensions\n"
	return [exec [info nameofexecutable] << $boot$script 2> /dev/null]
}

# Return the pids of the probe processes started with the given sleep duration.
#
# The duration is what makes a probe unique. The suite has to ask the process
# table "did anything survive?", and a plain "sleep 30" is common enough that
# one run would see another run's leftovers and fail for the wrong reason, so
# each case sleeps for an implausible number of seconds of its own.
proc probe_pids {marker} {
	if {[catch {exec ps -Ao pid=,command=} listing]} {
		return {}
	}
	set pids [list]
	foreach line [split $listing "\n"] {
		if {[string match "*sleep $marker*" $line] && ![string match "*ps -Ao*" $line]} {
			lappend pids [lindex [regexp -all -inline {\S+} $line] 0]
		}
	}
	return $pids
}

# Kill the probe processes left over from an earlier case, so that a stale
# process cannot decide the next assertion. Used as both setup and cleanup.
proc reap_probe {marker} {
	foreach pid [probe_pids $marker] {
		catch {exec kill -KILL $pid}
	}
	after 100
	return ""
}
