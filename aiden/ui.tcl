# SPDX-License-Identifier: GPL-3.0-only
# Aiden native view for de1app / DUI (base canvas 2560 x 1600).
# Source declares the view only. The controller owns hardware, settings,
# lifecycle, validation, persistence and navigation into the original skin.
namespace eval ::aiden::ui {
    variable directory [file dirname [info script]]
    variable pages {aiden_home aiden_recipe aiden_profiles aiden_modes aiden_scale aiden_status aiden_utilities aiden_workflow aiden_graph}
    variable mounted 0
    variable current_page aiden_home
    variable snapshot {}
    variable catalog {}
    variable filtered {}
    variable selected_id {}
    variable query {}
    variable favorites_only 0
    variable search_focused 0
    variable recipe_draft {}
    variable recipe_syncing 0
    variable recipe_dirty {}
    variable mode_draft {}
    variable mode_schema {}
    variable editing_mode flush
    variable workflow_draft espresso
    variable copy_name {}
    variable copy_open 0
    variable contexts {}
    variable graph_available 0
    variable reduced_motion 0
    variable motion_after {}
    variable motion_page {}
    variable motion_offset 0
    variable motion_token 0
    variable widgets
    variable gesture
    variable dynamic
    variable control_tags
    variable data
    variable palette
    array set widgets {}
    array set gesture {}
    array set dynamic {}
    array set control_tags {}
    array set palette {
        background #0C171E panel #172A34 inset #10212B raised #203841
        outline #36515D selected #223D40 mint #8AF6D6 flow #6DB9FF
        text #F4F8FA white #F4F8FA soft #B7CBD6 muted #8DA6B6 dim #547080
        dark #10382E stop #FA544B stop_outline #FFA18F warning #E4BA76
    }
    array set data {
        profile_title {Choose a profile} recipe_line {Recipe unavailable}
        status {Machine state unknown} note {} timer {—} weight {—} target {— g}
        temperature {— °C} idle_weight {— g} pressure {—} flow {—}
        last_title {No shot in this session} result_profile_title {No shot in this session} result_line {No shot in this session}
        result_state {} mode_title Espresso mode_values {} mode_hint {}
        stage_name {} readiness_title {Machine state unknown} readiness_detail {}
        primary_name {Start espresso} recipe_hint {Until you choose another profile.}
        ratio {Ratio unavailable} recipe_error {} chooser_count {No profiles loaded}
        preview_title {Select a profile} preview_type {} preview_description {}
        preview_metrics {} preview_graph_caption {Configured targets · stage time limits} preview_notice {Preview only · no changes applied}
        scale_title Scale scale_detail {Scale state unknown} scale_reading {— g}
        scale_note {Pairing and tare use separate controls.} context_error {}
        status_title Machine status_detail {Waiting for an authoritative machine state.}
        modes_title {Mode settings} modes_detail {} modes_hint {}
        workflow_hint {Each physical operation needs a fresh Start.}
        dose {} yield {} temperature_draft {} ratio_draft {}
        copy_hint {Saved as a distinct profile. Your working recipe stays selected.}
    }
    variable symbols
    array set symbols {
        espresso mug-saucer shower shower steam wind water droplet scale weight-scale
        tare arrows-to-circle play play stop stop down chevron-down history clock-rotate-left
        graph-options sliders gear-six gear arrows-out expand back arrow-left
        x xmark apply check check check advance forward-step reconnect arrows-rotate
        search magnifying-glass link link arrow-right arrow-right thermometer temperature-half
        moon moon warning-circle circle-exclamation arrow-counter-clockwise rotate-left
        bookmark-simple bookmark plus plus minus minus
    }
}

proc ::aiden::ui::get {record key {default {}}} {
    if {![catch {dict exists $record $key} exists] && $exists} {return [dict get $record $key]}
    return $default
}

proc ::aiden::ui::first {record keys {default {}}} {
    foreach key $keys {
        if {[dict exists $record $key] && [dict get $record $key] ne {}} {return [dict get $record $key]}
    }
    return $default
}

proc ::aiden::ui::boolean {record key {default 0}} {
    set value [get $record $key $default]
    return [expr {[string is boolean -strict $value] && [string is true -strict $value]}]
}

proc ::aiden::ui::number {value {decimals 1}} {
    if {![string is double -strict $value] || [string match -nocase *nan* $value] || [string match -nocase *inf* $value]} {return {—}}
    return [format %.*f $decimals $value]
}

proc ::aiden::ui::compact {value} {
    if {![string is double -strict $value]} {return {—}}
    set text [number $value 1]
    if {[string match *.0 $text]} {set text [string range $text 0 end-2]}
    return $text
}

proc ::aiden::ui::font {size {weight regular}} {
    variable widgets
    set key font,$size,$weight
    if {[info exists widgets($key)]} {return $widgets($key)}
    set filename Inter-Regular.ttf
    if {$weight eq {bold}} {set filename Inter-SemiBold.ttf}
    if {![catch {dui font get $filename $size} value] && $value ne {}} {
        set widgets($key) $value
    } elseif {[info commands ::skin_font] ne {}} {
        set family font
        if {$weight eq {bold}} {set family font_bold}
        set widgets($key) [::skin_font $family $size]
    } else {
        set widgets($key) [list Helvetica $size [expr {$weight eq {bold} ? {bold} : {normal}}]]
    }
    return $widgets($key)
}

proc ::aiden::ui::dispatch {action args} {
    variable data
    if {[info commands ::aiden::app::action] eq {}} {
        set data(note) {Aiden controller is unavailable.}
        refresh
        return 0
    }
    # Commands are synchronous; no transition or timer delays their dispatch.
    return [::aiden::app::action $action {*}$args]
}

proc ::aiden::ui::text {page tag x y value size {tone text} {width 0} {weight regular} {group {}}} {
    variable palette
    set args [list -tags [list $tag {*}$group] -anchor nw -text $value -font [font $size $weight] -fill $palette($tone) -justify left]
    if {$width > 0} {lappend args -width $width}
    return [dui add dtext $page $x $y {*}$args]
}

proc ::aiden::ui::label {page tag x y key size {tone text} {width 0} {weight regular} {group {}}} {
    variable data
    variable dynamic
    if {![info exists data($key)]} {set data($key) {}}
    set id [text $page $tag $x $y $data($key) $size $tone $width $weight $group]
    set dynamic($page,$tag) $key
    return $id
}

proc ::aiden::ui::panel {page tag x y x1 y1 {tone panel} {radius 36} {group {}}} {
    variable palette
    return [dui add shape round_outline $page $x $y $x1 $y1 -tags [list $tag {*}$group] -radius $radius -width 2 -fill $palette($tone) -outline $palette(outline)]
}

proc ::aiden::ui::line {page tag x y x1 y1 {group {}}} {
    variable palette
    dui add shape rect $page $x $y $x1 $y1 -tags [list $tag {*}$group] -fill $palette(outline) -outline {} -width 0
}

proc ::aiden::ui::icon {page tag x y name {size 56} {tone soft} {group {}}} {
    variable symbols
    variable palette
    variable directory
    set asset "$name-$tone-$size.png"
    if {[file exists [file join $directory ui-assets 2560x1600 $asset]]} {
        return [dui add image $page $x $y $asset -tags [list $tag {*}$group] -canvas_anchor center]
    }
    set symbol [get [array get symbols] $name circle]
    return [dui add symbol $page $x $y -tags [list $tag {*}$group] -anchor center -symbol $symbol -font_size [expr {$size / 2.0}] -fill $palette($tone)]
}

proc ::aiden::ui::hit {page tag x y width height command {group {}}} {
    variable control_tags
    set control_tags($page,$tag) [list $tag ${tag}-btn]
    return [dui add dbutton $page $x $y -tags [list $tag {*}$group] -bwidth $width -bheight $height -shape {} -command $command]
}

proc ::aiden::ui::button {page tag x y width height title command {primary 0} {group {}}} {
    variable palette
    variable control_tags
    set control_tags($page,$tag) [list $tag ${tag}-btn ${tag}-out ${tag}-lbl]
    set fill $palette(raised)
    set foreground $palette(soft)
    if {$primary} {set fill $palette(mint); set foreground $palette(dark)}
    return [dui add dbutton $page $x $y -tags [list $tag {*}$group] -bwidth $width -bheight $height -shape round_outline -radius 22 -width 2 \
        -fill $fill -outline $palette(outline) -disabledfill $palette(inset) -disabledoutline $palette(outline) \
        -label $title -label_font [font 22 bold] -label_fill $foreground -label_disabledfill $palette(muted) -command $command]
}

proc ::aiden::ui::icon_button {page tag x y width name command {group {}}} {
    variable palette
    variable control_tags
    dui add shape oval $page $x $y [expr {$x+$width}] [expr {$y+$width}] -tags [list ${tag}_ring {*}$group] -fill $palette(panel) -outline $palette(outline) \
        -disabledfill $palette(inset) -disabledoutline $palette(outline) -width 2
    icon $page ${tag}_icon [expr {$x+$width/2}] [expr {$y+$width/2}] $name 56 soft $group
    hit $page $tag $x $y $width $width $command $group
    lappend control_tags($page,$tag) ${tag}_ring ${tag}_icon
}

proc ::aiden::ui::base {page {backdrop 0}} {
    variable palette
    text $page ${page}_brand 78 57 decent 36 text 0 bold
    label $page ${page}_status 375 86 status 19 soft 440
    dui add shape oval $page 349 93 361 105 -tags ${page}_dot -fill $palette(mint) -outline {}
    if {$backdrop} {
        label $page ${page}_back_profile 86 343 profile_title 58 dim 1700 bold
        label $page ${page}_back_recipe 88 494 recipe_line 37 dim 1600
        text $page ${page}_back_graph 88 723 {Last shot} 24 dim
    }
    text $page ${page}_signature 78 1527 {A I D E N} 12 dim 0 bold
}

proc ::aiden::ui::sheet {page title subtitle {wide 0}} {
    set x 970
    set y 278
    set x1 2484
    set y1 1330
    if {$wide} {set x 315; set y 82; set y1 1518}
    base $page 1
    panel $page ${page}_shadow [expr {$x-6}] [expr {$y+14}] [expr {$x1+6}] [expr {$y1+18}] inset 42
    panel $page ${page}_panel $x $y $x1 $y1 panel 40
    text $page ${page}_heading [expr {$x+64}] [expr {$y+56}] $title 40 text [expr {$x1-$x-200}] bold
    text $page ${page}_subheading [expr {$x+64}] [expr {$y+152}] $subtitle 21 muted [expr {$x1-$x-164}]
    label $page ${page}_notice [expr {$x+64}] [expr {$y+205}] note 17 warning [expr {$x1-$x-164}]
    line $page ${page}_header_line $x [expr {$y+247}] $x1 [expr {$y+249}]
    line $page ${page}_footer_line $x [expr {$y1-184}] $x1 [expr {$y1-182}]
    icon_button $page ${page}_close [expr {$x1-144}] [expr {$y+63}] 78 x [list ::aiden::ui::cancel $page]
}

