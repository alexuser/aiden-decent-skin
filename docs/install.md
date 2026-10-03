# Installation

The preview requires the pinned de1app 1.46.1.1 / DSx2 3.30 dependencies and a
complete released Aiden package. The package contains the wrapper, dependency
manifest and runtime; a partial checkout is not an installation.
Live operation and updater survival have not been validated.

For development installation, keep the machine Idle with no pending operation,
close de1app, and make a recipient-local backup using the application's supported
backup procedure. Keep that backup on the recipient's device or private storage.
It is not a distribution input and should not be uploaded to this repository.

Extract the release ZIP to create a new `skins/Aiden/` directory with the
version-checked wrapper files at its root and Aiden modules/assets in
`skins/Aiden/aiden/`. Copy only the released file list. Do not overwrite DSx2,
default includes, native launchers, settings, profiles, shot history or plugins.
If `skins/Aiden/` already exists, reconcile it against the prior release's file
list rather than merging an unknown tree.

Select Aiden through the application's normal Styles page. If Aiden is hidden,
disable **Only show most popular skins**, select **Aiden**, then follow the
native Save/exit/restart sequence. Selection uses the native application's skin
settings. Selecting Aiden is the opt-in; no enabled marker is required.

Run `tclsh preflight.tcl /path/to/de1plus` before selecting Aiden, using
a Tcl installation with tcllib sha256 available. It reads the installed
dependency without executing it or changing settings. The same check runs
at startup. A missing or different required file blocks activation and opens
a recovery screen instead of allowing the app to reset plugin/GHC settings. Restore the previously selected native skin using
the application's supported selection/recovery procedure. Do not disable the
guard to force a mismatched installation to load.

Do not install the private development launcher patch. The native application
connects before skin loading and may request Idle on connection. This preview
does not guarantee that the machine stays asleep when the app is launched.

Before using machine actions, the release must pass the attended checks in
[validation](validation.md). Until then, use fake-only tests for development.
An application or skin update can change files and invalidate the pinned
manifest; updater survival has not been tested.
