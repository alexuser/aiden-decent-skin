# SPDX-License-Identifier: GPL-3.0-only
# Aiden recipe transactions. Sourcing is declarative: no files, settings, or
# machine commands are touched. Profiles are Tcl dictionaries, never scripts.
#
# Public API:
#   configure -profile_dir DIR -state_file FILE     read-only initialization
#   catalog ?query? ?filter? / reload / preview ID  read-only profile catalog
#   begin ?editor|chooser? / select ID / edit DICT  private editing transaction
#   cancel                                        discard this transaction
#   choose ID / apply DICT / reset_adjustments     explicit native commits
#   save_copy NAME DICT / favorite ID ?BOOLEAN?    explicit local file writes
#   working / snapshot / state                    read-only native reconciliation
# Draft values are dose/yield in grams, ratio as yield/dose, temperature in C.
# Native save_settings owns the app settings file. A separate atomic Aiden file
# stores committed provenance and favorites; it never contains a private draft.
namespace eval ::aiden::recipe {
    variable profile_dir {}
    variable state_file {}
    variable records [dict create]
    variable order {}
    variable loaded 0
    variable pending {}
    variable draft {}
    variable base {}
    variable base_source {}
    variable scope {}
    variable applying 0
    variable stored [dict create version 1 favorites {} recent {} working {}]
    variable last_error {}
    variable serial 0
}

proc ::aiden::recipe::get {data key {fallback {}}} {
    if {[dict exists $data $key]} {return [dict get $data $key]}
    return $fallback
}

proc ::aiden::recipe::require_commands {commands} {
    foreach command $commands {
        if {![llength [info commands $command]]} {error "Aiden recipes require $command"}
    }
}

proc ::aiden::recipe::dict_equal {left right} {
    if {[dict size $left] != [dict size $right]} {return 0}
    dict for {key value} $left {
        if {![dict exists $right $key] || [dict get $right $key] ne $value} {return 0}
    }
    return 1
}

proc ::aiden::recipe::number {value label low high} {
    if {![string is double -strict $value] ||
        [catch {expr {double($value)}} result] ||
        [regexp -nocase {nan|inf} $value] || $result < $low || $result > $high} {
        error "$label must be a finite number from $low to $high"
    }
    return $result
}

proc ::aiden::recipe::numeric_or_empty {value} {
    if {[string is double -strict $value] && ![regexp -nocase {nan|inf} $value] &&
        ![catch {expr {double($value)}} result] && ![regexp -nocase {nan|inf} $result]} {return $result}
    return {}
}

proc ::aiden::recipe::normal_type {type} {
    switch -- $type {
        settings_2 - settings_profile_pressure {return settings_2a}
        settings_profile_flow {return settings_2b}
        settings_profile_advanced - settings_2c2 {return settings_2c}
    }
    return $type
}

proc ::aiden::recipe::category {type} {
    switch -- [normal_type $type] {
        settings_2a {return Pressure}
        settings_2b {return Flow}
        settings_2c {return Advanced}
    }
    return Unknown
}

proc ::aiden::recipe::weight_key {profile} {
    if {[normal_type [get $profile settings_profile_type]] eq "settings_2c"} {
        return final_desired_shot_weight_advanced
    }
    return final_desired_shot_weight
}

proc ::aiden::recipe::fields {profile} {
    set dose [numeric_or_empty [get $profile grinder_dose_weight]]
    if {$dose eq {}} {set dose [numeric_or_empty [get $profile profile_grinder_dose_weight]]}
    set yield [numeric_or_empty [get $profile [weight_key $profile]]]
    set temperature [numeric_or_empty [get $profile espresso_temperature]]
    if {[normal_type [get $profile settings_profile_type]] eq "settings_2c"} {
        set steps [get $profile advanced_shot]
        if {[llength $steps] && ![catch {dict get [lindex $steps 0] temperature} first]} {
            set temperature [numeric_or_empty $first]
        }
    }
    set ratio {}
    if {$dose ne {} && $dose > 0 && $yield ne {}} {set ratio [expr {$yield / $dose}]}
    return [dict create dose $dose yield $yield ratio $ratio temperature $temperature]
}

proc ::aiden::recipe::stage_preview {profile} {
    set result {}
    set index 0
    foreach step [get $profile advanced_shot] {
        dict size $step
        set pump [get $step pump]
        set target {}
        if {$pump in {flow pressure}} {set target [numeric_or_empty [get $step $pump]]}
        lappend result [dict create index $index name [get $step name] pump $pump \
            target $target temperature [numeric_or_empty [get $step temperature]] \
            seconds [numeric_or_empty [get $step seconds]]]
        incr index
    }
    return $result
}