proc ::aiden::ui::mount {} {
    variable mounted
    variable directory
    variable pages
    variable palette
    variable widgets
    if {$mounted} {return aiden_home}
    if {[info commands ::dui] eq {}} {error {Aiden requires the native DUI runtime}}
    foreach page $pages {
        if {[dui page exists $page]} {error "Aiden page '$page' already exists"}
    }
    dui font add_dirs [file join $directory ui-assets]
    dui image add_dirs [file join $directory ui-assets]
    foreach page $pages {
        dui page add $page -namespace false -bg_color $palette(background) -bg_img {}
        dui page add_action $page show [list ::aiden::ui::page_shown $page]
    }
    mount_home
    mount_recipe
    mount_profiles
    mount_modes
    mount_scale
    mount_status
    mount_utilities
    mount_workflow
    mount_graph_detail
    trace add variable ::aiden::ui::query write ::aiden::ui::query_changed
    foreach {field key} {dose dose yield yield temperature temperature_draft ratio ratio_draft} {
        trace add variable ::aiden::ui::data($key) write [list ::aiden::ui::recipe_input_changed $field]
    }
    set mounted 1
    render {}
    return aiden_home
}

proc ::aiden::ui::mount_home {} {
    variable palette
    set page aiden_home
    base $page
    hit $page aiden_status_hit 338 53 480 110 [list ::aiden::ui::dispatch status]
    icon $page aiden_history_icon 2328 98 history 56 soft
    hit $page aiden_history_hit 2272 42 112 112 [list ::aiden::ui::dispatch history]
    icon $page aiden_utilities_icon 2460 98 gear-six 56 soft
    hit $page aiden_utilities_hit 2404 42 112 112 [list ::aiden::ui::dispatch utilities]
    panel $page aiden_mode_rail 900 52 1674 184 panel 70 aiden_idle
    set i 0
    foreach mode {espresso flush steam water} {
        set name $mode
        if {$mode eq {flush}} {set name shower}
        set x [expr {911 + $i*188}]
        panel $page aiden_mode_${mode}_selected $x 62 [expr {$x+186}] 174 selected 62 [list aiden_idle aiden_mode_selected_$mode]
        icon $page aiden_mode_${mode}_icon [expr {$x+93}] 119 $name 56 soft aiden_idle
        hit $page aiden_mode_$mode $x 54 186 130 [list ::aiden::ui::dispatch mode $mode] aiden_idle
        incr i
    }
    label $page aiden_ready_profile 88 330 profile_title 64 text 1700 bold aiden_ready
    icon $page aiden_profile_chevron 1762 405 down 40 soft aiden_ready
    hit $page aiden_profile_hit 72 309 1740 230 [list ::aiden::ui::dispatch profiles] aiden_ready
    label $page aiden_recipe_summary 88 502 recipe_line 38 soft 1700 regular aiden_ready
    icon $page aiden_recipe_icon 1734 545 graph-options 40 soft aiden_ready
    hit $page aiden_recipe_hit 72 493 1710 105 [list ::aiden::ui::dispatch recipe] aiden_ready
    icon $page aiden_scale_icon 1944 455 scale 56 soft aiden_scale_ready
    label $page aiden_scale_weight 2008 393 idle_weight 51 text 462 bold aiden_scale_ready
    hit $page aiden_scale_hit 1857 371 613 170 [list ::aiden::ui::dispatch scale] aiden_scale_ready
    # Keep the full weight line separate from the tare control and its hit area.
    icon_button $page aiden_tare 2302 570 168 tare [list ::aiden::ui::dispatch tare] aiden_scale_ready
    label $page aiden_readiness_title 1950 385 readiness_title 33 soft 450 bold aiden_readiness
    label $page aiden_readiness_detail 1950 468 readiness_detail 21 muted 450 regular aiden_readiness
    hit $page aiden_readiness_hit 1890 346 588 225 [list ::aiden::ui::dispatch status] aiden_readiness

    label $page aiden_active_profile 88 200 profile_title 28 text 610 bold aiden_active
    label $page aiden_timer 730 136 timer 94 text 485 bold aiden_active
    text $page aiden_timer_unit 1117 266 s 35 muted 0 regular aiden_active
    line $page aiden_metric_divider 1260 164 1262 341 aiden_active
    label $page aiden_yield 1326 136 weight 94 text 420 bold aiden_active
    text $page aiden_yield_unit 1740 266 g 35 muted 0 regular aiden_active
    label $page aiden_goal 1812 277 target 27 muted 310 regular aiden_active
    label $page aiden_live_temperature 2265 219 temperature 30 soft 248 bold aiden_active

    label $page aiden_last_title 88 713 last_title 25 soft 1720 bold aiden_ready_plot
    icon_button $page aiden_ready_graph_detail 1832 710 85 graph-options [list ::aiden::ui::dispatch graph] aiden_ready_plot
    panel $page aiden_active_plot_panel 76 384 2175 1460 inset 30 aiden_active_plot
    icon_button $page aiden_active_graph_detail 2054 405 85 arrows-out [list ::aiden::ui::dispatch graph] aiden_active_plot
    label $page aiden_pressure_reading 1922 605 pressure 53 mint 228 bold aiden_active_plot
    text $page aiden_pressure_unit 1924 716 bar 25 muted 0 regular aiden_active_plot
    label $page aiden_flow_reading 1922 1120 flow 53 flow 228 bold aiden_active_plot
    text $page aiden_flow_unit 1924 1231 mL/s 25 muted 0 regular aiden_active_plot
    mount_plot_pair $page ready 86 808 1740 274 0 aiden_ready_plot
    mount_plot_pair $page active 98 438 1740 452 28 aiden_active_plot

    label $page aiden_result_profile 88 323 result_profile_title 43 text 1270 bold aiden_post
    label $page aiden_result_line 98 481 result_line 32 text 1200 bold aiden_post
    label $page aiden_result_state 98 561 result_state 20 muted 1100 regular aiden_post
    panel $page aiden_result_plot_panel 76 716 1294 1451 inset 28 aiden_post
    label $page aiden_result_graph_title 106 747 last_title 19 muted 1100 regular aiden_post
    mount_plot_pair $page result 100 817 1162 259 22 aiden_post
    icon $page aiden_next_mode_icon 1564 606 shower 112 mint aiden_post
    label $page aiden_next_title 1500 720 mode_title 59 text 680 bold aiden_mode_context
    label $page aiden_next_values 1505 848 mode_values 27 soft 548 regular aiden_mode_context
    icon $page aiden_next_settings_icon 2108 885 graph-options 40 soft aiden_mode_context
    hit $page aiden_mode_settings_hit 1482 835 674 120 [list ::aiden::ui::open_mode_settings] aiden_mode_context
    label $page aiden_next_hint 1505 996 mode_hint 22 muted 650 regular aiden_mode_context
    icon_button $page aiden_skip 2262 956 132 advance [list ::aiden::ui::dispatch next] aiden_skip
    label $page aiden_stage_name 2208 933 stage_name 17 muted 260 regular aiden_stage
    icon $page aiden_stage_icon 2327 1048 advance 72 soft aiden_stage
    hit $page aiden_stage_hit 2192 920 270 197 [list ::aiden::ui::dispatch advance] aiden_stage

    # Outer hit bounds are identical in every state. Layered opaque rings give
    # depth without compositing, and the Stop surface has a distinct shape.
    dui add shape oval $page 2188 1178 2466 1456 -tags {aiden_start_outer aiden_start} -fill $palette(inset) -outline $palette(outline) -width 5
    dui add shape oval $page 2194 1184 2460 1450 -tags {aiden_start_inner aiden_start} -fill #294D4B -outline #95DDCB -width 3
    dui add shape oval $page 2204 1194 2450 1440 -tags {aiden_start_core aiden_start} -fill #203D3F -outline #416865 -width 2
    icon $page aiden_play_icon 2330 1318 play 112 mint aiden_start
    hit $page aiden_start_hit 2192 1182 270 270 [list ::aiden::ui::dispatch primary] aiden_start
    panel $page aiden_stop_surface 2192 1182 2462 1452 stop 48 aiden_stop
    icon $page aiden_stop_icon 2327 1317 stop 112 white aiden_stop
    hit $page aiden_stop_hit 2192 1182 270 270 [list ::aiden::ui::dispatch primary] aiden_stop
    label $page aiden_primary_name 2194 1472 primary_name 15 muted 278 regular aiden_primary_label
    label $page aiden_operation_note 88 1468 note 19 soft 1960
    icon $page aiden_workflow_icon 2327 1536 espresso 40 soft
    hit $page aiden_workflow_hit 2196 1493 280 83 [list ::aiden::ui::dispatch workflow]
}

proc ::aiden::ui::mount_plot_pair {page stem x y width height gap group} {
    mount_graph $page ${stem}_pressure $x $y $width $height pressure $group
    mount_graph $page ${stem}_flow $x [expr {$y+$height+$gap}] $width $height flow $group
}

proc ::aiden::ui::mount_graph {page stem x y width height signal group} {
    variable palette
    variable widgets
    set graph_x [expr {$x+62}]
    set graph_width [expr {$width-62}]
    set w [dui add graph $page $graph_x $y -tags [list aiden_$stem {*}$group] -canvas_width $graph_width -canvas_height $height \
        -background $palette(background) -plotbackground $palette(background) -borderwidth 0 -highlightthickness 0 \
        -plotborderwidth 0 -plotrelief flat -plotpadx 0 -plotpady 0 -leftmargin 58 -rightmargin 12 -topmargin 23 -bottommargin 33]
    set widgets(graph,$stem) $w
    set widgets(signal,$stem) $signal
    $w legend configure -hide yes
    $w axis configure x -min 0 -max 30 -stepsize 10 -tickfont [font 13] -color $palette(muted) -linewidth 0 -title {} -hide [expr {$signal eq {pressure}}]
    if {$signal eq {pressure}} {set max 9; set step 3; set unit bar} else {set max 4; set step 2; set unit mL/s}
    $w axis configure y -min 0 -max $max -stepsize $step -tickfont [font 13] -color $palette(muted) -linewidth 0 -title {}
    $w grid configure -hide no -color #2A424D -dashes {2 5} -linewidth 1
    if {[string match preview_* $stem]} {
        set bottom 4
        if {$signal eq {flow}} {set bottom 22}
        $w configure -topmargin 7 -bottommargin $bottom -leftmargin 37
        $w axis configure x -tickfont [font 9]
        $w axis configure y -tickfont [font 9]
    }
    text $page aiden_${stem}_unit $x [expr {$y+13}] $unit 13 muted 0 regular $group
    if {$signal eq {flow}} {text $page aiden_${stem}_seconds [expr {$x+$width-8}] [expr {$y+$height+4}] s 13 muted 0 regular $group}
    # Each element is bound to BLT vectors in set_graph, never a canvas drawing.
}

