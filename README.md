# Aiden

**0.1.0-alpha.1 is a developer preview. Live machine operation and updater
survival have not been validated.**

Aiden presents a focused native interface for espresso, flush, steam and hot
water. It uses de1app's machine APIs, safety state, history writer and native
editors. The independently selectable Aiden skin wrapper uses an existing DSx2
installation as a dependency; it does not modify that skin.

The preview targets **de1app 1.46.1.1 and DSx2 3.30**. The wrapper checks its
pinned dependency files before loading them. A mismatch must block Aiden
activation. This repository does not distribute de1app, DSx2, firmware, native
plugins or FontAwesome. Install those dependencies through their own supported
channels. See [compatibility](docs/compatibility.md).

Aiden provides operation views, explicit Start/Stop/Wake actions, guarded
recipe drafts and working adjustments, named profile copies, mode settings,
beverage workflows and routes back to the native interface. Draft browsing and
Cancel do not apply changes. Saved profile definitions stay separate from
working adjustments; unsupported custom profiles use the native editor.
Missing measurements remain unknown.

The native application initializes BLE before loading a skin and can request
Idle on connection. Aiden does not guarantee that launching the application
leaves a sleeping machine asleep. The private deployment used a separate launch
guard; that deployment change is not part of this public preview.

Host tests use fake native APIs and synthetic settings/profiles. They do not
establish physical Start/Stop behavior, BLE timing, scale settling, GHC behavior,
completed beverages or safe updater handling. The release gates are recorded in
[validation](docs/validation.md). Use this preview for source review and
development until attended checks are complete.

[Installation](docs/install.md) and [removal](docs/removal.md) describe the
tested wrapper layout and native skin selection. A complete version-checked
package is required; copying a partial checkout is not an installation.

New Aiden code, synthetic tests, build scripts and project-owned icons are
licensed under GNU GPL version 3 only; see [COPYING](COPYING). Inter 3.019 fonts
retain SIL OFL 1.1, and Phosphor icons retain MIT. Full notices are in
[NOTICE](NOTICE) and [LICENSES](LICENSES). The icon build uses public SVG inputs
and does not copy fonts or settings from a device. See
[asset building](docs/assets.md) and the
[attribution inventory](docs/attribution-inventory.json).

Run isolated tests with `python3 tools/check.py`. Build the runtime ZIP with
`python3 tools/build-release.py`. Before selecting the skin, run
`tclsh preflight.tcl /path/to/de1plus` against the recipient installation.
The preflight reads hashes only and does not execute the installed dependency.
