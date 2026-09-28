"""Generate the book-and-bookmark launcher icon and its six color presets.

Run from the repository root with Pillow installed: python tools/generate_litetale_icons.py
The generated PNGs are checked into the project; Pillow is not needed to build
or run the Android app.
"""

from pathlib import Path
from PIL import Image, ImageColor, ImageDraw


ROOT = Path(__file__).resolve().parents[1]
RES = ROOT / "android/app/src/main/res"
PALETTES = {
    "iris": ("#FAF7FF", "#4D3A6B", "#C5A8E9", "#E9DCFA", "#D7C4EA"),
    "blue": ("#F5F9FF", "#294E79", "#8DBAE8", "#D9EBFA", "#B9D5EF"),
    "rose": ("#FFF7FA", "#803D60", "#EAA8C7", "#F9DDEB", "#EDC3D5"),
    "orange": ("#FFFAF3", "#79502F", "#EFC18D", "#FBE7CB", "#EED3AC"),
    "teal": ("#F2FBF9", "#265D5D", "#8CCFC9", "#D6F0E9", "#AEDDD7"),
    "green": ("#F7FAF3", "#405F43", "#A8CAA0", "#DFEDD6", "#BED9B5"),
}
SCALE = 4
SIZE = 512 * SCALE


def box(*coords):
    return tuple(round(value * SCALE) for value in coords)


def blend(first, second, amount):
    a, b = ImageColor.getrgb(first), ImageColor.getrgb(second)
    return tuple(round(a[n] + (b[n] - a[n]) * amount) for n in range(3)) + (255,)


def rounded_mask(bounds, radii):
    left, top, right, bottom = box(*bounds)
    tl, tr, br, bl = (round(radius * SCALE) for radius in radii)
    mask = Image.new("L", (SIZE, SIZE))
    draw = ImageDraw.Draw(mask)
    draw.polygon(
        [
            (left + tl, top), (right - tr, top),
            (right, top + tr), (right, bottom - br),
            (right - br, bottom), (left + bl, bottom),
            (left, bottom - bl), (left, top + tl),
        ],
        fill=255,
    )
    for bounds, start, end in (
        ((left, top, left + 2 * tl, top + 2 * tl), 180, 270),
        ((right - 2 * tr, top, right, top + 2 * tr), 270, 360),
        ((right - 2 * br, bottom - 2 * br, right, bottom), 0, 90),
        ((left, bottom - 2 * bl, left + 2 * bl, bottom), 90, 180),
    ):
        draw.pieslice(bounds, start, end, fill=255)
    return mask


def rounded_gradient(image, bounds, radii, first, second):
    mask = rounded_mask(bounds, radii)
    layer = Image.new("RGBA", (SIZE, SIZE))
    drawer = ImageDraw.Draw(layer)
    left, top, right, bottom = box(*bounds)
    for x in range(left, right + 1):
        drawer.line((x, top, x, bottom), fill=blend(first, second, (x - left) / (right - left)))
    layer.putalpha(mask)
    image.alpha_composite(layer)


def book_glyph(palette):
    _, outline, left, right, bottom = palette
    image = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)
    # Keep three corners aligned, with the upper left slightly softer.
    silhouette = Image.new("RGBA", (SIZE, SIZE), ImageColor.getrgb(outline) + (255,))
    silhouette.putalpha(rounded_mask((78, 53, 434, 462), (44, 28, 28, 28)))
    image.alpha_composite(silhouette)
    rounded_gradient(image, (94, 69, 418, 407), (28, 12, 12, 12), left, right)
    draw = ImageDraw.Draw(image)
    # The straight spine and the lower page band make the silhouette readable
    # at small launcher sizes.
    draw.rounded_rectangle(box(138, 68, 156, 409), radius=5 * SCALE, fill=outline)
    draw.rounded_rectangle(box(94, 407, 418, 447), radius=28 * SCALE, fill=bottom)
    draw.rounded_rectangle(box(94, 397, 418, 413), radius=7 * SCALE, fill=outline)
    draw.rounded_rectangle(box(97, 414, 416, 446), radius=22 * SCALE, fill=bottom)

    draw.polygon(
        [box(x, y) for x, y in [(185, 68), (252, 68), (252, 186), (219, 163), (185, 186)]],
        fill=outline,
    )
    draw.polygon(
        [box(x, y) for x, y in [(199, 70), (238, 70), (238, 160), (219, 146), (199, 160)]],
        fill=left,
    )
    draw.rounded_rectangle(box(180, 266, 398, 360), radius=47 * SCALE, fill=outline)
    draw.rounded_rectangle(box(195, 281, 383, 345), radius=33 * SCALE, fill="#F8F4FD")
    for y in (302, 326):
        draw.rounded_rectangle(box(222, y, 357, y + 12), radius=6 * SCALE, fill=outline)
    return image