proc ::aiden::ui::mount_recipe {} {
    variable widgets
    variable palette
    set page aiden_recipe
    sheet $page Recipe {Adjust the next shots. Your saved profile stays unchanged.}
    set i 0
    foreach {field title unit} {dose Dose g yield Yield g temperature Temperature °C} {
        set x [expr {1035+$i*451}]
        text $page aiden_recipe_${field}_label $x 598 $title 21 muted 380 regular aiden_recipe_edit
        panel $page aiden_recipe_${field}_box $x 654 [expr {$x+423}] 796 inset 26 aiden_recipe_edit
        set var $field
        if {$field eq {temperature}} {set var temperature_draft}
        set widgets(recipe,$field) [dui add entry $page [expr {$x+24}] 669 -tags [list aiden_recipe_$field aiden_recipe_edit] \
            -canvas_width 277 -canvas_height 109 -font [font 37 bold] -textvariable ::aiden::ui::data($var) -trim 0 -editor_page 0 \
            -background $palette(inset) -foreground $palette(text) -insertbackground $palette(mint) -relief flat -borderwidth 0 \
            -highlightthickness 0 -justify left]
        text $page aiden_recipe_${field}_unit [expr {$x+346}] 704 $unit 22 muted 0 regular aiden_recipe_edit
        bind $widgets(recipe,$field) <FocusOut> [list ::aiden::ui::recipe_field_changed $field]
        bind $widgets(recipe,$field) <Return> "[list ::aiden::ui::recipe_field_changed $field]; break"
        bind $widgets(recipe,$field) <Escape> {::aiden::ui::cancel aiden_recipe; break}
        incr i
    }
    panel $page aiden_recipe_ratio_box 1035 836 2418 974 inset 26 aiden_recipe_edit
    label $page aiden_recipe_ratio 1068 876 ratio 23 soft 590 regular aiden_recipe_edit
    text $page aiden_recipe_ratio_label 1975 877 {Edit ratio} 18 muted 195 regular aiden_recipe_edit
    set widgets(recipe,ratio) [dui add entry $page 2173 858 -tags {aiden_recipe_ratio_input aiden_recipe_edit} \
        -canvas_width 204 -canvas_height 100 -font [font 26 bold] -textvariable ::aiden::ui::data(ratio_draft) -trim 0 -editor_page 0 \
        -background $palette(inset) -foreground $palette(text) -insertbackground $palette(mint) -relief flat -borderwidth 0 \
        -highlightthickness 2 -highlightbackground $palette(outline) -highlightcolor $palette(mint)]
    bind $widgets(recipe,ratio) <FocusOut> [list ::aiden::ui::recipe_field_changed ratio]
    bind $widgets(recipe,ratio) <Return> {::aiden::ui::recipe_field_changed ratio; break}
    bind $widgets(recipe,ratio) <Escape> {::aiden::ui::cancel aiden_recipe; break}
    label $page aiden_recipe_hint 1035 1018 recipe_hint 20 soft 1350 regular aiden_recipe_edit
    label $page aiden_recipe_error 1035 1085 recipe_error 18 warning 1330
    button $page aiden_recipe_cancel 1035 1186 195 86 Cancel [list ::aiden::ui::cancel $page] 0 aiden_recipe_edit
    icon_button $page aiden_recipe_reset 1629 1175 108 arrow-counter-clockwise [list ::aiden::ui::dispatch recipe_reset] aiden_recipe_edit
    button $page aiden_recipe_copy 1757 1186 256 86 {Save copy} [list ::aiden::ui::open_copy] 0 aiden_recipe_edit
    button $page aiden_recipe_apply 2037 1186 381 86 {Use adjustments} [list ::aiden::ui::commit_recipe] 1 aiden_recipe_edit

    text $page aiden_copy_label 1035 605 {Profile name} 23 muted 1200 regular aiden_copy
    set widgets(copy_name) [dui add entry $page 1062 681 -tags {aiden_copy_name aiden_copy} -canvas_width 1300 -canvas_height 107 \
        -font [font 30] -textvariable ::aiden::ui::copy_name -trim 0 -editor_page 0 -background $palette(inset) -foreground $palette(text) \
        -insertbackground $palette(mint) -relief flat -borderwidth 0 -highlightthickness 2 -highlightbackground $palette(outline) -highlightcolor $palette(mint)]
    label $page aiden_copy_hint 1035 856 copy_hint 21 soft 1290 regular aiden_copy
    button $page aiden_copy_back 1035 1186 234 86 Back [list ::aiden::ui::close_copy] 0 aiden_copy
    button $page aiden_copy_save 2081 1186 337 86 {Save copy} [list ::aiden::ui::commit_copy] 1 aiden_copy
}

proc ::aiden::ui::mount_profiles {} {
    variable widgets
    variable palette
    set page aiden_profiles
    sheet $page Profiles {Browse freely. Only Use profile changes the recipe.} 1
    panel $page aiden_search_box 380 385 1395 483 inset 22
    set widgets(search) [dui add entry $page 410 400 -tags aiden_search -canvas_width 925 -canvas_height 68 -font [font 23] \
        -textvariable ::aiden::ui::query -trim 0 -editor_page 0 -background $palette(inset) -foreground $palette(text) \
        -insertbackground $palette(mint) -relief flat -borderwidth 0 -highlightthickness 0]
    bind $widgets(search) <Escape> {::aiden::ui::cancel aiden_profiles; break}
    bind $widgets(search) <FocusIn> {::aiden::ui::search_layout 1}
    bind $widgets(search) <FocusOut> {::aiden::ui::search_layout 0}
    icon $page aiden_search_icon 1351 435 search 40 soft
    button $page aiden_profiles_all 380 507 510 88 All [list ::aiden::ui::filter_favorites 0]
    button $page aiden_profiles_favorites 897 507 498 88 Favorites [list ::aiden::ui::filter_favorites 1]
    label $page aiden_profiles_count 384 608 chooser_count 16 muted 950
    set widgets(profiles) [dui add text $page 380 646 -tags aiden_profile_list -canvas_width 996 -canvas_height 665 -font [font 23 bold] \
        -wrap word -background $palette(panel) -foreground $palette(soft) -relief flat -borderwidth 0 -highlightthickness 0 \
        -padx 0 -pady 8 -spacing1 8 -spacing3 8 -cursor arrow -takefocus 1 -exportselection 0 \
        -yscrollbar 1 -yscrollbar_width 18 -yscrollbar_sliderlength 94 -yscrollbar_background $palette(panel) -yscrollbar_troughcolor $palette(inset)]
    set w $widgets(profiles)
    $w tag configure metadata -font [font 16] -foreground $palette(muted) -spacing1 0 -spacing3 12
    bind $w <ButtonPress-1> {::aiden::ui::touch_begin %x %y; break}
    bind $w <B1-Motion> {::aiden::ui::touch_move %x %y; break}
    bind $w <ButtonRelease-1> {::aiden::ui::touch_end %x %y; break}
    bind $w <MouseWheel> {%W yview scroll [expr {-(%D / 120)}] units; break}
    bind $w <Button-4> {%W yview scroll -3 units; break}
    bind $w <Button-5> {%W yview scroll 3 units; break}
    bind $w <Up> {::aiden::ui::move_profile -1; break}
    bind $w <Down> {::aiden::ui::move_profile 1; break}
    bind $w <Return> {break}
    bind $w <KeyPress> {break}
    $w configure -state disabled
    panel $page aiden_preview_panel 1452 385 2417 1285 inset 29 aiden_profile_preview
    label $page aiden_preview_type 1496 433 preview_type 19 muted 755 regular aiden_profile_preview
    label $page aiden_preview_title 1496 486 preview_title 34 text 786 bold aiden_profile_preview
    icon_button $page aiden_preview_favorite 2292 413 80 bookmark-simple [list ::aiden::ui::favorite_selected] aiden_profile_preview
    set widgets(preview_description) [dui add text $page 1496 616 -tags {aiden_preview_description aiden_profile_preview} -canvas_width 862 -canvas_height 208 \
        -font [font 19] -wrap word -background $palette(inset) -foreground $palette(soft) -relief flat -borderwidth 0 \
        -highlightthickness 0 -padx 0 -pady 0 -cursor arrow -takefocus 1 -exportselection 0]
    bind $widgets(preview_description) <ButtonPress-1> {%W scan mark %x %y; break}
    bind $widgets(preview_description) <B1-Motion> {%W scan dragto %x %y; break}
    bind $widgets(preview_description) <MouseWheel> {%W yview scroll [expr {-(%D / 120)}] units; break}
    bind $widgets(preview_description) <KeyPress> {break}
    $widgets(preview_description) configure -state disabled
    label $page aiden_preview_metrics 1496 856 preview_metrics 25 soft 865 bold aiden_profile_preview
    label $page aiden_preview_graph_caption 1496 930 preview_graph_caption 14 muted 850 regular aiden_profile_preview
    mount_plot_pair $page preview 1495 970 860 110 41 {aiden_preview_signals aiden_profile_preview}
    label $page aiden_preview_notice 1496 1235 preview_notice 15 soft 851 regular aiden_profile_preview
    button $page aiden_profiles_cancel 1934 1379 210 86 Cancel [list ::aiden::ui::cancel $page]
    button $page aiden_profiles_use 2168 1379 250 86 {Use profile} [list ::aiden::ui::commit_profile] 1
    button $page aiden_profiles_clear 380 1379 194 86 Clear [list ::aiden::ui::clear_search]
    button $page aiden_search_clear 1452 391 194 86 Clear [list ::aiden::ui::clear_search] 0 aiden_search_actions
    button $page aiden_search_done 1750 391 668 86 Done [list ::aiden::ui::finish_search] 0 aiden_search_actions
    visibility $page aiden_search_actions 0
}

proc ::aiden::ui::mount_modes {} {
    set page aiden_modes
    sheet $page {Mode settings} {Prepare this mode. Use settings does not start the machine.}
    label $page aiden_modes_name 1035 592 modes_title 38 text 1290 bold
    label $page aiden_modes_detail 1035 677 modes_detail 18 muted 1290
    for {set i 0} {$i < 4} {incr i} {
        set y [expr {760+$i*82}]
        label $page aiden_mode_field_${i}_name 1035 $y mode_field_${i}_name 23 soft 575 regular aiden_mode_field_$i
        label $page aiden_mode_field_${i}_value 1670 $y mode_field_${i}_value 26 text 505 bold aiden_mode_field_$i
        button $page aiden_mode_field_${i}_minus 2170 [expr {$y-9}] 96 64 − [list ::aiden::ui::step_mode $i -1] 0 aiden_mode_field_$i
        button $page aiden_mode_field_${i}_plus 2290 [expr {$y-9}] 96 64 + [list ::aiden::ui::step_mode $i 1] 0 aiden_mode_field_$i
    }
    label $page aiden_modes_hint 1035 1098 modes_hint 16 muted 1330
    button $page aiden_modes_cancel 1035 1186 223 86 Cancel [list ::aiden::ui::cancel $page]
    button $page aiden_modes_apply 2081 1186 337 86 {Use settings} [list ::aiden::ui::commit_mode] 1
}

proc ::aiden::ui::mount_scale {} {
    set page aiden_scale
    sheet $page Scale {Measured weight, connection and tare.}
    icon $page aiden_scale_context_icon 1090 635 scale 112 soft
    label $page aiden_scale_context_reading 1215 583 scale_reading 74 text 1160 bold
    label $page aiden_scale_context_state 1035 795 scale_detail 26 soft 1330 bold
    label $page aiden_scale_context_note 1035 910 scale_note 23 muted 1330
    button $page aiden_scale_done 1035 1186 220 86 Done [list ::aiden::ui::cancel $page]
    button $page aiden_scale_pair 1660 1186 338 86 {Connect scale} [list ::aiden::ui::dispatch scale_reconnect]
    button $page aiden_scale_tare 2030 1186 388 86 Tare [list ::aiden::ui::dispatch tare] 1
}

