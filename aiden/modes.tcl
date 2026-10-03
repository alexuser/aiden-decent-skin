# SPDX-License-Identifier: GPL-3.0-only
# Aiden mode settings and preparation order. Sourcing only declares this module.
# All values are the installed app's canonical ::settings values. Native settings
# transmission happens only in apply; this module contains no Start/Stop route.
namespace eval ::aiden::modes {
    variable drafts {}
    variable applying 0
    variable last_apply {}
    variable state_file {}
    variable workflow_draft {}
    variable workflow_state {
        schema 1 selected espresso workflows {
            espresso {order espresso skipped {}}
            latte {order {espresso flush steam} skipped {}}
            americano {order {espresso water} skipped {}}
            steam {order {espresso steam} skipped {}}
        }
    }
}

proc ::aiden::modes::canonical {mode} {
    switch -- $mode {
        espresso - flush - steam - water {return $mode}
        hotwater - hot_water {return water}
        default {error "Unsupported mode: $mode"}
    }
}

proc ::aiden::modes::_finite {value} {
    if {![string is double -strict $value]} {return 0}
    if {[catch {expr {double($value)}} number]} {return 0}
    return [expr {$number > -Inf && $number < Inf}]
}

proc ::aiden::modes::_equal {left right} {
    if {[_finite $left] && [_finite $right]} {return [expr {$left == $right}]}
    return [string equal $left $right]
}

proc ::aiden::modes::_values_equal {left right} {
    if {[dict size $left] != [dict size $right]} {return 0}
    dict for {key value} $left {
        if {![dict exists $right $key] || ![_equal $value [dict get $right $key]]} {return 0}
    }
    return 1
}

proc ::aiden::modes::_snapshot {} {
    if {[info commands ::aiden::core::snapshot] eq {}} {
        error {Native machine state is unavailable}
    }
    return [::aiden::core::snapshot]
}

proc ::aiden::modes::_guard {} {
    set snapshot [_snapshot]
    foreach key {native_state state connected editable pending context_verified} {
        if {![dict exists $snapshot $key]} {error {Native idle state could not be verified}}
    }
    if {[dict get $snapshot native_state] ne "Idle" || [dict get $snapshot state] ne "idle" ||
        [dict get $snapshot connected] ne "1" || [dict get $snapshot editable] ne "1" ||
        [dict get $snapshot context_verified] ne "1" || [dict get $snapshot pending] ne {}} {
        error {Settings require a connected, verified idle machine with no pending operation}
    }
    return $snapshot
}

proc ::aiden::modes::_require {commands} {
    foreach command $commands {
        if {[info commands $command] eq {}} {error "Native settings API is unavailable: $command"}
    }
}

proc ::aiden::modes::_amount {} {
    # Installed binary.tcl:207-214 forces the firmware volume to 250 mL when a
    # scale handle exists. device_scale.tcl:1351-1355 uses water_volume as a
    # weight stop target only when water_stop_on_scale is enabled. An address
    # in preferences does not establish either the active route or readiness.
    set result [dict create unit {} available 0 semantics {} reason {Native hot-water amount route is unknown}]
    if {![info exists ::de1(scale_device_handle)] ||
        ![string is integer -strict $::de1(scale_device_handle)]} {return $result}
    if {$::de1(scale_device_handle) == 0} {
        return [dict create unit mL available 1 reason {} \
            semantics {Firmware volumetric stop target; native scale and stop policy remain authoritative}]
    }
    if {![info exists ::settings(water_stop_on_scale)] ||
        ![string is boolean -strict $::settings(water_stop_on_scale)]} {return $result}
    if {!$::settings(water_stop_on_scale)} {
        dict set result reason {Scale is connected and native weight stop is off; firmware uses 250 mL, so this amount is not effective}
        return $result
    }
    if {[info commands ::device::scale::saw::on_hotwater_start] eq {}} {
        dict set result reason {Native hot-water weight stop support is unavailable}
        return $result
    }
    return [dict create unit g available 1 reason {} \
        semantics {Native scale weight stop target; firmware volume is 250 mL. This is a target, not measured yield or scale readiness}]
}

