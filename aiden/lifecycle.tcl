# SPDX-License-Identifier: GPL-3.0-only
# Aiden operation presentation. This file is deliberately independent of Tk,
# device APIs, native persistence, and clocks. Only installed-core snapshots
# establish activity, flow end, and result finalization.
#
# Public API:
#   reset ?optionsDict?                 options: mode, workflow, recipe,
#                                      mode_order, skipped_modes, mode_values
#   ingest snapshotDict                a complete observed core snapshot
#   request start|stop|stage-advance ?detailsDict?
#                                      returns accepted, intent, mode, reason,
#                                      and presentation; dispatch is the caller's job
#   presentation                       returns a UI dictionary
#   select_mode mode                   presentation navigation only
#   configure_workflow workflow ?optionsDict?
#   complete_hold ?resultId?            optional UI reading hold completed;
#                                      ordinary completion only; espresso also
#                                      needs its confirmed native history record
#   continue ?resultId?                 explicit presentation continuation
#   result / operation_result / history
#
# Required snapshot keys are documented by the core adapter. Missing booleans
# default false and missing numbers remain empty. Start additionally requires
# start_verified and can_start_by_mode. Optional exact identity/ordering keys:
# operation_id, snapshot_sequence, result_id, history_id, final_result.
# Final measurements are immutable; later save acknowledgements live separately
# in persistence_status and history_status. Observation IDs are never advertised
# as native history identities. A recovery result requires an identified native
# final_result; a bare idle state never manufactures a shot.

namespace eval ::aiden::lifecycle {
    variable data
    if {![info exists data]} {set data {}}
    variable mode_names {espresso Espresso flush Flush steam Steam water {Hot water}}
    variable workflows {espresso espresso latte {espresso flush steam} americano {espresso water} steam {espresso steam}}
}

proc ::aiden::lifecycle::_get {value key {fallback {}}} {
    if {[dict exists $value $key]} {return [dict get $value $key]}
    return $fallback
}

proc ::aiden::lifecycle::_bool {value} {
    if {![string is boolean -strict $value]} {return 0}
    return [expr {$value ? 1 : 0}]
}

proc ::aiden::lifecycle::_number {value {nonnegative 0}} {
    if {![string is double -strict $value] || [regexp -nocase {nan|inf} $value]} {return {}}
    if {[catch {expr {$value + 0.0}} n]} {return {}}
    if {$nonnegative && $n < 0} {return {}}
    return $n
}

proc ::aiden::lifecycle::_valid_dict {value} {
    return [expr {![catch {dict size $value}]}]
}

proc ::aiden::lifecycle::_mode {mode} {
    switch -- [string tolower $mode] {
        espresso {return espresso}
        flush - hot_water_rinse {return flush}
        steam {return steam}
        water - hotwater - hot_water {return water}
    }
    return {}
}

proc ::aiden::lifecycle::_native_kind {snapshot} {
    switch -- [dict get $snapshot state] {
        espresso - steam - hot_water - hot_water_rinse {return operation}
        idle {return idle}
        refill - clean - descale - air_purge {return specialist}
        sleep - going_to_sleep {return blocked}
    }
    if {[_bool [_get $snapshot operation_active]]} {return operation}
    return unknown
}

proc ::aiden::lifecycle::_snapshot {raw} {
    if {![_valid_dict $raw]} {error "A lifecycle snapshot must be a dictionary"}
    set snapshot [dict merge [dict create state unknown substate {} mode {} connected 0 ready 0 \
        elapsed {} weight {} scale_connected 0 temperature {} profile_title {} dose {} \
        target_yield {} target_temp {} flow_confirmed 0 flow_ended 0 result_finalized 0 \
        start_verified 0 can_start_by_mode {} stage_advance_verified 0 stage_advance_available 0 \
        operation_ending 0 operation_id {}] $raw]
    dict set snapshot state [string tolower [dict get $snapshot state]]
    dict set snapshot substate [string tolower [dict get $snapshot substate]]
    foreach key {connected ready scale_connected flow_confirmed flow_ended result_finalized start_verified stage_advance_verified stage_advance_available operation_ending} {
        dict set snapshot $key [_bool [dict get $snapshot $key]]
    }
    foreach key {elapsed dose target_yield} {dict set snapshot $key [_number [dict get $snapshot $key] 1]}
    foreach key {weight temperature target_temp} {dict set snapshot $key [_number [dict get $snapshot $key]]}
    set mode [_mode [dict get $snapshot mode]]
    if {$mode eq {}} {set mode [_mode [dict get $snapshot state]]}
    dict set snapshot mode $mode
    if {![_valid_dict [dict get $snapshot can_start_by_mode]]} {dict set snapshot can_start_by_mode {}}
    set pending [_get $snapshot pending_request]
    if {[_valid_dict $pending] && $pending ne {}} {
        if {![dict exists $snapshot request_outcome]} {dict set snapshot request_outcome [_get $pending status]}
        if {![dict exists $snapshot request_action]} {dict set snapshot request_action [_get $pending action]}
    }
    return $snapshot
}

