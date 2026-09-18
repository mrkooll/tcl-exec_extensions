#!/usr/bin/env tclsh
#
# Run the exec_extensions test suite.
#
#   tclsh tests/all.tcl                  every theme
#   tclsh tests/all.tcl -file timeout.test   one theme
#   tclsh tests/all.tcl -match timeout-2.*   one group of cases
#   tclsh tests/all.tcl -verbose pbst        show passing cases too
#
# Exits non-zero when anything failed, so it can be used from a build.

package require tcltest 2.5

::tcltest::configure -testdir [file normalize [file dirname [info script]]]
::tcltest::configure {*}$argv

# runAllTests runs each file in its own interpreter and reports 1 when any of
# them failed. Its own counters are reset before it returns, so its result is
# the only thing left to go by.
exit [expr {[::tcltest::runAllTests] ? 1 : 0}]