proc ::aiden::modes::_field {key label unit min max step kind semantics source {factor 1}} {
    set value {}
    set available [info exists ::settings($key)]
    set reason {}
    if {$available} {set value $::settings($key)} else {set reason {Setting is absent from the installed app}}
    return [dict create key $key native_key $key label $label value $value native_value $value \
        unit $unit units [list $unit] min $min max $max step $step kind $kind \
        available $available reason $reason semantics $semantics source $source display_factor $factor \
        display_unit $unit display_step [expr {$step * $factor}] \
        display_min [expr {$min * $factor}] display_max [expr {$max * $factor}]]
}

proc ::aiden::modes::_fields {mode} {
    set fields {}
    switch -- $mode {
        flush {
            # Copied native calibration slider: de1_skin_settings.tcl:2308
            # is 3..120 s. DSx2 adjust rounds the timer to integer seconds.
            lappend fields [_field flush_seconds Duration s 3 120 1 integer \
                {Native flush timeout; selecting or editing flush does not start rinsing} \
                {source/de1_skin_settings.tcl:2308; source/DSx2/code/procs_vars.tcl:2465; installed-core/de1_comms.tcl:1195}]
            lappend fields [_field flush_flow {Flow rate} mL/s 1 10 0.1 decimal \
                {Native flush inlet flow target} \
                {source/DSx2/code/procs_vars.tcl:2468-2472; installed-core/de1_comms.tcl:1188}]
        }
        steam {
            lappend fields [_field steam_timeout Duration s 1 255 1 integer \
                {Native steam duration. Native zero means 255 s; this editor uses an explicit positive duration and does not enable the heater implicitly} \
                {source/DSx2/code/save_and_load.tcl:48-53; installed-core/binary.tcl:198-203}]
            set flow [_field steam_flow {Flow rate} {0.01 mL/s} 40 250 10 integer \
                {Native hundredths of mL/s; 80 means 0.8 mL/s. Proven calibration range is 0.4 to 2.5 mL/s} \
                {source/de1_skin_settings.tcl:2409-2417; installed-core/vars.tcl:4027-4028; installed-core/de1_comms.tcl:1210} 0.01]
            dict set flow display_unit mL/s
            lappend fields $flow
            set heater [_field steam_temperature {Heater temperature} \u00b0C 134 170 1 integer \
                {Steam heater setpoint, not measured milk temperature. Values below 135 C turn the heater off; native eco mode may substitute its own setpoint} \
                {source/de1_skin_settings.tcl:2407; installed-core/binary.tcl:183-195}]
            if {[info exists ::de1(in_eco_steam_mode)] && $::de1(in_eco_steam_mode) eq "1"} {
                dict set heater available 0
                dict set heater reason {Native eco steam mode substitutes its own heater temperature}
            }
            lappend fields $heater
            lappend fields [_field steam_disabled {Heater disabled} {} 0 1 1 boolean \
                {Explicit native steam heater disable flag; duration edits preserve this flag} \
                {source/DSx2/code/procs_vars.tcl:1579-1588; installed-core/binary.tcl:188-195}]
        }
        water {
            lappend fields [_field water_temperature Temperature \u00b0C 20 110 1 integer \
                {Native hot-water setpoint in Celsius, independent of display-unit preferences} \
                {source/DSx2/code/procs_vars.tcl:2492-2496; installed-core/binary.tcl:205}]
            set amount [_amount]
            set field [_field water_volume Amount [dict get $amount unit] 10 250 1 integer \
                [dict get $amount semantics] \
                {source/DSx2/code/procs_vars.tcl:2498-2502; installed-core/binary.tcl:207-214; installed-core/device_scale.tcl:1351-1355}]
            if {![dict get $amount available]} {
                dict set field available 0
                dict set field reason [dict get $amount reason]
            }
            lappend fields $field
            set field [_field hotwater_flow {Flow rate} mL/s 1 10 0.1 decimal \
                {Native hot-water inlet flow target; requires its dedicated settings setter} \
                {source/DSx2/code/procs_vars.tcl:2487-2490; installed-core/de1_comms.tcl:1169}]
            if {[info commands ::set_hotwater_flow_rate] eq {}} {
                dict set field available 0
                dict set field reason {Native hot-water flow settings setter is unavailable}
            }
            lappend fields $field
            # No more restrictive UI range is present in the supplied native
            # source. U8P0 proves the byte range; require a positive safety cap.
            lappend fields [_field water_time_max {Safety time limit} s 1 255 1 integer \
                {Native maximum hot-water duration; positive whole seconds within the installed unsigned-byte encoding} \
                {installed-core/vars.tcl:1389; installed-core/binary.tcl:217,452-456}]
        }
    }
    return $fields
}