proc ::aiden::recipe::read_data {path} {
    if {![file isfile $path] || [file type $path] ne "file"} {error {A regular data file is required}}
    if {[file size $path] > 1048576} {error {Data file exceeds the supported size}}
    set channel [::open $path rb]
    set code [catch {set bytes [read $channel]} message options]
    close $channel
    if {$code} {return -options $options $message}
    set data [encoding convertfrom utf-8 $bytes]
    if {[catch {dict size $data}]} {error {Malformed data dictionary}}
    return $data
}

proc ::aiden::recipe::allowed_fields {} {
    require_commands {::profile_vars}
    # Two obsolete grinder keys are explicitly discarded by load_settings_vars.
    return [concat [::profile_vars] {advanced_shot_tcl profile_editor profile_filename \
        profile_to_save original_profile_title grinder_dose_weight grinder_setting}]
}

proc ::aiden::recipe::validate_numeric_data {raw} {
    # The installed simple-profile converter contains unbraced expr calls.
    # Reject expression strings before invoking that reader, even for previews.
    foreach key {espresso_hold_time preinfusion_time espresso_pressure espresso_decline_time \
        pressure_end espresso_temperature espresso_temperature_0 espresso_temperature_1 \
        espresso_temperature_2 espresso_temperature_3 flow_profile_preinfusion \
        flow_profile_preinfusion_time flow_profile_hold flow_profile_hold_time \
        flow_profile_decline flow_profile_decline_time flow_profile_minimum_pressure \
        preinfusion_flow_rate final_desired_shot_volume final_desired_shot_weight \
        final_desired_shot_weight_advanced tank_desired_water_temperature \
        final_desired_shot_volume_advanced preinfusion_stop_pressure \
        final_desired_shot_volume_advanced_count_start maximum_pressure \
        maximum_pressure_range_advanced maximum_flow_range_advanced maximum_flow \
        maximum_pressure_range_default maximum_flow_range_default \
        profile_grinder_dose_weight profile_grinder_setting grinder_dose_weight grinder_setting} {
        set value [get $raw $key]
        if {$value ne {} && [numeric_or_empty $value] eq {}} {error "Invalid numeric profile field '$key'"}
    }
    foreach key {espresso_temperature_steps_enabled profile_hide insert_preinfusion_pause} {
        set value [get $raw $key]
        if {$value ne {} && ![string is boolean -strict $value]} {error "Invalid boolean profile field '$key'"}
    }
    foreach step [get $raw advanced_shot] {
        dict size $step
        foreach key {temperature pressure flow seconds volume weight exit_if exit_pressure_over \
            exit_pressure_under exit_flow_over exit_flow_under max_flow_or_pressure max_flow_or_pressure_range} {
            set value [get $step $key]
            if {$value ne {} && [numeric_or_empty $value] eq {}} {error "Invalid numeric stage field '$key'"}
        }
    }
}

proc ::aiden::recipe::validate_profile {raw profile} {
    set allowed [allowed_fields]
    dict for {key value} $raw {
        if {$key ni $allowed} {error "Unsupported profile field '$key'; use the existing editor"}
    }
    foreach key {advanced_shot_tcl profile_editor} {
        if {[string trim [get $raw $key]] ne {}} {
            error {Scripted or custom-editor profile: use the existing profile editor}
        }
    }
    set type [normal_type [get $profile settings_profile_type]]
    if {$type ni {settings_2a settings_2b settings_2c}} {error {Unsupported profile type}}
    if {[string trim [get $profile profile_title]] eq {}} {error {Profile has no title}}
    foreach key {espresso_temperature espresso_temperature_0 espresso_temperature_1 espresso_temperature_2 espresso_temperature_3} {
        set value [get $profile $key]
        if {$value ne {}} {number $value {Profile temperature (C)} 0 105}
    }
    foreach key {final_desired_shot_weight final_desired_shot_weight_advanced final_desired_shot_volume final_desired_shot_volume_advanced} {
        set value [get $profile $key]
        if {$value ne {}} {number $value {Profile weight/volume target} 0 2000}
    }
    foreach step [get $profile advanced_shot] {
        dict size $step
        if {![dict exists $step temperature]} {error {Stage temperature is unavailable; use the existing editor}}
        number [dict get $step temperature] {Stage temperature (C)} 0 105
    }
    if {$type eq "settings_2c" && ![llength [get $profile advanced_shot]]} {
        error {Advanced profile has no stages; use the existing editor}
    }
    return 1
}

