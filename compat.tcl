# SPDX-License-Identifier: GPL-3.0-only
# Derived DSx2 3.30 loader and narrow source adaptations; dependency stays intact.
# Source defines procedures only. load verifies dependency bytes before evaluation.
namespace eval ::aiden::distribution {
    variable skin_root {}
    variable dependency_root {}
    variable status [dict create status unloaded]
    variable active 0
    variable native_includes_loaded 0
    variable problem {}
}

proc ::aiden::distribution::asset_root {} {
    variable dependency_root
    return $dependency_root
}
proc ::aiden::distribution::state_root {} {
    variable skin_root
    return $skin_root
}
proc ::aiden::distribution::app_version {} {
    set provided [package provide de1app]
    if {$provided ne {}} {return $provided}
    # Native version.tcl registers an empty ifneeded script, not a provide.
    set available [package versions de1app]
    if {[llength $available] == 1} {return [lindex $available 0]}
    return unknown
}
proc ::aiden::distribution::read_bytes {path} {
    set fd [open $path rb]
    set result [read $fd]
    close $fd
    return $result
}

# Pure read-only preflight. All code is hashed before any dependency is evaluated.
proc ::aiden::distribution::verify {root specification app_version} {
    package require sha256
    if {$app_version ne [dict get $specification app_version]} {
        error "Aiden requires de1app [dict get $specification app_version]; installed version is $app_version. Select another skin or install a compatible Aiden release."
    }
    set root [file normalize $root]
    set texts {}
    dict for {relative digest} [dict get $specification files] {
        if {[file pathtype $relative] ne "relative" || ".." in [file split $relative]} {
            error {Invalid Aiden dependency manifest path}
        }
        set path [file join $root $relative]
        if {![file isfile $path] || ![file readable $path]} {
            error "Aiden requires installed DSx2 [dict get $specification dsx2_version]: missing $relative. Install the compatible DSx2 dependency first."
        }
        set bytes [read_bytes $path]
        if {[::sha2::sha256 -hex $bytes] ne $digest} {
            error "Aiden requires the supported DSx2 [dict get $specification dsx2_version] files: $relative differs. Select another skin or install a compatible Aiden release."
        }
        if {[file extension $relative] in {.tcl .txt}} {
            dict set texts $relative [encoding convertfrom utf-8 $bytes]
        }
    }
    foreach relative [dict get $specification sources] {
        if {![dict exists $texts $relative]} {error "Unverified Aiden source: $relative"}
    }
    return $texts
}

proc ::aiden::distribution::replace_once {text original replacement} {
    set index [string first $original $text]
    if {$index < 0 || [string first $original $text [expr {$index + [string length $original]}]] >= 0} {
        error {Unsupported DSx2 adaptation: expected exactly one source fragment}
    }
    return [string replace $text $index [expr {$index + [string length $original] - 1}] $replacement]
}