def centered_glyph(glyph, factor):
    result = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    scaled = glyph.resize((round(SIZE * factor), round(SIZE * factor)), Image.Resampling.LANCZOS)
    result.alpha_composite(scaled, ((SIZE - scaled.width) // 2, (SIZE - scaled.height) // 2))
    return result


def save_png(image, path, size):
    path.parent.mkdir(parents=True, exist_ok=True)
    image.resize((size, size), Image.Resampling.LANCZOS).save(path, optimize=True)


def svg_for_default():
    _, outline, left, right, bottom = PALETTES["iris"]
    return f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512" role="img" aria-labelledby="title">
  <title>LiteTale 书本与书签图标</title>
  <defs><linearGradient id="cover"><stop stop-color="{left}"/><stop offset="1" stop-color="{right}"/></linearGradient></defs>
  <rect width="512" height="512" rx="112" fill="#FAF7FF"/>
  <path d="M122 53h284q28 0 28 28v353q0 28-28 28H106q-28 0-28-28V97q0-44 44-44z" fill="{outline}"/>
  <path d="M122 69h284q12 0 12 12v314q0 12-12 12H106q-12 0-12-12V97q0-28 28-28z" fill="url(#cover)"/>
  <rect x="138" y="68" width="18" height="341" rx="5" fill="{outline}"/>
  <rect x="94" y="397" width="324" height="50" rx="25" fill="{outline}"/>
  <rect x="97" y="414" width="319" height="32" rx="16" fill="{bottom}"/>
  <path d="M185 68h67v118l-33-23-34 23z" fill="{outline}"/>
  <path d="M199 70h39v90l-19-14-20 14z" fill="{left}"/>
  <rect x="180" y="266" width="218" height="94" rx="47" fill="{outline}"/>
  <rect x="195" y="281" width="188" height="64" rx="32" fill="#F8F4FD"/>
  <path d="M228 308h123m-123 24h123" stroke="{outline}" stroke-width="12" stroke-linecap="round"/>
</svg>
'''


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


def main():
    color_lines = ["<resources>"]
    densities = {"mdpi": 48, "hdpi": 72, "xhdpi": 96, "xxhdpi": 144, "xxxhdpi": 192}
    for name, palette in PALETTES.items():
        background = palette[0]
        color_lines.append(f'    <color name="litetale_icon_bg_{name}">{background}</color>')
        glyph = book_glyph(palette)
        # Keep the complete book, including its lower page band, inside the
        # circular safe area used by many Android launchers.
        adaptive = centered_glyph(glyph, 0.50)
        legacy = Image.new("RGBA", (SIZE, SIZE), ImageColor.getrgb(background) + (255,))
        legacy.alpha_composite(centered_glyph(glyph, 0.70))
        save_png(adaptive, RES / "drawable-nodpi" / f"launcher_foreground_{name}.png", 432)
        save_png(legacy, RES / "drawable-nodpi" / f"launcher_legacy_{name}.png", 432)
        save_png(legacy, ROOT / "assets/icon_previews" / f"{name}.png", 160)
        for density, size in densities.items():
            filename = "ic_launcher.png" if name == "iris" else f"ic_launcher_{name}.png"
            save_png(legacy, RES / f"mipmap-{density}" / filename, size)
        write_adaptive_xml(name)

    color_lines.append('    <color name="novels_icon_background">#FAF7FF</color>')
    color_lines.append("</resources>")
    (RES / "values/colors.xml").write_text("\n".join(color_lines) + "\n", encoding="utf-8")
    (ROOT / "docs/litetale-app-icon.svg").write_text(svg_for_default(), encoding="utf-8")
    (RES / "drawable-v26/ic_launcher.xml").write_text(
        (RES / "mipmap-anydpi-v26/ic_launcher.xml").read_text(encoding="utf-8"),
        encoding="utf-8",
    )
    print("Generated", len(PALETTES), "LiteTale icon colorways")


if __name__ == "__main__":
    main()
