#!/usr/bin/env python3
# Venv activation is handled by the caller (switchwall.sh sources the venv before invoking this)
import argparse
import math
import json
import re
import sys
from PIL import Image
from materialyoucolor.quantize import QuantizeCelebi
from materialyoucolor.score.score import Score
from materialyoucolor.hct import Hct
from materialyoucolor.dynamiccolor.material_dynamic_colors import MaterialDynamicColors
from materialyoucolor.utils.color_utils import rgba_from_argb, argb_from_rgb
from materialyoucolor.utils.math_utils import (
    sanitize_degrees_double, difference_degrees, rotation_direction
)

# ---------------------------------------------------------------------------
# Scheme registry — add new schemes here without touching the rest of the code
# ---------------------------------------------------------------------------
SCHEME_MAP = {
    "scheme-content":     "materialyoucolor.scheme.scheme_content:SchemeContent",
    "scheme-expressive":  "materialyoucolor.scheme.scheme_expressive:SchemeExpressive",
    "scheme-fidelity":    "materialyoucolor.scheme.scheme_fidelity:SchemeFidelity",
    "scheme-fruit-salad": "materialyoucolor.scheme.scheme_fruit_salad:SchemeFruitSalad",
    "scheme-monochrome":  "materialyoucolor.scheme.scheme_monochrome:SchemeMonochrome",
    "scheme-neutral":     "materialyoucolor.scheme.scheme_neutral:SchemeNeutral",
    "scheme-rainbow":     "materialyoucolor.scheme.scheme_rainbow:SchemeRainbow",
    "scheme-tonal-spot":  "materialyoucolor.scheme.scheme_tonal_spot:SchemeTonalSpot",
    "scheme-vibrant":     "materialyoucolor.scheme.scheme_vibrant:SchemeVibrant",
}
DEFAULT_SCHEME = "scheme-tonal-spot"

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
parser = argparse.ArgumentParser(description="Material You color generation script")
parser.add_argument("--path",   type=str, default=None, help="Generate colorscheme from image path")
parser.add_argument("--size",   type=int, default=128,  help="Bitmap image size for quantization")
parser.add_argument("--color",  type=str, default=None, help="Generate colorscheme from hex color")
parser.add_argument("--mode",   type=str, choices=["dark", "light"], default="dark", help="Dark or light mode")
parser.add_argument("--scheme", type=str, default=DEFAULT_SCHEME,
                    choices=list(SCHEME_MAP.keys()), help="Material scheme to use")
parser.add_argument("--smart",          action="store_true", default=False, help="Auto-select scheme based on image colorfulness")
parser.add_argument("--transparency",   type=str, choices=["opaque", "transparent"], default="opaque")
parser.add_argument("--termscheme",     type=str, default=None, help="JSON file with terminal color scheme")
parser.add_argument("--harmony",        type=float, default=0.8,  help="(0-1) Hue shift strength toward accent")
parser.add_argument("--harmonize_threshold", type=float, default=100, help="(0-180) Max hue shift angle")
parser.add_argument("--term_fg_boost",  type=float, default=0.35, help="Boost terminal fg/bg contrast")
parser.add_argument("--blend_bg_fg",    action="store_true", default=False, help="Shift terminal bg/fg toward accent")
parser.add_argument("--cache",    type=str, default=None, help="File path to cache the dominant color hex")
parser.add_argument("--json-out", type=str, default=None, help="Write colors as JSON to this path (for MaterialThemeLoader)")
parser.add_argument("--debug",    action="store_true", default=False, help="Print debug info instead of SCSS")
args = parser.parse_args()

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
rgba_to_hex  = lambda rgba: "#{:02X}{:02X}{:02X}".format(rgba[0], rgba[1], rgba[2])
argb_to_hex  = lambda argb: "#{:02X}{:02X}{:02X}".format(*map(round, rgba_from_argb(argb)))
hex_to_argb  = lambda h:    argb_from_rgb(int(h[1:3], 16), int(h[3:5], 16), int(h[5:], 16))
display_color = lambda rgba: "\x1B[38;2;{};{};{}m{}\x1B[0m".format(
    rgba[0], rgba[1], rgba[2], "\x1b[7m   \x1b[7m"
)

