# SPDX-License-Identifier: GPL-3.0-only
namespace eval ::aiden::app {
    variable started 0
    variable timer {}
    variable hold_timer {}
    variable held_result {}
    variable native_view 0
    variable last_snapshot {}
    variable notice {}
    variable mode_draft {}
    variable workflow_draft {}
    variable last_status {}
}

proc ::aiden::app::get {data key {fallback {}}} {
    if {[dict exists $data $key]} {return [dict get $data $key]}
    return $fallback
}

proc ::aiden::app::report {problem {options {}}} {
    variable notice
    set notice $problem
    catch {
        set fd [open [file join $::aiden::root runtime-error.txt] w]
        puts $fd $problem
        if {[dict exists $options -errorinfo]} {puts $fd [dict get $options -errorinfo]}
        close $fd
    }
}

proc ::aiden::app::boot {} {
    variable started
    if {$started} {return}
    if {[catch {
        ::aiden::recipe::configure -profile_dir [file join [homedir] profiles] \
            -state_file [file join $::aiden::root recipe-state.tcl]
        ::aiden::modes::configure -state_file [file join $::aiden::root workflow-state.tcl]
        ::aiden::modes::workflow load
        ::aiden::core::install_event_hooks
        ::aiden::lifecycle::reset
        sync_workflow
        ::aiden::ui::mount
        ::aiden::ui::mount_native_return off
        ::aiden::ui::mount_native_return saver
        foreach page {ghc_espresso ghc_steam ghc_flush ghc_hotwater} {
            ::aiden::ui::mount_pending_stop $page
        }
        ::aiden::ui::set_reduced_motion [file exists [file join $::aiden::root reduce-motion]]
        if {[namespace which -command ::aiden::app::native_state_change] eq {}} {
            rename ::skins_page_change_due_to_de1_state_change ::aiden::app::native_state_change
            proc ::skins_page_change_due_to_de1_state_change {state} {::aiden::app::state_change $state}
        }
        set started 1
        ::aiden::ui::show aiden_home
        tick
        set fd [open [file join $::aiden::root boot-ok.txt] w]
        puts $fd {Aiden 0.1.0 native UI mounted; hardware commands require explicit user actions.}
        close $fd
        if {[info exists ::aiden::standalone] && $::aiden::standalone &&
                [namespace which -command ::aiden::distribution::boot_success] ne {}} {
            ::aiden::distribution::boot_success
        }
    } problem options]} {
        report $problem $options
        if {[info exists ::aiden::standalone] && $::aiden::standalone &&
                [namespace which -command ::aiden::distribution::boot_failure] ne {}} {
            set started 0
            variable timer
            if {$timer ne {}} {after cancel $timer; set timer {}}
            ::aiden::distribution::boot_failure $problem $options
        }
    }
}

proc ::aiden::app::state_change {state} {
    variable native_view
    set previous [::dui page current]
    # Always retain Decent/DSx2's existing state processing and safety screens.
    ::aiden::app::native_state_change $state
    if {!$native_view && ([string match aiden_* $previous] || [string match ghc_* $previous]) && \
        $state in {Idle Espresso Steam HotWater HotWaterRinse Sleep GoingToSleep}} {
        if {$state ne "Idle"} {catch {::aiden::recipe::cancel}}
        ::aiden::ui::show aiden_home
    }
}

proc ::aiden::app::sync_workflow {} {
    set work [::aiden::modes::workflow get]
    set selected [get $work selected espresso]
    set options {}
    if {[dict exists $work workflows $selected order]} {
        dict set options mode_order [dict get $work workflows $selected order]
    }
    if {[dict exists $work workflows $selected skipped]} {
        dict set options skipped_modes [dict get $work workflows $selected skipped]
    }
    ::aiden::lifecycle::configure_workflow $selected $options
}