proc ::aiden::ui::mount_status {} {
    set page aiden_status
    sheet $page Machine {Readiness and recovery use the installed machine state.}
    label $page aiden_status_context_title 1035 598 status_title 46 text 1320 bold
    label $page aiden_status_context_detail 1035 741 status_detail 25 soft 1320
    button $page aiden_status_reconnect 1035 964 385 90 Reconnect [list ::aiden::ui::dispatch machine_reconnect]
    button $page aiden_status_wake 1450 964 390 90 {Wake machine} [list ::aiden::ui::dispatch wake]
    button $page aiden_status_recovery 1870 964 548 90 {Recovery details} [list ::aiden::ui::dispatch recovery]
    button $page aiden_status_done 1035 1186 223 86 Done [list ::aiden::ui::cancel $page]
    button $page aiden_status_sleep 2027 1186 391 86 {Sleep machine} [list ::aiden::ui::dispatch sleep]
}

proc ::aiden::ui::mount_utilities {} {
    set page aiden_utilities
    sheet $page Utilities {The essentials stay close. Deeper controls stay here.} 1
    set entries {
        {water Cleaning {Flush, descale and care} maintenance}
        {graph-options Calibration {Machine and scale settings} calibration}
        {scale Devices {Machine and scale connections} devices}
        {history History {Shots, comparisons and notes} history}
        {bookmark-simple {Saved setups} {Recipes and workflows} saved_setups}
        {graph-options {Advanced profiles} {Compatible native profile editor} advanced}
        {gear-six Extensions {Journal and sharing preferences} extensions}
        {moon Sleep {Put the machine to sleep} sleep}
        {back {Original skin} {Return to the installed Decent UI} original_skin}
    }
    set i 0
    foreach row $entries {
        lassign $row image title detail action
        set x [expr {380+($i%3)*690}]
        set y [expr {408+($i/3)*283}]
        panel $page aiden_utility_${i}_panel $x $y [expr {$x+657}] [expr {$y+253}] inset 27
        icon $page aiden_utility_${i}_icon [expr {$x+72}] [expr {$y+67}] $image 72 soft
        text $page aiden_utility_${i}_title [expr {$x+40}] [expr {$y+120}] $title 25 soft 580 bold
        text $page aiden_utility_${i}_detail [expr {$x+40}] [expr {$y+184}] $detail 19 muted 580
        hit $page aiden_utility_$i $x $y 657 253 [list ::aiden::ui::dispatch $action]
        incr i
    }
    button $page aiden_utilities_done 2156 1379 261 86 Done [list ::aiden::ui::cancel $page]
}

proc ::aiden::ui::mount_workflow {} {
    set page aiden_workflow
    sheet $page {Your workflow} {Prepare the next mode. Every operation still needs Start.}
    set i 0
    foreach {id title detail image} {
        espresso {Espresso only} Espresso espresso
        latte Latte {Espresso → Flush → Steam} shower
        americano Americano {Espresso → Hot water} water
        steam {Espresso + steam} {Espresso → Steam} steam
    } {
        set x [expr {1035+($i%2)*702}]
        set y [expr {585+($i/2)*228}]
        panel $page aiden_workflow_${id}_panel $x $y [expr {$x+668}] [expr {$y+202}] inset 26
        icon $page aiden_workflow_${id}_icon [expr {$x+65}] [expr {$y+62}] $image 56 soft
        text $page aiden_workflow_${id}_title [expr {$x+119}] [expr {$y+39}] $title 24 soft 511 bold
        text $page aiden_workflow_${id}_detail [expr {$x+35}] [expr {$y+127}] $detail 20 muted 604
        hit $page aiden_workflow_$id $x $y 668 202 [list ::aiden::ui::select_workflow $id]
        incr i
    }
    label $page aiden_workflow_hint 1035 1072 workflow_hint 18 muted 1330
    button $page aiden_workflow_cancel 1035 1186 210 86 Cancel [list ::aiden::ui::cancel $page]
    button $page aiden_workflow_save 1757 1186 282 86 {Save setup} [list ::aiden::ui::dispatch workflow_save]
    button $page aiden_workflow_use 2065 1186 353 86 {Use workflow} [list ::aiden::ui::commit_workflow] 1
}

proc ::aiden::ui::refresh {} {
    variable mounted
    variable current_page
    variable dynamic
    variable data
    variable rendered_text
    if {!$mounted} {return}
    foreach item [array names dynamic "$current_page,*"] {
        lassign [split $item ,] page tag
        set key $dynamic($item)
        if {[info exists rendered_text($item)] && $rendered_text($item) eq $data($key)} {continue}
        dui item config $page $tag -text $data($key)
        set rendered_text($item) $data($key)
    }
}

proc ::aiden::ui::visibility {page group show} {
    set action hide
    if {$show} {set action show}
    dui item $action $page $group -initial 1
}

proc ::aiden::ui::enabled {page tag value} {
    variable control_tags
    set action disable
    if {$value} {set action enable}
    # DUI resolves exact canvas tags; a suffix wildcard is not a pattern.
    # Register each native button's hit area, fill, outline and label together.
    set tags {}
    foreach name $tag {
        if {[info exists control_tags($page,$name)]} {
            lappend tags {*}$control_tags($page,$name)
        } else {
            lappend tags $name
        }
    }
    dui item $action $page $tags -initial 1
}

proc ::aiden::ui::mode_name {mode} {
    switch -- $mode {
        flush {return Flush}
        steam {return Steam}
        water - hotwater - hot_water {return {Hot water}}
        default {return Espresso}
    }
}

proc ::aiden::ui::normalized_mode {mode} {
    if {$mode in {hotwater hot_water hot-water}} {return water}
    if {$mode ni {espresso flush steam water}} {return espresso}
    return $mode
}

proc ::aiden::ui::active {} {
    variable snapshot
    # An authoritative negative Stop capability must win over busy/phase. In
    # particular, Sleeping is blocked preparation, not an active operation.
    if {[dict exists $snapshot stop_available]} {return [boolean $snapshot stop_available]}
    if {[dict exists $snapshot primary_action]} {return [expr {[get $snapshot primary_action] eq {stop}}]}
    if {[boolean $snapshot busy]} {return 1}
    return [expr {[get $snapshot phase unknown] in {start-requested starting active brewing stop-requested stopping unknown-active}}]
}

proc ::aiden::ui::render {snapshotDict} {
    variable snapshot
    variable data
    variable mounted
    variable current_page
    set snapshot $snapshotDict
    variable reduced_motion
    if {[dict exists $snapshot reduced_motion]} {set_reduced_motion [boolean $snapshot reduced_motion]}
    if {[dict exists $snapshot reduce_motion]} {set_reduced_motion [boolean $snapshot reduce_motion]}
    set recipe [get $snapshot recipe {}]
    set profile [get $snapshot profile {}]
    set title [first $recipe {title profile_title name fullname} [first $profile {title fullname name} [first $snapshot {profile_title profile_name} {Choose a profile}]]]
    set data(profile_title) $title
    set dose [first $recipe {dose dose_weight} [get $snapshot dose {}]]
    set target [first $recipe {yield target_yield target_weight} [get $snapshot target_yield {}]]
    set temperature [first $recipe {temperature target_temp temperature_target temp} [get $snapshot target_temperature {}]]
    set data(recipe_line) "[compact $dose] g → [compact $target] g · [compact $temperature]°C"
    if {$dose eq {} && $target eq {} && $temperature eq {}} {set data(recipe_line) {Recipe unavailable}}
    set data(status) [first $snapshot {status status_text stage_name} {Machine state unknown}]
    set data(note) [first $snapshot {note operation_note message error} {}]
    set data(timer) [number [first $snapshot {elapsed time} {}]]
    set weight [first $snapshot {weight yield} {}]
    set quality [get $snapshot weight_quality unavailable]
    if {$quality in {unavailable missing disconnected none}} {set weight {}}
    set data(weight) [number $weight]
    set data(target) "/ [compact $target] g"
    set data(temperature) "[number [first $snapshot {temperature water_temperature basket_temperature} {}]] °C"
    set data(pressure) [number [get $snapshot pressure {}]]
    set data(flow) [number [get $snapshot flow {}]]
    set data(stage_name) [get $snapshot stage_name {}]
    set data(primary_name) [get $snapshot primary_name "Start [string tolower [mode_name [get $snapshot mode espresso]]]"]
    set scale [get $snapshot scale {}]
    set scale_weight [first $scale {weight reading} [first $snapshot {scale_weight idle_weight weight} {}]]
    set scale_quality [first $scale {quality state status} $quality]
    if {$scale_quality in {unavailable missing disconnected none unknown}} {set scale_weight {}}
    set data(idle_weight) "[number $scale_weight] g"
    set data(scale_reading) $data(idle_weight)
    set data(scale_detail) [first $scale {description detail status state} [get $snapshot scale_status {Scale state unknown}]]
    set data(scale_note) [first $scale {note reason} {}]
    if {$data(scale_note) eq {}} {
        if {$scale_weight eq {}} {set data(scale_note) {The scale reading is unavailable. A missing reading is never zero.}} else {set data(scale_note) {Tare with the cup in place, before starting.}}
    }
    if {$scale_quality eq {stale}} {append data(idle_weight) { · stale}; append data(scale_reading) { · stale}}
    set data(status_title) $data(status)
    set data(status_detail) [first $snapshot {status_detail readiness_detail reason} {Waiting for an authoritative machine state.}]
    set data(readiness_title) $data(status_title)
    set data(readiness_detail) [first $snapshot {readiness_detail reason} {}]
    set result [get $snapshot result {}]
    if {$result ne {}} {
        set result_title [first $result {profile_title title profile_name} $title]
        set data(last_title) "Last shot · $result_title"
        set data(result_profile_title) $result_title
        set result_weight [first $result {weight yield} {}]
        if {[get $result weight_quality unavailable] in {unavailable missing none}} {set result_weight {}}
        set data(result_line) "[number [first $result {elapsed time} {}]] s · [number $result_weight] g"
        if {$result_weight eq {}} {set data(result_line) "[number [first $result {elapsed time} {}]] s · Yield unavailable"}
        set data(result_state) [first $snapshot {result_state persistence_status} {Save unconfirmed}]
        set outcome [get $result outcome {}]
        if {$outcome ne {}} {append data(result_state) " · $outcome"}
    } else {
        set data(last_title) [get $snapshot graph_title {No shot in this session}]
        set data(result_profile_title) {}
        set data(result_line) {}
        set data(result_state) {}
    }
    set mode [normalized_mode [get $snapshot mode espresso]]
    set data(mode_title) [mode_name $mode]
    set data(mode_values) [get $snapshot mode_values {}]
    set data(mode_hint) [get $snapshot mode_hint {}]
    if {$data(mode_hint) eq {}} {
        switch -- $mode {
            flush {set data(mode_hint) {Remove portafilter}}
            steam {set data(mode_hint) {Place jug · milk temperature is not measured}}
            water {set data(mode_hint) {Place cup}}
        }
    }
    if {$mounted} {
        if {$current_page eq {aiden_profiles} && ![profile_view_visible]} {end_profile_interaction}
        if {([active] || [boolean $snapshot busy]) && $current_page ne {aiden_home} && [string match aiden_* [dui page current]]} {show aiden_home}
        if {$current_page in {aiden_home aiden_graph}} {render_home_layout}
        set graph [get $snapshot graph {}]
        if {$result ne {} && ![active]} {
            set graph [first $result {graph_samples graph samples} $graph]
        }
        if {$current_page in {aiden_home aiden_graph}} {set_graph $graph}
        if {$current_page ni {aiden_home aiden_graph}} {
            set tone warning
            if {[boolean $snapshot ready]} {set tone mint}
            if {[get $snapshot readiness {}] in {offline disconnected unknown sleeping sleep}} {set tone muted}
            foreach page $::aiden::ui::pages {dui item config $page ${page}_dot -fill $::aiden::ui::palette($tone)}
        }
        enabled aiden_scale aiden_scale_tare [boolean $scale can_tare [boolean $snapshot can_tare]]
        enabled aiden_status aiden_status_wake [boolean $snapshot can_wake]
        enabled aiden_status aiden_status_sleep [boolean $snapshot can_sleep]
        enabled aiden_status aiden_status_reconnect [boolean $snapshot can_reconnect]
        enabled aiden_status aiden_status_recovery [boolean $snapshot can_recover]
        enabled aiden_profiles aiden_profiles_use [expr {[selected_record] ne {} && [boolean [selected_record] applyable 1] && [boolean [selected_record] available 1] && [commit_allowed]}]
        enabled aiden_recipe {aiden_recipe_apply aiden_recipe_copy aiden_copy_save aiden_recipe_reset} [commit_allowed]
        enabled aiden_modes aiden_modes_apply [expr {[boolean $::aiden::ui::mode_schema editable] && [commit_allowed]}]
        enabled aiden_workflow aiden_workflow_use [commit_allowed]
        refresh
    }
    return $snapshot
}