def calculate_optimal_size(width: int, height: int, bitmap_size: int) -> tuple[int, int]:
    image_area  = width * height
    bitmap_area = bitmap_size ** 2
    scale = math.sqrt(bitmap_area / image_area) if image_area > bitmap_area else 1
    return max(1, round(width * scale)), max(1, round(height * scale))

def harmonize(design_color: int, source_color: int,
              threshold: float = 35, harmony: float = 0.5) -> int:
    from_hct = Hct.from_int(design_color)
    to_hct   = Hct.from_int(source_color)
    diff     = difference_degrees(from_hct.hue, to_hct.hue)
    rotation = min(diff * harmony, threshold)
    output_hue = sanitize_degrees_double(
        from_hct.hue + rotation * rotation_direction(from_hct.hue, to_hct.hue)
    )
    return Hct.from_hct(output_hue, from_hct.chroma, from_hct.tone).to_int()

def boost_chroma_tone(argb: int, chroma: float = 1, tone: float = 1) -> int:
    hct = Hct.from_int(argb)
    return Hct.from_hct(hct.hue, hct.chroma * chroma, hct.tone * tone).to_int()

def camel_to_snake(name: str) -> str:
    s1 = re.sub(r'(.)([A-Z][a-z]+)', r'\1_\2', name)
    return re.sub(r'([a-z0-9])([A-Z])', r'\1_\2', s1).lower()

def load_scheme_class(name: str):
    """Dynamically import a scheme class from SCHEME_MAP."""
    module_path, class_name = SCHEME_MAP[name].rsplit(":", 1)
    import importlib
    module = importlib.import_module(module_path)
    return getattr(module, class_name)

# ---------------------------------------------------------------------------
# Validate that at least one input source was provided
# ---------------------------------------------------------------------------
if args.path is None and args.color is None:
    parser.error("At least one of --path or --color must be provided.")

# ---------------------------------------------------------------------------
# Source color extraction
# ---------------------------------------------------------------------------
darkmode    = args.mode == "dark"
transparent = args.transparency == "transparent"
wsize = hsize = wsize_new = hsize_new = None  # kept for debug output

if args.path is not None:
    image = Image.open(args.path)

    if image.format == "GIF":
        try:
            image.seek(1)
        except EOFError:
            image.seek(0)
    if image.mode in ("L", "P"):
        image = image.convert("RGB")

    wsize, hsize = image.size
    wsize_new, hsize_new = calculate_optimal_size(wsize, hsize, args.size)
    if wsize_new < wsize or hsize_new < hsize:
        image = image.resize((wsize_new, hsize_new), Image.Resampling.BICUBIC)

    colors = QuantizeCelebi(list(image.getdata()), 128)
    argb   = Score.score(colors)[0]

    if args.cache is not None:
        with open(args.cache, "w") as f:
            f.write(argb_to_hex(argb))

    hct = Hct.from_int(argb)
    if args.smart and hct.chroma < 20:
        args.scheme = "scheme-neutral"

elif args.color is not None:
    color_hex = args.color if args.color.startswith("#") else f"#{args.color}"
    argb = hex_to_argb(color_hex)
    hct  = Hct.from_int(argb)

# ---------------------------------------------------------------------------
# Scheme generation
# ---------------------------------------------------------------------------
Scheme = load_scheme_class(args.scheme)
scheme = Scheme(hct, darkmode, 0.0)

material_colors: dict[str, str] = {}
term_colors:     dict[str, str] = {}

for color in vars(MaterialDynamicColors).keys():
    color_attr = getattr(MaterialDynamicColors, color)
    if hasattr(color_attr, "get_hct"):
        rgba = color_attr.get_hct(scheme).to_rgba()
        material_colors[color] = rgba_to_hex(rgba)