proc ::aiden::lifecycle::_recipe {snapshot} {
    set recipe [_get $snapshot recipe]
    if {![_valid_dict $recipe]} {set recipe {}}
    foreach key {profile_title profile_id dose target_yield target_temp} {
        if {[dict exists $snapshot $key]} {dict set recipe $key [dict get $snapshot $key]}
    }
    set title [_get $recipe profile_title [_get $recipe title]]
    foreach key {profile title name} {dict set recipe $key $title}
    dict set recipe yield [_get $recipe target_yield]
    dict set recipe temp [_get $recipe target_temp]
    return $recipe
}

proc ::aiden::lifecycle::_operation_recipe {snapshot} {
    set frozen [_get $snapshot operation_recipe]
    if {[_valid_dict $frozen] && $frozen ne {}} {
        dict set snapshot recipe $frozen
        foreach key {profile_title profile_id dose target_yield target_temp} {
            if {[dict exists $frozen $key]} {dict set snapshot $key [dict get $frozen $key]}
        }
    }
    return [_recipe $snapshot]
}

proc ::aiden::lifecycle::_weight {snapshot} {
    if {![dict get $snapshot scale_connected]} {return [dict create value {} quality unavailable]}
    set quality [string tolower [_get $snapshot weight_quality valid]]
    if {[_get $snapshot weight_fresh 1] ne {} && ![_bool [_get $snapshot weight_fresh 1]]} {set quality stale}
    if {$quality ni {valid measured final}} {return [dict create value {} quality $quality]}
    set weight [dict get $snapshot weight]
    if {$weight eq {}} {return [dict create value {} quality unavailable]}
    return [dict create value $weight quality valid]
}

proc ::aiden::lifecycle::_outcome {snapshot} {
    set final [_get $snapshot final_result]
    if {![_valid_dict $final]} {set final {}}
    foreach value [list [_get $snapshot stop_reason] [_get $snapshot outcome] [_get $final outcome]] {
        switch -- [string tolower $value] {
            normal - ordinary - complete - completed - automatic - success - target_reached - target-reached {return normal}
            manual - manual_stop - manual-stop - user_stop - physical_stop - operator_request {return manual}
            fault - failed - failure - error {return fault}
        }
    }
    return unknown
}

proc ::aiden::lifecycle::_fault {snapshot} {
    return [expr {[_bool [_get $snapshot faulted]] || [_get $snapshot fault] ne {} || \
        [_get $snapshot state] eq "fatal_error"}]
}

proc ::aiden::lifecycle::reset {{options {}}} {
    variable data
    variable workflows
    if {![_valid_dict $options]} {error "Lifecycle reset options must be a dictionary"}
    set mode [_mode [_get $options mode espresso]]
    set workflow [_get $options workflow espresso]
    if {$mode eq {}} {error "Unknown Aiden mode"}
    if {![dict exists $workflows $workflow]} {error "Unknown Aiden workflow"}
    set order [_validate_order [_get $options mode_order [dict get $workflows $workflow]]]
    set skipped [_validate_skipped [_get $options skipped_modes] $order]
    set serial [_get $data serial 0]
    set data [dict create machine [_snapshot {}] selected_mode $mode workflow $workflow \
        mode_order $order skipped_modes $skipped mode_values [_get $options mode_values] recipe [_get $options recipe] \
        current {} serial $serial last_sequence {} previous_native_active 0 retired_native_ids {} \
        last_result {} retained_result {} history {} history_status {} persistence_status {} \
        prepared_after_result 0 reason {} last_known_weight {} last_known_temperature {} unresolved {}]
    return [presentation]
}

proc ::aiden::lifecycle::_validate_order {order} {
    set result {}
    foreach mode $order {
        set mode [_mode $mode]
        if {$mode eq {}} {error "Workflow order contains an unsupported mode"}
        if {$mode in $result} {error "Workflow order cannot contain duplicate modes"}
        lappend result $mode
    }
    if {[lindex $result 0] ne "espresso"} {error "A beverage workflow must begin with espresso"}
    return $result
}

proc ::aiden::lifecycle::_validate_skipped {skipped order} {
    set result {}
    foreach mode $skipped {
        set mode [_mode $mode]
        if {$mode eq {} || $mode eq "espresso"} {error "Only optional flush, steam, or water modes can be skipped"}
        if {$mode ni $order} {error "A skipped mode must belong to the configured workflow order"}
        if {$mode in $result} {error "A skipped mode cannot be listed twice"}
        lappend result $mode
    }
    return $result
}

proc ::aiden::lifecycle::_sequence {} {
    variable data
    set result {}
    foreach mode [dict get $data mode_order] {
        if {$mode ni [dict get $data skipped_modes]} {lappend result $mode}
    }
    return $result
}

proc ::aiden::lifecycle::_next_mode {} {
    variable data
    set current [dict get $data current]
    set mode [dict get $data selected_mode]
    if {$current ne {}} {set mode [dict get $current mode]}
    set sequence [_sequence]
    set index [lsearch -exact $sequence $mode]
    if {$index < 0 || $index + 1 >= [llength $sequence]} {return {}}
    return [lindex $sequence [expr {$index + 1}]]
}

