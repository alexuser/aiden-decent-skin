# SPDX-License-Identifier: GPL-3.0-only
# Aiden 0.1.0-alpha.1; independently selectable DSx2 library wrapper.
# Derived from the GPL de1app/DSx2 loader. No dependency file is changed.
set aiden_skin_root [file dirname [info script]]
# Keep all errors inside this entry: native reset_skin also clears GHC/plugins.
if {[catch {
    package require de1plus 1.0
    source [file join $aiden_skin_root compat.tcl]
    ::aiden::distribution::load $aiden_skin_root
} aiden_startup_problem aiden_startup_options]} {
    if {[namespace which -command ::aiden::distribution::failure] ne {}} {
        catch {::aiden::distribution::failure $aiden_skin_root $aiden_startup_problem $aiden_startup_options}
    } else {
        catch {
            set aiden_error_fd [open [file join $aiden_skin_root startup-error.txt] w]
            puts $aiden_error_fd $aiden_startup_problem
            close $aiden_error_fd
        }
        catch {
            source [file join [homedir] skins default standard_includes.tcl]
            dui page add aiden_dependency_error
            dui add dtext aiden_dependency_error 1280 500 -anchor center -width 2100 \
                -font_size 24 -fill #222222 -text {Aiden installation is incomplete. Reinstall Aiden or select another skin.}
            dui add dbutton aiden_dependency_error 700 1000 -bwidth 1100 -bheight 160 \
                -shape round_outline -fill #10382e -outline #10382e -label_fill #ffffff \
                -label {Choose another skin} -command {backup_settings; dui page load tabletstyles; fill_skin_listbox}
            set ::nextpage(machine:off) aiden_dependency_error
            after idle {dui page load aiden_dependency_error}
        }
    }
}
unset -nocomplain aiden_skin_root aiden_startup_problem aiden_startup_options aiden_error_fd
