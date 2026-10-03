#!/usr/bin/env python3
"""Build an explicit runtime-only archive; never include local state or device data."""
from pathlib import Path
import hashlib
import json
import zipfile

ROOT = Path(__file__).resolve().parents[1]
VERSION = "0.1.0-alpha.1"
files = [ROOT / name for name in ("skin.tcl", "compat.tcl", "dependency-manifest.tcl", "preflight.tcl", "README.md", "COPYING", "NOTICE", "CHANGELOG.md")]
files += [ROOT / "docs" / (name + ".md") for name in ("install", "removal", "compatibility", "validation", "assets")]
files += [ROOT / "aiden" / (name + ".tcl") for name in ("bootstrap", "app", "core", "lifecycle", "recipe", "modes", "ui")]
files += [ROOT / "LICENSES" / name for name in ("GPL-3.0-only.txt", "OFL-1.1.txt", "MIT-Phosphor.txt")]
files += [ROOT / "aiden/ui-assets" / name for name in ("Inter-Regular.ttf", "Inter-SemiBold.ttf", "INTER-OFL-1.1.txt", "PHOSPHOR-LICENSE.txt")]
icons = json.loads((ROOT / "assets/icons/provenance.json").read_text())["icons"]
for icon in icons:
    source = ROOT / "assets/icons" / icon["file"]
    if hashlib.sha256(source.read_bytes()).hexdigest() != icon["sha256"]:
        raise SystemExit("Icon source changed; review and update provenance first")
for resolution in ("1280x800", "1920x1200", "2560x1600"):
    for icon in icons:
        for tone in ("soft", "mint", "white", "dark"):
            for size in (40, 56, 72, 112):
                files.append(ROOT / "aiden/ui-assets" / resolution / f"{Path(icon['file']).stem}-{tone}-{size}.png")
if any(not p.is_file() or p.is_symlink() for p in files):
    raise SystemExit("Missing or symlinked runtime input")
names = sorted({p.relative_to(ROOT).as_posix() for p in files})
(ROOT / "filelist.txt").write_text("\n".join(names + ["filelist.txt"]) + "\n")
names.append("filelist.txt")
output = ROOT / "dist"
output.mkdir(exist_ok=True)
archive = output / f"Aiden-{VERSION}.zip"
with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_DEFLATED) as z:
    for name in sorted(names):
        info = zipfile.ZipInfo("Aiden/" + name, date_time=(2026, 1, 1, 0, 0, 0))
        info.compress_type = zipfile.ZIP_DEFLATED
        info.external_attr = 0o100644 << 16
        z.writestr(info, (ROOT / name).read_bytes())
manifest = {name: hashlib.sha256((ROOT / name).read_bytes()).hexdigest() for name in sorted(names)}
(output / "SHA256SUMS").write_text(hashlib.sha256(archive.read_bytes()).hexdigest() + "  " + archive.name + "\n")
(output / "runtime-manifest.json").write_text(json.dumps({"version": VERSION, "files": manifest}, indent=2) + "\n")
print(f"Built {archive.name}: {len(names)} allowlisted runtime files")