proc ::aiden::lifecycle::_begin {snapshot {requested 0} {recovered 0}} {
    variable data
    set previous [dict get $data current]
    if {$previous ne {} && [dict get $previous native_id] ne {} && \
        [dict get $previous native_id] ni [dict get $data retired_native_ids]} {
        dict lappend data retired_native_ids [dict get $previous native_id]
    }
    dict incr data serial
    set native_id [dict get $snapshot operation_id]
    set mode [dict get $snapshot mode]
    if {$mode eq {}} {set mode [dict get $data selected_mode]}
    set current [dict create id observation-[dict get $data serial] native_id $native_id mode $mode \
        recipe [_operation_recipe $snapshot] requested $requested observed [expr {!$requested}] recovered $recovered \
        flow_confirmed 0 flow_ended 0 elapsed {} flow_elapsed {} elapsed_quality unconfirmed \
        weight {} weight_quality unavailable graph_samples {} stop_requested 0 manual_stop_requested 0 \
        auto_cancelled $recovered uncertain 0 finalized 0 outcome unknown result {} \
        stage_advance_pending 0 requested_stage {} flow_end_seen 0]
    dict set data current $current
    dict set data selected_mode $mode
    dict set data prepared_after_result 0
    dict set data persistence_status {}
    dict set data reason {}
}

proc ::aiden::lifecycle::_possible_active {} {
    variable data
    set current [dict get $data current]
    set machine [dict get $data machine]
    if {[_native_kind $machine] in {operation specialist} && ![dict get $machine flow_ended]} {return 1}
    return [expr {$current ne {} && ![dict get $current flow_ended] && ![dict get $current finalized]}]
}

proc ::aiden::lifecycle::_busy {} {
    variable data
    set current [dict get $data current]
    return [expr {[_possible_active] || ($current ne {} && ![dict get $current finalized])}]
}

proc ::aiden::lifecycle::_prepared_allowed {} {
    variable data
    set machine [dict get $data machine]
    return [expr {[dict get $machine connected] && [_native_kind $machine] eq "idle" && ![_fault $machine]}]
}

proc ::aiden::lifecycle::_start_allowed {} {
    variable data
    if {![_prepared_allowed] || [_busy]} {return 0}
    set machine [dict get $data machine]
    set allowed [_get [dict get $machine can_start_by_mode] [dict get $data selected_mode]]
    return [expr {[dict get $machine ready] && [dict get $machine start_verified] && [_bool $allowed]}]
}

proc ::aiden::lifecycle::_phase {} {
    variable data
    set machine [dict get $data machine]
    set current [dict get $data current]
    if {$current eq {}} {
        if {[_prepared_allowed]} {return prepared}
        return unknown-or-blocked
    }
    if {![dict get $machine connected] || [_fault $machine]} {return unknown-or-blocked}
    if {[_native_kind $machine] in {operation specialist} && [dict get $current flow_ended] && \
        ![dict get $machine flow_ended]} {return unknown-or-blocked}
    if {[dict get $current finalized]} {
        if {[_native_kind $machine] ne "idle"} {return unknown-or-blocked}
        if {[dict get $data prepared_after_result]} {return next-mode-prepared}
        return result
    }
    if {[dict get $current flow_ended]} {
        if {[dict get $current flow_end_seen] <= 1} {return flow-ended}
        return settling
    }
    if {[_native_kind $machine] in {unknown specialist blocked}} {return unknown-or-blocked}
    if {[dict get $current stop_requested] || [dict get $machine operation_ending]} {return stop-requested}
            if {![dict get $current observed]} {
        if {[dict get $current uncertain]} {return unknown-or-blocked}
        return start-requested
    }
    if {[_native_kind $machine] eq "idle"} {return unknown-or-blocked}
    return active
}

proc ::aiden::lifecycle::_stage_available {} {
    variable data
    set machine [dict get $data machine]
    set current [dict get $data current]
    if {$current eq {} || [_phase] ne "active"} {return 0}
    return [expr {[dict get $current mode] eq "espresso" && [dict get $current flow_confirmed] && \
        ![dict get $current stage_advance_pending] && [dict get $machine stage_advance_verified] && \
        [dict get $machine stage_advance_available]}]
}

proc ::aiden::lifecycle::_stage_identity {snapshot} {
    foreach key {stage_id stage_number stage_name} {
        set value [_get $snapshot $key]
        if {$value ne {}} {return $value}
    }
    return {}
}

proc ::aiden::lifecycle::_reply {accepted intent {reason {}}} {
    variable data
    return [dict create accepted $accepted intent $intent mode [dict get $data selected_mode] \
        reason $reason presentation [presentation]]
}