proc ::aiden::ui::render_home_layout {} {
    variable snapshot
    variable data
    variable palette
    variable pages
    set phase [get $snapshot phase unknown]
    set mode [normalized_mode [get $snapshot mode espresso]]
    set operating [active]
    set finished [expr {$phase in {flow-ended settling result complete}}]
    set post [expr {!$operating && !$finished && $mode ne {espresso}}]
    set live [expr {$operating || $finished}]
    foreach {group visible} [list aiden_idle [expr {!$live}] aiden_ready [expr {!$live && !$post}] \
        aiden_ready_plot [expr {!$live && !$post}] aiden_active $live aiden_active_plot $live aiden_post $post \
        aiden_mode_context $post aiden_start [expr {!$operating}] aiden_stop $operating aiden_primary_label 1] {
        visibility aiden_home $group $visible
    }
    foreach navmode {espresso flush steam water} {visibility aiden_home aiden_mode_selected_$navmode [expr {!$live && $mode eq $navmode}]}
    foreach tag {aiden_result_profile aiden_result_line aiden_result_state} {
        visibility aiden_home $tag [expr {$post && [get $snapshot result {}] ne {}}]
    }
    set ready [boolean $snapshot ready [expr {[get $snapshot readiness {}] eq {ready}}]]
    visibility aiden_home aiden_scale_ready [expr {!$live && !$post && $ready}]
    visibility aiden_home aiden_readiness [expr {!$live && !$post && !$ready}]
    visibility aiden_home aiden_stage [expr {$operating && [boolean $snapshot stage_advance_available]}]
    visibility aiden_home aiden_skip [expr {$post && [boolean $snapshot can_skip]}]
    enabled aiden_home aiden_start_hit [boolean $snapshot primary_enabled]
    enabled aiden_home aiden_stop_hit [boolean $snapshot primary_enabled $operating]
    enabled aiden_home aiden_tare [boolean $snapshot can_tare]
    enabled aiden_home {aiden_profile_hit aiden_recipe_hit aiden_mode_settings_hit} [expr {!$operating && [boolean $snapshot can_edit 1]}]
    enabled aiden_home {aiden_mode_espresso aiden_mode_flush aiden_mode_steam aiden_mode_water} [boolean $snapshot can_select_mode [expr {!$operating}]]
    set primary_action [get $snapshot primary_action {}]
    if {$operating && $primary_action ni {wait none}} {set data(primary_name) {Stop}}
    set primary_icon play
    if {$primary_action eq {wake}} {set primary_icon moon; set data(primary_name) {Wake machine}}
    if {$primary_action eq {continue}} {set primary_icon advance; set data(primary_name) Continue}
    set primary_tone mint
    set primary_enabled [boolean $snapshot primary_enabled]
    if {!$primary_enabled} {
        set primary_tone soft
        set primary_icon warning-circle
        if {[string match -nocase *sleep* [get $snapshot status {}]]} {set primary_icon moon}
        dui item config aiden_home aiden_start_outer -fill #101E26 -outline #2B434D
        dui item config aiden_home aiden_start_inner -fill #14252E -outline #36515D
        dui item config aiden_home aiden_start_core -fill #112129 -outline #293F49
    } else {
        dui item config aiden_home aiden_start_outer -fill $palette(inset) -outline $palette(outline)
        dui item config aiden_home aiden_start_inner -fill #294D4B -outline #95DDCB
        dui item config aiden_home aiden_start_core -fill #203D3F -outline #416865
    }
    replace_icon aiden_home aiden_play_icon $primary_icon 112 $primary_tone 
    if {[string length $data(profile_title)] > 28} {
        dui item config aiden_home aiden_ready_profile -font [fit_font $data(profile_title) 1700 244 46 26]
        # Two wrapped title lines have a reserved vertical band.
        move_item aiden_home aiden_recipe_summary 88 602
        move_item aiden_home aiden_recipe_icon 1734 646
        move_item aiden_home aiden_recipe_hit 72 590 1782 701
    } else {
        dui item config aiden_home aiden_ready_profile -font [font 64 bold]
        move_item aiden_home aiden_recipe_summary 88 502
        move_item aiden_home aiden_recipe_icon 1734 545
        move_item aiden_home aiden_recipe_hit 72 493 1782 598
    }
    dui item config aiden_home aiden_active_profile -font [fit_font $data(profile_title) 610 190 28 14]
    enabled aiden_home aiden_active_graph_detail [expr {!$operating && ![boolean $snapshot busy]}]
    set color $palette(mint)
    if {!$ready} {set color $palette(warning)}
    if {[get $snapshot readiness {}] in {offline disconnected unknown sleeping sleep}} {set color $palette(muted)}
    foreach page $pages {dui item config $page ${page}_dot -fill $color}
    set icon_name $mode
    if {$mode eq {flush}} {set icon_name shower}
    replace_icon aiden_home aiden_next_mode_icon $icon_name 112 mint
}

proc ::aiden::ui::move_item {page tag args} {
    set coords {}
    set i 0
    foreach value $args {
        if {$i % 2} {lappend coords [dui::platform::rescale_y $value]} else {lappend coords [dui::platform::rescale_x $value]}
        incr i
    }
    foreach id [dui item get $page $tag] {[dui canvas] coords $id {*}$coords}
}

proc ::aiden::ui::replace_icon {page tag name size tone} {
    variable directory
    set file [file join $directory ui-assets [dui cget screen_size_width]x[dui cget screen_size_height] "$name-$tone-$size.png"]
    if {![file exists $file]} {return}
    variable widgets
    set key image,$name,$size,$tone
    if {![info exists widgets($key)]} {set widgets($key) [::image create photo -file $file]}
    # Use the canvas item, as dui add image returns the photo name.
    dui item config $page $tag -image $widgets($key)
}

proc ::aiden::ui::page_shown {page args} {
    variable current_page
    variable mounted
    if {$current_page eq {aiden_profiles} && $page ne $current_page} {end_profile_interaction}
    set current_page $page
    if {!$mounted} {return}
    if {$page eq {aiden_home}} {render_home_layout}
    if {$page eq {aiden_recipe}} {render_recipe}
    if {$page eq {aiden_profiles}} {render_catalog}
    if {$page eq {aiden_modes}} {render_mode_fields}
    if {$page eq {aiden_workflow}} {render_workflow}
    style_widgets $page
    refresh
    if {$page ne {aiden_home}} {start_sheet_motion $page} else {cancel_motion}
}

proc ::aiden::ui::show {page} {
    variable mounted
    variable pages
    variable current_page
    variable snapshot
    if {!$mounted} {mount}
    if {![string match aiden_* $page]} {set page aiden_$page}
    if {$page ni $pages} {error "Unknown Aiden page '$page'"}
    if {([active] || [boolean $snapshot busy]) && $page ne {aiden_home}} {set page aiden_home}
    if {$current_page eq {aiden_profiles} && $page ne $current_page} {end_profile_interaction}
    set current_page $page
    dui page show $page
    page_shown $page
    return $page
}

proc ::aiden::ui::cancel {page} {
    variable editing_mode
    switch -- $page {
        aiden_recipe {dispatch recipe_cancel}
        aiden_profiles {finish_search; dispatch profile_cancel}
        aiden_modes {dispatch mode_cancel $editing_mode}
        aiden_workflow {dispatch workflow_cancel}
        default {dispatch close}
    }
}

proc ::aiden::ui::set_catalog {records} {
    variable catalog
    variable selected_id
    set catalog $records
    set found 0
    foreach record $catalog {if {[get $record id] eq $selected_id} {set found 1}}
    if {!$found} {
        set selected_id {}
        foreach record $catalog {if {[boolean $record current]} {set selected_id [get $record id]; break}}
    }
    render_catalog
    return [llength $catalog]
}

proc ::aiden::ui::set_selected {id} {
    variable selected_id
    set selected_id $id
    render_catalog
    return $id
}

proc ::aiden::ui::selected_record {} {
    variable catalog
    variable selected_id
    foreach record $catalog {if {[get $record id] eq $selected_id} {return $record}}
    return {}
}

proc ::aiden::ui::set_recipe {draftDict} {
    variable recipe_draft
    variable recipe_syncing
    variable recipe_dirty
    variable data
    variable copy_open
    variable current_page
    set recipe_syncing 1
    set recipe_draft $draftDict
    set data(dose) [get $draftDict dose {}]
    set data(yield) [first $draftDict {yield target_yield} {}]
    set data(temperature_draft) [first $draftDict {temperature temp} {}]
    set data(ratio_draft) [get $draftDict ratio {}]
    set data(recipe_error) [first $draftDict {error reason} {}]
    set data(recipe_hint) [get $draftDict hint {Until you choose another profile.}]
    set recipe_dirty {}
    # A private field edit can finish after the nested copy sheet is opened.
    if {$current_page ne {aiden_recipe}} {set copy_open 0}
    sync_recipe_numbers {}
    set recipe_syncing 0
    render_recipe
    return $recipe_draft
}

