#!/usr/bin/env python3
"""가림을 구운 사본(PNG)을 원본·정답과 비교한다. Python 표준 라이브러리만 쓴다(E2E 호스트 검사용).

사용: python3 -I apps/fixtures/check_artifact.py <기기에서 꺼낸 원본 사진> <기기에서 꺼낸 가림 사본>
원본 바이트로 가상 영수증(ground-truth.json)을 찾고, 다음을 확인해 JSON 한 줄로 낸다.
- 사본이 원본과 다른 바이트이고 PNG 청크가 그리기에 필요한 것뿐인지(메타데이터 청크 없음)
- 원본에 심어 둔 가상 메타데이터 표지 문자열이 사본에 없는지
- 정답의 민감한 줄 안 글자 픽셀이 모두 검정인지, 가림 띠 밖 픽셀이 원본과 같은지
"""
import json
import struct
import sys
import zlib
from pathlib import Path

ALLOWED = {"IHDR", "PLTE", "tRNS", "sRGB", "IDAT", "IEND"}
MARKERS = [b"SYNTHETIC-ORIGINAL-METADATA", b"SyntheticCam", b"NNA-r"]
HERE = Path(__file__).resolve().parent / "receipts"


def chunks(data):
    assert data[:8] == b"\x89PNG\r\n\x1a\n", "not a PNG"
    out, offset = [], 8
    while offset < len(data):
        size = struct.unpack(">I", data[offset:offset + 4])[0]
        out.append((data[offset + 4:offset + 8].decode("latin-1"), data[offset + 8:offset + 8 + size]))
        offset += size + 12
        if out[-1][0] == "IEND":
            break
    return out


def decode(data):
    """8비트 그레이·RGB·RGBA PNG를 (너비, 높이, 픽셀 RGB 함수)로 푼다."""
    parts = chunks(data)
    w, h, depth, ctype = struct.unpack(">IIBB", parts[0][1][:10])
    assert depth == 8 and ctype in (0, 2, 6), (depth, ctype)
    bpp = {0: 1, 2: 3, 6: 4}[ctype]
    raw = zlib.decompress(b"".join(body for name, body in parts if name == "IDAT"))
    stride = w * bpp
    rows, prev, i = [], bytearray(stride), 0
    for _ in range(h):
        f, line = raw[i], bytearray(raw[i + 1:i + 1 + stride])
        i += 1 + stride
        for x in range(stride):
            a = line[x - bpp] if x >= bpp else 0
            b, c = prev[x], (prev[x - bpp] if x >= bpp else 0)
            if f == 1:
                line[x] = (line[x] + a) & 255
            elif f == 2:
                line[x] = (line[x] + b) & 255
            elif f == 3:
                line[x] = (line[x] + (a + b) // 2) & 255
            elif f == 4:
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                line[x] = (line[x] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
        rows.append(line)
        prev = line

    def rgb(x, y):
        o = x * bpp
        px = rows[y][o:o + bpp]
        return (px[0],) * 3 if ctype == 0 else tuple(px[:3])

    return w, h, rgb


def main():
    original, artifact = Path(sys.argv[1]).read_bytes(), Path(sys.argv[2]).read_bytes()
    truths = json.loads((HERE / "ground-truth.json").read_text())
    truth = next(t for t in truths if (HERE / t["file"]).read_bytes() == original)
    names = [n for n, _ in chunks(artifact)]
    ow, oh, src = decode(original)
    aw, ah, art = decode(artifact)
    ink = black = 0
    for s in truth["sensitive"]:
        x0, y0, x1, y1 = s["rect"]
        for y in range(y0, y1):
            for x in range(x0, x1):
                if all(v < 128 for v in src(x, y)):
                    ink += 1
                    black += art(x, y) == (0, 0, 0)
    bands = [(s["rect"][1] - 40, s["rect"][3] + 40) for s in truth["sensitive"]]
    outside = differing = 0
    for y in range(0, oh, 3):
        if any(a <= y <= b for a, b in bands):
            continue
        for x in range(0, ow, 3):
            outside += 1
            differing += src(x, y) != art(x, y)
    result = {
        "fixture": truth["ref"],
        "same_bytes_as_original": original == artifact,
        "chunks": names,
        "only_allowed_chunks": set(names) <= ALLOWED,
        "metadata_markers_found": [m.decode() for m in MARKERS if m in artifact],
        "sensitive_ink_pixels": ink,
        "sensitive_ink_pixels_black": black,
        "sampled_pixels_outside_masks": outside,
        "outside_pixels_changed": differing,
        "size_matches": (ow, oh) == (aw, ah),
    }
    result["pass"] = (
        not result["same_bytes_as_original"] and result["only_allowed_chunks"] and not result["metadata_markers_found"]
        and ink > 0 and ink == black and differing == 0 and result["size_matches"]
    )
    print(json.dumps(result, ensure_ascii=False))
    sys.exit(0 if result["pass"] else 1)


if __name__ == "__main__":
    main()