proc ::aiden::lifecycle::request {action {details {}}} {
    variable data
    if {![_valid_dict $details]} {error "Lifecycle request details must be a dictionary"}
    switch -- $action {
        start {
            if {[_phase] ni {prepared next-mode-prepared} || ![_start_allowed]} {
                return [_reply 0 start {Start is unavailable until native readiness and capability are verified}]
            }
            set snapshot [dict get $data machine]
            dict set snapshot mode [dict get $data selected_mode]
            dict set snapshot operation_id {}
            if {[dict exists $details recipe]} {dict set snapshot recipe [dict get $details recipe]}
            _begin $snapshot 1
            return [_reply 1 start]
        }
        stop {
            if {![_possible_active]} {return [_reply 0 stop {No operation may be active}]}
            set current [dict get $data current]
            if {[dict get $current stop_requested]} {return [_reply 0 stop {Stop is already requested}]}
            dict set current stop_requested 1
            dict set current manual_stop_requested 1
            dict set current auto_cancelled 1
            dict set current stage_advance_pending 0
            dict set data current $current
            return [_reply 1 stop]
        }
        advance - stage-advance {
            if {![_stage_available]} {return [_reply 0 stage-advance {Native stage advance is unavailable}]}
            set current [dict get $data current]
            set machine [dict get $data machine]
            dict set current stage_advance_pending 1
            dict set current requested_stage [_stage_identity $machine]
            dict set data current $current
            return [_reply 1 stage-advance]
        }
        default {return [_reply 0 $action {Unsupported lifecycle request}]}
    }
}

proc ::aiden::lifecycle::_reconcile_save {snapshot} {
    variable data
    set current [dict get $data current]
    if {$current eq {} || ![dict get $current finalized]} {return}
    set final [_get $snapshot final_result]
    if {![_valid_dict $final]} {set final {}}
    set native_id [dict get $current native_id]
    if {$native_id ne {} && [_get $final operation_id] ne {} && [_get $final operation_id] ne $native_id} {return}
    set result_id [_get $snapshot result_id [_get $final result_id]]
    set frozen_result_id [dict get $current result native_result_id]
    if {$result_id ne {} && $frozen_result_id ne {} && $result_id ne $frozen_result_id} {return}
    set status [dict get $data persistence_status]
    if {$status eq {}} {
        set status [dict create saved 0 confirmed 0 history_id {} error {} \
            history_required [expr {[dict get $current mode] eq "espresso"}]]
    }
    if {[dict exists $snapshot result_saved] || [dict exists $final result_saved]} {
        dict set status confirmed 1
        set reported_saved [_bool [_get $snapshot result_saved [_get $final result_saved]]]
        if {$reported_saved && $native_id ne {}} {
            dict set status saved 1
            dict set status error {}
        } elseif {![dict get $status saved]} {
            dict set status error [_get $snapshot save_error [_get $final save_error]]
            if {$reported_saved && $native_id eq {}} {dict set status error {Native result identity unconfirmed}}
        }
    }
    set history_id [_get $snapshot history_id [_get $final history_id [_get $snapshot history_saved_shot_filename]]]
    if {$history_id ne {}} {dict set status history_id $history_id}
    if {![_bool [_get $snapshot result_saved]] && [_get $snapshot save_error] ne {} && ![dict get $status saved]} {
        dict set status error [dict get $snapshot save_error]
        dict set status confirmed 1
    }
    dict set data persistence_status $status
    dict set data history_status [dict get $current id] $status
}

proc ::aiden::lifecycle::_finalize {snapshot} {
    variable data
    set current [dict get $data current]
    if {[dict get $current finalized]} {return}
    set final [_get $snapshot final_result]
    if {![_valid_dict $final]} {set final {}}
    set duration [dict get $current flow_elapsed]
    if {$duration eq {}} {
        set duration [_number [_get $snapshot final_elapsed [_get $final final_elapsed [_get $final elapsed [_get $final time]]]] 1]
    }
    set weight [dict get $current weight]
    set quality [dict get $current weight_quality]
    if {[dict exists $snapshot final_weight]} {
        set weight [_number [dict get $snapshot final_weight]]
    } elseif {[dict exists $final final_weight] || [dict exists $final weight] || [dict exists $final yield]} {
        set weight [_number [_get $final final_weight [_get $final weight [_get $final yield]]]]
    }
    if {[dict exists $snapshot final_weight_quality]} {
        set quality [string tolower [dict get $snapshot final_weight_quality]]
    } elseif {[dict exists $final final_weight_quality] || [dict exists $final weight_quality]} {
        set quality [string tolower [_get $final final_weight_quality [_get $final weight_quality]]]
    }
    if {$weight eq {} || $quality ni {valid measured final native_final_estimate qualified}} {
        set weight {}
        if {$quality in {valid measured final} || $quality eq {}} {set quality unavailable}
    }
    set recipe [dict get $current recipe]
    set native_id [dict get $current native_id]
    if {$native_id ne {} && [_get $final operation_id] eq $native_id && \
        [_valid_dict [_get $final recipe]] && [_get $final recipe] ne {}} {
        dict set snapshot operation_recipe [dict get $final recipe]
        set recipe [_operation_recipe $snapshot]
    }
    set identity_quality observed
    if {$native_id ne {}} {set identity_quality native}
    set outcome [dict get $current outcome]
    set outcome_label [_get $snapshot outcome_label [_get $final outcome_label]]
    if {$outcome_label eq {}} {
        switch -- $outcome {
            normal {set outcome_label Complete}
            manual {set outcome_label {Manual stop}}
            fault {set outcome_label Fault}
            default {set outcome_label {Outcome unconfirmed}}
        }
    }
    set result [dict create id [dict get $current id] operation_id $native_id identity_quality $identity_quality \
        native_result_id [_get $snapshot result_id [_get $final result_id [_get $final id]]] mode [dict get $current mode] \
        recipe $recipe profile_title [_get $recipe profile_title] profile [_get $recipe profile_title] \
        dose [_get $recipe dose] target_yield [_get $recipe target_yield] target_temp [_get $recipe target_temp] \
        elapsed $duration time $duration weight $weight yield $weight weight_quality $quality \
        outcome $outcome outcome_label $outcome_label manual_stop_requested [dict get $current manual_stop_requested] \
        graph_samples [_get $final graph_samples [dict get $current graph_samples]] \
        timestamp [_get $final timestamp [_get $snapshot result_timestamp]]]
    dict set current finalized 1
    dict set current result $result
    dict set data current $current
    dict set data last_result $result
    if {[dict get $current mode] eq "espresso"} {
        dict set data retained_result $result
        dict set data history [linsert [dict get $data history] 0 $result]
    }
    _reconcile_save $snapshot
}