proc ::aiden::ui::recipe_model {} {
    variable recipe_draft
    variable data
    # A calculated ratio keeps its precision; the entry's rounded preview must
    # never turn an unchanged yield into a different target at commit time.
    return [dict create dose $data(dose) yield $data(yield) temperature $data(temperature_draft) ratio [get $recipe_draft ratio {}]]
}

proc ::aiden::ui::recipe_number {value {positive 0}} {
    if {[number $value] eq {—}} {return 0}
    if {$positive} {return [expr {$value > 0}]}
    return [expr {$value >= 0}]
}

proc ::aiden::ui::sync_recipe_numbers {field} {
    variable recipe_draft
    variable data
    set dose $data(dose)
    set yield $data(yield)
    if {$field eq {ratio}} {
        set ratio $data(ratio_draft)
        dict set recipe_draft ratio $ratio
        if {[recipe_number $dose 1] && [recipe_number $ratio]} {
            if {[catch {expr {round(double($dose) * $ratio * 10.0) / 10.0}} yield] || ![recipe_number $yield]} {
                set data(ratio) {Ratio unavailable}
                return
            }
            set data(yield) [format %.1f $yield]
        } else {
            set data(ratio) {Ratio unavailable}
            return
        }
    }
    dict set recipe_draft dose $dose
    dict set recipe_draft yield $yield
    dict set recipe_draft temperature $data(temperature_draft)
    set ratio {}
    if {[recipe_number $dose 1] && [recipe_number $yield]} {set ratio [expr {double($yield) / $dose}]}
    dict set recipe_draft ratio $ratio
    if {$field ne {ratio}} {
        set data(ratio_draft) {}
        if {$ratio ne {}} {set data(ratio_draft) [number $ratio 2]}
    }
    set data(ratio) {Ratio unavailable}
    if {$ratio ne {}} {set data(ratio) "1 : [number $ratio 2]"}
}

proc ::aiden::ui::recipe_input_changed {field args} {
    variable mounted
    variable current_page
    variable recipe_syncing
    variable recipe_dirty
    if {$recipe_syncing || !$mounted || $current_page ne {aiden_recipe}} {return}
    dict set recipe_dirty $field 1
    set recipe_syncing 1
    sync_recipe_numbers $field
    set recipe_syncing 0
    # Only local draft and labels change while typing. The controller validates
    # on field exit; native settings still require explicit Apply or Save copy.
    refresh
}

proc ::aiden::ui::recipe_field_changed {field} {
    variable data
    variable recipe_dirty
    variable current_page
    if {$current_page ne {aiden_recipe} || ![dict exists $recipe_dirty $field]} {return 0}
    set key $field
    if {$field eq {temperature}} {set key temperature_draft}
    if {$field eq {ratio}} {set key ratio_draft}
    set result [dispatch recipe_edit $field $data($key)]
    if {[dict exists $recipe_dirty $field]} {dict unset recipe_dirty $field}
    render_recipe
    return $result
}

proc ::aiden::ui::render_recipe {} {
    variable mounted
    variable copy_open
    variable data
    if {!$mounted} {return}
    visibility aiden_recipe aiden_recipe_edit [expr {!$copy_open}]
    visibility aiden_recipe aiden_copy $copy_open
    enabled aiden_recipe {aiden_recipe_apply aiden_recipe_copy aiden_copy_save aiden_recipe_reset} [commit_allowed]
    refresh
}

proc ::aiden::ui::commit_recipe {} {dispatch recipe_apply [recipe_model]}

proc ::aiden::ui::open_copy {} {
    variable copy_open
    variable copy_name
    variable data
    set copy_name "$data(profile_title) — adjusted"
    set copy_open 1
    dispatch recipe_save_copy_open [recipe_model]
    render_recipe
}

proc ::aiden::ui::close_copy {} {
    variable copy_open
    set copy_open 0
    dispatch recipe_save_copy_cancel
    render_recipe
}

proc ::aiden::ui::commit_copy {} {
    variable copy_name
    dispatch recipe_save_copy [string trim $copy_name] [recipe_model]
}

proc ::aiden::ui::clear_search {} {
    variable query
    set query {}
    dispatch profile_search {}
}

proc ::aiden::ui::query_changed {args} {
    variable query
    render_catalog
    dispatch profile_search $query
}

proc ::aiden::ui::filter_favorites {value} {
    variable favorites_only
    set favorites_only $value
    dispatch profile_filter [expr {$value ? {favorites} : {all}}]
    render_catalog
}

proc ::aiden::ui::finish_search {} {
    variable widgets
    variable search_focused
    set search_focused 0
    if {[info commands ::hide_android_keyboard] ne {}} {::hide_android_keyboard}
    focus [dui canvas]
    search_layout 0
}

proc ::aiden::ui::search_layout {focused} {
    variable search_focused
    variable mounted
    variable current_page
    if {!$mounted || ![profile_view_visible]} {
        if {!$focused} {set search_focused 0}
        return
    }
    set search_focused $focused
    visibility aiden_profiles aiden_profile_preview [expr {!$focused}]
    visibility aiden_profiles aiden_search_actions $focused
    foreach id [dui item get aiden_profiles aiden_profile_list] {
        [dui canvas] itemconfigure $id -height [dui::platform::rescale_y [expr {$focused ? 210 : 665}]]
    }
    # The description/graphs restore only if the selected record supports them.
    if {!$focused} {
        if {[info commands ::hide_android_keyboard] ne {}} {::hide_android_keyboard}
        set record [selected_record]
        set graph [get $record graph {}]
        if {$graph eq {}} {set graph [profile_graph $record]}
        visibility aiden_profiles aiden_preview_signals [expr {$graph ne {}}]
    }
}

proc ::aiden::ui::render_catalog {} {
    variable mounted
    variable catalog
    variable filtered
    variable query
    variable favorites_only
    variable selected_id
    variable data
    variable widgets
    variable palette
    variable gesture
    # A rebuilt row may identify a different profile at the same coordinates.
    unset -nocomplain gesture(profile)
    set filtered {}
    foreach record $catalog {
        if {$favorites_only && ![boolean $record favorite]} {continue}
        set title [first $record {title fullname name} {Unnamed profile}]
        if {$query ne {} && [string first [string tolower $query] [string tolower "$title [get $record description]"]] < 0} {continue}
        lappend filtered $record
    }
    set selection_visible 0
    foreach record $filtered {if {[get $record id] eq $selected_id} {set selection_visible 1; break}}
    if {!$selection_visible} {set selected_id {}}
    set data(chooser_count) "[llength $filtered] profiles · Drag to scroll"
    if {!$mounted || ![info exists widgets(profiles)]} {return}
    set w $widgets(profiles)
    set previous [$w yview]
    $w configure -state normal
    $w delete 1.0 end
    set row 0
    foreach record $filtered {
        set tag aiden_row_$row
        set title [first $record {title fullname name} {Unnamed profile}]
        set identity [get $record id]
        set marker {}
        if {[boolean $record current]} {append marker {  · Current}}
        $w insert end "$title\n" $tag
        set metadata "[get $record type Profile] · [compact [get $record dose]] g → [compact [get $record yield]] g"
        if {$marker ne {}} {append metadata $marker}
        if {![boolean $record available 1] || ![boolean $record applyable 1]} {set metadata [first $record {error reason} {Unavailable profile}]}
        $w insert end "$metadata\n" [list $tag metadata]
        set fill $palette(panel)
        set text $palette(soft)
        if {$identity eq $selected_id} {set fill $palette(selected); set text $palette(mint)}
        $w tag configure $tag -lmargin1 12 -lmargin2 12 -rmargin 20 -background $fill -foreground $text
        incr row
    }
    if {$row == 0} {$w insert end {No profiles match. Try a shorter name or All.}}
    $w configure -state disabled
    $w yview moveto [lindex $previous 0]
    set record [selected_record]
    if {$record eq {}} {
        set data(preview_title) {Select a profile}
        set data(preview_type) {}
        set data(preview_description) {Tap a full name to inspect the native profile.}
        set data(preview_metrics) {}
        set data(preview_notice) {Preview only · no changes applied}
    } else {
        set data(preview_title) [first $record {title fullname name} {Unnamed profile}]
        set data(preview_type) [get $record type Profile]
        set data(preview_description) [get $record description {}]
        set data(preview_metrics) "[compact [get $record dose]] g in    [compact [get $record yield]] g out    [compact [get $record temperature]]°C"
        set data(preview_notice) {Preview only · no changes applied}
        if {[boolean $record current]} {set data(preview_notice) {Current profile · existing adjustments stay in place}}
        if {![boolean $record available 1] || ![boolean $record applyable 1]} {
            set reason [first $record {error reason} {Profile unavailable}]
            append data(preview_description) "\n\n$reason"
            set data(preview_notice) {Use the compatible native editor.}
            if {![boolean $record available 1]} {set data(preview_notice) {Profile unavailable · details above}}
        }
        set graph [get $record graph {}]
        if {$graph eq {}} {set graph [profile_graph $record]}
    }
    set graph [get $record graph {}]
    if {$graph eq {}} {set graph [profile_graph $record]}
    if {$graph ne {}} {set_graph $graph preview}
    visibility aiden_profiles aiden_preview_signals [expr {$graph ne {}}]
    set description $widgets(preview_description)
    $description configure -state normal
    $description delete 1.0 end
    $description insert end $data(preview_description)
    $description configure -state disabled
    $description yview moveto 0
    dui item config aiden_profiles aiden_preview_title -font [fit_font $data(preview_title) 786 120 34 18]
    style_widgets aiden_profiles
    enabled aiden_profiles aiden_profiles_use [expr {$record ne {} && [boolean $record available 1] && [boolean $record applyable 1] && [commit_allowed]}]
    search_layout $::aiden::ui::search_focused
    refresh
}

proc ::aiden::ui::profile_view_visible {} {
    variable current_page
    return [expr {$current_page eq {aiden_profiles} && [dui page current] eq {aiden_profiles}}]
}

proc ::aiden::ui::end_profile_interaction {} {
    variable gesture
    variable search_focused
    unset -nocomplain gesture(profile)
    if {$search_focused} {finish_search}
}

proc ::aiden::ui::touch_begin {x y} {
    variable gesture
    variable widgets
    if {![profile_view_visible]} {unset -nocomplain gesture(profile); return}
    lassign [$widgets(profiles) yview] first last
    set gesture(profile) [list $x $y 0 $first $last]
    focus $widgets(profiles)
}

proc ::aiden::ui::touch_move {x y} {
    variable gesture
    variable widgets
    if {![profile_view_visible]} {unset -nocomplain gesture(profile); return}
    if {![info exists gesture(profile)]} {return}
    lassign $gesture(profile) ox oy moved first last
    if {abs($x-$ox)>8 || abs($y-$oy)>8} {set moved 1}
    set gesture(profile) [list $ox $oy $moved $first $last]
    set height [winfo height $widgets(profiles)]
    if {$moved && $height>0} {$widgets(profiles) yview moveto [expr {$first-double($y-$oy)/$height*($last-$first)}]}
}

