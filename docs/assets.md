# Asset building

The repository contains 15 project-owned SVG icons and 14 Phosphor regular SVGs
under `assets/icons/`. Their hashes and licenses are recorded in
`assets/icons/provenance.json`. Inter Regular/SemiBold 3.019 font files are
unchanged release inputs under `aiden/ui-assets/`; the builder never copies
fonts from a preview, an installed DSx2 skin or a device.

Use Python and the pinned build tools:

```sh
python3 -m venv .venv
.venv/bin/python -m pip install -r tools/requirements-build.txt
.venv/bin/python -m playwright install chromium
.venv/bin/python tools/rasterize-icons.py --check
.venv/bin/python tools/rasterize-icons.py
```

These setup commands download build tools/browser files into the developer's
environment. They are not bundled in the Aiden package. Playwright's default
Chromium launch is used. An existing Chromium executable can be supplied with
`AIDEN_CHROMIUM_EXECUTABLE=/path/to/chromium`; doing so changes the build
environment and should be recorded if producing a release.

The default output is `aiden/ui-assets/`; `--output PATH` chooses another build
directory. Each SVG produces four tones and logical sizes 40, 56, 72 and 112 at
1280x800, 1920x1200 and 2560x1600 densities. Outputs are icon-only transparent
PNGs. The builder includes the Phosphor MIT notice alongside the rasters.

The fonts require `LICENSES/OFL-1.1.txt` and a copy beside the font files. They
remain OFL-licensed, and Phosphor sources/derivatives remain MIT-licensed. Aiden's
own SVGs/build code use GPL-3.0-only. See `NOTICE` and the full license files.

Pinned package versions improve build consistency, but no bit-for-bit rebuild
comparison has been completed. Record Python, browser and platform versions,
verify hashes, and review the resulting rasters before replacing release assets.
The local Phosphor inputs lack a recorded upstream revision; their exact hashes
are preserved and should be matched to a pinned upstream revision for future
asset updates.
