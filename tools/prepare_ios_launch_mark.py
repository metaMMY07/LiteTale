"""Embed the app artwork with the same rounded clip as Flutter's iOS splash."""

from pathlib import Path
import struct


ROOT = Path(__file__).resolve().parents[1]


def launch_mark(png: bytes) -> bytes:
    # PNG's zlib payload is already in the PDF PNG-predictor format. Keep the
    # artwork bytes unchanged and clip the image at its 104 pt display size.
    assert png[:8] == b"\x89PNG\r\n\x1a\n"
    w, h, depth, color, compression, filter_method, interlace = struct.unpack(
        ">IIBBBBB", png[16:29]
    )
    assert w == h and (depth, color, compression, filter_method, interlace) == (
        8, 2, 0, 0, 0
    ), "Expected square 8-bit RGB artwork"
    data = bytearray()
    offset = 8
    while offset < len(png):
        length, kind = struct.unpack_from(">I4s", png, offset)
        if kind == b"IDAT":
            data.extend(png[offset + 8 : offset + 8 + length])
        offset += 12 + length

    def stream(payload: bytes, attributes: str = "") -> bytes:
        return (
            f"<< /Length {len(payload)} {attributes} >>\nstream\n".encode()
            + payload + b"\nendstream"
        )

    # 24 pt radius; cubic control points approximate the circular corners.
    commands = b"""q
24 0 m 80 0 l 93.2548 0 104 10.7452 104 24 c
104 80 l 104 93.2548 93.2548 104 80 104 c
24 104 l 10.7452 104 0 93.2548 0 80 c
0 24 l 0 10.7452 10.7452 0 24 0 c h W n
104 0 0 104 0 0 cm /Mark Do Q
"""
    objects = [
        b"<< /Type /Catalog /Pages 2 0 R >>",
        b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 104 104] "
        b"/Resources << /XObject << /Mark 5 0 R >> >> /Contents 4 0 R >>",
        stream(commands),
        stream(bytes(data), f"/Type /XObject /Subtype /Image /Width {w} /Height {h} "
               f"/ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /FlateDecode "
               f"/DecodeParms << /Predictor 15 /Colors 3 /BitsPerComponent 8 /Columns {w} >>"),
    ]
    pdf = bytearray(b"%PDF-1.4\n%\xe2\xe3\xcf\xd3\n")
    offsets = []
    for index, body in enumerate(objects, 1):
        offsets.append(len(pdf))
        pdf.extend(f"{index} 0 obj\n".encode() + body + b"\nendobj\n")
    xref = len(pdf)
    size = len(offsets) + 1
    pdf.extend(f"xref\n0 {size}\n0000000000 65535 f \n".encode())
    for offset in offsets:
        pdf.extend(f"{offset:010d} 00000 n \n".encode())
    pdf.extend(f"trailer\n<< /Size {size} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n".encode())
    return bytes(pdf)


if __name__ == "__main__":
    artwork = ROOT / "lib/assets/app_brand.png"
    target = ROOT / "ios/Runner/Assets.xcassets/LaunchMark.imageset/LaunchMark.pdf"
    target.write_bytes(launch_mark(artwork.read_bytes()))