proc ::aiden::distribution::adapt {relative text} {
    switch -- $relative {
        code/procs_vars.tcl {
            set text [replace_once $text {if {[file exists [skin_directory]/pages/cafe/graphs.tcl]} {
    file delete -force [skin_directory]/pages/cafe/graphs.tcl
}} {# Aiden: an installed dependency is read-only.}]
            set text [replace_once $text {    if {[file exists "[skin_directory]/plugins/steam_elapsed_timer.tcl"] == 1} {
        file rename -force [skin_directory]/plugins/steam_elapsed_timer.tcl [skin_directory]/plugins/steam_elapsed_timer.off
    }} {    # Aiden: leave dependency plugin files unchanged.}]
            set begin "proc check_app_extensions {} \{"
            # The body is bounded by two exact declarations in the pinned source.
            set begin_index [string first $begin $text]
            set end_index [string first "proc skin_negative_scale_tare {} \{" $text]
            if {$begin_index < 0 || $end_index <= $begin_index} {
                error {Unsupported DSx2 extension initialization fragment}
            }
            set text [string replace $text $begin_index [expr {$end_index - 1}] \
                "proc check_app_extensions {} \{return\}\n\n"]
            set text [replace_once $text {::register_state_change_handler Sleep Idle skin_load_fav} \
                {# Aiden: favourite application requires an explicit action.}]
            set text [replace_once $text "\nskin_negative_scale_tare\n" \
                "\n# Aiden: no recurring automatic tare is started.\n"]
            set text [string map [list \
                {[skin_directory]/fonts} {[::aiden::distribution::asset_root]/fonts} \
                {[skin_directory]/colour_themes} {[::aiden::distribution::asset_root]/colour_themes} \
                {[skin_directory]/settings} {[::aiden::distribution::state_root]/settings}] $text]
        }
        code/save_and_load.tcl {
            set text [string map [list {[skin_directory]/settings} \
                {[::aiden::distribution::state_root]/settings}] $text]
        }
        pages/Damian/home.tcl {
            set text [replace_once $text {if {$::android != 1} {
    start_idle
}} {# Aiden: source never requests Idle, including desktop simulation.}]
            set text [replace_once $text "\nskin_load \$::skin(auto_load_fav)\n" \
                "\n# Aiden: do not apply a favourite during source.\n"]
        }
    }
    if {[string first {[skin_directory]} $text] >= 0} {
        error "Unsupported DSx2 path reference in $relative"
    }
    return $text
}

proc ::aiden::distribution::read_preferences {name array_name} {
    set path [file join [state_root] settings $name]
    if {[file exists $path]} {
        set data [encoding convertfrom utf-8 [read_bytes $path]]
        if {[llength $data] % 2} {error "Invalid Aiden preferences: $name"}
        uplevel #0 [list array set $array_name $data]
    }
}

proc ::aiden::distribution::load {root} {
    variable skin_root
    variable dependency_root
    variable status
    variable active
    variable native_includes_loaded
    variable manifest
    if {$active} {return $status}
    set skin_root [file normalize $root]
    set dependency_root [file normalize [file join $skin_root .. DSx2]]
    source [file join $skin_root dependency-manifest.tcl]
    set texts [verify $dependency_root $manifest [app_version]]
    set scripts {}
    foreach relative [dict get $manifest sources] {
        dict set scripts $relative [adapt $relative [dict get $texts $relative]]
    }
    set defaults [dict get $texts code/default_settings.txt]
    if {[llength $defaults] % 2} {error {Invalid supported DSx2 defaults}}
    foreach path [list [file join [homedir] skins default standard_includes.tcl] \
            [file join $skin_root aiden bootstrap.tcl]] {
        if {![file readable $path]} {error "Incomplete Aiden installation: [file tail $path]"}
    }

    # All validation/adaptation finishes before native/base sources or state writes.
    package require lambda
    uplevel #0 [list source [file join [homedir] skins default standard_includes.tcl]]
    set native_includes_loaded 1
    uplevel #0 [list array set ::skin $defaults]
    read_preferences skin_settings.txt ::skin
    read_preferences skin_graphs.txt ::skin_graphs
    # Only the reviewed Damian base is supported; do not import dependency prefs.
    array set ::skin {theme Damian colour_theme_folder default colour_theme default auto_load_fav none \
        auto_load_fav_Damian none auto_load_fav_cafe none auto_tare_negative_reading 0 workflow none}
    foreach relative [dict get $manifest sources] {
        if {[catch {uplevel #0 [dict get $scripts $relative]} result options]} {
            dict set options -errorinfo "Aiden DSx2 library $relative: $result\n[dict get $options -errorinfo]"
            return -options $options $result
        }
    }
    read_preferences D_graphs.tdb ::D_graphs
    .can configure -bg $::skin_background_colour
    # Aiden modules retain native action/safety/history ownership. Their bootstrap
    # schedules UI mount; no installed DSx2 Damian.start/end is sourced.
    set active 1
    set status [dict create status mounting app_version [dict get $manifest app_version] \
        dsx2_version [dict get $manifest dsx2_version] startup_wake_policy native_first_connection]
    namespace eval ::aiden {variable standalone 1}
    uplevel #0 [list source [file join $skin_root aiden bootstrap.tcl]]
    return $status
}

# App boot owns confirmation; merely sourcing/scheduling it is not a loaded UI.
proc ::aiden::distribution::mounted {} {
    variable active
    variable status
    if {$active && [dict get $status status] eq "mounting"} {
        dict set status status loaded
    }
    return $status
}

proc ::aiden::distribution::boot_failure {error options} {
    return [failure [state_root] $error $options]
}
proc ::aiden::distribution::boot_success {} {return [mounted]}

proc ::aiden::distribution::choose_skin {} {
    # Direct navigation avoids the page_show user-present MMR helper.
    if {[info exists ::settings(stress_test)] && $::settings(stress_test)} {return}
    if {[info exists ::idle_next_step] && $::idle_next_step ne {}} {return}
    backup_settings
    dui page load tabletstyles
    fill_skin_listbox
}

proc ::aiden::distribution::show_failure {} {
    if {[info exists ::settings(stress_test)] && $::settings(stress_test)} {return}
    if {[info exists ::idle_next_step] && $::idle_next_step ne {}} {return}
    dui page load aiden_dependency_error
}

proc ::aiden::distribution::failure {root error options} {
    variable skin_root
    variable dependency_root
    variable status
    variable problem
    variable active
    variable native_includes_loaded
    set skin_root [file normalize $root]
    set dependency_root [file normalize [file join $skin_root .. DSx2]]
    set active 0
    set problem $error
    set status [dict create status blocked startup_wake_policy native_first_connection]
    catch {
        set fd [open [file join $skin_root startup-error.txt] w]
        puts $fd $error
        if {[dict exists $options -errorinfo]} {puts $fd [dict get $options -errorinfo]}
        close $fd
    }
    # Keep native load_skin from running reset_skin and clearing GHC/plugins.
    # This fallback loads only the installed app's ordinary safety/settings pages.
    if {!$native_includes_loaded} {
        catch {
            uplevel #0 [list source [file join [homedir] skins default standard_includes.tcl]]
            set native_includes_loaded 1
        }
    }
    catch {
        if {![dui page exists aiden_dependency_error]} {dui page add aiden_dependency_error}
        dui add dtext aiden_dependency_error 1280 350 -anchor center -width 2100 \
            -font_size 28 -fill #222222 -text {Aiden could not activate}
        dui add dtext aiden_dependency_error 1280 650 -anchor center -width 2100 \
            -font_size 18 -fill #222222 \
            -text {Required Aiden files are missing or incompatible. Choose another skin or reinstall a compatible Aiden release. Details are in Aiden's startup log.}
        dui add dbutton aiden_dependency_error 700 1050 -bwidth 1100 -bheight 160 \
            -shape round_outline -fill #10382e -outline #10382e -label_fill #ffffff \
            -label {Choose another skin} -command ::aiden::distribution::choose_skin
        # Native explicit Stop remains available when the inspected core matches.
        if {[app_version] eq "1.46.1.1" && \
                [file readable [file join $skin_root aiden core.tcl]]} {
            if {[namespace which -command ::aiden::core::command] eq {}} {
                uplevel #0 [list source [file join $skin_root aiden core.tcl]]
            }
            dui add dbutton aiden_dependency_error 900 1260 -bwidth 700 -bheight 130 \
                -shape round_outline -fill #10382e -outline #10382e -label_fill #ffffff \
                -label {Stop} -command {catch {::aiden::core::command stop}}
        }
        proc ::skins_page_change_due_to_de1_state_change {state} {
            # Preserve native faults/maintenance/refill routing.
            if {$state in {Idle Sleep GoingToSleep Espresso Steam HotWater HotWaterRinse}} {
                ::aiden::distribution::show_failure
            } else {
                ::page_change_due_to_de1_state_change $state
            }
        }
        # Normal app startup selects off; route it to the blocked recovery page.
        set ::nextpage(machine:off) aiden_dependency_error
        after idle ::aiden::distribution::show_failure
    }
    return $status
}