proc ::aiden::ui::touch_end {x y} {
    variable gesture
    variable widgets
    variable filtered
    if {![info exists gesture(profile)]} {return}
    lassign $gesture(profile) ox oy moved
    unset gesture(profile)
    if {![profile_view_visible]} {return}
    if {$moved || abs($x-$ox)>8 || abs($y-$oy)>8} {return}
    foreach tag [$widgets(profiles) tag names @$x,$y] {
        if {[regexp {^aiden_row_([0-9]+)$} $tag -> row] && $row<[llength $filtered]} {
            select_profile [get [lindex $filtered $row] id]
            return
        }
    }
}

proc ::aiden::ui::select_profile {id} {
    variable selected_id
    set selected_id $id
    dispatch profile_select $id
    render_catalog
}

proc ::aiden::ui::move_profile {direction} {
    variable filtered
    variable selected_id
    variable widgets
    set index -1
    set i 0
    foreach record $filtered {if {[get $record id] eq $selected_id} {set index $i}; incr i}
    if {$i==0} {return}
    set index [expr {max(0,min($i-1,$index+$direction))}]
    select_profile [get [lindex $filtered $index] id]
    $widgets(profiles) see aiden_row_$index.first
}

proc ::aiden::ui::commit_profile {} {
    variable selected_id
    if {$selected_id eq {} || [selected_record] eq {}} {return}
    dispatch profile_apply $selected_id
}

proc ::aiden::ui::favorite_selected {} {
    variable selected_id
    if {$selected_id ne {}} {dispatch profile_favorite $selected_id}
}

proc ::aiden::ui::set_mode_settings {mode settingsDict} {
    variable editing_mode
    variable mode_schema
    variable mode_draft
    set editing_mode [normalized_mode $mode]
    set mode_schema $settingsDict
    set mode_draft [get $settingsDict values $settingsDict]
    render_mode_fields
    return $mode_draft
}

proc ::aiden::ui::render_mode_fields {} {
    variable mounted
    variable mode_schema
    variable mode_draft
    variable editing_mode
    variable data
    variable snapshot
    set data(modes_title) [get $mode_schema title [mode_name $editing_mode]]
    set data(modes_detail) [get $mode_schema reason {}]
    set data(modes_hint) [get $mode_schema hint {Values apply only to this mode.}]
    if {$data(modes_detail) eq {Settings require a connected, verified idle machine with no pending operation}} {
        set data(modes_detail) {Wait for the machine to be ready before applying changes.}
        if {![boolean $snapshot connected]} {set data(modes_detail) {Connect the machine to apply changes.}}
    }
    if {$editing_mode eq {steam}} {set data(modes_hint) {Heater setpoint only; milk temperature is not measured. At 134 °C the heater is off.}}
    if {!$mounted} {return}
    set fields [get $mode_schema fields {}]
    for {set i 0} {$i<4} {incr i} {
        set present [expr {$i<[llength $fields]}]
        visibility aiden_modes aiden_mode_field_$i $present
        if {!$present} {continue}
        set field [lindex $fields $i]
        set key [first $field {native_key key} {}]
        set value [get $mode_draft $key [get $field value {}]]
        set scale [first $field {display_factor display_scale} 1]
        if {[string is double -strict $value] && $scale!=1} {set value [expr {$value*double($scale)}]}
        if {[get $field display_value {}] ne {} && ![dict exists $mode_draft $key]} {set value [get $field display_value]}
        set data(mode_field_${i}_name) [get $field label $key]
        set unit [first $field {display_unit unit} {}]
        if {$unit eq {} && [llength [get $field units {}]] == 1} {set unit [lindex [get $field units] 0]}
        set data(mode_field_${i}_value) [string trim "[compact $value] $unit"]
        if {$key eq "water_volume" && $unit eq {}} {set data(mode_field_${i}_value) {Unavailable}}
        if {[get $field kind {}] eq {boolean} || [get $field semantics {}] in {boolean bool} || [get $field units {}] eq {boolean}} {set data(mode_field_${i}_value) [expr {[string is true -strict $value] ? {On} : {Off}}]}
        set available [boolean $field available]
        enabled aiden_modes [list aiden_mode_field_${i}_minus aiden_mode_field_${i}_plus] $available
        if {!$available && [get $field reason] ne {}} {set data(modes_hint) [get $field reason]}
    }
    enabled aiden_modes aiden_modes_apply [expr {[boolean $mode_schema editable [expr {[llength $fields]>0}]] && [commit_allowed]}]
    refresh
}

proc ::aiden::ui::step_mode {index direction} {
    variable mode_schema
    variable mode_draft
    variable editing_mode
    variable current_page
    if {$current_page ne {aiden_modes} || [dui page current] ne {aiden_modes}} {return}
    set fields [get $mode_schema fields {}]
    if {$index>=[llength $fields]} {return}
    set field [lindex $fields $index]
    if {![boolean $field available]} {return}
    set key [first $field {native_key key} {}]
    set value [get $mode_draft $key [get $field value {}]]
    if {[get $field kind {}] eq {boolean} || [get $field semantics {}] in {boolean bool} || [get $field units {}] eq {boolean}} {
        set value [expr {![string is true -strict $value]}]
    } else {
        if {![string is double -strict $value]} {return}
        set step [get $field step 1]
        if {![string is double -strict $step]} {return}
        set value [expr {$value+$direction*$step}]
        set min [get $field min {}]
        set max [get $field max {}]
        if {[string is double -strict $min]} {set value [expr {max($min,$value)}]}
        if {[string is double -strict $max]} {set value [expr {min($max,$value)}]}
    }
    dict set mode_draft $key $value
    dispatch mode_edit $editing_mode $key $value
    render_mode_fields
}

proc ::aiden::ui::commit_mode {} {
    variable editing_mode
    variable mode_draft
    variable current_page
    if {$current_page ne {aiden_modes} || [dui page current] ne {aiden_modes}} {return}
    dispatch mode_apply $editing_mode $mode_draft
}

proc ::aiden::ui::set_context {page contextDict} {
    variable contexts
    variable data
    if {![string match aiden_* $page]} {set page aiden_$page}
    dict set contexts $page $contextDict
    switch -- $page {
        aiden_home {
            if {[boolean $contextDict graph_expanded]} {show aiden_graph}
        }
        aiden_status {
            set data(status_title) [get $contextDict title $data(status_title)]
            set data(status_detail) [get $contextDict detail $data(status_detail)]
        }
        aiden_scale {
            set data(scale_detail) [get $contextDict detail $data(scale_detail)]
            set data(scale_note) [get $contextDict note $data(scale_note)]
        }
        aiden_recipe {set data(recipe_error) [get $contextDict error {}]}
        aiden_workflow {
            variable workflow_draft
            set workflow_draft [get $contextDict selected $workflow_draft]
            set data(workflow_hint) [get $contextDict hint $data(workflow_hint)]
            render_workflow
        }
    }
    refresh
    return $contextDict
}

proc ::aiden::ui::select_workflow {id} {
    variable workflow_draft
    set workflow_draft $id
    dispatch workflow_select $id
    render_workflow
}

proc ::aiden::ui::render_workflow {} {
    variable workflow_draft
    variable mounted
    variable palette
    if {!$mounted} {return}
    foreach id {espresso latte americano steam} {
        set fill $palette(inset)
        if {$id eq $workflow_draft} {set fill $palette(selected)}
        dui item config aiden_workflow aiden_workflow_${id}_panel -fill $fill
    }
    refresh
}

proc ::aiden::ui::commit_workflow {} {
    variable workflow_draft
    dispatch workflow_apply $workflow_draft
}

# Bind graph elements to existing BLT vectors or create view-owned BLT vectors
# from supplied recorded sample lists. Missing samples split the signal; values
# are never interpolated, predicted, or replaced with zero.
proc ::aiden::ui::vector {name values} {
    set full ::aiden::ui::v_$name
    if {[info commands $full] eq {}} {
        if {[info commands ::blt::vector] ne {}} {::blt::vector create $full} elseif {[info commands ::vector] ne {}} {::vector create $full} else {error {Aiden graphs require native BLT vectors}}
    }
    $full set $values
    return $full
}

proc ::aiden::ui::finite {value} {
    return [expr {[string is double -strict $value] && ![string match -nocase *nan* $value] && ![string match -nocase *inf* $value]}]
}

proc ::aiden::ui::set_graph {graphDict {context home}} {
    variable mounted
    variable widgets
    variable palette
    if {!$mounted} {return}
    set graph $graphDict
    # A list of timestamped sample dictionaries is also accepted.
    if {[llength $graph]>0 && ![catch {dict exists [lindex $graph 0] elapsed} is_sample] && $is_sample} {
        set times {}; set pressure {}; set flow {}
        foreach sample $graph {
            lappend times [first $sample {elapsed time} {}]
            lappend pressure [get $sample pressure {}]
            lappend flow [get $sample flow {}]
        }
        set graph [dict create elapsed $times pressure $pressure flow $flow]
    }
    set elapsed [first $graph {elapsed time times x vector_elapsed} {}]
    set external_time [expr {$elapsed ne {} && [llength $elapsed]==1 && [info commands $elapsed] ne {}}]
    set max_time 30
    if {$external_time} {catch {set max_time [expr {max(30,ceil([$elapsed index end]/10.0)*10)}]}} elseif {[llength $elapsed]>0 && [finite [lindex $elapsed end]]} {set max_time [expr {max(30,ceil([lindex $elapsed end]/10.0)*10)}]}
    foreach signal {pressure flow} {
        set values [first $graph [list $signal ${signal}s vector_$signal] {}]
        set external [expr {$external_time && [llength $values]==1 && [info commands $values] ne {}}]
        set extent_values $values
        if {$external} {catch {set extent_values [$values range 0 end]}}
        set ymin 0
        set ymax [expr {$signal eq {pressure} ? 9 : 4}]
        set ystep [expr {$signal eq {pressure} ? 3 : 2}]
        foreach value $extent_values {
            if {![finite $value]} {continue}
            set ymin [expr {min($ymin,floor($value))}]
            set ymax [expr {max($ymax,ceil($value/$ystep)*$ystep)}]
        }
        set segments {}
        if {$external} {
            lappend segments [list $elapsed $values]
        } else {
            set times {}; set samples {}; set segment 0
            foreach t $elapsed value $values {
                if {[finite $t] && [finite $value]} {
                    lappend times $t
                    lappend samples $value
                } elseif {[llength $times]>0} {
                    lappend segments [list [vector ${context}_${signal}_x$segment $times] [vector ${context}_${signal}_y$segment $samples]]
                    incr segment
                    set times {}; set samples {}
                }
            }
            if {[llength $times]>0} {lappend segments [list [vector ${context}_${signal}_x$segment $times] [vector ${context}_${signal}_y$segment $samples]]}
        }
        foreach key [array names widgets graph,*] {
            set stem [string range $key 6 end]
            if {$widgets(signal,$stem) ne $signal} {continue}
            if {$context eq {preview} && ![string match preview_* $stem]} {continue}
            if {$context ne {preview} && [string match preview_* $stem]} {continue}
            set w $widgets($key)
            set index 0
            foreach pair $segments {
                lassign $pair xs ys
                set element signal_$index
                if {![$w element exists $element]} {$w element create $element -symbol none -label {} -linewidth 3 -color $palette([expr {$signal eq {pressure} ? {mint} : {flow}}]) -smooth linear -pixels 0}
                $w element configure $element -xdata $xs -ydata $ys -hide no
                incr index
            }
            foreach element [$w element names signal_*] {
                if {[string range $element 7 end]>=$index} {$w element configure $element -hide yes}
            }
            $w axis configure x -max $max_time
            set step $ystep
            if {[string match preview_* $stem] && $signal eq {flow} && $ymax>4} {set step [expr {$ymax/2.0}]}
            $w axis configure y -min $ymin -max $ymax -stepsize $step
            set goal [get $graph ${signal}_goal {}]
            set goal_element goal
            if {$external_time && [llength $goal]==1 && [info commands $goal] ne {}} {
                if {![$w element exists $goal_element]} {$w element create $goal_element -symbol none -label {} -linewidth 1 -dashes {4 5} -color $palette(muted) -smooth linear -pixels 0}
                $w element configure $goal_element -xdata $elapsed -ydata $goal -hide no
            } elseif {[$w element exists $goal_element]} {$w element configure $goal_element -hide yes}
        }
    }
    return $graph
}

