# Validation status

**0.1.0-alpha.1 is a developer preview, not machine validated. App-update survival is untested.**

Run `python3 tools/check.py` with Tcl 8.5+ and tcllib. The portable suites use
synthetic profiles/settings and fake native APIs. They cover guarded commands,
recipe precision and cancellation, workflow transitions, native legacy page
routing, dependency validation, and startup recovery. The UI fixture checks
nine native pages, disabled controls, stable Stop targets and missing telemetry.
Two source-reference tests are optional and require local reference directories;
those directories must never be committed or distributed.

On 2026-10-03, physical Android tablet checks verified standalone launch under
Aiden, its entry in the native skin selector, profile search and preview,
recipe draft arithmetic/cancellation, mode draft cancellation, workflow preview,
graph detail, native history return, and native home return. A deliberately
withheld Aiden manifest opened recovery and the native skin selector. Restoring
the manifest restored startup. App settings and DSx2 preferences stayed unchanged
apart from the explicitly selected skin; original profile content was preserved.
Machine connection was unavailable throughout these checks. The private test
installation retained its existing startup wake guard; that guard is not shipped.

The QA pass fixed live ratio preview, crowded Steam notes, a duplicated empty
result heading, opaque Bluetooth handle interpretation, startup-error propagation,
and legacy pages lacking explicit DUI background markers. Static screenshots do
not establish animation frame timing or physical machine behavior.

Before a stable release, complete attended espresso/flush/steam/hot-water tests,
UI and physical Stop, scale loss/settling, disconnect/reconnect, GHC handoff,
safety notices, post-shot preparation and completed-result/history behavior.
Every next operation still needs an explicit Start. Test removal/rollback and
real app updates separately, including dependency mismatch recovery and data
preservation. Do not merge the upstream inclusion draft until those gates pass.

Release artifacts use an explicit file set, include asset licenses and exclude
settings, profiles, history, device identifiers, private screenshots and backups.
