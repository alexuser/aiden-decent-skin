# SPDX-License-Identifier: GPL-3.0-only
# Headless registration/dispatch fixture. No hardware, settings or app source.
# Recipe arithmetic is checked against the controller's pure normalizer.
namespace eval ::fixture {
    variable pages {}
    variable current aiden_home
    variable commands {}
    variable items {}
    variable tag_ids {}
    variable item_pages {}
    variable states {}
    variable initial_states {}
    variable options {}
    variable next 0
    variable vectors {}
    variable actions {}
    variable elements
    array set elements {}
}
proc ::fixture::register {page tags} {
    variable next
    variable items
    variable tag_ids
    variable item_pages
    variable states
    variable initial_states
    variable current
    set tag [lindex $tags 0]
    if {[dict exists $items "$page,$tag"]} {error "Duplicate tag $page,$tag"}
    set id [incr next]
    dict set items "$page,$tag" $id
    dict set item_pages $id $page
    dict set states $id [expr {$page eq $current ? {normal} : {hidden}}]
    dict set initial_states $id normal
    foreach name $tags {dict lappend tag_ids "$page,$name" $id}
    return $id
}
proc ::fixture::find {page tags} {
    variable tag_ids
    variable item_pages
    set ids {}
    foreach tag $tags {
        # Native DUI passes exact tag expressions to canvas find withtag.
        # Only the standalone all-items forms have special meaning.
        if {$tag in {* all {}}} {
            dict for {id item_page} $item_pages {if {$item_page eq $page} {lappend ids $id}}
        } elseif {[dict exists $tag_ids "$page,$tag"]} {
            lappend ids {*}[dict get $tag_ids "$page,$tag"]
        }
    }
    return [lsort -integer -unique $ids]
}
proc ::fixture::state {page tag {initial 0}} {
    set id [lindex [find $page $tag] 0]
    if {$id eq {}} {return missing}
    if {$initial} {return [dict get $::fixture::initial_states $id]}
    return [dict get $::fixture::states $id]
}
proc ::fixture::tap {page tag} {
    variable commands
    if {[state $page $tag] ne {normal}} {return 0}
    uplevel #0 [dict get $commands "$page,$tag"]
    return 1
}
proc ::fixture::widget {name args} {
    variable elements
    switch -- [lindex $args 0] {
        yview {return {0 1}}
        tag {
            if {[lindex $args 1] eq {names}} {return aiden_row_0}
            return {}
        }
        element {
            set method [lindex $args 1]
            set element [lindex $args 2]
            switch -- $method {
                exists {return [info exists elements($name,$element)]}
                create {set elements($name,$element) [lrange $args 3 end]}
                names {
                    set out {}
                    foreach key [array names elements "$name,*"] {lappend out [lindex [split $key ,] 1]}
                    return $out
                }
                configure {set elements($name,$element) [lrange $args 3 end]}
            }
        }
    }
    return {}
}
proc .can {args} {
    if {[lindex $args 0] eq {coords}} {return {0 0}}
    return {}
}
namespace eval ::dui::platform {}
proc ::dui::platform::rescale_x {x} {return [expr {$x*.75}]}
proc ::dui::platform::rescale_y {y} {return [expr {$y*.75}]}
proc ::dui {section args} {
    variable ::fixture::pages
    variable ::fixture::current
    variable ::fixture::commands
    variable ::fixture::items
    variable ::fixture::next
    variable ::fixture::states
    variable ::fixture::initial_states
    variable ::fixture::item_pages
    variable ::fixture::options
    switch -- $section {
        canvas {return .can}
        cget {
            if {[lindex $args 0] eq {screen_size_width}} {return 1920}
            if {[lindex $args 0] eq {screen_size_height}} {return 1200}
            return 1
        }
        font {
            if {[lindex $args 0] eq {get}} {return {Helvetica 20}}
            return {}
        }
        image {return {}}
        page {
            set action [lindex $args 0]
            set page [lindex $args 1]
            switch -- $action {
                exists {return [expr {$page in $pages}]}
                add {lappend pages $page; return $page}
                current {return $current}
                show {
                    set current $page
                    dict for {id item_page} $item_pages {
                        set state hidden
                        if {$item_page eq $page} {set state [dict get $initial_states $id]}
                        dict set states $id $state
                    }
                    return $page
                }
                add_action {return {}}
                default {error "Unhandled page action: $args"}
            }
        }
        add {
            set type [lindex $args 0]
            if {$type eq {shape}} {set page [lindex $args 2]} else {set page [lindex $args 1]}
            if {$page ni $pages} {error "Unregistered page $page"}
            set pos [lsearch -exact $args -tags]
            if {$pos<0} {error "Missing item tag $args"}
            set tags [lindex $args [expr {$pos+1}]]
            set tag [lindex $tags 0]
            if {$type eq {dbutton}} {
                # DUI always creates a -btn item, including transparent hits.
                ::fixture::register $page [list ${tag}-btn {*}[lrange $tags 1 end]]
                set shape_pos [lsearch -exact $args -shape]
                if {$shape_pos>=0 && [lindex $args [expr {$shape_pos+1}]] eq {round_outline}} {
                    ::fixture::register $page [list ${tag}-out {*}[lrange $tags 1 end]]
                }
                set label_pos [lsearch -exact $args -label]
                if {$label_pos>=0 && [lindex $args [expr {$label_pos+1}]] ne {}} {
                    ::fixture::register $page [list ${tag}-lbl {*}[lrange $tags 1 end]]
                }
            }
            set id [::fixture::register $page $tags]
            set pos [lsearch -exact $args -command]
            if {$pos>=0} {dict set commands "$page,$tag" [lindex $args [expr {$pos+1}]]}
            if {$type in {graph entry text}} {
                set name .fixture$id
                interp alias {} $name {} ::fixture::widget $name
                return $name
            }
            return $id
        }
        item {
            set action [lindex $args 0]
            set page [lindex $args 1]
            set tags [lindex $args 2]
            set ids [::fixture::find $page $tags]
            if {$action eq {get}} {return $ids}
            if {$action in {enable disable show hide}} {
                switch -- $action {enable - show {set state normal} disable {set state disabled} hide {set state hidden}}
                set initial_pos [lsearch -exact $args -initial]
                set do_initial [expr {$initial_pos>=0 && [lindex $args [expr {$initial_pos+1}]]}]
                foreach id $ids {
                    if {$action in {enable disable}} {
                        if {[dict get $states $id] ne {hidden}} {dict set states $id $state}
                    } elseif {$page eq $current} {dict set states $id $state}
                    if {$do_initial} {dict set initial_states $id $state}
                }
            } elseif {$action eq {config}} {
                foreach id $ids {
                    foreach {option value} [lrange $args 3 end] {dict set options $id $option $value}
                }
            }
            return {}
        }
        default {error "Unhandled DUI section $section $args"}
    }
}
proc bind {args} {}
proc winfo {what args} {
    if {$what eq {height}} {return 600}
    return 1
}
proc focus {args} {}
proc image {args} {return fixture-image}
namespace eval ::blt {}
proc ::blt::vector {method name} {
    interp alias {} $name {} ::fixture::vector $name
    return $name
}
proc ::fixture::vector {name method args} {
    variable vectors
    if {$method eq {set}} {dict set vectors $name [lindex $args 0]}
    if {$method eq {index}} {return [lindex [dict get $vectors $name] end]}
    return {}
}
namespace eval ::aiden::app {}
proc ::aiden::app::action {name args} {
    lappend ::fixture::actions [list $name {*}$args]
    return 1
}
proc assert {condition message} {
    if {![uplevel 1 [list expr $condition]]} {error $message}
}
source [file join [file dirname [info script]] ui.tcl]
source [file join [file dirname [info script]] recipe.tcl]
assert {[::aiden::ui::mount] eq {aiden_home}} {Wrong mount result}
assert {[llength $::fixture::pages]==9} {Not all nine native pages registered}
::aiden::ui::set_reduced_motion 1
set items_before [dict size $::fixture::items]
::aiden::ui::mount
assert {[dict size $::fixture::items]==$items_before} {Mount is not idempotent}
set snapshot [dict create phase ready mode espresso status Ready ready 1 primary_enabled 1 can_select_mode 1 can_tare 1 weight 0 weight_quality live \
    scale [dict create weight 0 quality live can_tare 1 state connected] recipe [dict create title {Gentle and sweet} dose 18 yield 36 temperature 88] elapsed 0 temperature 88 pressure 0 flow 0]
