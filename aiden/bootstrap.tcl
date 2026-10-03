# SPDX-License-Identifier: GPL-3.0-only
# Aiden DSx2 extension entry. No physical operation is requested by this file.
namespace eval ::aiden {variable root [file dirname [info script]]}
if {([info exists ::aiden::standalone] && $::aiden::standalone) || [file exists [file join $::aiden::root enabled]]} {
    if {[catch {
        foreach module {core lifecycle recipe modes ui app} {
            source [file join $::aiden::root ${module}.tcl]
        }
        after idle ::aiden::app::boot
    } problem options]} {
        catch {
            set fd [open [file join $::aiden::root startup-error.txt] w]
            puts $fd $problem
            puts $fd [dict get $options -errorinfo]
            close $fd
        }
        # Standalone startup errors belong to its recoverable blocked screen.
        if {[info exists ::aiden::standalone] && $::aiden::standalone} {
            return -options $options $problem
        }
        # Leave the original DSx2 pages and controls intact for the legacy hook.
    }
}