proc ::aiden::modes::_display {field value} {
    dict set field value $value
    dict set field native_value $value
    if {$value eq {} || ![_finite $value]} {
        dict set field display_value \u2014
    } elseif {[dict get $field kind] eq "boolean"} {
        dict set field display_value [expr {$value ? "Yes" : "No"}]
    } elseif {[dict get $field display_factor] != 1} {
        dict set field display_value [format %.1f [expr {$value * [dict get $field display_factor]}]]
    } elseif {[dict get $field kind] eq "decimal"} {
        dict set field display_value [format %.1f $value]
    } else {
        dict set field display_value [format %g $value]
    }
    return $field
}

proc ::aiden::modes::get {mode} {
    set mode [canonical $mode]
    set title [dict get {espresso Espresso flush Flush steam Steam water {Hot water}} $mode]
    set values {}
    set fields {}
    foreach field [_fields $mode] {
        set key [dict get $field key]
        set value [dict get $field value]
        if {[info exists ::settings($key)]} {dict set values $key $value}
        lappend fields [_display $field $value]
    }
    set editable 0
    if {![catch {
        _guard
        _require {::save_settings ::de1_send_steam_hotwater_settings}
    } reason]} {set editable 1; set reason {}}
    if {$mode eq "espresso"} {
        set editable 0
        set reason {Espresso settings are edited in the recipe sheet}
    }
    set hint {}
    switch -- $mode {
        flush {set hint {Native flush duration and flow. Remove the portafilter.}}
        steam {set hint {Flow is shown in mL/s. Heater temperature is a setpoint; milk temperature is not measured. 134 C turns the heater off.}}
        water {set hint {Amount follows the native volume or scale weight stop route. Temperature is the water setpoint.}}
    }
    return [dict create mode $mode title $title fields $fields values $values \
        editable $editable reason $reason hint $hint scope {Native settings; the next operation still requires explicit Start}]
}

proc ::aiden::modes::_signature {mode} {
    set signature {}
    foreach field [_fields $mode] {
        dict set signature [dict get $field key] [list [dict get $field unit] [dict get $field available] [dict get $field reason]]
    }
    return $signature
}

proc ::aiden::modes::begin {mode} {
    variable drafts
    set mode [canonical $mode]
    if {$mode eq "espresso"} {error {Use the recipe sheet to edit espresso}}
    set draft [get $mode]
    dict set draft baseline [dict get $draft values]
    dict set draft signature [_signature $mode]
    dict set drafts $mode $draft
    return $draft
}

proc ::aiden::modes::draft {mode} {
    variable drafts
    set mode [canonical $mode]
    if {![dict exists $drafts $mode]} {return [begin $mode]}
    set draft [dict get $drafts $mode]
    set fields {}
    foreach field [dict get [get $mode] fields] {
        set value {}
        if {[dict exists $draft values [dict get $field key]]} {set value [dict get $draft values [dict get $field key]]}
        lappend fields [_display $field $value]
    }
    dict set draft fields $fields
    return $draft
}

proc ::aiden::modes::_validate {mode values baseline} {
    if {[catch {dict size $values}]} {error {Mode settings must be a dictionary}}
    set specs {}
    foreach field [_fields $mode] {dict set specs [dict get $field key] $field}
    set result $baseline
    dict for {key value} $values {
        if {![dict exists $specs $key]} {error "Unsupported $mode setting: $key"}
        if {[dict exists $baseline $key] && [_equal $value [dict get $baseline $key]]} {continue}
        set field [dict get $specs $key]
        if {![dict get $field available]} {error "$key: [dict get $field reason]"}
        if {![_finite $value]} {error "$key must be a finite number"}
        set min [dict get $field min]
        set max [dict get $field max]
        set step [dict get $field step]
        if {$value < $min || $value > $max} {error "$key must be between $min and $max [dict get $field unit]"}
        set count [expr {($value - $min) / double($step)}]
        if {abs($count - round($count)) > 0.000001} {error "$key must use increments of $step [dict get $field unit]"}
        if {[dict get $field kind] in {integer boolean}} {
            set value [expr {int(round($value))}]
        } else {set value [format %.1f $value]}
        dict set result $key $value
    }
    return $result
}

proc ::aiden::modes::edit {mode key value} {
    variable drafts
    set mode [canonical $mode]
    set pending [draft $mode]
    set values [_validate $mode [dict create $key $value] [dict get $pending values]]
    dict set drafts $mode values $values
    return [draft $mode]
}

