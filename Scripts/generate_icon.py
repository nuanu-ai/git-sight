"""Draws the git-sight app icon: a loupe over a commit graph."""

import math
from pathlib import Path
from PIL import Image, ImageChops, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parents[1]
RESOURCES = ROOT / "Resources"
RESOURCES.mkdir(exist_ok=True)

SIZE = 1024
SS = 2  # draw at 2x and downsample for clean edges
S = SIZE * SS


def px(value):
    return round(value * SS)


def box(cx, cy, r):
    return (px(cx - r), px(cy - r), px(cx + r), px(cy + r))


def vertical_gradient(top, bottom, size=S):
    strip = Image.new("RGBA", (1, 256))
    for y in range(256):
        t = y / 255
        strip.putpixel((0, y), tuple(round(a + (b - a) * t) for a, b in zip(top, bottom)))
    return strip.resize((size, size), Image.Resampling.BICUBIC)


def radial_gradient(inner, outer, size):
    mask = Image.radial_gradient("L").resize((size, size), Image.Resampling.BICUBIC)
    return Image.composite(Image.new("RGBA", (size, size), outer), Image.new("RGBA", (size, size), inner), mask)


def squircle_mask(left, top, side, extent=286, exponent=3.8, steps=200):
    """Rounded square whose corners are superellipse quarters: straight sides,
    curvature easing into the corner like Apple's continuous corners."""
    right, bottom = left + side, top + side
    corners = [(right - extent, bottom - extent, 1, 1), (left + extent, bottom - extent, -1, 1),
               (left + extent, top + extent, -1, -1), (right - extent, top + extent, 1, -1)]
    points = []
    for k, (cx, cy, sx, sy) in enumerate(corners):
        for i in range(steps + 1):
            a = (math.pi / 2) * i / steps
            if k % 2:
                a = math.pi / 2 - a
            x = extent * math.cos(a) ** (2 / exponent)
            y = extent * math.sin(a) ** (2 / exponent)
            points.append((px(cx + sx * x), px(cy + sy * y)))
    mask = Image.new("L", (S, S))
    ImageDraw.Draw(mask).polygon(points, fill=255)
    return mask


def stroke(draw, points, width, fill):
    """Round-capped stroke: stamp discs densely along the polyline."""
    r = width / 2
    for (x0, y0), (x1, y1) in zip(points, points[1:]):
        steps = max(1, int(math.hypot(x1 - x0, y1 - y0) / 1.5))
        for i in range(steps + 1):
            t = i / steps
            draw.ellipse(box(x0 + (x1 - x0) * t, y0 + (y1 - y0) * t, r), fill=fill)


def cubic(p0, p1, p2, p3, steps=80):
    out = []
    for i in range(steps + 1):
        t = i / steps
        u = 1 - t
        out.append(tuple(u**3 * a + 3 * u * u * t * b + 3 * u * t * t * c + t**3 * d
                         for a, b, c, d in zip(p0, p1, p2, p3)))
    return out


def layer():
    return Image.new("RGBA", (S, S), (0, 0, 0, 0))


def masked(image, mask):
    out = image.copy()
    out.putalpha(ImageChops.multiply(image.getchannel("A"), mask))
    return out


canvas = layer()

# Tile on Apple's grid: 824 px, centered, continuous corners.
TILE_LEFT, TILE_SIDE = 100, 824
tile_mask = squircle_mask(TILE_LEFT, TILE_LEFT, TILE_SIDE)

shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
shadow.putalpha(ImageChops.offset(tile_mask, 0, px(12)).point(lambda v: v * 0.45))
canvas.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(px(14))))

tile = vertical_gradient((52, 104, 214), (18, 30, 96))
glow = radial_gradient((96, 150, 255, 120), (96, 150, 255, 0), px(900))
tile.alpha_composite(glow, (px(512 - 450), px(470 - 450)))
canvas.alpha_composite(masked(tile, tile_mask))

# Faint inner rim, brighter on top, as on Apple's tiles.
rim = layer()
inner = ImageChops.offset(tile_mask, 0, px(3))
rim_alpha = ImageChops.subtract(tile_mask, inner)
rim.paste((255, 255, 255, 255), (0, 0), rim_alpha.point(lambda v: v * 0.35))
canvas.alpha_composite(rim)

# A loupe: the lens sits up and to the left, the handle runs to the lower right.
CX, CY = 470, 468
RING_OUTER, RING_INNER = 262, 216
HANDLE_ANGLE = math.radians(45)
HANDLE_FROM, HANDLE_TO, HANDLE_WIDTH = 236, 418, 96


def along(distance):
    return (CX + distance * math.cos(HANDLE_ANGLE), CY + distance * math.sin(HANDLE_ANGLE))


