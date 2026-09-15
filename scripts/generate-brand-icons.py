#!/usr/bin/env python3
"""Generate macOS icon derivatives from the official Square JPG (requires Pillow)."""
from pathlib import Path
from PIL import Image, ImageOps

ROOT = Path(__file__).resolve().parents[1]
BRAND = ROOT / "stts/Resources/Brand"
image = Image.open(BRAND / "a2gent.jpg").convert("RGB")
for size in [16, 32, 64, 128, 256, 512, 1024]:
    image.resize((size, size), Image.Resampling.LANCZOS).save(
        ROOT / f"stts/Assets.xcassets/AppIcon.appiconset/icon_{size}x{size}.png"
    )

# Remove the white background to let AppKit tint the mark for any menu-bar theme.
alpha = ImageOps.grayscale(image).point(
    lambda value: max(0, min(255, int((245 - value) * 255 / 170)))
)
alpha = alpha.crop(alpha.point(lambda value: 255 if value > 80 else 0).getbbox())
alpha.thumbnail((64, 64), Image.Resampling.LANCZOS)
mask = Image.new("L", (72, 72))
mask.paste(alpha, ((72 - alpha.width) // 2, (72 - alpha.height) // 2))
icon = Image.new("RGBA", (72, 72), (0, 0, 0, 0))
icon.putalpha(mask)
icon.save(BRAND / "status-icon.png")