proc ::aiden::recipe::make_record {id path} {
    set record [dict create id $id path $path title $id fullname $id type Unknown \
        profile_type {} description {} dose {} yield {} ratio {} temperature {} \
        parameters {} stagepreview {} available 0 applyable 0 current 0 favorite 0 \
        hidden 0 error {} profile {} source {}]
    set code [catch {
        require_commands {::profile::read_legacy}
        set raw [read_data $path]
        validate_numeric_data $raw
        set profile [::profile::read_legacy profile_file $path \
            {advanced_shot_tcl profile_editor profile_filename profile_to_save original_profile_title}]
        dict size $profile
        set title [get $profile profile_title]
        if {[string trim $title] eq {}} {error {Profile has no title}}
        set type [normal_type [get $profile settings_profile_type]]
        set hidden [get $profile profile_hide 0]
        if {$hidden eq {}} {set hidden 0}
        if {![string is boolean -strict $hidden]} {error {Invalid profile visibility}}
        dict set record title $title
        dict set record fullname $title
        dict set record profile_type $type
        dict set record type [category $type]
        dict set record hidden [expr {$hidden ? 1 : 0}]
        dict set record description [get $profile profile_notes]
        dict set record profile $profile
        dict set record source $raw
        dict set record available 1
        set parameters [fields $profile]
        dict set record parameters $parameters
        dict for {key value} $parameters {dict set record $key $value}
        if {[catch {validate_profile $raw $profile} reason]} {
            dict set record error $reason
        } else {
            dict set record stagepreview [stage_preview $profile]
            dict set record applyable 1
        }
    } message]
    if {$code} {dict set record error "Could not read profile: $message"}
    return $record
}

proc ::aiden::recipe::configure {args} {
    variable profile_dir
    variable state_file
    variable stored
    variable records
    variable order
    variable loaded
    variable applying
    variable last_error
    if {$applying} {error {A recipe transaction is in progress}}
    if {[llength $args] % 2} {error {Expected option/value pairs}}
    set next_dir $profile_dir
    set next_file $state_file
    foreach {key value} $args {
        switch -- $key {
            -profile_dir {set next_dir [file normalize $value]}
            -state_file {set next_file [file normalize $value]}
            default {error "Unknown Aiden recipe option: $key"}
        }
    }
    if {$next_dir eq {} || ![file isdirectory $next_dir]} {error {A readable profile directory is required}}
    if {$next_file eq {} || [file dirname $next_file] eq $next_dir ||
        [file isdirectory $next_file]} {error {A separate Aiden state file is required}}
    set next_store [dict create version 1 favorites {} recent {} working {}]
    if {[file exists $next_file]} {
        set next_store [read_data $next_file]
        if {[get $next_store version] ne "1"} {error {Unsupported Aiden recipe state version}}
        foreach key {favorites recent working} {
            if {![dict exists $next_store $key]} {error {Incomplete Aiden recipe state}}
        }
        foreach key {favorites recent} {llength [dict get $next_store $key]}
        set working [dict get $next_store working]
        if {$working ne {}} {
            foreach key {profile_id source base effective} {
                if {![dict exists $working $key]} {error {Incomplete committed recipe state}}
            }
            foreach key {source base effective} {dict size [dict get $working $key]}
        }
    }
    set profile_dir $next_dir
    set state_file $next_file
    set stored $next_store
    set records [dict create]
    set order {}
    set loaded 0
    set last_error {}
    cancel
    return [dict create profile_dir $profile_dir state_file $state_file]
}

proc ::aiden::recipe::active_id {} {
    if {[info exists ::settings(profile_filename)]} {return $::settings(profile_filename)}
    return {}
}

proc ::aiden::recipe::effective {} {
    require_commands {::profile_vars}
    set result [dict create]
    foreach key [concat [::profile_vars] {profile_filename grinder_dose_weight advanced_shot_tcl profile_editor}] {
        if {[info exists ::settings($key)]} {dict set result $key $::settings($key)}
    }
    return $result
}

proc ::aiden::recipe::working_matches {{native {}}} {
    variable stored
    variable profile_dir
    set working [get $stored working]
    if {$working eq {} || [get $working profile_id] ne [active_id]} {return 0}
    if {$native eq {}} {set native [effective]}
    if {![dict_equal $native [dict get $working effective]]} {return 0}
    set id [active_id]
    if {$id eq {} || [file tail $id] ne $id || $id in {. ..}} {return 0}
    if {[catch {read_data [file join $profile_dir ${id}.tcl]} raw]} {return 0}
    return [dict_equal $raw [dict get $working source]]
}

