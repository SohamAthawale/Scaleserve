from __future__ import annotations

from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter


ROOT = Path(__file__).resolve().parents[1]
MAC_ICON_DIR = ROOT / "macos/Runner/Assets.xcassets/AppIcon.appiconset"
WINDOWS_ICON_PATH = ROOT / "windows/runner/resources/app_icon.ico"
PREVIEW_DIR = ROOT / "assets/branding"
PREVIEW_PATH = PREVIEW_DIR / "scaleserve_brand_icon.png"

OBSIDIAN = (5, 5, 5, 255)
CARBON = (11, 13, 11, 255)
GRAPHITE = (20, 23, 19, 255)
LIME = (162, 255, 90, 255)
LIME_HIGHLIGHT = (162, 255, 90, 255)


def lerp(a: float, b: float, t: float) -> float:
    return a + (b - a) * t


def lerp_color(
    start: tuple[int, ...],
    end: tuple[int, ...],
    t: float,
) -> tuple[int, ...]:
    return tuple(round(lerp(sa, ea, t)) for sa, ea in zip(start, end))


def sample_gradient(
    stops: list[tuple[float, tuple[int, ...]]],
    t: float,
) -> tuple[int, ...]:
    clamped = max(0.0, min(1.0, t))
    for index in range(len(stops) - 1):
        left_stop, left_color = stops[index]
        right_stop, right_color = stops[index + 1]
        if clamped <= right_stop:
            local_t = (
                0.0
                if right_stop == left_stop
                else (clamped - left_stop) / (right_stop - left_stop)
            )
            return lerp_color(left_color, right_color, local_t)
    return stops[-1][1]


def create_diagonal_gradient(
    size: int,
    stops: list[tuple[float, tuple[int, ...]]],
) -> Image.Image:
    gradient = Image.new("RGBA", (size, size))
    pixels = gradient.load()
    denominator = max((size - 1) * 2, 1)
    for y in range(size):
        for x in range(size):
            pixels[x, y] = sample_gradient(stops, (x + y) / denominator)
    return gradient


def tile_point(
    tile_rect: tuple[int, int, int, int],
    nx: float,
    ny: float,
) -> tuple[float, float]:
    left, top, right, bottom = tile_rect
    return (
        left + (right - left) * nx,
        top + (bottom - top) * ny,
    )


def polygon_points(
    tile_rect: tuple[int, int, int, int],
    normalized_points: list[tuple[float, float]],
) -> list[tuple[float, float]]:
    return [tile_point(tile_rect, nx, ny) for nx, ny in normalized_points]


def offset_points(
    points: list[tuple[float, float]],
    dx: float,
    dy: float,
) -> list[tuple[float, float]]:
    return [(x + dx, y + dy) for x, y in points]


def create_icon_master(size: int = 1024) -> Image.Image:
    margin = round(size * 0.08)
    tile_rect = (margin, margin, size - margin, size - margin)
    tile_radius = round(size * 0.24)

    canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    tile_mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(tile_mask).rounded_rectangle(
        tile_rect,
        radius=tile_radius,
        fill=255,
    )

    tile = create_diagonal_gradient(
        size,
        [
            (0.0, OBSIDIAN),
            (0.65, OBSIDIAN),
            (1.0, GRAPHITE),
        ],
    )

    sheen = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    sheen_draw = ImageDraw.Draw(sheen)
    sheen_draw.polygon(
        [
            tile_point(tile_rect, -0.08, 0.18),
            tile_point(tile_rect, 0.38, -0.06),
            tile_point(tile_rect, 0.52, 0.04),
            tile_point(tile_rect, 0.06, 0.28),
        ],
        fill=(245, 246, 240, 10),
    )
    sheen = sheen.filter(ImageFilter.GaussianBlur(radius=size * 0.02))
    tile.alpha_composite(sheen)

    tile.putalpha(tile_mask)
    canvas.alpha_composite(tile)

    top_blade = polygon_points(
        tile_rect,
        [(0.26, 0.24), (0.62, 0.24), (0.48, 0.39), (0.12, 0.39)],
    )
    bottom_blade = polygon_points(
        tile_rect,
        [(0.16, 0.54), (0.52, 0.54), (0.38, 0.69), (0.02, 0.69)],
    )

    mark_gradient = create_diagonal_gradient(
        size,
        [
            (0.0, LIME),
            (1.0, LIME),
        ],
    )
    mark_mask = Image.new("L", (size, size), 0)
    mark_mask_draw = ImageDraw.Draw(mark_mask)
    mark_mask_draw.polygon(top_blade, fill=255)
    mark_mask_draw.polygon(bottom_blade, fill=255)
    mark = Image.composite(
        mark_gradient,
        Image.new("RGBA", (size, size), (0, 0, 0, 0)),
        mark_mask,
    )
    canvas.alpha_composite(mark)

    seam_draw = ImageDraw.Draw(canvas)
    seam_draw.line(
        [
            tile_point(tile_rect, 0.32, 0.39),
            tile_point(tile_rect, 0.44, 0.52),
        ],
        fill=(5, 5, 5, 110),
        width=round(size * 0.034),
    )

    return canvas


def save_png_variants(master: Image.Image) -> None:
    PREVIEW_DIR.mkdir(parents=True, exist_ok=True)
    master.save(PREVIEW_PATH)

    sizes = {
        1024: "app_icon_1024.png",
        512: "app_icon_512.png",
        256: "app_icon_256.png",
        128: "app_icon_128.png",
        64: "app_icon_64.png",
        32: "app_icon_32.png",
        16: "app_icon_16.png",
    }
    for dimension, filename in sizes.items():
        output = MAC_ICON_DIR / filename
        resized = master.resize((dimension, dimension), Image.Resampling.LANCZOS)
        resized.save(output)


def save_windows_icon(master: Image.Image) -> None:
    WINDOWS_ICON_PATH.parent.mkdir(parents=True, exist_ok=True)
    master.save(
        WINDOWS_ICON_PATH,
        format="ICO",
        sizes=[
            (16, 16),
            (24, 24),
            (32, 32),
            (48, 48),
            (64, 64),
            (128, 128),
            (256, 256),
        ],
    )


def main() -> None:
    master = create_icon_master()
    save_png_variants(master)
    save_windows_icon(master)
    print(f"Generated brand icon assets at {MAC_ICON_DIR} and {WINDOWS_ICON_PATH}")


if __name__ == "__main__":
    main()