proc ::aiden::modes::cancel {mode} {
    variable drafts
    set mode [canonical $mode]
    if {[dict exists $drafts $mode]} {dict unset drafts $mode}
    return [get $mode]
}

proc ::aiden::modes::reset {mode} {return [begin $mode]}

proc ::aiden::modes::last_apply {} {
    variable last_apply
    return $last_apply
}

proc ::aiden::modes::apply {mode draftDict} {
    variable drafts
    variable applying
    variable last_apply
    set mode [canonical $mode]
    if {$applying} {error {A mode settings transaction is already in progress}}
    if {![dict exists $drafts $mode]} {error {Open the mode settings draft before applying}}
    _guard
    _require {::save_settings ::de1_send_steam_hotwater_settings}
    set before [dict get [get $mode] values]
    set pending [dict get $drafts $mode]
    if {![_values_equal $before [dict get $pending baseline]] ||
        [_signature $mode] ne [dict get $pending signature]} {
        error {Native settings or their units changed while editing; reopen the draft}
    }
    if {[catch {dict size $draftDict}]} {error {Mode settings must be a dictionary}}
    if {[dict exists $draftDict values]} {
        if {[dict exists $draftDict mode] && [canonical [dict get $draftDict mode]] ne $mode} {error {Draft belongs to another mode}}
        set draftDict [dict get $draftDict values]
    }
    set wanted [_validate $mode $draftDict $before]
    set changed {}
    dict for {key value} $wanted {
        if {![dict exists $before $key] || ![_equal $value [dict get $before $key]]} {lappend changed $key}
    }
    if {"hotwater_flow" in $changed} {_require {::set_hotwater_flow_rate}}
    if {$changed eq {}} {
        dict unset drafts $mode
        set last_apply [dict create mode $mode status unchanged values $before settings_sent 0 acknowledged 0]
        return $last_apply
    }
    set applying 1
    set saved 0
    set last_apply [dict create mode $mode status applying values $wanted persisted unknown settings_sent 0 acknowledged 0]
    set code [catch {
        dict for {key value} $wanted {set ::settings($key) $value}
        ::save_settings
        set saved 1
        dict set last_apply persisted 1
        # A native callback inside persistence can change machine state. Never
        # transmit the second half of an edit once that state becomes active.
        _guard
        ::de1_send_steam_hotwater_settings
        if {"hotwater_flow" in $changed} {
            _guard
            ::set_hotwater_flow_rate $::settings(hotwater_flow)
        }
        if {![_values_equal $wanted [dict get [get $mode] values]]} {
            error {Native globals did not retain the requested values}
        }
        if {$mode eq "steam" && [info exists ::de1(steam_disable_toggle)]} {
            set ::de1(steam_disable_toggle) [expr {!$::settings(steam_disabled)}]
        }
    } message options]
    set applying 0
    if {$code} {
        if {!$saved} {
            dict for {key value} $before {set ::settings($key) $value}
            dict set last_apply status persistence_failed
            dict set last_apply error $message
            return -code error -errorcode {AIDEN MODES SAVE_UNCONFIRMED} \
                "Settings save failed; native globals were restored and file persistence is unconfirmed: $message"
        }
        dict set last_apply status transmission_unconfirmed
        dict set last_apply error $message
        dict unset drafts $mode
        return -code error -errorcode {AIDEN MODES SEND_UNCONFIRMED} \
            "Settings were saved; native settings transmission is unconfirmed: $message"
    }
    dict unset drafts $mode
    dict set last_apply status saved
    dict set last_apply settings_sent 1
    return $last_apply
}

proc ::aiden::modes::configure {args} {
    variable state_file
    variable applying
    if {$applying} {error {Cannot reconfigure during a settings transaction}}
    if {[llength $args] % 2} {error {Expected option/value pairs}}
    set next $state_file
    foreach {key value} $args {
        switch -- $key {
            -state_file {if {$value eq {}} {set next {}} else {set next [file normalize $value]}}
            default {error "Unknown mode option: $key"}
        }
    }
    set state_file $next
    return [dict create state_file $state_file]
}

proc ::aiden::modes::_workflow_path {} {
    variable state_file
    if {$state_file eq {}} {
        if {[info commands ::skin_directory] eq {}} {error {A local Aiden workflow file has not been configured}}
        return [file join [::skin_directory] settings aiden_workflows.tcl]
    }
    return $state_file
}