# Extended material colors not in the standard palette
# Base success greens, harmonized toward the wallpaper's primary key color
_success_base = {
    "dark": {
        "success":            "#B5CCBA",
        "onSuccess":          "#213528",
        "successContainer":   "#374B3E",
        "onSuccessContainer": "#D1E9D6",
    },
    "light": {
        "success":            "#4F6354",
        "onSuccess":          "#FFFFFF",
        "successContainer":   "#D1E8D5",
        "onSuccessContainer": "#0C1F13",
    },
}
_primary_argb = hex_to_argb(material_colors.get("primary_paletteKeyColor", argb_to_hex(argb)))
_mode_key = "dark" if darkmode else "light"
for _name, _hex in _success_base[_mode_key].items():
    _harmonized = harmonize(hex_to_argb(_hex), _primary_argb, args.harmonize_threshold, args.harmony * 0.5)
    material_colors[_name] = argb_to_hex(_harmonized)

# ---------------------------------------------------------------------------
# Terminal color harmonization
# ---------------------------------------------------------------------------
if args.termscheme is not None:
    with open(args.termscheme, "r") as f:
        term_source_colors: dict[str, str] = json.load(f)["dark" if darkmode else "light"]

    primary_argb = hex_to_argb(material_colors["primary_paletteKeyColor"])

    for color, val in term_source_colors.items():
        if args.scheme == "scheme-monochrome":
            term_colors[color] = val
            continue

        if args.blend_bg_fg and color == "term0":
            result = boost_chroma_tone(
                hex_to_argb(material_colors["surfaceContainerLow"]), 1.2, 0.95
            )
        elif args.blend_bg_fg and color == "term15":
            result = boost_chroma_tone(hex_to_argb(material_colors["onSurface"]), 3, 1)
        else:
            result = harmonize(
                hex_to_argb(val), primary_argb,
                args.harmonize_threshold, args.harmony
            )
            result = boost_chroma_tone(
                result, 1, 1 + args.term_fg_boost * (1 if darkmode else -1)
            )
        term_colors[color] = argb_to_hex(result)

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------
if args.json_out is not None:
    json_colors = {
        camel_to_snake(k): v
        for k, v in material_colors.items()
        if "palette" not in k.lower() and not k.startswith("term")
    }
    import os
    os.makedirs(os.path.dirname(args.json_out), exist_ok=True)
    with open(args.json_out, "w") as f:
        json.dump(json_colors, f, indent=2)

if not args.debug:
    print(f"$darkmode: {darkmode};")
    print(f"$transparent: {transparent};")
    for color, code in material_colors.items():
        print(f"${color}: {code};")
    for color, code in term_colors.items():
        print(f"${color}: {code};")
else:
    if args.path is not None:
        print("\n--------------Image properties-----------------")
        print(f"Image size:    {wsize} x {hsize}")
        print(f"Resized image: {wsize_new} x {hsize_new}")
    print("\n---------------Selected color------------------")
    print(f"Dark mode: {darkmode}")
    print(f"Scheme:    {args.scheme}")
    print(f"Accent:    {display_color(rgba_from_argb(argb))} {argb_to_hex(argb)}")
    print(f"HCT:       {hct.hue:.2f}  {hct.chroma:.2f}  {hct.tone:.2f}")
    print("\n---------------Material colors-----------------")
    for color, code in material_colors.items():
        rgba = rgba_from_argb(hex_to_argb(code))
        print(f"{color.ljust(32)} : {display_color(rgba)}  {code}")
    print("\n----------Harmonize terminal colors------------")
    for color, code in term_colors.items():
        rgba        = rgba_from_argb(hex_to_argb(code))
        code_source = term_source_colors[color]
        rgba_source = rgba_from_argb(hex_to_argb(code_source))
        print(f"{color.ljust(6)} : {display_color(rgba_source)} {code_source} --> {display_color(rgba)} {code}")
    print("-----------------------------------------------")
