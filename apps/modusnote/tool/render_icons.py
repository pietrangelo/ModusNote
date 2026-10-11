"""Renders the platform app icons from assets/brand/modus_app_icon.svg.

The SVG is the source of truth; the PNGs it produces are committed so that
builds need neither a browser nor ImageMagick. Run from apps/modusnote after
changing the SVG:

    python3 tool/render_icons.py [path/to/chrome]

Needs a Chromium binary (headless rasterizer) and ImageMagick `convert`.
"""

import json
import os
import re
import subprocess
import sys
import tempfile

APP = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SOURCE = os.path.join(APP, "assets", "brand", "modus_app_icon.svg")
MASTER = 1024
# iOS-like corner radius, used where the platform does not mask for us.
CORNER = 0.2237

ANDROID = {"mdpi": 48, "hdpi": 72, "xhdpi": 96, "xxhdpi": 144, "xxxhdpi": 192}


def svg_at(size, rounded):
    svg = open(SOURCE).read()
    svg = re.sub(r'width="512" height="512">', f'width="{size}" height="{size}">', svg, count=1)
    if rounded:
        radius = 512 * CORNER
        clip = (
            f'<clipPath id="squircle"><rect width="512" height="512" rx="{radius:.1f}"/></clipPath>\n'
            "  </defs>\n  <g clip-path=\"url(#squircle)\">"
        )
        svg = svg.replace("  </defs>", clip, 1).replace("</svg>", "  </g>\n</svg>")
    return svg


def rasterize(chrome, svg, out, workdir):
    path = os.path.join(workdir, "icon.svg")
    with open(path, "w") as handle:
        handle.write(svg)
    subprocess.run(
        [
            chrome,
            "--headless",
            "--no-sandbox",
            "--disable-gpu",
            "--hide-scrollbars",
            "--default-background-color=00000000",
            # Headless Chromium loses some height to window chrome: render taller, crop.
            f"--window-size={MASTER},{MASTER + 256}",
            f"--screenshot={out}",
            "file://" + path,
        ],
        check=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    subprocess.run(["convert", out, "-crop", f"{MASTER}x{MASTER}+0+0", "+repage", out], check=True)


def resize(master, size, out, opaque=False):
    flags = ["-alpha", "remove", "-alpha", "off"] if opaque else []
    subprocess.run(
        ["convert", master, "-filter", "Lanczos", "-resize", f"{size}x{size}", *flags, "-strip", out],
        check=True,
    )


def main():
    chrome = sys.argv[1] if len(sys.argv) > 1 else os.environ.get(
        "CHROME", "/opt/pw-browsers/chromium-1194/chrome-linux/chrome"
    )
    with tempfile.TemporaryDirectory() as workdir:
        full = os.path.join(workdir, "full.png")
        rounded = os.path.join(workdir, "rounded.png")
        rasterize(chrome, svg_at(MASTER, rounded=False), full, workdir)
        rasterize(chrome, svg_at(MASTER, rounded=True), rounded, workdir)

        for density, size in ANDROID.items():
            resize(rounded, size, os.path.join(APP, f"android/app/src/main/res/mipmap-{density}/ic_launcher.png"))

        # iOS masks the icon itself and rejects an alpha channel.
        iconset = os.path.join(APP, "ios/Runner/Assets.xcassets/AppIcon.appiconset")
        for image in json.load(open(os.path.join(iconset, "Contents.json")))["images"]:
            points = float(image["size"].split("x")[0])
            scale = int(image["scale"].rstrip("x"))
            resize(full, round(points * scale), os.path.join(iconset, image["filename"]), opaque=True)

        web = os.path.join(APP, "web")
        resize(rounded, 16, os.path.join(web, "favicon.png"))
        for size in (192, 512):
            resize(rounded, size, os.path.join(web, f"icons/Icon-{size}.png"))
            resize(full, size, os.path.join(web, f"icons/Icon-maskable-{size}.png"), opaque=True)


if __name__ == "__main__":
    main()