proc ::aiden::modes::_workflow_config {config} {
    if {[catch {dict size $config}]} {error {Workflow configuration is malformed}}
    foreach key [dict keys $config] {
        if {$key ni {order skipped}} {error "Unsupported workflow field: $key"}
    }
    if {![dict exists $config order] || ![dict exists $config skipped]} {error {Workflow order and skipped modes are required}}
    set order {}
    foreach mode [dict get $config order] {
        set mode [canonical $mode]
        if {$mode in $order} {error {A preparation mode may appear only once}}
        lappend order $mode
    }
    if {$order eq {}} {error {A workflow needs at least one preparation mode}}
    if {[lindex $order 0] ne "espresso"} {error {A beverage workflow starts with espresso; select steam, flush or water directly for a standalone operation}}
    set skipped {}
    foreach mode [dict get $config skipped] {
        set mode [canonical $mode]
        if {$mode eq "espresso" || $mode ni $order || $mode in $skipped} {
            error {Skipped modes must be distinct optional modes in the workflow}
        }
        lappend skipped $mode
    }
    return [dict create order $order skipped $skipped]
}

proc ::aiden::modes::_workflow_validate {state} {
    if {[catch {dict size $state}]} {error {Aiden workflow file is malformed}}
    if {[lsort [dict keys $state]] ne {schema selected workflows} || [dict get $state schema] ne "1"} {
        error {Unsupported Aiden workflow file schema}
    }
    if {[dict get $state selected] ni {espresso latte americano steam}} {error {Unsupported beverage workflow}}
    set workflows [dict get $state workflows]
    if {[lsort [dict keys $workflows]] ne {americano espresso latte steam}} {error {The four Aiden beverage workflows are required}}
    foreach id {espresso latte americano steam} {
        dict set workflows $id [_workflow_config [dict get $workflows $id]]
    }
    return [dict create schema 1 selected [dict get $state selected] workflows $workflows]
}

proc ::aiden::modes::_workflow_equal {left right} {
    if {[dict get $left selected] ne [dict get $right selected]} {return 0}
    foreach id {espresso latte americano steam} {
        foreach key {order skipped} {
            if {[dict get $left workflows $id $key] ne [dict get $right workflows $id $key]} {return 0}
        }
    }
    return 1
}

proc ::aiden::modes::_workflow_write {path state} {
    if {[file exists $path] && [file type $path] ne "file"} {error {Workflow destination must be a regular local file}}
    file mkdir [file dirname $path]
    set temporary "${path}.[pid].[clock clicks].tmp"
    set channel {}
    set code [catch {
        set channel [::open $temporary {WRONLY CREAT EXCL} 0600]
        fconfigure $channel -encoding utf-8 -translation lf
        puts $channel $state
        close $channel
        set channel {}
        file rename -force $temporary $path
    } message options]
    if {$channel ne {}} {catch {close $channel}}
    if {$code} {
        catch {file delete $temporary}
        return -options $options $message
    }
}

