# Removal and rollback

These are the intended removal steps for a complete Aiden wrapper package.
They must be validated for the supported runtime before a stable release.

When the machine is Idle and no operation is pending, select the previous
native skin through Styles and follow the native Save/exit/restart sequence.
Verify that the native skin loads before closing the application to remove
the released `skins/Aiden/` files.

Remove only Aiden package files listed by the installed release manifest.
Recipient-created Aiden state should be handled as local user data: preserve it
privately if the recipient wants to retain favorites/workflows/adjustments.
Do not delete DSx2, default includes, native profiles, shot history, plugins or
settings. Never restore a developer's settings snapshot.

The selectable wrapper is designed to avoid global launcher and DSx2 patches.
If migrating from a private patched deployment, use that deployment's own
verified rollback record; this public package has no authority to overwrite
those files. Preserve any settings changed after installation.

If the wrapper cannot load because dependencies changed, recover the previously
working native skin using the application's supported recovery path. A backup
can help recover damaged files, but should not replace later settings/history
without reconciliation. Keep recovery records private.

Updater survival is unvalidated. Do not assume that an application update will
retain Aiden, keep dependencies compatible, or preserve the selected wrapper.
