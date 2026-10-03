# Compatibility

This developer preview targets de1app **1.46.1.1** and DSx2 **3.30**. Aiden's
wrapper uses a separately installed DSx2 skin and native default includes. The
wrapper is being prepared with hashes for the required code and existing
dependency fonts; a version label alone is insufficient if those files changed.

The intended installed layout is `skins/Aiden/` containing the Aiden wrapper and
an `aiden/` runtime subdirectory. The dependency paths normally resolve to
`skins/DSx2/` and `skins/default/`. The wrapper retains Aiden as the selected skin
and must not load a recipient's private DSx2 startup/end customizations or a
DSx2-local Aiden deployment. Dependencies remain in their own directories.

An absent or changed pinned dependency must stop wrapper loading before its
dependency scripts and Aiden state files are created. Do not bypass the check,
rename a different version to match, or replace recipient settings with a
development snapshot. Recheck the native API contract and update the manifest
with appropriate tests before supporting another version.

Native machine control, safety notices, history persistence, advanced recipe
editors, maintenance and plugins remain provided by de1app/DSx2. Native font and
symbol fallback providers are external dependencies. Aiden bundles only the
separately licensed Inter font files and its listed icon assets.

Generated icon rasters cover 1280x800, 1920x1200 and 2560x1600. Resolution asset
coverage is not proof of layout or hardware compatibility on each tablet.

Native BLE initialization occurs before skin loading. Dependency rejection or
read-only Aiden startup cannot undo native connection behavior; the application
can enter Idle on first connection. This preview makes no asleep-at-launch
guarantee. Live operation and updater survival remain unvalidated.