::aiden::ui::render $snapshot
assert {$::aiden::ui::data(weight) eq {0.0}} {Real sensor zero was lost}
::aiden::ui::render [dict replace $snapshot weight {} weight_quality unavailable scale [dict create state disconnected]]
assert {$::aiden::ui::data(weight) eq {—}} {Missing weight rendered as zero}
::aiden::ui::render $snapshot
::aiden::ui::set_catalog [list \
    [dict create id one title {Gentle and sweet} type Pressure description Gentle dose 18 yield 36 temperature 88 available 1 current 1 favorite 0] \
    [dict create id two title {A full long profile name with distinguishing information preserved} type Advanced description Long dose 18 yield 45 temperature 91 available 1 current 0 favorite 1] \
    [dict create id broken title {Unreadable profile} available 0 reason {Native parse failed}]]
::aiden::ui::show profiles
::aiden::ui::select_profile two
assert {$::aiden::ui::selected_id eq {two}} {Chooser selection identity lost}
assert {[lindex [lindex $::fixture::actions end] 0] eq {profile_select}} {Chooser did not dispatch pending selection}
::aiden::ui::filter_favorites 1
assert {[llength $::aiden::ui::filtered]==1} {Favorites filter failed}
set ::aiden::ui::query distinguishing
assert {[llength $::aiden::ui::filtered]==1} {Full-name search failed}
::aiden::ui::commit_profile
assert {[lindex $::fixture::actions end] eq {profile_apply two}} {Profile apply must use stable ID}
::aiden::ui::cancel aiden_profiles
assert {[lindex $::fixture::actions end] eq {profile_cancel}} {Profile Cancel missing}
::aiden::ui::set_recipe [dict create dose 18 yield 36 temperature 88]
::aiden::ui::show recipe
set native_recipe [dict create settings_profile_type settings_2a grinder_dose_weight 18 final_desired_shot_weight 36 espresso_temperature 88]
set native_reference [::aiden::recipe::fields $native_recipe]
set action_count [llength $::fixture::actions]
set ::aiden::ui::data(dose) 19
assert {$::aiden::ui::data(ratio) eq {1 : 1.89}} {Focused dose edit left the displayed ratio stale}
assert {$::aiden::ui::data(ratio_draft) eq {1.89}} {Focused dose edit left the ratio entry stale}
assert {$::aiden::ui::data(dose) eq {19}} {Live preview reformatted the focused dose input}
assert {[llength $::fixture::actions]==$action_count} {Typing a dose dispatched an action}
set calculated [::aiden::recipe::normalize_draft $native_recipe [::aiden::ui::recipe_model] $native_reference]
assert {[dict get $calculated yield]==36} {Rounded ratio preview changed the unchanged yield at commit}
assert {abs([dict get $calculated ratio]-36.0/19.0)<1e-12} {Recipe model lost the calculated ratio precision}
::aiden::ui::recipe_field_changed ratio
assert {[llength $::fixture::actions]==$action_count} {An untouched rounded ratio dispatched an edit on focus loss}
set ::aiden::ui::data(yield) 40
assert {$::aiden::ui::data(ratio) eq {1 : 2.11}} {Focused yield edit left the displayed ratio stale}
set ::aiden::ui::data(ratio_draft) 2.5
assert {$::aiden::ui::data(yield) eq {47.5}} {Focused ratio edit did not preview the new yield}
assert {$::aiden::ui::data(ratio_draft) eq {2.5}} {Live preview rewrote the focused ratio input}
set calculated [::aiden::recipe::normalize_draft $native_recipe [::aiden::ui::recipe_model] $native_reference]
assert {[dict get $calculated yield]==47.5} {Explicit ratio edit did not reach the commit model}
assert {[llength $::fixture::actions]==$action_count} {Live ratio synchronization dispatched an action}
set ::aiden::ui::data(ratio_draft) .
assert {$::aiden::ui::data(ratio) eq {Ratio unavailable}} {Partial ratio input displayed a stale valid ratio}
assert {$::aiden::ui::data(ratio_draft) eq {.}} {Partial ratio input was overwritten}
assert {[catch {::aiden::recipe::normalize_draft $native_recipe [::aiden::ui::recipe_model] $native_reference}]} {Invalid ratio was replaced by an earlier valid value}
set ::aiden::ui::data(ratio_draft) 1e308
assert {!$::aiden::ui::recipe_syncing} {Overflowing preview left input synchronization locked}
assert {$::aiden::ui::data(ratio) eq {Ratio unavailable}} {Overflowing ratio produced an invalid preview}
foreach missing {{} 0 NaN} {
    set ::aiden::ui::data(dose) $missing
    assert {$::aiden::ui::data(ratio) eq {Ratio unavailable}} {Unavailable or zero dose produced a fabricated ratio}
    assert {!$::aiden::ui::recipe_syncing} {Incomplete numeric input left synchronization locked}
}
assert {[llength $::fixture::actions]==$action_count} {Incomplete input dispatched an action}
::aiden::ui::set_recipe $native_reference
assert {$::aiden::ui::data(dose)==18 && $::aiden::ui::data(ratio) eq {1 : 2.00}} {Controller draft reload did not restore the recipe}
assert {[llength $::fixture::actions]==$action_count} {Controller draft reload triggered a write trace action}
set ::aiden::ui::data(dose) 19
::aiden::ui::cancel aiden_recipe
assert {[lindex $::fixture::actions end] eq {recipe_cancel}} {Recipe Cancel dispatched a commit action}
::aiden::ui::show home
set action_count [llength $::fixture::actions]
::aiden::ui::recipe_field_changed dose
assert {[llength $::fixture::actions]==$action_count} {Late focus loss edited a cancelled recipe draft}
::aiden::ui::set_recipe $native_reference
::aiden::ui::show recipe
assert {$::aiden::ui::data(dose)==18 && $::aiden::ui::data(ratio) eq {1 : 2.00}} {Reopened recipe retained the cancelled dose}
assert {![array exists ::settings]} {UI draft preview wrote native settings}
set ::aiden::ui::data(yield) 45
::aiden::ui::recipe_field_changed yield
assert {[lindex $::fixture::actions end] eq {recipe_edit yield 45}} {Recipe edit did not dispatch its private draft value}
::aiden::ui::open_copy
assert {$::aiden::ui::copy_open} {Copy flow missing}
::aiden::ui::set_recipe [::aiden::ui::recipe_model]
assert {$::aiden::ui::copy_open} {Private recipe validation closed the nested copy sheet}
set ::aiden::ui::copy_name {My adjusted profile}
::aiden::ui::commit_copy
assert {[lindex [lindex $::fixture::actions end] 0] eq {recipe_save_copy}} {Copy must be separate from apply}
::aiden::ui::close_copy
::aiden::ui::commit_recipe
assert {[lindex [lindex $::fixture::actions end] 0] eq {recipe_apply}} {Use adjustments missing}
set fields [list [dict create key steam_flow native_key steam_flow label Flow value 70 available 1 min 40 max 250 step 10 display_factor .01 display_unit mL/s] \
    [dict create key steam_disabled native_key steam_disabled label {Heater disabled} value 0 available 1 semantics boolean]]