proc ::aiden::lifecycle::ingest {raw} {
    variable data
    set snapshot [_snapshot $raw]
    set sequence [_number [_get $snapshot snapshot_sequence] 1]
    set last_sequence [dict get $data last_sequence]
    # The installed adapter sequence orders state events. Equal sequences may
    # contain fresh sensor readings and must still be consumed.
    if {$sequence ne {} && $last_sequence ne {} && $sequence < $last_sequence} {return [presentation]}
    set current [dict get $data current]
    set native_id [dict get $snapshot operation_id]
    set kind [_native_kind $snapshot]
    set native_active [expr {$kind in {operation specialist}}]
    if {$current ne {} && $native_id ne {} && $native_id ne [dict get $current native_id] && \
        $native_id in [dict get $data retired_native_ids]} {
        if {![dict get $current observed]} {
            # Native current-state reads can still carry the preceding result
            # while a fresh request waits for its own operation observation.
            foreach key {flow_confirmed flow_ended result_finalized result_saved} {dict set snapshot $key 0}
            dict set snapshot operation_id {}
            dict set snapshot final_result {}
            dict set snapshot operation_recipe {}
            set native_id {}
        } else {return [presentation]}
    }
    set final [_get $snapshot final_result]
    set recovery_candidate [expr {!$native_active && [dict get $snapshot flow_ended] && \
        [dict get $snapshot result_finalized] && $native_id ne {} && [_valid_dict $final] && \
        [_get $final operation_id] eq $native_id}]
    set mismatched_id [expr {$current ne {} && $native_id ne {} && \
        [dict get $current native_id] ne {} && $native_id ne [dict get $current native_id]}]
    if {$mismatched_id && !$native_active && !$recovery_candidate} {return [presentation]}
    if {$sequence ne {}} {dict set data last_sequence $sequence}
    set was_active [dict get $data previous_native_active]
    dict set data machine $snapshot
    dict set data previous_native_active $native_active
    dict set data recipe [_recipe $snapshot]
    set reading [_weight $snapshot]
    if {[dict get $reading value] ne {}} {
        dict set data last_known_weight [dict get $reading value]
    } elseif {[_number [_get $snapshot last_known_weight]] ne {}} {
        dict set data last_known_weight [_number [dict get $snapshot last_known_weight]]
    }
    if {[dict get $snapshot temperature] ne {}} {dict set data last_known_temperature [dict get $snapshot temperature]}

    set new_operation [expr {$current eq {} && $native_active}]
    if {$current ne {} && $native_active && [dict get $current observed]} {
        set distinct_id [expr {$native_id ne {} && [dict get $current native_id] ne {} && $native_id ne [dict get $current native_id]}]
        set distinct_edge [expr {([dict get $current finalized] || [dict get $current flow_ended]) && !$was_active && \
            ($native_id eq {} || [dict get $current native_id] eq {})}]
        set distinct_mode [expr {[dict get $snapshot mode] ne {} && [dict get $snapshot mode] ne [dict get $current mode]}]
        if {$distinct_id || $distinct_edge || $distinct_mode} {set new_operation 1}
    }
    if {$new_operation} {
        if {$current ne {}} {
            set old_id [dict get $current native_id]
            if {$old_id ne {} && $old_id ni [dict get $data retired_native_ids]} {dict lappend data retired_native_ids $old_id}
            if {![dict get $current finalized]} {dict lappend data unresolved $current}
        }
        _begin $snapshot
        set current [dict get $data current]
    } elseif {$recovery_candidate && ($current eq {} || $mismatched_id || \
        (![dict get $current observed] && [_bool [_get $snapshot operation_reconciled]]))} {
        if {$current ne {}} {
            set old_id [dict get $current native_id]
            if {$old_id ne {} && $old_id ni [dict get $data retired_native_ids]} {dict lappend data retired_native_ids $old_id}
            if {![dict get $current finalized]} {dict lappend data unresolved $current}
        }
        set recovered_snapshot $snapshot
        set final [dict get $snapshot final_result]
        if {[dict exists $final recipe] && [_valid_dict [dict get $final recipe]]} {
            dict set recovered_snapshot recipe [dict get $final recipe]
            foreach key {profile_title profile_id dose target_yield target_temp} {
                if {[dict exists [dict get $final recipe] $key]} {dict set recovered_snapshot $key [dict get [dict get $final recipe] $key]}
            }
        } else {
            foreach key {profile_title profile_id dose target_yield target_temp} {
                if {[dict exists $final $key]} {dict set recovered_snapshot $key [dict get $final $key]}
            }
        }
        dict set recovered_snapshot mode [_mode [_get $final mode espresso]]
        _begin $recovered_snapshot 0 1
        set current [dict get $data current]
        dict set current flow_elapsed [_number [_get $snapshot final_elapsed [_get $final final_elapsed [_get $final elapsed [_get $final time]]]] 1]
    }
    if {$current eq {}} {return [presentation]}

    # A rejection cannot erase a start already observed at the machine.
    set request_outcome [string tolower [_get $snapshot request_outcome]]
    set rejected [_bool [_get $snapshot start_rejected]]
    if {$request_outcome in {rejected not-started} && [_get $snapshot request_action start] eq "start"} {set rejected 1}
    if {![dict get $current observed] && !$native_active && $rejected} {
        dict set data current {}
        dict set data reason [_get $snapshot request_reason {Start rejected}]
        return [presentation]
    }
    if {$native_active && ![dict get $current observed]} {
        dict set current observed 1
        dict set current native_id $native_id
        dict set current mode [dict get $snapshot mode]
        if {[dict get $current mode] eq {}} {dict set current mode [dict get $data selected_mode]}
        dict set current recipe [_operation_recipe $snapshot]
        dict set data selected_mode [dict get $current mode]
    }
    if {[dict get $current observed] && [dict get $current native_id] eq {} && $native_id ne {} && ![dict get $current finalized]} {
        dict set current native_id $native_id
    }
    if {$request_outcome in {unknown uncertain} || ![dict get $snapshot connected] || [_fault $snapshot] || \
        ($kind in {unknown specialist blocked} && ![dict get $current finalized]) || \
        ($kind eq "idle" && [dict get $current flow_confirmed] && ![dict get $snapshot flow_ended] && ![dict get $current finalized]) || \
        ($native_active && [dict get $current flow_ended] && ![dict get $snapshot flow_ended])} {
        dict set current uncertain 1
        dict set current auto_cancelled 1
    }
    if {[_bool [_get $snapshot stop_rejected]] || ($request_outcome eq "rejected" && [_get $snapshot request_action] eq "stop")} {
        dict set current stop_requested 0
        dict set data reason [_get $snapshot request_reason {Stop rejected}]
    }
    set stage [_stage_identity $snapshot]
    if {[dict get $current stage_advance_pending] && \
        ([_bool [_get $snapshot stage_advance_acknowledged]] || [_bool [_get $snapshot stage_advance_rejected]] || \
        ($stage ne {} && $stage ne [dict get $current requested_stage]))} {
        dict set current stage_advance_pending 0
        if {[_bool [_get $snapshot stage_advance_rejected]]} {dict set data reason [_get $snapshot stage_advance_reason {Stage advance rejected}]}
    }
    set outcome [_outcome $snapshot]
    if {[_fault $snapshot]} {set outcome fault}
    if {[dict get $current observed] && $outcome ne "unknown" && ![dict get $current finalized]} {dict set current outcome $outcome}
    if {[dict get $current observed] && $outcome in {manual fault}} {dict set current auto_cancelled 1}
    if {[dict get $current observed] && [dict get $snapshot flow_confirmed]} {dict set current flow_confirmed 1}
    if {![dict get $current flow_ended] && [dict get $current flow_confirmed]} {
        set elapsed [dict get $snapshot elapsed]
        if {$elapsed ne {} && ([dict get $current elapsed] eq {} || $elapsed >= [dict get $current elapsed])} {
            dict set current elapsed $elapsed
            dict set current elapsed_quality native
        }
    }
    if {![dict get $current finalized]} {
        dict set current weight [dict get $reading value]
        dict set current weight_quality [dict get $reading quality]
        if {[dict exists $snapshot graph_samples]} {dict set current graph_samples [dict get $snapshot graph_samples]}
    }
    if {[dict get $current observed] && [dict get $snapshot flow_ended] && ![dict get $current flow_ended]} {
        dict set current flow_ended 1
        if {[dict get $current flow_elapsed] eq {}} {
            dict set current flow_elapsed [_number [_get $snapshot flow_end_elapsed [dict get $current elapsed]] 1]
        }
        dict set current stage_advance_pending 0
        dict set current flow_end_seen 1
    } elseif {[dict get $current flow_ended]} {dict incr current flow_end_seen}

    # Native cancellation before flow may return to preparation without a shot.
    # Ordinary idle polls do not acknowledge a pending command.
    if {![dict get $current flow_confirmed] && (![dict get $snapshot result_finalized] || ![dict get $current observed]) && $kind eq "idle" && \
        [dict get $snapshot connected] && ([_bool [_get $snapshot operation_reconciled]] || \
        ([dict get $current observed] && [_bool [_get $snapshot idle_verified]]))} {
        dict set data current {}
        return [presentation]
    }
    dict set data current $current
    set final [_get $snapshot final_result]
    set final_matches 1
    if {[_valid_dict $final] && [_get $final operation_id] ne {} && [dict get $current native_id] ne {}} {
        set final_matches [expr {[dict get $final operation_id] eq [dict get $current native_id]}]
    }
    if {[dict get $snapshot result_finalized] && [dict get $current flow_ended] && $final_matches} {_finalize $snapshot}
    _reconcile_save $snapshot
    return [presentation]
}

