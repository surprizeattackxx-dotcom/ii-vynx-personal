#!/usr/bin/env python3
import sys

try:
    import cv2
    import numpy as np
except ImportError:
    # cv2 unavailable — fall back to a safe default immediately
    print("scheme-tonal-spot")
    sys.exit(0)

# ---------------------------------------------------------------------------
# Valid scheme names (single source of truth)
# ---------------------------------------------------------------------------
SCHEMES = [
    "scheme-content",
    "scheme-expressive",
    "scheme-fidelity",
    "scheme-fruit-salad",
    "scheme-monochrome",
    "scheme-neutral",
    "scheme-rainbow",
    "scheme-tonal-spot",
    "scheme-vibrant",
]

# ---------------------------------------------------------------------------
# Colorfulness metric (Hasler & Süsstrunk)
# ---------------------------------------------------------------------------
def image_colorfulness(image: np.ndarray) -> float:
    (B, G, R) = cv2.split(image.astype("float"))
    rg = np.absolute(R - G)
    yb = np.absolute(0.5 * (R + G) - B)
    colorfulness = (
        np.sqrt(np.std(rg) ** 2 + np.std(yb) ** 2)
        + 0.3 * np.sqrt(np.mean(rg) ** 2 + np.mean(yb) ** 2)
    )
    return float(colorfulness)

# ---------------------------------------------------------------------------
# Average brightness (0-255)
# ---------------------------------------------------------------------------
def image_brightness(image: np.ndarray) -> float:
    gray = cv2.cvtColor(image, cv2.COLOR_BGR2GRAY)
    return float(np.mean(gray))

# ---------------------------------------------------------------------------
# Scheme selection — uses colorfulness and brightness to pick from all schemes
# Thresholds (tuneable via CLI):
#   t1 < t2 < t3 < t4  — colorfulness breakpoints
#   brightness_mid      — splits high-colorfulness branch into bright vs dark
# ---------------------------------------------------------------------------
def pick_scheme(colorfulness: float, brightness: float,
                t1: float = 20, t2: float = 40, t3: float = 70, t4: float = 100,
                brightness_mid: float = 128) -> str:
    if colorfulness < t1:
        # Very muted / near-greyscale
        return "scheme-monochrome"
    elif colorfulness < t2:
        # Low colour — neutral tones, overcast skies
        return "scheme-neutral"
    elif colorfulness < t3:
        # Moderate colour — most natural photos
        return "scheme-tonal-spot"
    elif colorfulness < t4:
        # Moderately vivid — illustrative art, stylised photos
        # Bright images → fruit-salad (playful hue rotation)
        # Dark images   → content (faithful to source)
        return "scheme-fruit-salad" if brightness > brightness_mid else "scheme-content"
    else:
        # Highly colourful — vivid artwork, sunsets, neon
        # Very bright → rainbow (maximum hue variety)
        # Bright      → expressive (bold, energetic)
        # Dark        → fidelity (accurate to image colors)
        # Very dark   → vibrant (punchy, saturated)
        if brightness > 200:
            return "scheme-rainbow"
        elif brightness > brightness_mid:
            return "scheme-expressive"
        elif brightness > 64:
            return "scheme-fidelity"
        else:
            return "scheme-vibrant"

# ---------------------------------------------------------------------------
# Image loading with resize
# ---------------------------------------------------------------------------
def load_and_resize_image(img_path: str, max_dim: int = 128):
    img = cv2.imread(img_path)
    if img is None:
        return None
    h, w = img.shape[:2]
    if max(h, w) > max_dim:
        scale = max_dim / max(h, w)
        img = cv2.resize(img, (int(w * scale), int(h * scale)),
                         interpolation=cv2.INTER_AREA)
    return img

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def main() -> None:
    import argparse
    parser = argparse.ArgumentParser(description="Auto-detect Material You scheme from image")
    parser.add_argument("image", nargs="?", default=None, help="Path to image")
    parser.add_argument("--colorfulness", action="store_true", help="Print colorfulness score and exit")
    parser.add_argument("--brightness",   action="store_true", help="Print brightness score and exit")
    parser.add_argument("--t1", type=float, default=20,  help="Colorfulness threshold: monochrome below this (default: 20)")
    parser.add_argument("--t2", type=float, default=40,  help="Colorfulness threshold: neutral below this (default: 40)")
    parser.add_argument("--t3", type=float, default=70,  help="Colorfulness threshold: tonal-spot below this (default: 70)")
    parser.add_argument("--t4", type=float, default=100, help="Colorfulness threshold: fruit-salad/content below this (default: 100)")
    parser.add_argument("--brightness-mid", type=float, default=128, help="Brightness midpoint for scheme branching (default: 128)")
    args = parser.parse_args()

    if args.image is None:
        print("scheme-tonal-spot")
        sys.exit(0)

    img = load_and_resize_image(args.image)
    if img is None:
        print("scheme-tonal-spot", file=sys.stderr)
        print("scheme-tonal-spot")
        sys.exit(0)

    colorfulness = image_colorfulness(img)
    brightness   = image_brightness(img)

    if args.colorfulness:
        print(f"{colorfulness:.2f}")
    elif args.brightness:
        print(f"{brightness:.2f}")
    else:
        scheme = pick_scheme(colorfulness, brightness,
                             args.t1, args.t2, args.t3, args.t4, args.brightness_mid)
        print(scheme)

if __name__ == "__main__":
    main()