proc ::aiden::recipe::working {} {
    variable stored
    variable last_error
    set native [effective]
    set result [fields $native]
    dict set result id [active_id]
    dict set result profile_id [active_id]
    dict set result title [get $native profile_title]
    dict set result fullname [get $native profile_title]
    dict set result settings $native
    dict set result effective $native
    dict set result modified [working_matches $native]
    dict set result stagepreview [stage_preview $native]
    dict set result error $last_error
    set prior [get $stored working]
    dict set result conflict [expr {$prior ne {} && [get $prior profile_id] eq [active_id] && ![dict get $result modified]}]
    return $result
}

# Copy-on-write Tcl values give each observed shot an independent recipe value.
proc ::aiden::recipe::snapshot {} {return [working]}

proc ::aiden::recipe::reload {} {
    variable profile_dir
    variable records
    variable order
    variable loaded
    variable applying
    if {$applying} {error {A recipe transaction is in progress}}
    if {$profile_dir eq {}} {error {Configure Aiden recipes first}}
    set next [dict create]
    set next_order {}
    foreach name [lsort -dictionary [glob -nocomplain -tails -directory $profile_dir *.tcl]] {
        if {[string match .aiden-* $name]} {continue}
        set path [file normalize [file join $profile_dir $name]]
        if {[file dirname $path] ne $profile_dir || [file type $path] ne "file"} {continue}
        set id [file rootname $name]
        dict set next $id [make_record $id $path]
        lappend next_order $id
    }
    set records $next
    set order $next_order
    set loaded 1
    return [catalog]
}

proc ::aiden::recipe::catalog {{query {}} {filter all}} {
    variable records
    variable order
    variable stored
    variable profile_dir
    variable loaded
    set filter [string tolower $filter]
    if {$filter ni {all pressure flow advanced hidden favorites recent}} {error {Unknown recipe filter}}
    if {$profile_dir eq {}} {error {Configure Aiden recipes first}}
    if {!$loaded} {reload}
    set words [regexp -all -inline {\S+} [string tolower $query]]
    set ids $order
    if {$filter eq "recent"} {set ids [get $stored recent]}
    set result {}
    foreach id $ids {
        if {![dict exists $records $id]} {continue}
        set record [dict get $records $id]
        set hidden [dict get $record hidden]
        if {$filter eq "hidden"} {
            if {!$hidden} {continue}
        } elseif {$hidden} {continue}
        if {$filter in {pressure flow advanced} && $filter ne [string tolower [dict get $record type]]} {continue}
        set favorite [expr {$id in [get $stored favorites]}]
        if {$filter eq "favorites" && !$favorite} {continue}
        set haystack [string tolower [list $id [dict get $record title] [dict get $record type] [dict get $record description]]]
        set match 1
        foreach word $words {if {[string first $word $haystack] < 0} {set match 0; break}}
        if {!$match} {continue}
        dict set record current [expr {$id eq [active_id]}]
        dict set record favorite $favorite
        if {[dict get $record current]} {
            set parameters [fields [effective]]
            dict set record parameters $parameters
            dict for {key value} $parameters {dict set record $key $value}
        }
        lappend result $record
    }
    return $result
}

proc ::aiden::recipe::preview {id} {
    variable records
    variable loaded
    if {!$loaded} {reload}
    if {![dict exists $records $id]} {error {Profile is no longer available}}
    return [dict get $records $id]
}

proc ::aiden::recipe::begin {{kind editor}} {
    variable applying
    variable base
    variable base_source
    variable draft
    variable pending
    variable scope
    if {$applying} {error {A recipe transaction is in progress}}
    if {$kind ni {editor chooser}} {error {Unknown recipe transaction}}
    set native [effective]
    set source {}
    if {$kind eq "chooser"} {
        reload
    } else {
        set record [make_record [active_id] [profile_path [active_id]]]
        if {![dict get $record applyable]} {error [dict get $record error]}
        foreach key {advanced_shot_tcl profile_editor} {
            if {[string trim [get $native $key]] ne {}} {error {Use the existing profile editor for this recipe}}
        }
        set source [dict get $record source]
    }
    set base $native
    set base_source $source
    set draft [fields $native]
    set pending {}
    set scope $kind
    return $draft
}

proc ::aiden::recipe::select {id} {
    variable applying
    variable pending
    variable scope
    if {$applying} {error {A recipe transaction is in progress}}
    if {$scope ne "chooser"} {begin chooser}
    set record [preview $id]
    if {![dict get $record available]} {error [dict get $record error]}
    set pending $id
    return $record
}