proc ::aiden::app::sample {} {
    variable native_view
    set native [::aiden::core::snapshot]
    if {[string match aiden_* [get $native current_page]]} {set native_view 0}
    set recipe [::aiden::recipe::working]
    set recipe [dict merge $recipe [dict create profile_title [get $recipe title] \
        target_yield [get $recipe yield] target_temp [get $recipe temperature]]]
    dict set native recipe $recipe
    set p [::aiden::lifecycle::ingest $native]
    set snapshot [dict merge $native $p]
    set can_wake [expr {[get $native native_state] eq "Sleep" && [get $native connected 0] && \
        [get $native pending] eq {} && ![get $p busy 0] && [get $p primary_action] ne "stop"}]
    if {$can_wake} {
        dict set snapshot primary_action wake
        dict set snapshot primary_enabled 1
        dict set snapshot status Sleeping
    }
    variable notice
    dict set snapshot notice $notice
    dict set snapshot note $notice
    dict set snapshot working_recipe $recipe
    dict set snapshot can_edit [expr {![get $snapshot busy 0]}]
    dict set snapshot can_wake $can_wake
    dict set snapshot can_sleep [expr {[get $native editable 0] && [get $native pending] eq {}}]
    dict set snapshot can_reconnect 0
    dict set snapshot can_recover [expr {![get $snapshot busy 0]}]
    dict set snapshot graph [get $native graph_vectors]
    dict set snapshot readiness [get $native state]
    dict set snapshot scale [dict create weight [get $native weight] quality [get $snapshot weight_quality unavailable] \
        status [get $native scale_status] can_tare [get $snapshot can_tare 0]]
    set primary [get $snapshot primary_action wait]
    set names [dict create start "Start [get $snapshot mode espresso]" stop Stop wake Wake continue Continue wait {Not ready}]
    dict set snapshot primary_name [get $names $primary {Not ready}]
    set modeinfo [::aiden::modes::get [get $snapshot mode espresso]]
    set labels {}
    foreach field [get $modeinfo fields] {
        set key [get $field key]
        if {$key eq "steam_disabled"} {
            if {[get $field value 0]} {lappend labels {Heater off}}
        } elseif {$key ne "water_time_max" && [get $field available 0]} {
            lappend labels "[get $field display_value [get $field value]] [get $field display_unit [get $field unit]]"
        }
    }
    dict set snapshot mode_values [join $labels { · }]
    return $snapshot
}

proc ::aiden::app::tick {} {
    variable timer
    variable last_snapshot
    variable hold_timer
    variable held_result
    variable last_status
    if {$timer ne {}} {after cancel $timer; set timer {}}
    if {[catch {
        set last_snapshot [sample]
        ::aiden::ui::render $last_snapshot
        set status {}
        foreach key {native_state native_substate connected pending phase mode primary_action primary_enabled current_page context_verified} {
            dict set status $key [get $last_snapshot $key]
        }
        if {[info exists ::de1(device_handle)]} {
            dict set status handle_integer [string is integer -strict $::de1(device_handle)]
            dict set status handle_zero [expr {$::de1(device_handle) eq "0"}]
            dict set status handle_empty [expr {$::de1(device_handle) eq {}}]
        }
        if {$status ne $last_status} {
            set fd [open [file join $::aiden::root status.tcl] w]
            puts $fd $status
            close $fd
            set last_status $status
        }
        if {[get $last_snapshot auto_handoff_available 0]} {
            set id [get [get $last_snapshot operation_result] id]
            if {$hold_timer eq {} && $held_result ne $id} {
                set held_result $id
                set hold_timer [after 1500 [list ::aiden::app::finish_hold $id]]
            }
        } elseif {$hold_timer ne {}} {after cancel $hold_timer; set hold_timer {}}
    } problem options]} {report $problem $options}
    set interval 500
    if {[get $last_snapshot busy 0]} {set interval 100}
    set timer [after $interval ::aiden::app::tick]
}

proc ::aiden::app::finish_hold {id} {
    variable hold_timer
    set hold_timer {}
    # This timer changes presentation only after independently finalized results.
    if {[catch {::aiden::lifecycle::complete_hold $id} problem options]} {report $problem $options}
    tick
}

proc ::aiden::app::route {target} {
    variable native_view
    ::aiden::core::route $target
    set native_view 1
}

proc ::aiden::app::dispatch_operation {intent args} {
    if {[catch {::aiden::core::command $intent {*}$args} problem options]} {
        set observed [::aiden::core::snapshot]
        # Empty transport state proves the core guard rejected before dispatch.
        # An uncertain native call retains its pending record and stays unknown.
        if {[get $observed pending] eq {}} {
            dict set observed request_action $intent
            dict set observed request_outcome rejected
            dict set observed request_reason $problem
            if {$intent eq "advance"} {
                dict set observed stage_advance_rejected 1
                dict set observed stage_advance_reason $problem
            }
            ::aiden::lifecycle::ingest $observed
        }
        return -options $options $problem
    }
}

