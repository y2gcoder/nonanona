"""가상 영수증에서 가림 회귀 테스트용 흐린 사본을 만든다."""
from pathlib import Path

from PIL import Image, ImageFilter

here = Path(__file__).resolve().parent
source = here.parents[4] / "fixtures" / "receipts" / "receipt-r03.png"
with Image.open(source) as original:
    original.convert("RGB").filter(ImageFilter.GaussianBlur(radius=4)).save(here / "mask-blur-r03.png")