proc ::aiden::lifecycle::_auto_handoff_available {} {
    variable data
    set current [dict get $data current]
    if {$current eq {} || [_phase] ne "result" || [dict get $data prepared_after_result]} {return 0}
    set status [dict get $data persistence_status]
    set persistence_ok [expr {[dict get $current mode] ne "espresso" || \
        ($status ne {} && [_bool [_get $status saved]] && [_get $status history_id] ne {})}]
    return [expr {[dict get $current finalized] && [dict get $current outcome] eq "normal" && \
        ![dict get $current auto_cancelled] && [dict get $current native_id] ne {} && \
        $persistence_ok && [_next_mode] ne {}}]
}

proc ::aiden::lifecycle::_prepare_next {result_id} {
    variable data
    set current [dict get $data current]
    if {$current eq {} || ![dict get $current finalized]} {return [_reply 0 prepare {A native finalized result is required}]}
    if {$result_id ne {} && $result_id ne [dict get $current id]} {return [_reply 0 prepare {The result hold belongs to an older operation}]}
    if {[dict get $data prepared_after_result]} {return [_reply 0 prepare {The next view is already prepared}]}
    set next [_next_mode]
    if {$next eq {}} {set next [dict get $current mode]}
    dict set data selected_mode $next
    dict set data prepared_after_result 1
    return [_reply 1 prepare]
}