::aiden::ui::set_mode_settings steam [dict create title Steam values [dict create steam_flow 70 steam_disabled 0] fields $fields editable 1]
::aiden::ui::show modes
::aiden::ui::step_mode 0 1
assert {[dict get $::aiden::ui::mode_draft steam_flow]==80} {Mode edit did not preserve native units}
assert {$::aiden::ui::data(mode_field_0_value) eq {0.8 mL/s}} {Native steam flow display conversion failed}
::aiden::ui::step_mode 1 1
assert {[dict get $::aiden::ui::mode_draft steam_disabled]==1} {Boolean mode field failed}
::aiden::ui::commit_mode
assert {[lrange [lindex $::fixture::actions end] 0 1] eq {mode_apply steam}} {Mode apply missing}
::aiden::ui::set_graph [dict create elapsed {0 1 2 3 4} pressure {0 1 {} 3 4} flow {0 1 2 {} 4}]
assert {[dict get $::fixture::vectors ::aiden::ui::v_home_pressure_x0] eq {0 1}} {Pressure gap was filled}
assert {[dict get $::fixture::vectors ::aiden::ui::v_home_pressure_x1] eq {3 4}} {Pressure gap segmentation failed}
::aiden::ui::vector external_time {0 1 2}
::aiden::ui::vector external_pressure {0 1 2}
::aiden::ui::vector external_flow {0 1 2}
::aiden::ui::set_graph [dict create elapsed ::aiden::ui::v_external_time pressure ::aiden::ui::v_external_pressure flow ::aiden::ui::v_external_flow]
::aiden::ui::show profiles
::aiden::ui::render [dict replace $snapshot phase active busy 1 stop_available 1 stage_advance_available 1]
assert {$::aiden::ui::current_page eq {aiden_home}} {Active Stop was occluded by a chooser}
assert {[::aiden::ui::show recipe] eq {aiden_home}} {Sheet opened over active Stop}
::aiden::ui::dispatch primary
assert {[lindex $::fixture::actions end] eq {primary}} {Primary dispatch missing}
::aiden::ui::render [dict replace $snapshot phase ready mode water result [dict create profile_title Previous elapsed 28.1 weight 36.1 weight_quality live outcome completed] result_state Saved]
assert {[string match {*Previous} $::aiden::ui::data(last_title)]} {Earlier graph was relabelled as next profile}
::aiden::ui::render [dict replace $snapshot phase ready mode steam result {}]
assert {$::aiden::ui::data(result_profile_title) eq {}} {Empty retained result became a giant duplicated headline}
assert {[::fixture::state aiden_home aiden_result_profile 1] eq {hidden}} {Empty retained result headline was visible on the mode page}
assert {$::aiden::ui::data(last_title) eq {No shot in this session} && $::aiden::ui::data(mode_title) eq {Steam}} {Empty mode page lost its truthful caption or mode context}
::aiden::ui::set_mode_settings steam [dict create title Steam values [dict create steam_flow 70 steam_disabled 0] fields $fields editable 0 \
    reason {Settings require a connected, verified idle machine with no pending operation} \
    hint {Flow is shown in mL/s. Heater temperature is a setpoint; milk temperature is not measured. 134 C turns the heater off.}]
