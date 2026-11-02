from pathlib import Path
from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parents[1]
RESOURCES = ROOT / "Resources"
RESOURCES.mkdir(exist_ok=True)
SIZE = 1024
image = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))

# Subtle depth under the dark tile.
shadow = Image.new("RGBA", image.size)
shadow_draw = ImageDraw.Draw(shadow)
shadow_draw.rounded_rectangle((58, 66, 966, 974), radius=218, fill=(0, 0, 0, 180))
shadow = shadow.filter(ImageFilter.GaussianBlur(24))
image.alpha_composite(shadow)

# Vertical graphite gradient, kept quiet so the graph remains legible at Dock size.
tile = Image.new("RGBA", image.size)
pixels = tile.load()
for y in range(SIZE):
    t = y / (SIZE - 1)
    color = tuple(round(a + (b - a) * t) for a, b in zip((42, 48, 61), (19, 21, 28)))
    for x in range(SIZE):
        pixels[x, y] = (*color, 255)
mask = Image.new("L", image.size)
ImageDraw.Draw(mask).rounded_rectangle((48, 40, 976, 968), radius=224, fill=255)
image.paste(tile, (0, 0), mask)

draw = ImageDraw.Draw(image)
draw.rounded_rectangle((49, 41, 975, 967), radius=223, outline=(255, 255, 255, 24), width=3)

blue = (70, 157, 255, 255)
orange = (255, 174, 66, 255)
purple = (190, 125, 255, 255)
rail_shadow = (0, 0, 0, 100)

# Three rails: one mainline and two pieces of work branching away.
rails = [
    ([(386, 760), (386, 292)], blue),
    ([(386, 668), (386, 610), (438, 554), (606, 500), (632, 474), (632, 292)], orange),
    ([(386, 530), (386, 486), (346, 446), (270, 414), (236, 386), (236, 292)], purple),
]
for points, color in rails:
    shifted = [(x + 5, y + 9) for x, y in points]
    draw.line(shifted, fill=rail_shadow, width=54, joint="curve")
    draw.line(points, fill=color, width=48, joint="curve")

for x, y, color in [(386, 730, blue), (632, 458, orange), (236, 382, purple)]:
    draw.ellipse((x - 46, y - 46, x + 46, y + 46), fill=(24, 27, 35, 255), outline=color, width=24)

# The latest commit doubles as the "sight" mark: a bright lens around the main rail.
draw.ellipse((278, 174, 494, 390), fill=(23, 26, 34, 255), outline=(236, 244, 255, 255), width=30)
draw.ellipse((338, 234, 434, 330), fill=blue)
draw.ellipse((365, 255, 391, 281), fill=(225, 241, 255, 255))

image.save(RESOURCES / "AppIcon.png")

iconset = ROOT / "Artifacts" / "AppIcon.iconset"
iconset.mkdir(parents=True, exist_ok=True)
for points in (16, 32, 128, 256, 512):
    for scale in (1, 2):
        dimension = points * scale
        suffix = "" if scale == 1 else "@2x"
        resized = image.resize((dimension, dimension), Image.Resampling.LANCZOS)
        resized.save(iconset / f"icon_{points}x{points}{suffix}.png")
