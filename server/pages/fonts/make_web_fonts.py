#!/usr/bin/env python3
"""Builds serv.pub's web fonts from the app's own (assets/fonts).

The pages may load fonts only from their own origin (`font-src 'self'`),
so serv.pub serves these files itself, as the servpub Worker's static
assets. Each is the app's variable font cut to the Latin, punctuation and
symbol ranges the pages declare in `unicode-range` (any other character
falls back to the system's fonts) and compressed as WOFF2.

Run it again when a font in the app changes, and commit the output:

    python3 -m venv /tmp/fonts && /tmp/fonts/bin/pip install fonttools brotli
    /tmp/fonts/bin/python server/pages/fonts/make_web_fonts.py
"""

from pathlib import Path

from fontTools import subset

ROOT = Path(__file__).resolve().parents[3]
SOURCE = ROOT / "apps/modusnote/assets/fonts"
TARGET = ROOT / "server/pages/public/fonts"

# Must match publish::render::UNICODE_RANGE.
UNICODES = "U+0000-024F,U+0259,U+02B0-02FF,U+0300-036F,U+1E00-1EFF,U+2000-206F,U+20A0-20CF,U+2100-218F,U+2190-21FF,U+2200-22FF,U+2600-26FF"

# Name served at /fonts/<name>.woff2 (publish::render::FONT_FILES) and the
# app's file it comes from.
FONTS = {
    "jakarta": "PlusJakartaSans-Variable.ttf",
    "inter": "Inter-Variable.ttf",
    "literata": "reading/Literata-Variable.ttf",
    "literata-italic": "reading/Literata-Italic-Variable.ttf",
    "atkinson": "reading/AtkinsonHyperlegibleNext-Variable.ttf",
    "atkinson-italic": "reading/AtkinsonHyperlegibleNext-Italic-Variable.ttf",
    "quattro": "reading/iAWriterQuattro-Variable.ttf",
    "quattro-italic": "reading/iAWriterQuattro-Italic-Variable.ttf",
}

LICENCES = [
    "Inter-OFL.txt",
    "PlusJakartaSans-OFL.txt",
    "reading/Literata-OFL.txt",
    "reading/AtkinsonHyperlegibleNext-OFL.txt",
    "reading/iAWriterQuattro-OFL.md",
]


def main() -> None:
    TARGET.mkdir(parents=True, exist_ok=True)
    for name, source in FONTS.items():
        options = subset.Options()
        options.flavor = "woff2"
        options.layout_features = ["*"]
        options.name_IDs = ["*"]
        options.name_languages = ["*"]
        options.notdef_outline = True
        options.hinting = False
        font = subset.load_font(str(SOURCE / source), options)
        subsetter = subset.Subsetter(options)
        subsetter.populate(unicodes=subset.parse_unicodes(UNICODES))
        subsetter.subset(font)
        out = TARGET / f"{name}.woff2"
        subset.save_font(font, str(out), options)
        print(f"{out.relative_to(ROOT)}: {out.stat().st_size // 1024} KiB")
    licences = TARGET / "LICENCES.txt"
    licences.write_text(
        "\n\n".join(
            f"== {Path(l).name} ==\n\n" + (SOURCE / l).read_text(encoding="utf-8")
            for l in LICENCES
        ),
        encoding="utf-8",
    )


if __name__ == "__main__":
    main()