assert {$::aiden::ui::data(modes_detail) eq {Connect the machine to apply changes.}} {Offline mode explanation was not compact and actionable}
assert {[string length $::aiden::ui::data(modes_hint)]<90 && [string match {*milk temperature is not measured*} $::aiden::ui::data(modes_hint)]} {Compact Steam note lost its measurement limitation}
foreach page $::fixture::pages {::aiden::ui::show $page}
# Host-native alerts must survive a lifecycle poll while the view's private
# page value still names the sheet that launched a native route.
::aiden::ui::render $snapshot
::aiden::ui::show profiles
set ::fixture::current native_alert
::aiden::ui::render [dict replace $snapshot phase active busy 1 stop_available 1]
assert {$::fixture::current eq {native_alert}} {Native alert was replaced by the Aiden poll}
::aiden::ui::render [dict replace $snapshot phase unknown-or-blocked status Sleeping readiness disconnected ready 0 primary_enabled 0 primary_action wait stop_available 0 busy 0 editable 0]
assert {![::aiden::ui::active]} {Sleeping preparation was shown as an active operation}
assert {![::aiden::ui::commit_allowed]} {Offline preparation allowed an apply action}
assert {[dui item get aiden_profiles aiden_profiles_use*] eq {}} {Fixture incorrectly expanded native tag wildcards}
::aiden::ui::show profiles
foreach tag {aiden_profiles_use aiden_profiles_use-btn aiden_profiles_use-out aiden_profiles_use-lbl} {
    assert {[::fixture::state aiden_profiles $tag] eq {disabled}} "Offline profile control part is active: $tag"
    assert {[::fixture::state aiden_profiles $tag 1] eq {disabled}} "Offline profile control part will re-enable on entry: $tag"
}
set action_count [llength $::fixture::actions]
assert {![::fixture::tap aiden_profiles aiden_profiles_use]} {Disabled native profile control accepted a tap}
assert {[llength $::fixture::actions]==$action_count} {Disabled native profile control dispatched an action}
foreach {page tag} {aiden_recipe aiden_recipe_apply aiden_modes aiden_modes_apply aiden_workflow aiden_workflow_use} {
    foreach family_tag $::aiden::ui::control_tags($page,$tag) {
        assert {[::fixture::state $page $family_tag 1] eq {disabled}} "Offline sheet control part will re-enable on entry: $page,$family_tag"
    }
}
foreach page $::aiden::ui::pages {
    set dot [lindex [dui item get $page ${page}_dot] 0]
    assert {[dict get $::fixture::options $dot -fill] eq $::aiden::ui::palette(muted)} "Sheet readiness dot disagrees with offline state: $page"
}
::aiden::ui::render $snapshot
::aiden::ui::show profiles
foreach tag {aiden_profiles_use aiden_profiles_use-btn aiden_profiles_use-out aiden_profiles_use-lbl} {
    assert {[::fixture::state aiden_profiles $tag] eq {normal}} "Ready profile control part failed to re-enable: $tag"
}
assert {[::fixture::tap aiden_profiles aiden_profiles_use]} {Enabled native profile control failed to dispatch}
assert {[lindex $::fixture::actions end] eq {profile_apply two}} {Ready profile control dispatched an incorrect stable ID}
::aiden::ui::set_reduced_motion 0
::aiden::ui::show recipe
assert {$::aiden::ui::motion_after ne {}} {Sheet entry motion was not scheduled}
::aiden::ui::dispatch primary
assert {[lindex $::fixture::actions end] eq {primary}} {Motion delayed primary dispatch}
::aiden::ui::set_reduced_motion 1
assert {$::aiden::ui::motion_after eq {}} {Reduced motion did not cancel pending frames}
::aiden::ui::set_context aiden_home [dict create graph_expanded 1]
assert {$::aiden::ui::current_page eq {aiden_graph}} {Graph detail action was inert}
set native_profile [dict create settings_profile_type settings_2a preinfusion_time 20 espresso_hold_time 16 espresso_decline_time 30 preinfusion_stop_pressure 4 espresso_pressure 6 pressure_end 4 preinfusion_flow_rate 8]
set preview [::aiden::ui::profile_graph [dict create profile $native_profile]]
assert {[lindex [dict get $preview elapsed] end]==66} {Configured stage time limits were invented}
assert {[dict get $preview flow] eq {8 8 {} {} {}}} {Unspecified preview flow was replaced with zero}
dui page add ghc_espresso
dui page add ghc_steam
assert {[::aiden::ui::mount_pending_stop]==2} {Native GHC Stop overlays did not mount}
assert {[::aiden::ui::mount_pending_stop]==2} {Native GHC Stop overlays were not idempotent}
set ghc_stop [dict get $::fixture::commands ghc_espresso,aiden_pending_stop_hit]
assert {$ghc_stop eq {::aiden::ui::dispatch stop}} {Native pending Stop did not use the explicit dispatcher}
puts "PASS: 9 pages, $items_before native items, [dict size $::fixture::commands] controls, [llength $::fixture::actions] dispatches; live recipe arithmetic and commit precision, exact native tag families, disabled taps, readiness dots, drafts, stable IDs, native units, unavailable sensors, BLT gap segmentation and Stop visibility verified."
