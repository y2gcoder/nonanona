#!/usr/bin/env python3
"""가상 영수증 PNG로 EXIF 방향이 붙은 JPEG을 만든다(E2E용, 호스트 macOS, Python 표준 라이브러리 + sips).

픽셀은 똑바른 영수증을 반시계로 90° 돌려 저장하고, EXIF Orientation=6("시계로 90° 돌려 보라")을 붙인다.
방향을 적용하는 앱은 원래 영수증과 같은 똑바른 그림(가로 720 × 세로 746 등)을 얻고, 무시하는 앱은 옆으로 누운 그림을 얻는다.
사용: python3 -I apps/fixtures/make_exif_rotated.py <똑바른 PNG> <출력 JPEG>
"""
import struct
import subprocess
import sys
import tempfile
from pathlib import Path


def exif_orientation_segment(value):
    """APP1 Exif: TIFF(빅엔디언) IFD0 항목 하나(0x0112 Orientation, SHORT, 1개)."""
    ifd = struct.pack(">H", 1) + struct.pack(">HHIHH", 0x0112, 3, 1, value, 0) + struct.pack(">I", 0)
    tiff = b"MM" + struct.pack(">HI", 42, 8) + ifd
    body = b"Exif\x00\x00" + tiff
    return b"\xff\xe1" + struct.pack(">H", len(body) + 2) + body


def strip_app1(jpeg):
    """SOI 뒤의 기존 APP1(EXIF·XMP)을 뺀다. 나머지 세그먼트는 그대로 둔다."""
    assert jpeg[:2] == b"\xff\xd8", "not a JPEG"
    out, i = bytearray(jpeg[:2]), 2
    while i < len(jpeg) and jpeg[i] == 0xFF and jpeg[i + 1] not in (0xDA, 0xD9):
        marker = jpeg[i + 1]
        size = struct.unpack(">H", jpeg[i + 2:i + 4])[0]
        if marker != 0xE1:
            out += jpeg[i:i + 2 + size]
        i += 2 + size
    return bytes(out + jpeg[i:])


def main():
    source, target = Path(sys.argv[1]), Path(sys.argv[2])
    with tempfile.TemporaryDirectory() as tmp:
        rotated = Path(tmp) / "rotated.jpg"
        # sips -r는 시계 방향 각도다. 270°(= 반시계 90°)로 돌려 JPEG으로 저장한다.
        subprocess.run(["sips", "-s", "format", "jpeg", "-s", "formatOptions", "95", "-r", "270", str(source), "--out", str(rotated)],
                       check=True, capture_output=True)
        data = strip_app1(rotated.read_bytes())
    target.write_bytes(data[:2] + exif_orientation_segment(6) + data[2:])
    print(target)


if __name__ == "__main__":
    main()