proc ::aiden::recipe::cancel {} {
    variable applying
    variable pending
    variable draft
    variable base
    variable base_source
    variable scope
    if {$applying} {error {A recipe transaction is in progress}}
    set pending {}
    set draft {}
    set base {}
    set base_source {}
    set scope {}
    return [state]
}

proc ::aiden::recipe::state {} {
    variable pending
    variable draft
    variable scope
    variable last_error
    return [dict create active [active_id] pending $pending draft $draft scope $scope error $last_error]
}

proc ::aiden::recipe::profile_path {id} {
    variable profile_dir
    if {$profile_dir eq {} || $id eq {} || [file tail $id] ne $id || $id in {. ..}} {error {Invalid profile identity}}
    set path [file normalize [file join $profile_dir ${id}.tcl]]
    if {[file dirname $path] ne $profile_dir || ![file isfile $path] || [file type $path] ne "file"} {
        error {The profile file is no longer available}
    }
    return $path
}

proc ::aiden::recipe::guard {} {
    variable profile_dir
    variable state_file
    require_commands {::aiden::core::snapshot ::homedir ::profile_vars ::profile::read_legacy}
    if {$profile_dir ne [file normalize [file join [::homedir] profiles]]} {
        error {Recipe commits require the app's actual profile directory}
    }
    if {$state_file eq {}} {error {Aiden recipe persistence is not configured}}
    set status [::aiden::core::snapshot]
    foreach key {native_state editable pending context_verified current_page current_context} {
        if {![dict exists $status $key]} {error {The native operation state could not be verified}}
    }
    if {[dict get $status native_state] ne "Idle" ||
        ![string is true -strict [dict get $status editable]] ||
        [dict get $status pending] ne {} ||
        ![string is true -strict [dict get $status context_verified]] ||
        [dict get $status current_page] ne [dict get $status current_context] ||
        [dict get $status current_page] ni {aiden_home aiden_profiles aiden_recipe} ||
        ![info exists ::de1(current_context)] ||
        $::de1(current_context) ne [dict get $status current_context] ||
        ![info exists ::de1(state)] || ![info exists ::de1_num_state($::de1(state))] ||
        $::de1_num_state($::de1(state)) ne "Idle"} {
        error {Recipe changes require verified idle preparation with no pending operation}
    }
    return $status
}

proc ::aiden::recipe::check_base {} {
    variable base
    variable scope
    if {$scope eq {} || $base eq {}} {error {Open and review the recipe before committing}}
    if {![dict_equal $base [effective]]} {
        error {The native recipe changed during this draft. Reopen it to review the current recipe.}
    }
}

proc ::aiden::recipe::check_record {record} {
    set path [profile_path [dict get $record id]]
    if {$path ne [dict get $record path] || ![dict get $record applyable]} {
        error [dict get $record error]
    }
    set fresh [make_record [dict get $record id] $path]
    if {![dict get $fresh applyable]} {error [dict get $fresh error]}
    if {![dict_equal [dict get $fresh source] [dict get $record source]] ||
        ![dict_equal [dict get $fresh profile] [dict get $record profile]]} {
        error {The saved profile changed since preview. Reopen it to review the new recipe.}
    }
    return $fresh
}

proc ::aiden::recipe::normalize_draft {native input reference} {
    dict size $input
    foreach key [dict keys $input] {
        if {$key ni {dose yield ratio temperature}} {error "Unsupported recipe field '$key'"}
    }
    set values [fields $native]
    dict for {key value} $input {dict set values $key $value}
    set old [fields $native]
    set dose [get $values dose]
    set yield [get $values yield]
    set temperature [get $values temperature]
    # DSx2 adjust dose: 2..40 g; adjust saw: basic 0..100, advanced 0..2000.
    # Existing unset/zero dose stays readable when a different field is edited.
    if {[dict exists $input dose] && $dose ne [get $old dose]} {number $dose {Dose (g)} 2 40}
    if {$dose ne {}} {number $dose {Dose (g)} 0 40}
    set maximum 100
    if {[normal_type [get $native settings_profile_type]] eq "settings_2c"} {set maximum 2000}
    set ratio_edited 0
    if {[dict exists $input ratio] && [get $input ratio] ne {}} {
        if {$dose eq {} || $dose <= 0} {error {Set a positive dose before editing ratio}}
        # Ratio has no separate native bound: the supported yield bounds it.
        set ratio [number [get $input ratio] Ratio 0 [expr {2000.0 / $dose}]]
        set old_ratio [numeric_or_empty [get $reference ratio]]
        if {$old_ratio eq {} || abs($ratio-$old_ratio) > 0.000000001 || ![dict exists $input yield]} {
            set ratio_edited 1
        }
        if {$ratio_edited} {
            if {$dose eq {} || $dose <= 0} {error {Set a positive dose before editing ratio}}
            set yield [expr {round($dose * $ratio * 10.0) / 10.0}]
        }
    }
    if {$yield ne {}} {
        # An unchanged source target may exceed DSx2's compact basic control.
        set limit $maximum
        if {!$ratio_edited && $yield eq [get $old yield]} {set limit 2000}
        number $yield {Target yield (g)} 0 $limit
    }
    if {$temperature ne {}} {number $temperature {Temperature (C)} 0 105}
    set ratio {}
    if {$dose ne {} && $dose > 0 && $yield ne {}} {set ratio [expr {double($yield) / $dose}]}
    return [dict create dose $dose yield $yield ratio $ratio temperature $temperature]
}

proc ::aiden::recipe::edit {changes} {
    variable applying
    variable draft
    variable base
    variable scope
    if {$applying} {error {A recipe transaction is in progress}}
    if {$scope ne "editor"} {error {Open a recipe draft first}}
    check_base
    set merged $draft
    dict for {key value} $changes {dict set merged $key $value}
    set draft [normalize_draft $base $merged $draft]
    return $draft
}

# Compatible offset semantics from vars.tcl change_espresso_temperature. Unlike
# its broad range_check_shot_variables call, this pure operation cannot clamp
# unrelated dose/pressure fields. All stage differences are preserved exactly.
proc ::aiden::recipe::adjusted {native values} {
    set next $native
    foreach {field key} [list dose grinder_dose_weight yield [weight_key $native]] {
        if {[get $values $field] ne {}} {dict set next $key [get $values $field]}
    }
    set old [fields $native]
    set target [get $values temperature]
    set current [get $old temperature]
    if {$target eq $current} {return $next}
    if {$target eq {} || $current eq {}} {error {Temperature offset is unavailable; use the existing editor}}
    set delta [expr {double($target) - $current}]
    set type [normal_type [get $native settings_profile_type]]
    if {$type eq "settings_2c"} {
        set steps [get $native advanced_shot]
        if {![llength $steps]} {error {Stage temperatures are unavailable; use the existing editor}}
        set minimum 0
        if {[info exists ::settings(minimum_water_temperature)]} {
            set minimum [number $::settings(minimum_water_temperature) {Native minimum temperature} 0 105]
        }
        set updated {}
        foreach step $steps {
            set value [expr {[number [get $step temperature] {Stage temperature (C)} 0 105] + $delta}]
            number $value {Stage temperature (C)} $minimum 105
            dict set step temperature $value
            lappend updated $step
        }
        dict set next advanced_shot $updated
        dict set next espresso_temperature [dict get [lindex $updated 0] temperature]
    } elseif {$type in {settings_2a settings_2b}} {
        dict set next espresso_temperature $target
        if {[string is true -strict [get $native espresso_temperature_steps_enabled 0]]} {
            # Native simple-profile offset normalizes step 0 to the global temp.
            # A source where those differ cannot use that operation faithfully.
            if {[get $native espresso_temperature_0] eq {} ||
                [number [get $native espresso_temperature_0] {First stage temperature (C)} 0 105] != $current} {
                error {First stage temperature differs from the base; use the existing editor}
            }
            foreach key {espresso_temperature_0 espresso_temperature_1 espresso_temperature_2 espresso_temperature_3} {
                set value [expr {[number [get $native $key] {Stage temperature (C)} 0 105] + $delta}]
                number $value {Stage temperature (C)} 0 105
                dict set next $key $value
            }
        }
    } else {error {Use the existing profile editor for this recipe}}
    return $next
}

proc ::aiden::recipe::serialize {data} {
    set text {}
    foreach key [lsort -dictionary [dict keys $data]] {
        append text [list $key] " " [list [dict get $data $key]] "\n"
    }
    return $text
}

proc ::aiden::recipe::stage_file {target data} {
    variable serial
    set dir [file dirname $target]
    if {![file isdirectory $dir]} {error {The persistence directory is unavailable}}
    if {[file exists $target] && [file type $target] ne "file"} {error {Persistence requires a regular file}}
    incr serial
    set temporary [file join $dir .aiden-[pid]-[clock clicks]-${serial}.tcl]
    set channel [::open $temporary {WRONLY CREAT EXCL}]
    set code [catch {
        fconfigure $channel -encoding utf-8 -translation lf
        puts -nonewline $channel [serialize $data]
        flush $channel
    } message options]
    set close_code [catch {close $channel} close_message close_options]
    if {$code || $close_code} {
        catch {file delete $temporary}
        if {$code} {return -options $options $message}
        return -options $close_options $close_message
    }
    if {![dict_equal [read_data $temporary] $data]} {
        file delete $temporary
        error {Persistence validation failed}
    }
    return $temporary
}

proc ::aiden::recipe::commit_state {temporary next} {
    variable state_file
    variable stored
    if {[file exists $state_file] && [file type $state_file] ne "file"} {error {Aiden state file was replaced}}
    file rename -force $temporary $state_file
    set stored $next
}

proc ::aiden::recipe::persist_native {expected} {
    require_commands {::save_settings ::settings_filename}
    ::save_settings
    set saved [read_data [::settings_filename]]
    dict for {key value} $expected {
        if {![dict exists $saved $key] || [dict get $saved $key] ne $value} {
            error {The app did not confirm saved recipe settings. Verify the current recipe.}
        }
    }
}

proc ::aiden::recipe::refresh_native {next} {
    require_commands {::profile::sync_from_legacy ::update_onscreen_variables ::send_de1_settings_soon}
    dict for {key value} $next {set ::settings($key) $value}
    set ::settings(profile_has_changed) 1
    ::profile::sync_from_legacy
    ::update_onscreen_variables
}

proc ::aiden::recipe::finish_transaction {code result options temporary} {
    variable applying
    variable last_error
    set applying 0
    if {$temporary ne {} && [file exists $temporary]} {catch {file delete $temporary}}
    if {$code} {
        set last_error "$result The displayed recipe is reconciled from the app; review it before continuing."
        cancel
        return -options $options $last_error
    }
    set last_error {}
    cancel
    return [working]
}

proc ::aiden::recipe::apply {input} {
    variable applying
    variable scope
    variable draft
    variable base
    variable base_source
    variable stored
    variable state_file
    if {$applying} {error {A recipe transaction is in progress}}
    if {$scope ne "editor"} {error {Open a recipe draft first}}
    guard
    check_base
    require_commands {::profile::sync_from_legacy ::update_onscreen_variables ::send_de1_settings_soon ::save_settings ::settings_filename}
    set record [make_record [active_id] [profile_path [active_id]]]
    if {![dict get $record applyable]} {error [dict get $record error]}
    if {![dict_equal $base_source [dict get $record source]]} {error {The saved profile changed; reopen the draft}}
    set values [normalize_draft $base $input $draft]
    set next_native [adjusted $base $values]
    # Reuse the original baseline across successive adjustment transactions.
    set original $base
    if {[working_matches $base]} {set original [dict get $stored working base]}
    set next $stored
    dict set next working [dict create profile_id [active_id] source $base_source \
        base $original effective $next_native]
    set temporary [stage_file $state_file $next]
    set applying 1
    set code [catch {
        guard
        check_base
        refresh_native $next_native
        if {![dict_equal $next_native [effective]]} {error {The app changed the recipe during the adjustment commit}}
        persist_native [effective]
        commit_state $temporary $next
        ::send_de1_settings_soon
    } result options]
    return [finish_transaction $code $result $options $temporary]
}

proc ::aiden::recipe::choose {id} {
    variable applying
    variable scope
    variable pending
    variable stored
    variable state_file
    if {$applying} {error {A recipe transaction is in progress}}
    if {$scope ne "chooser"} {error {Open and preview the profile chooser first}}
    guard
    check_base
    set record [check_record [preview $id]]
    if {$id eq [active_id]} {cancel; return [working]}
    require_commands {::select_profile ::save_settings ::settings_filename}
    set dose {}
    if {[working_matches]} {set dose [get [dict get $stored working base] grinder_dose_weight]}
    set suggested [numeric_or_empty [get [dict get $record profile] profile_grinder_dose_weight]]
    if {$suggested ne {} && $suggested > 0} {set dose [number $suggested {Profile dose (g)} 2 40]}
    set next $stored
    dict set next working {}
    set recent [list $id]
    foreach prior [get $stored recent] {if {$prior ne $id} {lappend recent $prior}}
    dict set next recent [lrange $recent 0 19]
    set temporary [stage_file $state_file $next]
    set applying 1
    set code [catch {
        guard
        check_base
        check_record $record
        if {$dose ne {}} {set ::settings(grinder_dose_weight) $dose}
        set selected [::select_profile $id]
        if {$selected eq "-1" || [active_id] ne $id ||
            ![info exists ::settings(profile_title)] || $::settings(profile_title) eq {}} {
            error {The app did not confirm the selected profile}
        }
        persist_native [effective]
        commit_state $temporary $next
    } result options]
    return [finish_transaction $code $result $options $temporary]
}

proc ::aiden::recipe::reset_adjustments {} {
    variable applying
    variable stored
    variable state_file
    if {$applying} {error {A recipe transaction is in progress}}
    guard
    if {![working_matches]} {
        if {[get $stored working] ne {}} {error {The recipe changed externally; review it in the existing editor before resetting}}
        return [working]
    }
    require_commands {::select_profile ::save_settings ::settings_filename}
    set record [make_record [active_id] [profile_path [active_id]]]
    if {![dict get $record applyable]} {error [dict get $record error]}
    set before [effective]
    set id [active_id]
    set dose [get [dict get $stored working base] grinder_dose_weight]
    set next $stored
    dict set next working {}
    set temporary [stage_file $state_file $next]
    set applying 1
    set code [catch {
        guard
        if {![dict_equal $before [effective]]} {error {The native recipe changed before reset}}
        check_record $record
        set selected [::select_profile $id]
        if {$selected eq "-1" || [active_id] ne $id} {error {The app did not confirm recipe reset}}
        if {$dose ne {}} {set ::settings(grinder_dose_weight) $dose}
        persist_native [effective]
        commit_state $temporary $next
    } result options]
    return [finish_transaction $code $result $options $temporary]
}

proc ::aiden::recipe::save_copy {name input} {
    variable applying
    variable scope
    variable base
    variable base_source
    variable draft
    variable profile_dir
    variable records
    variable order
    if {$applying} {error {A recipe transaction is in progress}}
    if {$scope ne "editor"} {error {Open a recipe draft first}}
    guard
    check_base
    require_commands {::profile::filename_from_title}
    set name [string trim $name]
    if {$name eq {} || [regexp {[\x00-\x1f\x7f]} $name] ||
        [regexp {(^|[/\\])\.\.([/\\]|$)} $name]} {error {Enter a distinct, readable copy name}}
    set id [::profile::filename_from_title $name]
    if {$id eq {} || [file tail $id] ne $id || $id in {. ..}} {error {The copy name cannot form a valid filename}}
    foreach existing [glob -nocomplain -tails -directory $profile_dir *.tcl] {
        if {[string equal -nocase [file rootname $existing] $id]} {error {A profile already uses that filename. Choose a different name.}}
    }
    set source [read_data [profile_path [active_id]]]
    if {![dict_equal $source $base_source]} {error {The saved profile changed; reopen the draft}}
    set values [normalize_draft $base $input $draft]
    set adjusted [adjusted $base $values]
    set copy [dict create]
    foreach key [::profile_vars] {
        if {[dict exists $adjusted $key]} {dict set copy $key [dict get $adjusted $key]}
    }
    dict set copy profile_title $name
    dict set copy read_only 0
    dict set copy read_only_backup {}
    dict set copy profile_hide 0
    dict set copy profile_grinder_dose_weight [get $values dose]
    set target [file join $profile_dir ${id}.tcl]
    set temporary [stage_file $target $copy]
    set applying 1
    set code [catch {
        guard
        check_base
        set readback [make_record $id $temporary]
        if {![dict get $readback applyable]} {error [dict get $readback error]}
        if {[file exists $target]} {error {A profile already uses that filename}}
        # No -force: an existing profile is never overwritten.
        file rename $temporary $target
        dict set records $id [make_record $id $target]
        set order [lsort -dictionary [dict keys $records]]
    } result options]
    set applying 0
    if {[file exists $temporary]} {catch {file delete $temporary}}
    if {$code} {return -options $options $result}
    # Keep draft, committed settings, and profile selection exactly as they were.
    return [preview $id]
}

proc ::aiden::recipe::favorite {id {enabled {}}} {
    variable applying
    variable stored
    variable state_file
    if {$applying} {error {A recipe transaction is in progress}}
    preview $id
    set favorites [get $stored favorites]
    set current [expr {$id in $favorites}]
    if {$enabled eq {}} {set enabled [expr {!$current}]}
    if {![string is boolean -strict $enabled]} {error {Favorite state must be boolean}}
    set next_favorites {}
    foreach prior $favorites {if {$prior ne $id} {lappend next_favorites $prior}}
    if {$enabled} {lappend next_favorites $id}
    set next $stored
    dict set next favorites $next_favorites
    set temporary [stage_file $state_file $next]
    set code [catch {commit_state $temporary $next} result options]
    if {[file exists $temporary]} {catch {file delete $temporary}}
    if {$code} {return -options $options $result}
    return [expr {$enabled ? 1 : 0}]
}
