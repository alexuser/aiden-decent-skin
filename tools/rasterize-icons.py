#!/usr/bin/env python3
"""Build Aiden icon-only PNGs from this repository's public SVG sources.

Copyright (c) 2026 Aiden contributors.
SPDX-License-Identifier: GPL-3.0-only
Inter fonts are separate unchanged inputs and are never copied by this tool.
Phosphor source/derivative assets retain their MIT notice.
"""

from __future__ import annotations

import argparse
import base64
from io import BytesIO
import os
from pathlib import Path
import shutil
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parent.parent
COLORS = {"soft": "#b7cbd6", "mint": "#8af6d6", "white": "#f4f8fa", "dark": "#10382e"}
SIZES = (40, 56, 72, 112)
DENSITIES = (("2560x1600", 1), ("1920x1200", 0.75), ("1280x800", 0.5))


def icon_sources() -> dict[str, Path]:
    sources: dict[str, Path] = {}
    for folder in (ROOT / "assets/icons/aiden", ROOT / "assets/icons/phosphor"):
        if not folder.is_dir():
            raise ValueError(f"Missing public icon directory: {folder}")
        for source in sorted(folder.glob("*.svg")):
            if source.stem in sources:
                raise ValueError(f"Duplicate icon name: {source.stem}")
            svg = source.read_text(encoding="utf-8")
            if "<!DOCTYPE" in svg or "<!ENTITY" in svg:
                raise ValueError(f"External XML declarations are unsupported: {source.name}")
            tree = ET.fromstring(svg)
            if tree.tag.rsplit("}", 1)[-1] != "svg":
                raise ValueError(f"Not an SVG: {source.name}")
            for node in tree.iter():
                if node.tag.rsplit("}", 1)[-1] not in {"svg", "path", "circle", "rect", "line", "polyline", "polygon", "ellipse", "g", "title", "desc"}:
                    raise ValueError(f"Unsupported SVG element: {source.name}")
                if any(key.rsplit("}", 1)[-1] in {"href", "style"} or key.lower().startswith("on") for key in node.attrib):
                    raise ValueError(f"External or active SVG content is unsupported: {source.name}")
            sources[source.stem] = source
    if not sources:
        raise ValueError("No public SVG icon inputs were found")
    return sources


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT / "aiden/ui-assets")
    parser.add_argument("--check", action="store_true", help="Validate SVG inputs without launching a browser or writing outputs")
    args = parser.parse_args()
    sources = icon_sources()
    notice = ROOT / "LICENSES/MIT-Phosphor.txt"
    if not notice.is_file():
        raise ValueError("Missing Phosphor MIT notice")
    count = len(sources) * len(COLORS) * len(SIZES) * len(DENSITIES)
    if args.check:
        print(f"Validated {len(sources)} public SVG inputs; expected {count} PNG outputs. No files written.")
        return 0

    from PIL import Image
    from playwright.sync_api import sync_playwright

    args.output.mkdir(parents=True, exist_ok=True)
    with sync_playwright() as playwright:
        launch = {"headless": True}
        executable = os.environ.get("AIDEN_CHROMIUM_EXECUTABLE", "").strip()
        if executable:
            launch["executable_path"] = str(Path(executable).expanduser().resolve(strict=True))
        browser = playwright.chromium.launch(**launch)
        try:
            page = browser.new_page(viewport={"width": 120, "height": 120}, device_scale_factor=2)
            for name, source in sources.items():
                svg = source.read_text(encoding="utf-8")
                for tone, color in COLORS.items():
                    data = base64.b64encode(svg.replace("currentColor", color).encode("utf-8")).decode("ascii")
                    for size in SIZES:
                        page.set_viewport_size({"width": size, "height": size})
                        page.set_content(f'<body style="margin:0;background:transparent"><img style="display:block;width:{size}px;height:{size}px" src="data:image/svg+xml;base64,{data}"></body>')
                        master = Image.open(BytesIO(page.screenshot(omit_background=True))).convert("RGBA")
                        for resolution, factor in DENSITIES:
                            dest = args.output / resolution
                            dest.mkdir(exist_ok=True)
                            pixels = max(1, round(size * factor))
                            master.resize((pixels, pixels), Image.Resampling.LANCZOS).save(dest / f"{name}-{tone}-{size}.png")
        finally:
            browser.close()
    shutil.copyfile(notice, args.output / "PHOSPHOR-LICENSE.txt")
    print(f"Built {count} icon PNGs from {len(sources)} public SVGs in {args.output}. Fonts were not copied.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
