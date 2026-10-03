# SPDX-License-Identifier: GPL-3.0-only
# Aiden's boundary to the inspected de1app1.46.1.1 / DSx2 Damian runtime.
# Source and snapshot are read-only. Only command dispatches physical requests.
# Bootstrap must explicitly install observers after the native app has loaded.
# No native callback, history writer, safety policy, or timer is replaced here.
namespace eval ::aiden::core {
    variable hook_flags {}
    variable pending_request {}
    variable observed_operation {}
    variable completed_result {}
    variable event_sequence 0
    variable last_state_event {}
    variable request_sequence 0
    variable request_context {}
    variable request_reconciliation {}
    variable transport_sequence 0
    variable transport_write {}
    variable transport_read {}
    variable transport_read_context {}
    variable transport_calls {}
    variable ble_calls {}
    variable connection_epoch 0
    variable verification_counts {}
}

proc ::aiden::core::_read {name {fallback {}}} {
    if {[info exists $name]} {return [set $name]}
    return $fallback
}

proc ::aiden::core::_number {value} {
    if {$value eq {} || ![string is double -strict $value]} {return {}}
    # Reject NaN/Inf: missing or invalid measurements must never become zero.
    if {[catch {expr {double($value) > -Inf && double($value) < Inf}} finite] || !$finite} {return {}}
    return $value
}

proc ::aiden::core::_boolean {value {fallback 0}} {
    if {![string is boolean -strict $value]} {return $fallback}
    return [expr {$value ? 1 : 0}]
}

proc ::aiden::core::_has {name} {expr {[namespace which -command $name] ne {}}}

proc ::aiden::core::_native_state {} {
    set raw [_read ::de1(state)]
    if {$raw ne {} && [info exists ::de1_num_state($raw)]} {return $::de1_num_state($raw)}
    return unknown
}

proc ::aiden::core::_native_substate {} {
    set raw [_read ::de1(substate)]
    if {$raw ne {} && [info exists ::de1_substate_types($raw)]} {return $::de1_substate_types($raw)}
    return unknown
}

proc ::aiden::core::_state_name {native} {
    switch -- $native {
        GoingToSleep {return going_to_sleep}
        HotWater {return hot_water}
        HotWaterRinse {return hot_water_rinse}
        SteamRinse {return steam_rinse}
        AirPurge {return air_purge}
        FatalError {return fatal_error}
        InBootLoader {return in_boot_loader}
        SchedIdle {return scheduled_idle}
        default {return [string tolower [string map {{ } _} $native]]}
    }
}

proc ::aiden::core::_mode {native} {
    switch -- $native {
        Espresso {return espresso}
        Steam {return steam}
        HotWater {return water}
        HotWaterRinse {return flush}
        default {return {}}
    }
}

proc ::aiden::core::_phase {native substate} {
    # Exact installed ::de1::state::flow_phase classification; no telemetry guess.
    if {[_mode $native] eq {}} {return {}}
    switch -- $substate {
        starting - ready - heating - {final heating} - stabilising {return before}
        preinfusion - pouring {return during}
        ending {return after}
        default {return {}}
    }
}

proc ::aiden::core::_connection {field} {
    if {![info exists ::de1($field)] || $::de1($field) eq {}} {
        return [dict create connected 0 status unknown]
    }
    # Native connected callbacks retain the BLE handle verbatim; it is opaque.
    # Native disconnect handlers use zero, not a numeric handle range.
    set handle $::de1($field)
    if {$handle == 0} {return [dict create connected 0 status disconnected]}
    if {$field eq "device_handle" && $handle == 1} {
        # bluetooth.tcl assigns 1 only to the non-Android simulated DE1.
        # The native Android command queue excludes that sentinel from delivery.
        if {[info exists ::android] && $::android == 0} {
            return [dict create connected 1 status simulated]
        }
        return [dict create connected 0 status unknown]
    }
    return [dict create connected 1 status connected]
}

proc ::aiden::core::_timer_keys {mode} {
    switch -- $mode {
        espresso {return {espresso_start espresso_stop}}
        steam {return {steam_pour_start steam_pour_stop}}
        water {return {water_pour_start water_pour_stop}}
        flush {return {flush_pour_start flush_pour_stop}}
        default {return {}}
    }
}

proc ::aiden::core::_elapsed {mode} {
    lassign [_timer_keys $mode] start_key stop_key
    if {$start_key eq {}} {return {}}
    set start [_number [_read ::timers($start_key)]]
    set stop [_number [_read ::timers($stop_key)]]
    if {$start eq {} || $stop eq {} || $start <= 0 || $stop < 0} {return {}}
    # Same clock and start/stop fields as installed vars.tcl's native timers.
    # We never create/reset these fields or start a timer after an action tap.
    set end [expr {$stop > 0 ? $stop : [clock milliseconds]}]
    if {$end < $start} {return {}}
    return [expr {($end - $start) / 1000.0}]
}

proc ::aiden::core::_native_id {native {event {}}} {
    set mode [_mode $native]
    if {$mode eq {}} {return {}}
    if {$mode eq "espresso"} {
        set stamp [_number [_read ::settings(espresso_clock)]]
        if {$stamp ne {} && $stamp > 0} {return espresso:$stamp}
    } elseif {[dict exists $event event_time]} {
        set stamp [_number [dict get $event event_time]]
        if {$stamp ne {} && $stamp > 0} {return $mode:$stamp}
    }
    lassign [_timer_keys $mode] start_key stop_key
    set stamp [_number [_read ::timers($start_key)]]
    if {$stamp ne {} && $stamp > 0} {return $mode:$stamp}
    return {}
}

