"""Generate LiteTale launcher icon colorways from the approved iris artwork.

Run from the repository root with Pillow installed:
    python tools/generate_litetale_icons.py

The iris artwork is the source for every colorway. This script changes only
color values; it does not redraw, resize, or reposition the supplied artwork.
"""

from itertools import combinations
from pathlib import Path

from PIL import Image, ImageDraw


ROOT = Path(__file__).resolve().parents[1]
RES = ROOT / "android/app/src/main/res"
PALETTES = {
    "iris": ("#FFFFFF", "#4D3A6B", "#C5A8E9", "#E9DCFA", "#D7C4EA"),
    "blue": ("#F5F9FF", "#294E79", "#8DBAE8", "#D9EBFA", "#B9D5EF"),
    "rose": ("#FFF7FA", "#803D60", "#EAA8C7", "#F9DDEB", "#EDC3D5"),
    "orange": ("#FFFAF3", "#79502F", "#EFC18D", "#FBE7CB", "#EED3AC"),
    "teal": ("#F2FBF9", "#265D5D", "#8CCFC9", "#D6F0E9", "#AEDDD7"),
    "green": ("#F7FAF3", "#405F43", "#A8CAA0", "#DFEDD6", "#BED9B5"),
}

# These are the colors in the approved iris raster artwork. Source colors at
# antialiased edges are blended between these anchors, so mapping the nearest
# source-color segment keeps those edge pixels soft while changing their hue.
SOURCE_COLORS = {
    "background": "#FFFFFF",
    "outline": "#513E70",
    "cover_left": "#C8B6EF",
    "cover_right": "#E4D6FC",
    "bottom": "#CFC5E2",
    "detail": "#F4EFFA",
}
COLOR_ROLES = tuple(SOURCE_COLORS)
COLOR_SEGMENTS = tuple(combinations(COLOR_ROLES, 2))


def rgb(value):
    value = value.removeprefix("#")
    return tuple(int(value[index : index + 2], 16) for index in (0, 2, 4))


def target_colors(palette):
    return {
        "background": rgb(palette[0]),
        "outline": rgb(palette[1]),
        "cover_left": rgb(palette[2]),
        "cover_right": rgb(palette[3]),
        "bottom": rgb(palette[4]),
        # The bookmark label stays pale across all colorways.
        "detail": rgb(SOURCE_COLORS["detail"]),
    }


def colorize(image, palette):
    """Recolor one iris raster without changing its dimensions or alpha."""
    source = image.convert("RGBA")
    source_anchors = {role: rgb(color) for role, color in SOURCE_COLORS.items()}
    output_anchors = target_colors(palette)
    segments = [
        (
            source_anchors[first],
            source_anchors[second],
            output_anchors[first],
            output_anchors[second],
        )
        for first, second in COLOR_SEGMENTS
    ]
    mapped_colors = {}

    def mapped_rgb(color):
        cached = mapped_colors.get(color)
        if cached is not None:
            return cached

        best_error = float("inf")
        best_color = color
        for source_start, source_end, output_start, output_end in segments:
            direction = tuple(
                source_end[channel] - source_start[channel]
                for channel in range(3)
            )
            length_squared = sum(value * value for value in direction)
            projection = sum(
                (color[channel] - source_start[channel]) * direction[channel]
                for channel in range(3)
            ) / length_squared
            amount = min(1.0, max(0.0, projection))
            error = sum(
                (
                    color[channel]
                    - (source_start[channel] + direction[channel] * amount)
                )
                ** 2
                for channel in range(3)
            )
            if error < best_error:
                best_error = error
                best_color = tuple(
                    round(
                        output_start[channel]
                        + (output_end[channel] - output_start[channel]) * amount
                    )
                    for channel in range(3)
                )

        mapped_colors[color] = best_color
        return best_color

    recolored = []
    for red, green, blue, alpha in source.getdata():
        if alpha == 0:
            # Preserve invisible source RGB too; it cannot affect rendered edges.
            recolored.append((red, green, blue, alpha))
        else:
            recolored.append((*mapped_rgb((red, green, blue)), alpha))

    output = Image.new("RGBA", source.size)
    output.putdata(recolored)
    if image.mode == "RGB":
        return output.convert("RGB")
    return output


