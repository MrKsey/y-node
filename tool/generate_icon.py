"""Generates the Y-Node launcher icon set.

The mark is a single copper "Y" (for Yggdrasil) with a node dot on each tip, on
a deep teal background. No outline, no mesh ring: the letter fills the tile and
is thick enough to read at 48 px. Everything is drawn at 4x and downsampled, so
the curves stay clean at every density.

Run from the repository root:

    python tool/generate_icon.py
"""

from __future__ import annotations

import os

from PIL import Image, ImageDraw

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT_DIR = os.path.join(ROOT, "assets", "icon")

SIZE = 1024
SS = 4  # supersampling factor
S = SIZE * SS

TEAL_DARK = (5, 46, 43)
TEAL_MID = (13, 106, 99)
TEAL_LIGHT = (16, 130, 120)
COPPER = (217, 119, 6)
COPPER_LIGHT = (245, 158, 11)
COPPER_DEEP = (180, 83, 9)
CREAM = (255, 247, 237)


def lerp(a: tuple[int, int, int], b: tuple[int, int, int], t: float) -> tuple[int, int, int]:
    return (
        int(round(a[0] + (b[0] - a[0]) * t)),
        int(round(a[1] + (b[1] - a[1]) * t)),
        int(round(a[2] + (b[2] - a[2]) * t)),
    )


def background() -> Image.Image:
    """A diagonal teal gradient with a soft highlight behind the mark."""
    img = Image.new("RGB", (S, S), TEAL_DARK)
    draw = ImageDraw.Draw(img)
    for y in range(S):
        t = y / (S - 1)
        draw.line([(0, y), (S, y)], fill=lerp(TEAL_DARK, TEAL_MID, t * 0.95))

    # Radial highlight in the upper middle, drawn as concentric translucent
    # circles: cheap, and the supersampling hides the banding.
    glow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    gdraw = ImageDraw.Draw(glow)
    cx, cy = S * 0.5, S * 0.40
    for i in range(60, 0, -1):
        r = S * 0.42 * (i / 60.0)
        alpha = int(26 * (1 - i / 60.0) ** 1.6)
        gdraw.ellipse([cx - r, cy - r, cx + r, cy + r], fill=(*TEAL_LIGHT, alpha))
    return Image.alpha_composite(img.convert("RGBA"), glow)


def rounded_line(
    draw: ImageDraw.ImageDraw,
    start: tuple[float, float],
    end: tuple[float, float],
    width: int,
    fill: tuple[int, int, int, int],
) -> None:
    draw.line([start, end], fill=fill, width=width)
    r = width / 2
    for (x, y) in (start, end):
        draw.ellipse([x - r, y - r, x + r, y + r], fill=fill)


def mark(scale: float = 1.0, monochrome: bool = False) -> Image.Image:
    """Draws a big, thick Y with a dot on every tip, on a transparent canvas."""
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)

    cx, cy = S / 2, S / 2
    # The letter takes most of the tile: the arms reach the upper corners and the
    # trunk ends near the bottom edge. A thick stroke keeps it readable in the
    # small sizes a status bar or a list uses.
    junction = (cx, cy + S * 0.035 * scale)
    left = (cx - S * 0.255 * scale, cy - S * 0.255 * scale)
    right = (cx + S * 0.255 * scale, cy - S * 0.255 * scale)
    bottom = (cx, cy + S * 0.300 * scale)

    width = int(S * 0.098 * scale)
    color = (255, 255, 255, 255) if monochrome else (*COPPER_LIGHT, 255)
    rounded_line(draw, left, junction, width, color)
    rounded_line(draw, right, junction, width, color)
    rounded_line(draw, junction, bottom, width, color)

    # The tips carry a node dot, a little wider than the stroke: it is what makes
    # the letter read as a network and not as a plain glyph.
    dot = width * 1.25
    for (x, y) in (left, right, bottom):
        draw.ellipse([x - dot, y - dot, x + dot, y + dot], fill=color)

    return img


def save(img: Image.Image, name: str, size: int = SIZE) -> None:
    os.makedirs(OUT_DIR, exist_ok=True)
    out = img.resize((size, size), Image.LANCZOS)
    path = os.path.join(OUT_DIR, name)
    out.save(path, "PNG")
    print(f"wrote {path} ({size}x{size})")


def main() -> None:
    bg = background()

    # Full icon: background plus the mark at full size.
    icon = Image.alpha_composite(bg, mark(scale=1.0))
    save(icon, "icon.png")

    # Adaptive icon layers. Android crops the foreground to a circle or squircle
    # and only guarantees the inner 66%, so the mark shrinks into the safe zone.
    save(bg, "icon_background.png")
    save(mark(scale=0.60), "icon_foreground.png")

    # Monochrome layer for themed icons.
    save(mark(scale=0.60, monochrome=True), "icon_monochrome.png")

    # A round variant, in case a launcher asks for one explicitly.
    round_icon = icon.resize((SIZE, SIZE), Image.LANCZOS)
    mask = Image.new("L", (SIZE, SIZE), 0)
    ImageDraw.Draw(mask).ellipse([0, 0, SIZE - 1, SIZE - 1], fill=255)
    round_icon.putalpha(mask)
    save(round_icon, "icon_round.png")


if __name__ == "__main__":
    main()