proc ::aiden::lifecycle::complete_hold {{result_id {}}} {
    if {![_auto_handoff_available]} {return [_reply 0 prepare {Automatic presentation handoff is unavailable}]}
    return [_prepare_next $result_id]
}

proc ::aiden::lifecycle::continue {{result_id {}}} {
    return [_prepare_next $result_id]
}

proc ::aiden::lifecycle::select_mode {mode} {
    variable data
    set mode [_mode $mode]
    if {$mode eq {}} {error "Unknown Aiden mode"}
    if {[_busy]} {error "Mode selection is unavailable while an operation or request is unresolved"}
    dict set data selected_mode $mode
    set current [dict get $data current]
    if {$current ne {}} {
        dict set current auto_cancelled 1
        dict set data current $current
        dict set data prepared_after_result 1
    }
    return [presentation]
}

proc ::aiden::lifecycle::configure_workflow {workflow {options {}}} {
    variable data
    variable workflows
    if {![dict exists $workflows $workflow]} {error "Unknown Aiden workflow"}
    if {![_valid_dict $options]} {error "Workflow options must be a dictionary"}
    if {[_busy]} {error "Workflow application is unavailable while an operation or request is unresolved"}
    if {$workflow eq [dict get $data workflow]} {
        set default_order [dict get $data mode_order]
        set default_skipped [dict get $data skipped_modes]
    } else {
        set default_order [dict get $workflows $workflow]
        set default_skipped {}
    }
    set order [_validate_order [_get $options mode_order $default_order]]
    set skipped [_validate_skipped [_get $options skipped_modes $default_skipped] $order]
    dict set data workflow $workflow
    dict set data mode_order $order
    dict set data skipped_modes $skipped
    if {[dict exists $options mode_values]} {dict set data mode_values [dict get $options mode_values]}
    set current [dict get $data current]
    if {$current ne {}} {
        dict set current auto_cancelled 1
        dict set data current $current
    }
    return [presentation]
}

proc ::aiden::lifecycle::result {} {
    variable data
    if {[dict get $data retained_result] ne {}} {return [dict get $data retained_result]}
    return [dict get $data last_result]
}

proc ::aiden::lifecycle::operation_result {} {
    variable data
    return [_get [dict get $data current] result]
}

proc ::aiden::lifecycle::history {} {
    variable data
    return [dict get $data history]
}

proc ::aiden::lifecycle::_save_state {status} {
    if {[dict exists $status history_required] && ![_bool [dict get $status history_required]]} {return Complete}
    if {[_bool [_get $status saved]]} {return Saved}
    if {[_bool [_get $status confirmed]]} {return Unsaved}
    return {Save unconfirmed}
}