def save_colorway(source_path, destination, palette):
    source = Image.open(source_path)
    output = colorize(source, palette)
    if output.size != source.size:
        raise AssertionError(f"Unexpected resize while recoloring {source_path}")
    if source.mode == "RGBA" and output.getchannel("A").tobytes() != source.getchannel("A").tobytes():
        raise AssertionError(f"Alpha changed while recoloring {source_path}")
    destination.parent.mkdir(parents=True, exist_ok=True)
    output.save(destination, optimize=True)


def write_adaptive_xml(name):
    filename = "ic_launcher" if name == "iris" else f"ic_launcher_{name}"
    xml = f'''<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@color/litetale_icon_bg_{name}" />
    <foreground android:drawable="@drawable/launcher_foreground_{name}" />
    <monochrome android:drawable="@drawable/novels_monochrome" />
</adaptive-icon>
'''
    (RES / "mipmap-anydpi-v26" / f"{filename}.xml").write_text(xml, encoding="utf-8")
    legacy = f'''<bitmap xmlns:android="http://schemas.android.com/apk/res/android"
    android:src="@drawable/launcher_legacy_{name}" />
'''
    (RES / "mipmap-anydpi" / f"{filename}.xml").write_text(legacy, encoding="utf-8")


def write_contact_sheet():
    names = tuple(PALETTES)
    cell_size = 192
    label_height = 30
    gap = 24
    columns = 3
    rows = (len(names) + columns - 1) // columns
    width = columns * cell_size + (columns + 1) * gap
    height = rows * (cell_size + label_height) + (rows + 1) * gap
    sheet = Image.new("RGB", (width, height), "#F1F0F4")
    draw = ImageDraw.Draw(sheet)

    for index, name in enumerate(names):
        row, column = divmod(index, columns)
        left = gap + column * (cell_size + gap)
        top = gap + row * (cell_size + label_height + gap)
        icon = Image.open(ROOT / "assets/icon_previews" / f"{name}.png").convert("RGB")
        if icon.size != (cell_size, cell_size):
            raise AssertionError(f"Unexpected preview dimensions for {name}: {icon.size}")
        sheet.paste(icon, (left, top))
        draw.text(
            (left + 4, top + cell_size + 7),
            name.title(),
            fill="#322B3A",
        )

    destination = ROOT / "docs/qa/0.1.11/icon-colorways.png"
    destination.parent.mkdir(parents=True, exist_ok=True)
    sheet.save(destination, optimize=True)


def main():
    densities = {"mdpi": 48, "hdpi": 72, "xhdpi": 96, "xxhdpi": 144, "xxxhdpi": 192}
    required_iris = [
        RES / "drawable-nodpi/launcher_foreground_iris.png",
        RES / "drawable-nodpi/launcher_legacy_iris.png",
        ROOT / "assets/icon_previews/iris.png",
        *(RES / f"mipmap-{density}/ic_launcher.png" for density in densities),
    ]
    if any(not path.is_file() for path in required_iris):
        raise FileNotFoundError("The approved iris icon assets are missing")

    color_lines = ["<resources>"]
    for name, palette in PALETTES.items():
        color_lines.append(f'    <color name="litetale_icon_bg_{name}">{palette[0]}</color>')
        if name == "iris":
            # Keep the approved iris artwork byte-for-byte unchanged.
            write_adaptive_xml(name)
            continue

        save_colorway(
            RES / "drawable-nodpi/launcher_foreground_iris.png",
            RES / "drawable-nodpi" / f"launcher_foreground_{name}.png",
            palette,
        )
        save_colorway(
            RES / "drawable-nodpi/launcher_legacy_iris.png",
            RES / "drawable-nodpi" / f"launcher_legacy_{name}.png",
            palette,
        )
        save_colorway(
            ROOT / "assets/icon_previews/iris.png",
            ROOT / "assets/icon_previews" / f"{name}.png",
            palette,
        )
        for density in densities:
            save_colorway(
                RES / f"mipmap-{density}/ic_launcher.png",
                RES / f"mipmap-{density}/ic_launcher_{name}.png",
                palette,
            )
        write_adaptive_xml(name)

    color_lines.append('    <color name="novels_icon_background">#FAF7FF</color>')
    color_lines.append("</resources>")
    (RES / "values/colors.xml").write_text("\n".join(color_lines) + "\n", encoding="utf-8")
    write_contact_sheet()
    print("Generated", len(PALETTES), "LiteTale icon colorways")


if __name__ == "__main__":
    main()
