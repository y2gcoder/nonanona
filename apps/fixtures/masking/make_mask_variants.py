#!/usr/bin/env python3
"""가상 영수증(receipts/)을 기울이거나 흐리게 한 가림 시험 이미지와, 그 사진에서 기기 OCR이 보인 모양을 흉내 낸 줄을 만든다.

Python 표준 라이브러리만 쓴다. 결과는 결정적이다(난수 없음).
사용: python3 -I apps/fixtures/masking/make_mask_variants.py

- 회전은 반시계(양수)로, 글자가 잘리지 않게 캔버스를 넓히고 빈 곳은 종이 색으로 채운다(쌍선형 보간).
- 흐림은 가우시안(분리형, 가장자리 복제)이다. 출력은 회색조 값을 담은 8비트 RGB PNG이고(JVM ImageIO가 그레이 PNG를 선형 색공간으로
  바꾸지 않게), 가림 검사(검정 0)와 섞이지 않게 밝기를 1 이상으로 둔다.
- `variants.json`의 `ocr`은 2026-11-26 OCR 측정(Android ML Kit)에서 관찰한 실패를 흉내 낸다: 기울면 카드 라벨과 번호 조각이
  따로 읽히고(r01 +15°, r04 −8°), 흐리면 라벨이 깨지거나(会員→会) 번호를 못 읽는다(r03). r02 +3°는 회원번호 줄을 아예 못 읽는다.
  `lines`는 정답 줄의 변환된 네 모서리(픽셀)와 민감·가격 줄 표시다. 단위 테스트(MaskHardeningTest)가 둘 다 읽는다.
"""
import json
import math
import struct
import sys
import zlib
from pathlib import Path

HERE = Path(__file__).resolve().parent
RECEIPTS = HERE.parent / "receipts"
sys.dont_write_bytecode = True
sys.path.insert(0, str(HERE.parent))
from check_artifact import decode  # noqa: E402

PRICE = ("円", "¥", "合計", "小計", "税")

# (이름, 영수증, 회전 도(반시계 양수), 흐림 σ, OCR이 읽은 모양 {원문: [(읽은 글자, 원본 x 시작, x 끝), …]}).
# 글자가 None인 조각은 OCR이 읽지 못한 부분이고, 빈 목록은 그 줄을 통째로 못 읽은 것이다.
# 조각 경계 x는 원본 줄 안 글자 열의 빈 칸에서 잰 값이다(라벨 안 글자 간격과 토큰 간격이 비슷해 자동으로 나누지 않는다).
VARIANTS = [
    ("r01-rot15-split", "r01", 15.0, 0.0,
     {"カード番号 **** **** **** 4821": [("カード番号", 50, 182), ("**** **** ****", 182, 316), ("4821", 316, 383)]}),
    ("r04-rotm8-split", "r04", -8.0, 0.0,
     {"カード番号 **** **** **** 9034": [("カード番号", 50, 182), ("**** **** **** 9034", 182, 389)]}),
    ("r02-blur22-garbled", "r02", 0.0, 2.2, {"会員番号 MN-7731-0459": [("会号 MN-7731-0459", 49, 360)]}),
    ("r03-blur22-label-only", "r03", 0.0, 2.2, {"承認番号 083912": [("承認番号", 48, 156), (None, 156, 262)]}),
    ("r02-rot3-missed", "r02", 3.0, 0.0, {"会員番号 MN-7731-0459": []}),
]


def luma_of(path):
    w, h, rgb = decode(path.read_bytes())
    return w, h, [[(lambda p: (p[0] * 299 + p[1] * 587 + p[2] * 114) // 1000)(rgb(x, y)) for x in range(w)] for y in range(h)]


def rotate(img, w, h, degrees, background):
    a = math.radians(degrees)
    c, s = math.cos(a), math.sin(a)
    nw = math.ceil(w * abs(c) + h * abs(s))
    nh = math.ceil(w * abs(s) + h * abs(c))
    cx, cy, ncx, ncy = w / 2, h / 2, nw / 2, nh / 2
    out = []
    for y in range(nh):
        row = []
        for x in range(nw):
            dx, dy = x + 0.5 - ncx, y + 0.5 - ncy
            sx = dx * c - dy * s + cx - 0.5
            sy = dx * s + dy * c + cy - 0.5
            x0, y0 = math.floor(sx), math.floor(sy)
            fx, fy = sx - x0, sy - y0
            acc = 0.0
            for yy, wy in ((y0, 1 - fy), (y0 + 1, fy)):
                for xx, wx in ((x0, 1 - fx), (x0 + 1, fx)):
                    v = img[yy][xx] if 0 <= xx < w and 0 <= yy < h else background
                    acc += v * wx * wy
            row.append(round(acc))
        out.append(row)

    def forward(px, py):
        dx, dy = px - cx, py - cy
        return dx * c + dy * s + ncx, -dx * s + dy * c + ncy

    return out, nw, nh, forward


def blur(img, w, h, sigma):
    r = math.ceil(3 * sigma)
    k = [math.exp(-(i * i) / (2 * sigma * sigma)) for i in range(-r, r + 1)]
    t = sum(k)
    k = [v / t for v in k]
    tmp = [[sum(k[j] * row[min(w - 1, max(0, x + j - r))] for j in range(2 * r + 1)) for x in range(w)] for row in img]
    return [[round(sum(k[j] * tmp[min(h - 1, max(0, y + j - r))][x] for j in range(2 * r + 1))) for x in range(w)] for y in range(h)]


def encode_rgb(img, w, h):
    raw = b"".join(b"\x00" + bytes(max(1, min(255, v)) for v in row for _ in range(3)) for row in img)

    def chunk(name, body):
        return struct.pack(">I", len(body)) + name + body + struct.pack(">I", zlib.crc32(name + body) & 0xFFFFFFFF)

    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))


def corners(rect, forward):
    l, t, r, b = rect
    return [round(v, 2) for p in (forward(l, t), forward(r, t), forward(r, b), forward(l, b)) for v in p]


def main():
    truths = {t["ref"]: t for t in json.loads((RECEIPTS / "ground-truth.json").read_text())}
    out = []
    for name, ref, degrees, sigma, edits in VARIANTS:
        truth = truths[ref]
        w, h, img = luma_of(RECEIPTS / truth["file"])
        background = img[4][4]
        forward = lambda x, y: (x, y)  # noqa: E731
        if degrees:
            img, w, h, forward = rotate(img, w, h, degrees, background)
        if sigma:
            img = blur(img, w, h, sigma)
        (HERE / f"{name}.png").write_bytes(encode_rgb(img, w, h))
        sensitive = {line["text"] for line in truth["sensitive"]}
        lines, ocr = [], []
        for line in truth["lines"]:
            text, rect = line["text"], line["rect"]
            lines.append({"text": text, "corners": corners(rect, forward), "sensitive": text in sensitive,
                          "price": any(p in text for p in PRICE)})
            for piece, x0, x1 in edits.get(text, [(text, rect[0], rect[2])]):
                if piece is not None:
                    ocr.append({"text": piece, "corners": corners((x0, rect[1], x1, rect[3]), forward)})
        out.append({"name": name, "file": f"{name}.png", "ref": ref, "rotateDegrees": degrees, "blurSigma": sigma,
                    "width": w, "height": h, "lines": lines, "ocr": ocr})
    (HERE / "variants.json").write_text(json.dumps(out, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