proc ::aiden::lifecycle::presentation {} {
    variable data
    variable mode_names
    set machine [dict get $data machine]
    set current [dict get $data current]
    set mode [dict get $data selected_mode]
    set phase [_phase]
    set possible [_possible_active]
    set busy [_busy]
    set primary wait
    set enabled 0
    switch -- $phase {
        prepared - next-mode-prepared {
            if {[_start_allowed]} {set primary start; set enabled 1}
        }
        start-requested - active - stop-requested - unknown-or-blocked {
            if {$possible} {set primary stop; set enabled [expr {![dict get $current stop_requested]}]}
        }
        result {set primary continue; set enabled 1}
    }
    set status {Machine state unknown}
    switch -- $phase {
        prepared - next-mode-prepared {
            if {[_start_allowed]} {set status "[dict get $mode_names $mode] ready"} else {set status {Machine not ready}}
        }
        start-requested {set status {Start requested}}
        active {
            set status [dict get $mode_names $mode]
            if {![dict get $current flow_confirmed]} {set status {Waiting for flow}}
        }
        stop-requested {set status {Stop requested}}
        flow-ended {set status {Flow ended}}
        settling {set status {Settling weight}}
        result {set status {Result finalized}}
        unknown-or-blocked {
            if {![dict get $machine connected]} {
                set status {Connection lost}
            } elseif {[_fault $machine]} {
                set status [_get $machine fault]
                if {$status eq {}} {set status {Machine fault}}
            } elseif {[_native_kind $machine] eq "blocked"} {
                set status Sleeping
            } elseif {[_native_kind $machine] eq "specialist"} {
                set status {Native specialist operation}
            }
        }
    }
    set elapsed {}
    set weight_info [_weight $machine]
    set weight [dict get $weight_info value]
    set weight_quality [dict get $weight_info quality]
    set recipe [dict get $data recipe]
    set flow_confirmed 0
    set flow_ended 0
    set result_finalized 0
    set operation_id {}
    set operation_identity {}
    set stage_pending 0
    if {$current ne {}} {
        set recipe [dict get $current recipe]
        set flow_confirmed [dict get $current flow_confirmed]
        set flow_ended [dict get $current flow_ended]
        set result_finalized [dict get $current finalized]
        set operation_id [dict get $current native_id]
        set operation_identity [dict get $current id]
        set stage_pending [dict get $current stage_advance_pending]
        if {$flow_ended} {set elapsed [dict get $current flow_elapsed]} else {set elapsed [dict get $current elapsed]}
        set weight [dict get $current weight]
        set weight_quality [dict get $current weight_quality]
        if {$result_finalized} {
            set weight [dict get $current result weight]
            set weight_quality [dict get $current result weight_quality]
        }
        if {[dict get $data prepared_after_result]} {
            set recipe [dict get $data recipe]
            set elapsed {}
            set weight [dict get $weight_info value]
            set weight_quality [dict get $weight_info quality]
        }
    }
    set operation_persistence [dict get $data persistence_status]
    set persistence $operation_persistence
    set displayed_result [result]
    if {$displayed_result ne {} && [dict exists $data history_status [dict get $displayed_result id]]} {
        set persistence [dict get $data history_status [dict get $displayed_result id]]
    }
    set saved [_bool [_get $persistence saved]]
    set result_state {}
    set operation_result_state {}
    if {$displayed_result ne {}} {set result_state [_save_state $persistence]}
    if {[operation_result] ne {}} {set operation_result_state [_save_state $operation_persistence]}
    set temperature [dict get $machine temperature]
    if {![dict get $machine connected]} {set temperature {}}
    set fresh [expr {$phase in {prepared next-mode-prepared}}]
    return [dict create phase $phase mode $mode primary_action $primary primary_enabled $enabled \
        status $status busy $busy stop_available $possible can_select_mode [expr {!$busy}] \
        can_tare [expr {!$busy && [dict get $machine scale_connected] && $phase in {prepared next-mode-prepared}}] \
        elapsed $elapsed weight $weight weight_quality $weight_quality last_known_weight [dict get $data last_known_weight] \
        temperature $temperature last_known_temperature [dict get $data last_known_temperature] \
        connected [dict get $machine connected] ready [dict get $machine ready] scale_connected [dict get $machine scale_connected] \
        flow_confirmed $flow_confirmed flow_ended $flow_ended result_finalized $result_finalized \
        operation_id $operation_id operation_identity $operation_identity recipe $recipe \
        profile_title [_get $recipe profile_title] dose [_get $recipe dose] target_yield [_get $recipe target_yield] target_temp [_get $recipe target_temp] \
        result [result] retained_result [result] operation_result [operation_result] history [history] \
        persistence_status $persistence history_status [dict get $data history_status] result_saved $saved \
        result_save_error [_get $persistence error] result_state $result_state \
        operation_persistence_status $operation_persistence operation_result_saved [_bool [_get $operation_persistence saved]] \
        operation_result_state $operation_result_state operation_result_save_error [_get $operation_persistence error] \
        next_mode [_next_mode] auto_handoff_available [_auto_handoff_available] hold_duration_ms 1500 \
        workflow [dict get $data workflow] workflow_modes [_sequence] workflow_order [dict get $data mode_order] \
        mode_order [dict get $data mode_order] mode_values [dict get $data mode_values] \
        stage_advance_available [_stage_available] stage_advance_pending $stage_pending stage_name [_get $machine stage_name] \
        graph [_get $machine graph [_get $machine graph_vectors]] graph_samples [_get $machine graph_samples] samples [_get $machine samples] \
        fresh_start $fresh freshStart $fresh requires_start $fresh reason [dict get $data reason] unresolved_operations [dict get $data unresolved]]
}

::aiden::lifecycle::reset