# Explicit native-screen return affordance. This adds one UI control only; the
# controller decides which original-skin routes and callbacks remain active.
proc ::aiden::ui::mount_native_return {{page off}} {
    variable widgets
    if {[namespace which -command ::aiden::core::native_page_exists] ne {}} {
        if {![::aiden::core::native_page_exists $page]} {return 0}
    } elseif {![dui page exists $page]} {return 0}
    if {[info exists widgets(native_return,$page)]} {return 1}
    set widgets(native_return,$page) [button $page aiden_native_return 1800 12 250 85 Aiden [list ::aiden::ui::dispatch home]]
    return 1
}

proc ::aiden::ui::open_mode_settings {} {
    variable snapshot
    dispatch mode_settings [normalized_mode [get $snapshot mode espresso]]
}

proc ::aiden::ui::commit_allowed {} {
    variable snapshot
    if {[active] || [boolean $snapshot busy]} {return 0}
    if {[dict exists $snapshot editable]} {return [boolean $snapshot editable]}
    if {[dict exists $snapshot connected]} {return [expr {[boolean $snapshot connected] && [boolean $snapshot ready]}]}
    return 1
}

# Native widget options can be changed by the host theme when a page is shown.
# Reapply Aiden's bounded opaque surfaces after host page setup.
proc ::aiden::ui::style_widgets {page} {
    variable widgets
    variable palette
    set entries {}
    if {$page eq {aiden_profiles} && [info exists widgets(search)]} {lappend entries $widgets(search)}
    if {$page eq {aiden_recipe}} {
        foreach key {recipe,dose recipe,yield recipe,temperature recipe,ratio copy_name} {
            if {[info exists widgets($key)]} {lappend entries $widgets($key)}
        }
    }
    foreach w $entries {
        $w configure -background $palette(inset) -foreground $palette(text) -disabledbackground $palette(inset) \
            -disabledforeground $palette(muted) -readonlybackground $palette(inset) -insertbackground $palette(mint) \
            -relief flat -borderwidth 0 -highlightthickness 0 -highlightbackground $palette(inset) -highlightcolor $palette(mint) \
            -selectbackground $palette(selected) -selectforeground $palette(text)
    }
    foreach key {profiles preview_description} {
        if {$page ne {aiden_profiles} || ![info exists widgets($key)]} {continue}
        set fill $palette(panel)
        if {$key eq {preview_description}} {set fill $palette(inset)}
        $widgets($key) configure -background $fill -foreground $palette(soft) -relief flat -borderwidth 0 \
            -highlightthickness 0 -highlightbackground $fill -highlightcolor $palette(mint) \
            -selectbackground $palette(selected) -selectforeground $palette(text) -inactiveselectbackground $palette(selected)
    }
}

proc ::aiden::ui::fit_font {value width height preferred minimum} {
    set width [dui::platform::rescale_x $width]
    set height [dui::platform::rescale_y $height]
    set chosen [font $preferred bold]
    if {[info commands ::font] eq {}} {return $chosen}
    for {set size $preferred} {$size>=$minimum} {incr size -2} {
        set chosen [font $size bold]
        set lines 1
        set line {}
        foreach word [split $value] {
            set trial [string trim "$line $word"]
            if {[::font measure $chosen $trial]>$width && $line ne {}} {incr lines; set line {}}
            if {[::font measure $chosen $word]>$width} {
                # Tk wraps an unbroken filename by character, too. Account for
                # those lines instead of treating an over-wide word as one line.
                foreach ch [split $word {}] {
                    if {$line ne {} && [::font measure $chosen "$line$ch"]>$width} {incr lines; set line {}}
                    append line $ch
                }
            } else {set line [string trim "$line $word"]}
        }
        if {$lines*[::font metrics $chosen -linespace]<=$height} {break}
    }
    return $chosen
}

# This graph shows the file's configured targets and maximum stage durations.
# It describes recipe data only, never a predicted or measured beverage trace.
proc ::aiden::ui::profile_graph {record} {
    set stages [get $record stagepreview {}]
    set times {}; set pressure {}; set flow {}; set elapsed 0
    if {[llength $stages]} {
        foreach stage $stages {
            set seconds [get $stage seconds {}]
            set target [get $stage target {}]
            set pump [get $stage pump {}]
            if {![finite $seconds] || $seconds<=0 || ![finite $target] || $pump ni {pressure flow}} {return {}}
            foreach t [list $elapsed [expr {$elapsed+$seconds}]] {
                lappend times $t
                lappend pressure [expr {$pump eq {pressure} ? $target : {}}]
                lappend flow [expr {$pump eq {flow} ? $target : {}}]
            }
            set elapsed [expr {$elapsed+$seconds}]
        }
        return [dict create elapsed $times pressure $pressure flow $flow]
    }
    set profile [get $record profile {}]
    set type [get $profile settings_profile_type {}]
    if {$type in {settings_2a settings_2a2}} {
        set pre [get $profile preinfusion_time {}]
        set hold [get $profile espresso_hold_time {}]
        set decline [get $profile espresso_decline_time {}]
        set start [get $profile preinfusion_stop_pressure {}]
        set peak [get $profile espresso_pressure {}]
        set end [get $profile pressure_end {}]
        set preflow [get $profile preinfusion_flow_rate {}]
        foreach value [list $pre $hold $decline $start $peak $end $preflow] {if {![finite $value]} {return {}}}
        set t1 $pre
        set t2 [expr {$pre+$hold}]
        set t3 [expr {$t2+$decline}]
        return [dict create elapsed [list 0 $t1 $t1 $t2 $t3] pressure [list $start $start $peak $peak $end] flow [list $preflow $preflow {} {} {}]]
    }
    if {$type in {settings_2b settings_2b2}} {
        foreach key {flow_profile_preinfusion_time flow_profile_hold_time flow_profile_decline_time flow_profile_preinfusion flow_profile_hold flow_profile_decline} {
            set $key [get $profile $key {}]
            if {![finite [set $key]]} {return {}}
        }
        set t1 $flow_profile_preinfusion_time
        set t2 [expr {$t1+$flow_profile_hold_time}]
        set t3 [expr {$t2+$flow_profile_decline_time}]
        return [dict create elapsed [list 0 $t1 $t1 $t2 $t3] pressure [list {} {} {} {} {}] flow [list $flow_profile_preinfusion $flow_profile_preinfusion $flow_profile_hold $flow_profile_hold $flow_profile_decline]]
    }
    return {}
}

proc ::aiden::ui::mount_graph_detail {} {
    set page aiden_graph
    sheet $page Graph {Recorded pressure and pump flow. Sensor gaps stay visible.} 1
    label $page aiden_graph_title 380 372 last_title 26 soft 1960 bold
    mount_plot_pair $page detail 390 438 2000 397 43 aiden_graph_signals
    button $page aiden_graph_done 2156 1379 261 86 Done [list ::aiden::ui::cancel $page]
}

proc ::aiden::ui::set_reduced_motion {value} {
    variable reduced_motion
    set reduced_motion [expr {[string is true -strict $value] ? 1 : 0}]
    if {$reduced_motion} {cancel_motion}
    return $reduced_motion
}

proc ::aiden::ui::cancel_motion {} {
    variable motion_after
    variable motion_page
    variable motion_offset
    variable motion_token
    incr motion_token
    if {$motion_after ne {}} {after cancel $motion_after; set motion_after {}}
    if {$motion_page ne {} && $motion_offset!=0} {move_sheet_decor $motion_page [expr {-$motion_offset}]}
    set motion_offset 0
    set motion_page {}
}

proc ::aiden::ui::move_sheet_decor {page amount} {
    # Decorations alone move. Entries and every command's touch target remain
    # stationary, including Wake/Tare, and the primary never joins this set.
    set pixels [dui::platform::rescale_x $amount]
    foreach suffix {shadow panel heading subheading header_line footer_line} {
        foreach item [dui item get $page ${page}_$suffix] {[dui canvas] move $item $pixels 0}
    }
}

proc ::aiden::ui::start_sheet_motion {page} {
    variable reduced_motion
    variable motion_after
    variable motion_page
    variable motion_offset
    variable motion_token
    cancel_motion
    if {$reduced_motion || [active]} {return}
    set motion_page $page
    set motion_offset 16
    move_sheet_decor $page 16
    set motion_after [after 40 [list ::aiden::ui::sheet_motion_frame $page $motion_token 3]]
}

proc ::aiden::ui::sheet_motion_frame {page token remaining} {
    variable motion_after
    variable motion_page
    variable motion_offset
    variable motion_token
    if {$token!=$motion_token} {return}
    set motion_after {}
    if {[dui page current] ne $page || [active]} {cancel_motion; return}
    set next [expr {$remaining*4}]
    move_sheet_decor $page [expr {$next-$motion_offset}]
    set motion_offset $next
    if {$remaining>0} {set motion_after [after 40 [list ::aiden::ui::sheet_motion_frame $page $token [expr {$remaining-1}]]]} else {set motion_page {}}
}

# A native GHC instruction can occupy the entire screen after a transmitted
# Start. Keep its instruction intact and add the same fixed Stop target.
proc ::aiden::ui::mount_pending_stop {{instruction_pages {ghc_espresso ghc_steam ghc_flush ghc_hotwater}}} {
    variable widgets
    variable palette
    set count 0
    foreach page $instruction_pages {
        if {![dui page exists $page]} {continue}
        if {[info exists widgets(pending_stop,$page)]} {incr count; continue}
        dui add shape round_outline $page 2192 1182 2462 1452 -tags aiden_pending_stop_surface -radius 48 -width 3 \
            -fill $palette(stop) -outline $palette(stop_outline)
        icon $page aiden_pending_stop_icon 2327 1317 stop 112 white
        set widgets(pending_stop,$page) [hit $page aiden_pending_stop_hit 2192 1182 270 270 [list ::aiden::ui::dispatch stop]]
        text $page aiden_pending_stop_name 2194 1472 Stop 15 soft 270
        incr count
    }
    return $count
}