proc ::aiden::core::_graph {{mode espresso}} {
    if {$mode ne "espresso"} {return [dict create vectors {} samples {} units {}]}
    set names [dict create elapsed espresso_elapsed pressure espresso_pressure \
        pressure_goal espresso_pressure_goal flow espresso_flow flow_goal espresso_flow_goal \
        weight espresso_weight scale_rate espresso_flow_weight temperature espresso_temperature_basket \
        temperature_goal espresso_temperature_goal stage_changes espresso_state_change]
    set vectors {}
    set samples {}
    dict for {key name} $names {
        if {![_has ::$name]} {continue}
        # BLT range reads copy actual native samples, preserving NaN gaps.
        if {[catch {uplevel #0 [list ::$name range 0 end]} values]} {continue}
        dict set vectors $key $name
        dict set samples $key $values
    }
    return [dict create vectors $vectors samples $samples units \
        [dict create elapsed s pressure bar pressure_goal bar flow mL/s flow_goal mL/s \
            weight g scale_rate g/s temperature degC temperature_goal degC]]
}

proc ::aiden::core::_scale {} {
    set conn [_connection scale_device_handle]
    set configured [expr {[_read ::settings(scale_bluetooth_address)] ne {}}]
    set status [dict get $conn status]
    set reporting 0
    set reporting_verified 0
    if {[dict get $conn connected] && [_has ::device::scale::is_reporting]} {
        if {![catch {::device::scale::is_reporting} native] && [string is boolean -strict $native]} {
            set reporting [_boolean $native]
            set reporting_verified 1
            set status [expr {$reporting ? "live" : "stale"}]
        }
    }
    if {[info exists ::settings(scale_bluetooth_address)] && !$configured && \
        ![dict get $conn connected]} {set status unconfigured}
    if {$configured && ![dict get $conn connected] && \
        [_number [_read ::currently_connecting_scale_handle]] ne {} && \
        [_read ::currently_connecting_scale_handle] > 0} {set status reconnecting}
    set last_known [_number [_read ::de1(scale_weight)]]
    set weight {}
    if {[dict get $conn connected] && $reporting_verified && $reporting} {set weight $last_known}
    return [dict create connected [dict get $conn connected] configured $configured \
        status $status reporting $reporting reporting_verified $reporting_verified weight $weight \
        last_known_weight $last_known last_update [_number [_read ::device::scale::_last_weight_update_time]]]
}

proc ::aiden::core::_finalizing {} {
    if {[_has ::de1::event::apply::after_flow_complete_is_pending] && \
        ![catch {::de1::event::apply::after_flow_complete_is_pending} value]} {
        return [_boolean $value 1]
    }
    # Without the inspected native flag, finalization is unverified.
    return 1
}

proc ::aiden::core::_ghc_policy {} {
    # Exact installed ghc_required logic; never bypass native GHC restrictions.
    set android [_read ::android]
    set undroid [_read ::undroid]
    if {![string is boolean -strict $android] || ![string is boolean -strict $undroid]} {
        return [dict create verified 0 required 0]
    }
    if {![_boolean $android] || [_boolean $undroid]} {return [dict create verified 1 required 0]}
    set installed [_read ::settings(ghc_is_installed)]
    if {![string is integer -strict $installed]} {return [dict create verified 0 required 0]}
    return [dict create verified 1 required [expr {$installed ni {0 1 2 4}}]]
}

proc ::aiden::core::_start_policy {native substate connected scale} {
    variable pending_request
    set flags [dict create espresso 0 flush 0 steam 0 water 0]
    set reasons [dict create espresso {Machine state is not ready} flush {Machine state is not ready} \
        steam {Machine state is not ready} water {Machine state is not ready}]
    set verified 0
    if {!$connected || $native ne "Idle" || $substate ne "ready" || \
        $pending_request ne {} || [_finalizing]} {return [dict create verified 1 flags $flags reasons $reasons]}
    if {[_boolean [_read ::settings(stress_test)] 1]} {
        return [dict create verified 1 flags $flags reasons [dict create espresso {Native stress test is enabled} \
            flush {Native stress test is enabled} steam {Native stress test is enabled} water {Native stress test is enabled}]]
    }
    set verified 1
    if {![dict get [_ghc_policy] verified]} {
        return [dict create verified 0 flags $flags reasons [dict create espresso {Native hardware start policy unavailable} \
            flush {Native hardware start policy unavailable} steam {Native hardware start policy unavailable} \
            water {Native hardware start policy unavailable}]]
    }
    foreach mode {espresso flush steam water} {
        set api ::start_$mode
        if {![_has $api]} {dict set reasons $mode {Native action unavailable}; continue}
        dict set flags $mode 1
        dict set reasons $mode {}
    }
    set only_scale [_read ::settings(start_espresso_only_if_scale_connected)]
    if {![string is boolean -strict $only_scale]} {
        dict set flags espresso 0
        dict set reasons espresso {Native scale start policy unavailable}
    } elseif {[_boolean $only_scale] && [dict get $scale configured] && ![dict get $scale connected]} {
        dict set flags espresso 0
        dict set reasons espresso {Please connect your scale}
    }
    set timeout [_number [_read ::settings(steam_timeout)]]
    set disabled [_read ::settings(steam_disabled)]
    set target [_number [_read ::settings(steam_temperature)]]
    set actual [_number [_read ::de1(steam_heater_temperature)]]
    set eco [_boolean [_read ::de1(in_eco_steam_mode)]]
    if {$timeout eq {} || $timeout <= 0 || ![string is boolean -strict $disabled] || [_boolean $disabled]} {
        dict set flags steam 0
        dict set reasons steam {Steam is turned off or its setting is unavailable}
    } elseif {!$eco && ($target eq {} || $actual eq {} || $actual <= $target - 14)} {
        # Exact DSx2 start_button_ready threshold, using direct native fields.
        dict set flags steam 0
        dict set reasons steam {Machine still heating}
    }
    return [dict create verified $verified flags $flags reasons $reasons]
}

proc ::aiden::core::snapshot {} {
    variable pending_request
    variable observed_operation
    variable completed_result
    variable event_sequence
    variable last_state_event
    variable request_reconciliation
    variable hook_flags
    set native [_native_state]
    set substate [_native_substate]
    set mode [_mode $native]
    set connection [_connection device_handle]
    set connected [dict get $connection connected]
    set scale [_scale]
    set ready [expr {$connected && $native eq "Idle" && $substate eq "ready"}]
    set finalizing [_finalizing]
    set editable [expr {$ready && $pending_request eq {} && !$finalizing && \
        ![_boolean [_read ::settings(stress_test)] 1]}]
    set page {}
    if {[_has ::dui]} {catch {set page [::dui page current]}}
    set context [_read ::de1(current_context)]
    set phase [_phase $native $substate]
    set flow_confirmed [expr {$connected && $phase eq "during"}]
    set flow_ended 0
    set finalized 0
    set id {}
    set elapsed {}
    set operation $observed_operation
    set retain_operation [expr {$operation ne {} && ($mode eq {} || [dict get $operation mode] eq $mode)}]
    if {$retain_operation && $mode ne {} && $phase in {before during} && [dict get $operation flow_ended]} {
        set retain_operation 0
    }
    if {$retain_operation && $mode eq "espresso" && [_native_id $native] ne [dict get $operation operation_id]} {
        set retain_operation 0
    }
    if {$retain_operation && $pending_request ne {} && \
        [dict exists $pending_request new_operation] && [dict get $pending_request new_operation] && \
        [dict get $operation flow_ended]} {set retain_operation 0}
    if {$retain_operation && $request_reconciliation ne {} && \
        [dict get $request_reconciliation new_operation] && [dict get $operation flow_ended]} {
        # Canceling the next request must not republish the previous result as
        # though it belongs to the canceled operation.
        set retain_operation 0
    }
    if {$retain_operation} {
        set id [dict get $operation operation_id]
        set flow_confirmed [expr {$flow_confirmed || [dict get $operation flow_confirmed]}]
        set flow_ended [dict get $operation flow_ended]
        set finalized [dict get $operation result_finalized]
        if {$mode eq {}} {set mode [dict get $operation mode]}
    } elseif {$mode ne {} && $phase in {during after}} {set id [_native_id $native]}
    if {$mode ne {} && ($flow_confirmed || $flow_ended)} {set elapsed [_elapsed $mode]}
    if {$flow_ended && $retain_operation && [dict exists $operation final_elapsed]} {
        set elapsed [dict get $operation final_elapsed]
    }
    set graph [_graph $mode]
    set profile_type [_read ::settings(settings_profile_type)]
    set target_field [expr {$profile_type in {settings_2c settings_2c2} ? \
        "final_desired_shot_weight_advanced" : "final_desired_shot_weight"}]
    set policy [_start_policy $native $substate $connected $scale]
    set ghc [_ghc_policy]
    set faulted [expr {$native eq "FatalError" || [string match Error_* $substate]}]
    set fault {}
    if {$faulted} {
        set raw_substate [_read ::de1(substate)]
        set fault [_read ::de1_substate_type_description($raw_substate) $substate]
        if {$fault eq "ready"} {set fault $native}
    }
    set temperature {}
    if {$connected} {
        set temperature_field [expr {$native eq "Steam" ? "steam_heater_temperature" : "head_temperature"}]
        set temperature [_number [_read ::de1($temperature_field)]]
    }
    set stage_available [expr {$connected && $native eq "Espresso" && $phase eq "during" && \
        [_has ::start_next_step] && $pending_request eq {}}]
    set pressure {}
    set flow {}
    if {$connected && $native eq "Espresso" && $phase eq "during"} {
        set pressure [_number [_read ::de1(pressure)]]
        set flow [_number [_read ::de1(flow)]]
    }
    set s [dict create state [_state_name $native] native_state $native native_substate $substate \
        state_raw [_read ::de1(state)] substate_raw [_read ::de1(substate)] \
        substate [string tolower [string map {{ } _} $substate]] mode $mode \
        connected $connected connection_status [dict get $connection status] ready $ready editable $editable \
        pending [expr {$pending_request eq {} ? "" : [dict get $pending_request action]}] \
        pending_request $pending_request elapsed $elapsed weight [dict get $scale weight] \
        scale_connected [dict get $scale connected] scale_configured [dict get $scale configured] \
        scale_status [dict get $scale status] scale_reporting [dict get $scale reporting] \
        scale_reporting_verified [dict get $scale reporting_verified] \
        weight_fresh [dict get $scale reporting] \
        weight_quality [expr {[dict get $scale weight] ne {} ? "valid" : \
            ([dict get $scale status] eq "stale" ? "stale" : "unavailable")}] \
        can_tare [dict get $scale connected] faulted $faulted fault $fault \
        last_known_weight [dict get $scale last_known_weight] scale_last_update [dict get $scale last_update] \
        temperature $temperature profile_title [_read ::settings(profile_title)] \
        profile_id [_read ::settings(profile_filename)] dose [_number [_read ::settings(grinder_dose_weight)]] \
        target_yield [_number [_read ::settings($target_field)]] target_yield_unit g \
        target_temp [_number [_read ::settings(espresso_temperature)]] temperature_unit degC \
        flow_confirmed $flow_confirmed flow_ended $flow_ended result_finalized $finalized \
        operation_id $id operation_ending [expr {$connected && $phase eq "after"}] \
        operation_recipe [expr {$retain_operation ? [dict get $operation recipe] : ""}] \
        pressure $pressure pressure_unit bar flow $flow flow_unit mL/s \
        native_finalization_pending $finalizing snapshot_sequence $event_sequence \
        graph_vectors [dict get $graph vectors] graph_samples [dict get $graph samples] \
        graph_units [dict get $graph units] current_page $page current_context $context \
        context_verified [expr {$page ne {} && $page eq $context}] \
        start_verified [dict get $policy verified] can_start_by_mode [dict get $policy flags] \
        ghc_policy_verified [dict get $ghc verified] start_requires_group_head [dict get $ghc required] \
        start_instruction [expr {[dict get $ghc required] ? "Start on the group head controller" : ""}] \
        start_reasons [dict get $policy reasons] stage_advance_verified [_has ::start_next_step] \
        stage_advance_available $stage_available stage_name [_read ::settings(current_frame_description)] \
        stage_number [_read ::de1(current_frame_number)] outcome unknown stop_reason unknown \
        final_result {} result_id {} history_id {} result_saved 0 save_error {} \
        final_weight {} final_elapsed {} final_weight_quality unavailable \
        current_state_verified 0 idle_verified 0 operation_reconciled 0]
    dict set s stop_reconciliation_verified [expr {[_transport_hooks_available] &&
        [dict exists $hook_flags ::userdata_append] && [dict exists $hook_flags ::de1_comm] &&
        [dict exists $hook_flags ::de1_ble_handler]}]
    dict set s stop_verification [_stop_verification]
    dict set s request_reconciliation $request_reconciliation
    if {$connected && $last_state_event ne {} && \
        [dict get $last_state_event this_state] eq $native && \
        [dict get $last_state_event this_substate] eq $substate} {
        dict set s current_state_verified 1
        dict set s idle_verified [expr {$native eq "Idle"}]
        dict set s operation_reconciled [expr {$native eq "Idle" && $pending_request eq {}}]
    }
    if {$connected && $native eq "Idle" && $pending_request eq {} && $request_reconciliation ne {}} {
        dict set s current_state_verified 1
        dict set s idle_verified 1
        dict set s operation_reconciled 1
        dict set s request_action stop
        dict set s request_outcome reconciled
    }
    if {$completed_result ne {} && $id ne {} && [dict get $completed_result operation_id] eq $id} {
        dict set s final_result $completed_result
        foreach key {result_id history_id result_saved save_error final_weight final_elapsed final_weight_quality outcome stop_reason} {
            dict set s $key [dict get $completed_result $key]
        }
    }
    return $s
}

proc ::aiden::core::_begin_operation {native event} {
    variable observed_operation
    variable completed_result
    variable pending_request
    variable request_reconciliation
    set request_reconciliation {}
    set type [_read ::settings(settings_profile_type)]
    set target_field [expr {$type in {settings_2c settings_2c2} ? \
        "final_desired_shot_weight_advanced" : "final_desired_shot_weight"}]
    set recipe [dict create profile_id [_read ::settings(profile_filename)] \
        profile_title [_read ::settings(profile_title)] dose [_number [_read ::settings(grinder_dose_weight)]] \
        target_yield [_number [_read ::settings($target_field)]] target_temp [_number [_read ::settings(espresso_temperature)]] \
        profile_type $type advanced_shot [_read ::settings(advanced_shot)]]
    set observed_operation [dict create mode [_mode $native] native_state $native \
        operation_id [_native_id $native $event] start_event $event flow_confirmed 0 \
        flow_ended 0 result_finalized 0 final_elapsed {} recipe $recipe \
        autostop_initial [_read ::de1(app_autostop_triggered)] autostop_at_end {} \
        manual_stop_requested [expr {$pending_request ne {} && [dict get $pending_request action] eq "stop"}]]
    set completed_result {}
}

proc ::aiden::core::observe_state {event} {
    variable event_sequence
    variable last_state_event
    variable pending_request
    variable observed_operation
    foreach key {this_state this_substate previous_state previous_substate event_time} {
        if {![dict exists $event $key]} {return}
    }
    incr event_sequence
    set last_state_event $event
    set this [dict get $event this_state]
    set previous [dict get $event previous_state]
    set phase [_phase $this [dict get $event this_substate]]
    set old_phase [_phase $previous [dict get $event previous_substate]]
    if {[_mode $this] ne {} && ($this ne $previous || $observed_operation eq {})} {
        _begin_operation $this $event
    }
    if {$observed_operation ne {} && $phase eq "during"} {
        dict set observed_operation flow_confirmed 1
    }
    if {$observed_operation ne {} && $old_phase eq "during" && $phase ne "during" && \
        [dict get $observed_operation mode] eq [_mode $previous]} {
        dict set observed_operation flow_ended 1
        dict set observed_operation flow_end_event $event
        dict set observed_operation final_elapsed [_elapsed [_mode $previous]]
        dict set observed_operation autostop_at_end [_read ::de1(app_autostop_triggered)]
    }
    if {$pending_request ne {}} {
        set action [dict get $pending_request action]
        set fresh [expr {![dict exists $pending_request request_time] ||
            [dict get $event event_time] > [dict get $pending_request request_time]}]
        if {($action eq "start" && [_mode $this] eq [dict get $pending_request mode]) || \
            ($fresh && $action eq "stop" && [_mode $this] eq {} && $this in {Idle Sleep}) || \
            ($fresh && $action eq "sleep" && $this eq "Sleep") || \
            ($fresh && $action eq "wake" && $this eq "Idle")} {set pending_request {}}
    }
}

proc ::aiden::core::observe_disconnect {args} {
    variable last_state_event
    variable event_sequence
    variable connection_epoch
    variable transport_read
    variable transport_write
    variable request_reconciliation
    set last_state_event {}
    incr connection_epoch
    set transport_read {}
    set transport_write {}
    set request_reconciliation {}
    incr event_sequence
    # Preserve pending and last operation; a disconnect is never completion.
}

proc ::aiden::core::observe_complete {event} {
    variable observed_operation
    variable completed_result
    variable event_sequence
    if {$observed_operation eq {} || ![dict get $observed_operation flow_ended]} {return}
    # Native completion is not uniquely tagged when an operation is replaced
    # before its pending callback. Refuse to bind such an event to the new shot.
    if {[_mode [_native_state]] ne {} || ![dict exists $observed_operation flow_end_event]} {return}
    if {[dict exists $event event_time] && \
        [dict get $event event_time] < [dict get [dict get $observed_operation flow_end_event] event_time]} {return}
    set mode [dict get $observed_operation mode]
    set id [dict get $observed_operation operation_id]
    if {$id eq {}} {return}
    set scale [_scale]
    set weight {}
    set quality unavailable
    if {[dict get $scale connected] && [dict get $scale reporting_verified] && [dict get $scale reporting]} {
        if {$mode eq "espresso"} {set weight [_number [_read ::de1(final_espresso_weight)]]}
        if {$mode eq "water"} {set weight [_number [_read ::de1(final_water_weight)]]}
        if {$weight ne {}} {set quality native_final_estimate}
    }
    set history_id {}
    set saved 0
    set save_error {}
    if {$mode eq "espresso"} {
        set file [_read ::settings(history_saved_shot_filename)]
        set stamp [_number [_read ::settings(espresso_clock)]]
        if {$stamp ne {} && $id eq "espresso:$stamp" && $file ne {} && \
            [_boolean [_read ::settings(history_saved)]]} {
            set expected [clock format $stamp -format %Y%m%dT%H%M%S]
            if {[file rootname [file tail $file]] eq $expected} {set history_id $file; set saved 1}
        }
        if {!$saved} {
            set save_error [expr {[_boolean [_read ::settings(should_save_history)]] ? \
                "Native history did not confirm this result" : "Native history saving is disabled"}]
        }
    }
    set graph [_graph $mode]
    set outcome unknown
    set stop_reason unknown
    if {[dict get $observed_operation manual_stop_requested]} {
        set stop_reason operator_request
    } elseif {$mode in {espresso water} && \
        [string is false -strict [dict get $observed_operation autostop_initial]] && \
        [string is true -strict [dict get $observed_operation autostop_at_end]] && \
        [_native_state] eq "Idle" && [_native_substate] eq "ready" && \
        [dict get [_connection device_handle] connected]} {
        set outcome normal
        set stop_reason native_app_autostop
    }
    set completed_result [dict create operation_id $id result_id $id history_id $history_id \
        result_saved $saved save_error $save_error final_weight $weight final_weight_quality $quality \
        final_elapsed [dict get $observed_operation final_elapsed] mode $mode outcome $outcome stop_reason $stop_reason \
        recipe [dict get $observed_operation recipe] \
        graph_samples [dict get $graph samples] graph_units [dict get $graph units] \
        finalization_event $event]
    dict set observed_operation result_finalized 1
    incr event_sequence
}

proc ::aiden::core::install_event_hooks {} {
    variable hook_flags
    set bindings [dict create \
        ::de1::event::listener::on_all_state_change_add ::aiden::core::observe_state \
        ::de1::event::listener::on_disconnect_add ::aiden::core::observe_disconnect \
        ::de1::event::listener::after_flow_complete_add ::aiden::core::observe_complete]
    dict for {registrar callback} $bindings {
        if {![dict exists $hook_flags $registrar] && [_has $registrar]} {
            # Default native idle scheduling appends behind native reset/save
            # listeners. Do not rename callbacks or touch their callback lists.
            uplevel #0 [list $registrar $callback]
            dict set hook_flags $registrar 1
        }
    }
    # Native StateInfo reads with an unchanged value do not emit a state-change
    # event. Add read-only execution observers to the exact inspected transport
    # entry points; preserve their names, bodies, callbacks, and return values.
    if {[_transport_hooks_available]} {
        foreach {api operations callback} {
            ::userdata_append enter ::aiden::core::_queue_trace
            ::de1_comm {enter leave} ::aiden::core::_comm_trace
            ::de1_ble_handler {enter leave} ::aiden::core::_ble_trace
        } {
            if {![dict exists $hook_flags $api]} {
                if {[lsearch -exact [trace info execution $api] [list $operations $callback]] < 0} {
                    trace add execution $api $operations $callback
                }
                dict set hook_flags $api 1
            }
        }
    }
    return $hook_flags
}

proc ::aiden::core::_transport_hooks_available {} {
    if {![string is true -strict [_read ::android]] ||
        [package provide de1_comms] ne "1.1" || [package provide de1_bluetooth] ne "1.1"} {return 0}
    foreach api {::userdata_append ::de1_comm ::de1_ble_handler} {
        if {![_has $api]} {return 0}
    }
    return 1
}

proc ::aiden::core::_idle_payload {payload} {
    if {[string length $payload] != 1 || ![info exists ::de1_state(Idle)]} {return 0}
    return [expr {$payload eq $::de1_state(Idle)}]
}

proc ::aiden::core::_verification_count {key} {
    variable verification_counts
    dict incr verification_counts $key
}

proc ::aiden::core::_stop_verification {} {
    variable hook_flags
    variable pending_request
    variable transport_write
    variable transport_read
    variable verification_counts
    set diag [dict create transport_supported [_transport_hooks_available] pending_stop 0 \
        enqueue_seen 0 write_present [expr {$transport_write ne {}}] write_accepted 0 \
        write_acknowledged 0 write_is_idle 0 read_present [expr {$transport_read ne {}}] \
        read_matches_request 0 read_matches_write 0 queue_known 0 queue_length {} wrote {}]
    foreach {key api} {queue ::userdata_append dispatch ::de1_comm callback ::de1_ble_handler} {
        dict set diag ${key}_hook [dict exists $hook_flags $api]
        set count 0
        if {[_has $api] && ![catch {trace info execution $api} observers]} {set count [llength $observers]}
        dict set diag ${key}_trace_count $count
    }
    if {$pending_request ne {} && [dict get $pending_request action] eq "stop"} {
        dict set diag pending_stop 1
        dict set diag enqueue_seen [expr {[dict exists $pending_request stop_enqueued] &&
            [dict get $pending_request stop_enqueued]}]
        if {$transport_read ne {} && [dict exists $pending_request id]} {
            dict set diag read_matches_request [expr {[dict get $transport_read id] eq [dict get $pending_request id]}]
        }
    }
    if {$transport_write ne {}} {
        dict set diag write_accepted [dict get $transport_write accepted]
        dict set diag write_acknowledged [dict get $transport_write acknowledged]
        dict set diag write_is_idle [_idle_payload [dict get $transport_write payload]]
        if {$transport_read ne {}} {
            dict set diag read_matches_write [expr {[dict get $transport_read write_ticket] eq [dict get $transport_write ticket]}]
        }
    }
    if {[info exists ::de1(cmdstack)] && ![catch {llength $::de1(cmdstack)} length]} {
        dict set diag queue_known 1
        dict set diag queue_length $length
    }
    if {[string is boolean -strict [_read ::de1(wrote)]]} {dict set diag wrote [_boolean [_read ::de1(wrote)]]}
    foreach key {queue_trace_errors dispatch_trace_errors callback_trace_errors fence_queued fence_armed read_received proof_confirmed} {
        dict set diag $key [expr {[dict exists $verification_counts $key] ? [dict get $verification_counts $key] : 0}]
    }
    dict set diag requested_state_ack_seen [expr {[dict exists $verification_counts requested_state_ack_seen] ?
        [dict get $verification_counts requested_state_ack_seen] : 0}]
    foreach key {ack_value_length ack_payload_matches ack_serial_matches} {
        dict set diag $key [expr {[dict exists $verification_counts $key] ? [dict get $verification_counts $key] : ""}]
    }
    return $diag
}

proc ::aiden::core::_write_is_inflight {} {
    variable transport_write
    if {$transport_write eq {} || ![dict get $transport_write accepted] ||
        ![string is true -strict [_read ::de1(wrote)]]} {return 0}
    set previous [_read ::de1(previouscmd)]
    return [expr {[llength $previous] == 4 && [namespace tail [lindex $previous 0]] eq "de1_comm" &&
        [lrange $previous 1 2] eq {write RequestedState} &&
        [lindex $previous 3] eq [dict get $transport_write payload]}]
}

# Execution trace errors must never interrupt a native queue or BLE callback.
proc ::aiden::core::_queue_trace {command operation} {
    if {[catch {::aiden::core::_queue_observed $command}]} {_verification_count queue_trace_errors}
}

proc ::aiden::core::_queue_observed {command} {
    variable pending_request
    variable request_context
    if {$request_context eq {} || $pending_request eq {} ||
        [dict get $pending_request action] ne "stop" ||
        [dict get $pending_request id] ne $request_context} {return}
    set cmd [lindex $command 2]
    if {[namespace tail [lindex $cmd 0]] eq "de1_comm" &&
        [lrange $cmd 1 2] eq {write RequestedState} && [_idle_payload [lindex $cmd 3]]} {
        dict set pending_request stop_enqueued 1
    }
}

proc ::aiden::core::_comm_trace {command args} {
    if {[catch {::aiden::core::_comm_observed $command {*}$args}]} {_verification_count dispatch_trace_errors}
}

proc ::aiden::core::_comm_observed {command args} {
    variable transport_sequence
    variable transport_write
    variable transport_read
    variable transport_read_context
    variable transport_calls
    set operation [lindex $args end]
    if {$operation eq "enter"} {
        set ticket {}
        if {[lrange $command 1 2] eq {write RequestedState}} {
            incr transport_sequence
            set ticket $transport_sequence
            set transport_write [dict create ticket $ticket payload [lindex $command 3] \
                handle [_read ::de1(device_handle)] accepted 0 acknowledged 0]
        } elseif {[lrange $command 1 2] eq {read StateInfo} && $transport_read_context eq {}} {
            # A different read cannot be mistaken for the explicit Stop fence.
            set transport_read {}
        }
        lappend transport_calls $ticket
    } elseif {$operation eq "leave" && [llength $transport_calls]} {
        set ticket [lindex $transport_calls end]
        set transport_calls [lrange $transport_calls 0 end-1]
        if {$ticket ne {} && $transport_write ne {} && [dict get $transport_write ticket] eq $ticket} {
            dict set transport_write accepted [expr {[lindex $args 0] == 0 && [lindex $args 1] eq "1"}]
        }
    }
}

proc ::aiden::core::_ble_trace {command args} {
    if {[catch {::aiden::core::_ble_observed $command {*}$args}]} {_verification_count callback_trace_errors}
}

proc ::aiden::core::_ble_observed {command args} {
    variable ble_calls
    variable transport_write
    variable transport_read
    variable verification_counts
    set operation [lindex $args end]
    if {$operation eq "enter"} {
        set read {}
        set data [lindex $command 2]
        if {[lindex $command 1] eq "characteristic" && ![catch {dict size $data}]} {
            set valid 1
            foreach key {handle state suuid cuuid access value} {
                if {![dict exists $data $key]} {set valid 0}
            }
            if {$valid && [dict get $data state] eq "connected" &&
                [dict get $data handle] eq [_read ::de1(device_handle)] &&
                [_read ::de1(suuid)] ne {} &&
                [dict get $data suuid] eq [_read ::de1(suuid)] &&
                [dict get [_connection device_handle] connected]} {
                set access [dict get $data access]
                set cuuid [dict get $data cuuid]
                if {$access eq "w" && [_read ::de1(cuuid_02)] ne {} && $cuuid eq [_read ::de1(cuuid_02)]} {
                    _verification_count requested_state_ack_seen
                    dict set verification_counts ack_value_length [string length [dict get $data value]]
                    dict set verification_counts ack_payload_matches [expr {$transport_write ne {} &&
                        [dict get $transport_write payload] eq [dict get $data value]}]
                    dict set verification_counts ack_serial_matches [_write_is_inflight]
                }
                if {$access eq "w" && [_read ::de1(cuuid_02)] ne {} &&
                    $cuuid eq [_read ::de1(cuuid_02)] && $transport_write ne {} &&
                    [dict get $transport_write accepted] &&
                    [dict get $transport_write handle] eq [dict get $data handle] &&
                    [dict get $transport_write payload] eq [dict get $data value]} {
                    # Observe before native run_next_userdata_cmd dispatches the
                    # next queue entry, otherwise the write identity is lost.
                    dict set transport_write acknowledged 1
                } elseif {$access eq "r" && [_read ::de1(cuuid_0E)] ne {} &&
                    $cuuid eq [_read ::de1(cuuid_0E)] && $transport_read ne {}} {
                    set read [dict merge $transport_read [dict create value [dict get $data value]]]
                    set transport_read {}
                    _verification_count read_received
                }
            }
        }
        lappend ble_calls $read
    } elseif {$operation eq "leave" && [llength $ble_calls]} {
        set read [lindex $ble_calls end]
        set ble_calls [lrange $ble_calls 0 end-1]
        if {$read ne {} && [lindex $args 0] == 0} {_reconcile_idle_read $read}
    }
}

proc ::aiden::core::_read_after_stop {id epoch} {
    variable pending_request
    variable connection_epoch
    variable transport_write
    variable transport_read
    variable transport_read_context
    set transport_read {}
    if {$pending_request ne {} && [dict get $pending_request id] eq $id &&
        [dict get $pending_request action] eq "stop" && $epoch == $connection_epoch &&
        [dict exists $pending_request stop_enqueued] && [dict get $pending_request stop_enqueued] &&
        $transport_write ne {} && [dict get $transport_write acknowledged] &&
        [_idle_payload [dict get $transport_write payload]]} {
        set transport_read [dict create id $id epoch $epoch write_ticket [dict get $transport_write ticket]]
        _verification_count fence_armed
    }
    # This one read was queued only by an explicit Stop. It follows the native
    # Idle write in the existing serial queue and adds no timer or physical start.
    set transport_read_context $id
    set code [catch {::de1_comm read StateInfo} result options]
    set transport_read_context {}
    if {$code || $result ne "1"} {set transport_read {}}
    if {$code} {return -options $options $result}
    return $result
}

proc ::aiden::core::_reconcile_idle_read {read} {
    variable pending_request
    variable observed_operation
    variable connection_epoch
    variable transport_write
    variable request_reconciliation
    variable last_state_event
    variable event_sequence
    if {$pending_request eq {} || [dict get $pending_request id] ne [dict get $read id] ||
        [dict get $pending_request action] ne "stop" || [dict get $read epoch] != $connection_epoch ||
        ![dict get [_connection device_handle] connected] || $transport_write eq {} ||
        [dict get $transport_write ticket] ne [dict get $read write_ticket] ||
        ![dict get $transport_write acknowledged] || [_native_state] ne "Idle" || [_finalizing]} {return}
    if {$observed_operation ne {} && [dict get $observed_operation flow_confirmed] &&
        ![dict get $observed_operation flow_ended]} {return}
    set value [dict get $read value]
    if {[string length $value] != 2} {return}
    binary scan $value cc state substate
    if {($state & 255) != [_read ::de1(state)] || ($substate & 255) != [_read ::de1(substate)] ||
        [_native_substate] eq "unknown" || [string match Error_* [_native_substate]]} {return}
    foreach entry [_read ::de1(cmdstack)] {
        set cmd [lindex $entry 1]
        if {[namespace tail [lindex $cmd 0]] eq "de1_comm" && [lrange $cmd 1 2] eq {write RequestedState}} {return}
    }
    set now [expr {[clock milliseconds] / 1000.0}]
    set request_reconciliation [dict create id [dict get $pending_request id] action stop \
        new_operation [dict get $pending_request new_operation] source native_stop_ack_and_idle_read event_time $now]
    set pending_request {}
    set last_state_event [dict create this_state Idle this_substate [_native_substate] \
        previous_state Idle previous_substate [_native_substate] event_time $now source native_state_read]
    incr event_sequence
    _verification_count proof_confirmed
}

proc ::aiden::core::command {action args} {
    variable pending_request
    variable request_sequence
    variable request_context
    variable request_reconciliation
    set s [snapshot]
    set mode {}
    if {$action eq "start"} {
        if {[llength $args] != 1 || [lindex $args 0] ni {espresso flush steam water}} {
            error {Start requires espresso, flush, steam, or water}
        }
        set mode [lindex $args 0]
        if {![dict get $s start_verified] || ![dict get $s can_start_by_mode $mode]} {
            error [dict get $s start_reasons $mode]
        }
        set api ::start_$mode
    } else {
        if {[llength $args]} {error "$action accepts no arguments"}
        switch -- $action {
            stop {
                if {![dict get $s connected]} {error {Stop delivery cannot be verified while disconnected}}
                if {[dict get $s native_state] in {Sleep GoingToSleep}} {error {The machine is sleeping; use explicit Wake}}
                set api ::start_idle
            }
            tare {
                if {![dict get $s scale_connected]} {error {No connected scale is available to tare}}
                set api ::device::scale::tare
            }
            reconnect_scale {
                if {![dict get $s scale_configured]} {error {Choose a scale in native settings first}}
                if {[dict get $s scale_connected]} {error {The scale is already connected}}
                set api ::ble_connect_to_scale
            }
            advance {
                if {![dict get $s stage_advance_verified] || ![dict get $s stage_advance_available]} {
                    error {Native stage advance is unavailable in this state}
                }
                set api ::start_next_step
            }
            sleep {
                if {![dict get $s connected] || [dict get $s native_state] ne "Idle" || $pending_request ne {}} {
                    error {Sleep requires a connected idle machine with no pending request}
                }
                set api ::start_sleep
            }
            wake {
                if {![dict get $s connected] || [dict get $s native_state] ne "Sleep" || $pending_request ne {}} {
                    error {Wake requires a connected sleeping machine with no pending request}
                }
                set api ::start_idle
            }
            default {error "Unsupported Aiden action: $action"}
        }
    }
    if {![_has $api]} {error "The installed action $api is unavailable"}
    set track [expr {$action in {start stop sleep wake}}]
    if {$track} {
        set new_operation [expr {$action eq "start" || ($pending_request ne {} && \
            [dict exists $pending_request new_operation] && [dict get $pending_request new_operation])}]
        incr request_sequence
        set pending_request [dict create id $request_sequence action $action mode $mode api $api status requested \
            request_time [expr {[clock milliseconds] / 1000.0}] new_operation $new_operation]
        set request_reconciliation {}
    }
    if {$action eq "stop"} {
        variable observed_operation
        if {$observed_operation ne {} && ![dict get $observed_operation flow_ended]} {
            dict set observed_operation manual_stop_requested 1
        }
    }
    if {$track} {set request_context $request_sequence}
    set code [catch {uplevel #0 [list $api]} result options]
    set request_context {}
    if {$code} {
        # A thrown request may already have reached a transport. Keep pending.
        if {$track} {dict set pending_request status uncertain}
        return -options $options $result
    }
    variable hook_flags
    if {$action eq "stop" && [dict get $s native_state] eq "Idle" && ![dict get $s flow_confirmed] &&
        $pending_request ne {} && [dict get $pending_request id] == $request_sequence &&
        [dict exists $pending_request stop_enqueued] && [dict get $pending_request stop_enqueued] &&
        [dict exists $hook_flags ::de1_ble_handler] && [dict exists $hook_flags ::de1_comm]} {
        variable connection_epoch
        # A fence read is an observation in the same queue, not a second Stop.
        # Queue failure preserves pending uncertainty instead of acknowledging.
        if {[catch {::userdata_append {Aiden Stop state verification} \
            [list ::aiden::core::_read_after_stop $request_sequence $connection_epoch] 1}]} {
            if {$pending_request ne {}} {dict set pending_request status uncertain}
        } else {
            _verification_count fence_queued
        }
    }
    return [dict create action $action mode $mode api $api status requested confirmed 0 native_return $result \
        requires_group_head [expr {$action eq "start" && [dict get $s start_requires_group_head]}]]
}

proc ::aiden::core::native_page_exists {page} {
    if {![_has ::dui] || ![regexp {^[A-Za-z_][A-Za-z0-9_]*$} $page]} {return 0}
    if {![catch {::dui page exists $page} declared] && [_boolean $declared]} {return 1}
    # Inspected DUI::page::exists checks only a declared background marker.
    # DSx2 off/saver and some native settings have p:<page> items without one.
    # DUI's own loader and items API support these legacy pages directly.
    if {![catch {::dui page items $page} items] && [llength $items] > 0} {return 1}
    # Native saver images are created directly with the page-name tag rather
    # than p:<page> or pages markers (gui.tcl set_de1_screen_saver_directory).
    if {[catch {
        set canvas [::dui canvas]
        set legacy_items [$canvas find withtag $page]
    }]} {return 0}
    return [expr {[llength $legacy_items] > 0}]
}

proc ::aiden::core::route {target} {
    set s [snapshot]
    if {[dict get $s pending] eq "stop"} {
        error {Waiting for machine confirmation of Stop; navigation is locked}
    }
    set sleeping [expr {[dict get $s connected] && [dict get $s native_state] eq "Sleep" && \
        [dict get $s pending] eq {} && ![dict get $s native_finalization_pending]}]
    set offline_setup [expr {$target in {scale app history original native_home} && ![dict get $s connected] && \
        [dict get $s pending] eq {} && ![dict get $s native_finalization_pending] && \
        [_mode [dict get $s native_state]] eq {} && \
        (![dict get $s flow_confirmed] || [dict get $s flow_ended])}]
    if {(![dict get $s editable] && !$sleeping && !$offline_setup) || ![dict get $s context_verified]} {
        error {Native utilities require a verified idle machine and current screen}
    }
    if {[_boolean [_read ::settings(stress_test)] 1] || [_read ::idle_next_step] ne {}} {
        error {Native stress-test navigation may start an operation}
    }
    if {![_has ::dui]} {error {Native page routing is unavailable}}
    set page {}
    switch -- $target {
        profiles {set page settings_1}
        settings - machine - maintenance - cleaning {set page settings_3}
        scale - app {set page settings_4}
        extensions {set page extensions}
        workflow {set page workflow_settings}
        descale {set page descale_prepare}
        history {set page history_viewer}
        original - native_home {set page off}
        calibration {error {Open calibration from native machine settings to retain its warning and initialization}}
        dye {
            if {![_has ::plugins::DYE::open]} {error {The installed DYE extension is unavailable}}
            ::plugins::DYE::open -which_shot last
            return [dict create target dye status opened return_policy native_page]
        }
        default {error "Unsupported native route: $target"}
    }
    if {![native_page_exists $page]} {
        error "The installed destination $page is unavailable"
    }
    if {$page in {settings_1 settings_3 settings_4 extensions descale_prepare}} {
        if {![_has ::backup_settings]} {error {Native settings backup is unavailable}}
        ::backup_settings
        # This is the inspected native settings transaction callback variable.
        # Native Save/Cancel retains its own transmission/heating side effects.
        set ::settings_optional_callback {}
    }
    if {$page eq "extensions"} {
        if {![_has ::fill_extensions_listbox]} {error {Native extension catalog is unavailable}}
        ::fill_extensions_listbox
    }
    # page_show/page_to_show_when_off also send a user-present MMR notice.
    # Direct DUI navigation avoids that physical side effect of mere routing.
    ::dui page load $page
    return [dict create target $target page $page status opened return_policy native_page]
}