silver = vertical_gradient((250, 252, 255), (172, 186, 220))

drop = layer()
dd = ImageDraw.Draw(drop)
dd.ellipse(box(CX, CY + 20, RING_OUTER), fill=(6, 12, 48, 150))
stroke(dd, [(x, y + 20) for x, y in (along(HANDLE_FROM), along(HANDLE_TO))], HANDLE_WIDTH, (6, 12, 48, 150))
canvas.alpha_composite(drop.filter(ImageFilter.GaussianBlur(px(22))))

handle_mask = layer()
stroke(ImageDraw.Draw(handle_mask), [along(HANDLE_FROM), along(HANDLE_TO)], HANDLE_WIDTH, (255, 255, 255, 255))
handle_mask = handle_mask.getchannel("A")
canvas.alpha_composite(masked(silver, handle_mask))
ring_mask = Image.new("L", (S, S))
ring_draw = ImageDraw.Draw(ring_mask)
ring_draw.ellipse(box(CX, CY, RING_OUTER), fill=255)
ring_draw.ellipse(box(CX, CY, RING_INNER), fill=0)
canvas.alpha_composite(masked(silver, ring_mask))

# Glass: deep navy, lighter toward the middle.
glass_mask = Image.new("L", (S, S))
ImageDraw.Draw(glass_mask).ellipse(box(CX, CY, RING_INNER), fill=255)
glass = layer()
glass.alpha_composite(radial_gradient((32, 52, 126, 255), (10, 16, 52, 255), px(RING_INNER * 2)),
                      (px(CX - RING_INNER), px(CY - RING_INNER)))
canvas.alpha_composite(masked(glass, glass_mask))

# Commit graph seen through the lens: a mainline and one branch that went its own way.
graph = layer()
g = ImageDraw.Draw(graph)
MAIN_X, BRANCH_X = CX - 62, CX + 74
OLD_Y, FORK_Y, TIP_Y = CY - 112, CY + 104, CY - 84
LANE, DOT, GAP = 36, 34, 14
lane_color = (226, 236, 255, 255)
amber = (255, 178, 62, 255)
glass_tone = (20, 32, 88, 255)

stroke(g, [(MAIN_X, CY - RING_INNER - 20), (MAIN_X, CY + RING_INNER + 20)], LANE, lane_color)
branch = cubic((MAIN_X, FORK_Y), (MAIN_X, FORK_Y - 100), (BRANCH_X, FORK_Y - 70), (BRANCH_X, FORK_Y - 170))
stroke(g, branch + [(BRANCH_X, TIP_Y)], LANE, amber)

for y in (OLD_Y, FORK_Y):
    g.ellipse(box(MAIN_X, y, DOT + GAP), fill=glass_tone)
    g.ellipse(box(MAIN_X, y, DOT), fill=lane_color)

tip_glow = layer()
ImageDraw.Draw(tip_glow).ellipse(box(BRANCH_X, TIP_Y, DOT + 26), fill=(255, 170, 50, 140))
graph.alpha_composite(tip_glow.filter(ImageFilter.GaussianBlur(px(16))))
g.ellipse(box(BRANCH_X, TIP_Y, DOT + GAP), fill=glass_tone)
g.ellipse(box(BRANCH_X, TIP_Y, DOT + 2), fill=amber)

canvas.alpha_composite(masked(graph, glass_mask))

# Glass reflection: a soft crescent in the upper left.
sheen = layer()
sd = ImageDraw.Draw(sheen)
sd.ellipse(box(CX - 34, CY - 50, RING_INNER - 18), fill=(255, 255, 255, 44))
sd.ellipse(box(CX + 8, CY + 8, RING_INNER + 8), fill=(0, 0, 0, 0))
canvas.alpha_composite(masked(sheen.filter(ImageFilter.GaussianBlur(px(6))), glass_mask))

# Thin dark bevel where glass meets the ring.
bevel = layer()
ImageDraw.Draw(bevel).ellipse(box(CX, CY, RING_INNER), outline=(8, 14, 46, 200), width=px(5))
canvas.alpha_composite(bevel)

image = canvas.resize((SIZE, SIZE), Image.Resampling.LANCZOS)
image.save(RESOURCES / "AppIcon.png")

iconset = ROOT / "Artifacts" / "AppIcon.iconset"
iconset.mkdir(parents=True, exist_ok=True)
for points in (16, 32, 128, 256, 512):
    for scale in (1, 2):
        dimension = points * scale
        suffix = "" if scale == 1 else "@2x"
        resized = image.resize((dimension, dimension), Image.Resampling.LANCZOS)
        resized.save(iconset / f"icon_{points}x{points}{suffix}.png")