proc ::aiden::modes::workflow {action args} {
    variable workflow_state
    variable workflow_draft
    switch -- $action {
        get {
            if {$args ne {}} {error {workflow get takes no arguments}}
            set result $workflow_state
            set id [dict get $workflow_state selected]
            dict set result id $id
            dict set result title [dict get {espresso {Espresso only} latte Latte americano Americano steam {Espresso + steam}} $id]
            dict set result order [dict get $workflow_state workflows $id order]
            dict set result skipped [dict get $workflow_state workflows $id skipped]
            dict set result scope {Preparation order only; each operation requires explicit Start}
            dict set result auto_start 0
            return $result
        }
        load {
            if {$args ne {}} {error {workflow load takes no arguments}}
            set path [_workflow_path]
            if {![file exists $path]} {return [workflow get]}
            if {[file type $path] ne "file" || [file size $path] > 65536} {error {Aiden workflow file is not a supported regular file}}
            set channel [::open $path r]
            fconfigure $channel -encoding utf-8 -translation lf
            set code [catch {set data [read $channel]} message options]
            close $channel
            if {$code} {return -options $options $message}
            set checked [_workflow_validate $data]
            set workflow_state $checked
            set workflow_draft {}
            return [workflow get]
        }
        begin {
            if {[llength $args] > 1} {error {workflow begin takes an optional beverage ID}}
            set id [dict get $workflow_state selected]
            if {$args ne {}} {set id [lindex $args 0]}
            if {$id ni {espresso latte americano steam}} {error {Unsupported beverage workflow}}
            set workflow_draft [dict merge [dict create id $id] [dict get $workflow_state workflows $id] \
                [dict create baseline $workflow_state scope {Preparation order only} auto_start 0]]
            return $workflow_draft
        }
        edit {
            if {[llength $args] != 2 || $workflow_draft eq {}} {error {Open a workflow draft, then edit a field}}
            lassign $args key value
            if {$key ni {order skipped}} {error {Only preparation order and skipped modes are editable}}
            set config [dict create order [dict get $workflow_draft order] skipped [dict get $workflow_draft skipped]]
            dict set config $key $value
            set config [_workflow_config $config]
            foreach key {order skipped} {dict set workflow_draft $key [dict get $config $key]}
            return $workflow_draft
        }
        apply {
            if {[llength $args] > 1 || $workflow_draft eq {}} {error {Open a workflow draft before applying}}
            _guard
            set pending $workflow_draft
            if {$args ne {}} {set pending [lindex $args 0]}
            if {[catch {dict size $pending}]} {error {Workflow draft must be a dictionary}}
            foreach key [dict keys $pending] {
                if {$key ni {id order skipped baseline scope auto_start}} {error "Unsupported workflow draft field: $key"}
            }
            if {![dict exists $pending id] || [dict get $pending id] ne [dict get $workflow_draft id]} {error {Workflow draft identity changed}}
            if {[dict exists $pending auto_start] && [dict get $pending auto_start] ne "0"} {error {Physical auto-start is not a supported workflow setting}}
            if {![_workflow_equal $workflow_state [dict get $workflow_draft baseline]]} {error {Workflow changed while editing; reopen the draft}}
            set config [_workflow_config [dict create order [dict get $pending order] skipped [dict get $pending skipped]]]
            set next $workflow_state
            set id [dict get $pending id]
            dict set next selected $id
            dict set next workflows $id $config
            set next [_workflow_validate $next]
            _workflow_write [_workflow_path] $next
            set workflow_state $next
            set workflow_draft {}
            return [workflow get]
        }
        cancel {
            if {$args ne {}} {error {workflow cancel takes no arguments}}
            set workflow_draft {}
            return [workflow get]
        }
        reset {return [workflow begin {*}$args]}
        configure {
            if {[llength $args] ni {2 3}} {error {workflow configure requires beverage ID, order, and optional skipped modes}}
            lassign $args id order skipped
            set pending [workflow begin $id]
            set config [_workflow_config [dict create order $order skipped $skipped]]
            foreach key {order skipped} {dict set pending $key [dict get $config $key]}
            return [workflow apply $pending]
        }
        next {
            if {[llength $args] ni {1 2}} {error {workflow next requires completed mode and an optional beverage ID}}
            set completed [canonical [lindex $args 0]]
            set id [dict get $workflow_state selected]
            if {[llength $args] == 2} {set id [lindex $args 1]}
            if {$id ni {espresso latte americano steam}} {error {Unsupported beverage workflow}}
            set order {}
            set config [dict get $workflow_state workflows $id]
            foreach mode [dict get $config order] {
                if {$mode ni [dict get $config skipped]} {lappend order $mode}
            }
            set index [lsearch -exact $order $completed]
            if {$index < 0} {return {}}
            return [lindex $order [expr {$index + 1}]]
        }
        default {error "Unsupported workflow action: $action"}
    }
}

proc ::aiden::modes::setup {{action route}} {
    if {$action ne "route"} {error {Saved beverage setups use the existing native DSx2 save/load surface}}
    # No atomic combined recipe/mode serializer exists in the recipe module.
    # Native favorites are broad saved setups, distinct from profile bookmarks.
    # Metadata only: the app's verified utility dispatcher owns page navigation.
    return [dict create route native_home page off configuration_page workflow_settings \
        title {Saved beverage setups} \
        scope {Native DSx2 setup: recipe identity, dose and grinder settings, steam heater/flow/duration, flush duration, hot-water flow/temperature/amount, and DSx2 workflow/jug settings} \
        reason {Use native DSx2 named setup controls; Aiden has no combined recipe-and-mode load transaction} \
        source {source/DSx2/code/save_and_load.tcl:1-24,94-140,146-204; source/DSx2/pages/cafe/cafe.tcl:74,536-561} \
        auto_start 0 bookmark 0]
}
