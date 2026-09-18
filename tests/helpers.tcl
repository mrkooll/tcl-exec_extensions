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