proc ::aiden::app::action {name args} {
    variable native_view
    variable notice
    variable mode_draft
    variable workflow_draft
    set notice {}
    if {[catch {
        set snapshot [sample]
        switch -- $name {
            home - back - close {
                ::aiden::recipe::cancel
                set native_view 0
                ::aiden::ui::show aiden_home
            }
            primary {
                set intent [get $snapshot primary_action wait]
                if {![get $snapshot primary_enabled 0]} {error [get $snapshot status {Unavailable}]}
                switch -- $intent {
                    start - stop {
                        set reply [::aiden::lifecycle::request $intent [dict create recipe [dict get $snapshot recipe]]]
                        if {![dict get $reply accepted]} {error [dict get $reply reason]}
                        if {$intent eq "start"} {dispatch_operation start [dict get $snapshot mode]} else {dispatch_operation stop}
                    }
                    wake {::aiden::core::command wake}
                    continue {::aiden::lifecycle::continue}
                    default {error {Machine is not ready}}
                }
            }
            mode {::aiden::lifecycle::select_mode [lindex $args 0]; ::aiden::ui::show aiden_home}
            profiles {
                ::aiden::recipe::begin chooser
                ::aiden::ui::set_catalog [::aiden::recipe::catalog]
                ::aiden::ui::show aiden_profiles
            }
            profile_select {::aiden::ui::set_context aiden_profiles [::aiden::recipe::select [lindex $args 0]]}
            profile_filter - profile_search {# Filtering is private UI state.}
            profile_favorite {::aiden::recipe::favorite [lindex $args 0]; ::aiden::ui::set_catalog [::aiden::recipe::catalog]}
            profile_apply {::aiden::recipe::choose [lindex $args 0]; ::aiden::ui::show aiden_home}
            profile_cancel {::aiden::recipe::cancel; ::aiden::ui::show aiden_home}
            recipe {::aiden::ui::set_recipe [::aiden::recipe::begin editor]; ::aiden::ui::show aiden_recipe}
            recipe_edit {::aiden::ui::set_recipe [::aiden::recipe::edit [dict create {*}$args]]}
            recipe_apply {::aiden::recipe::apply [lindex $args 0]; ::aiden::ui::show aiden_home}
            recipe_save_copy {
                ::aiden::recipe::save_copy {*}$args
                set notice {Copy saved. Your working recipe stays selected.}
                ::aiden::ui::show aiden_recipe
            }
            recipe_save_copy_open - recipe_save_copy_cancel {# View owns this nested draft sheet.}
            recipe_cancel {::aiden::recipe::cancel; ::aiden::ui::show aiden_home}
            recipe_reset {::aiden::recipe::reset_adjustments; ::aiden::ui::show aiden_home}
            tare - reconnect_scale - sleep - wake {::aiden::core::command $name}
            stop {
                set reply [::aiden::lifecycle::request stop]
                if {![dict get $reply accepted]} {error [dict get $reply reason]}
                dispatch_operation stop
            }
            advance {
                set reply [::aiden::lifecycle::request advance]
                if {![dict get $reply accepted]} {error [dict get $reply reason]}
                dispatch_operation advance
            }
            next - continue {::aiden::lifecycle::continue; ::aiden::ui::show aiden_home}
            scale - status - utilities {::aiden::ui::show aiden_$name}
            workflow {
                set workflow_draft [::aiden::modes::workflow begin]
                ::aiden::ui::set_context aiden_workflow [::aiden::modes::workflow get]
                ::aiden::ui::show aiden_workflow
            }
            history {route history}
            graph {::aiden::ui::set_context aiden_home [dict create graph_expanded 1]}
            route {route [lindex $args 0]}
            native - original - original_skin - saved_setups {route original}
            advanced {route profiles}
            devices {route scale}
            extensions {route extensions}
            recovery {route machine}
            maintenance - calibration {route machine}
            scale_reconnect {::aiden::core::command reconnect_scale}
            machine_reconnect {error {Use Devices to reconnect the machine}}
            mode_settings {
                set mode [lindex $args 0]
                set mode_draft [::aiden::modes::begin $mode]
                ::aiden::ui::set_mode_settings $mode $mode_draft
                ::aiden::ui::show aiden_modes
            }
            mode_edit {
                set mode_draft [::aiden::modes::edit {*}$args]
                ::aiden::ui::set_mode_settings [lindex $args 0] $mode_draft
            }
            mode_apply {::aiden::modes::apply {*}$args; ::aiden::ui::show aiden_home}
            mode_cancel {::aiden::modes::cancel {*}$args; ::aiden::ui::show aiden_home}
            workflow_select {set workflow_draft [::aiden::modes::workflow begin [lindex $args 0]]}
            workflow_cancel {::aiden::modes::workflow cancel; ::aiden::ui::show aiden_home}
            workflow_save {route original}
            workflow_apply {
                if {[get $workflow_draft id] ne [lindex $args 0]} {error {Reopen the workflow draft}}
                ::aiden::modes::workflow apply $workflow_draft
                sync_workflow
                ::aiden::ui::show aiden_home
            }
            default {error "Unsupported Aiden action: $name"}
        }
    } problem options]} {report $problem $options}
    tick
}
