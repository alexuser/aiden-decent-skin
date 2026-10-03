# SPDX-License-Identifier: GPL-3.0-only
# Read-only CLI: tclsh preflight.tcl /path/to/de1plus
# No Tk, BLE, package startup, source of installed dependency, or settings writes.
if {[llength $argv] != 1} {
    puts stderr {Usage: tclsh preflight.tcl /path/to/de1plus}
    exit 2
}
set aiden_preflight_root [file dirname [info script]]
source [file join $aiden_preflight_root compat.tcl]
source [file join $aiden_preflight_root dependency-manifest.tcl]
if {[catch {
    set aiden_app_root [file normalize [lindex $argv 0]]
    set aiden_version_text [::aiden::distribution::read_bytes [file join $aiden_app_root version.tcl]]
    if {![regexp {package ifneeded de1app ([^[:space:]]+)} $aiden_version_text -> aiden_app_version]} {
        error {Cannot identify installed de1app version}
    }
    set aiden_verified_texts [::aiden::distribution::verify [file join $aiden_app_root skins DSx2] \
        $::aiden::distribution::manifest $aiden_app_version]
    foreach aiden_relative [dict get $::aiden::distribution::manifest sources] {
        ::aiden::distribution::adapt $aiden_relative [dict get $aiden_verified_texts $aiden_relative]
    }
} aiden_preflight_problem]} {
    puts stderr $aiden_preflight_problem
    exit 1
}
puts {Aiden dependency preflight passed. No installed code was executed or changed.}
