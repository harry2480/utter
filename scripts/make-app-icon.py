#!/usr/bin/env python3
"""utter のアプリアイコン（iOS・macOS の AppIcon）を描き出す。

黒地に白で、音声の波形の最後の1本がテキストカーソル（I 字）になる絵。
色や形を変えたら、このスクリプトを実行し直して PNG をコミットする。

    python3 scripts/make-app-icon.py

Pillow（`pip install Pillow`）が要る。ビルドでは実行しない（PNG を直接使う）。
"""

from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent.parent
IOS_ICONSET = ROOT / "Apps/iOS/Resources/Assets.xcassets/AppIcon.appiconset"
MAC_ICONSET = ROOT / "Apps/macOS/Resources/Assets.xcassets/AppIcon.appiconset"

# 描画の解像度。最後に縮小してなめらかにする
CANVAS = 4096
# わずかに明るい黒（左上）から黒（右下）へのグラデーション
BACKGROUND_TOP = (0x2C, 0x2C, 0x2E)
BACKGROUND_BOTTOM = (0x0A, 0x0A, 0x0A)
FOREGROUND = (0xFF, 0xFF, 0xFF)
# 背景の一辺に対する絵の大きさ（iOS は角を丸く切り取るため、余白をとる）
GLYPH_SCALE = 0.74
# macOS の角丸の板（1024 のうち 824。Apple のテンプレートに合わせる）
MAC_INSET_RATIO = 100 / 1024
MAC_CORNER_RATIO = 0.225
MAC_SIZES = [16, 32, 128, 256, 512]


def lerp(a, b, t):
    return tuple(round(a[i] + (b[i] - a[i]) * t) for i in range(3))


def background(size):
    """左上から右下への斜めのグラデーション（縦と横のグラデーションを半分ずつ重ねる）"""
    vertical = Image.new("RGB", (size, size))
    horizontal = Image.new("RGB", (size, size))
    vd, hd = ImageDraw.Draw(vertical), ImageDraw.Draw(horizontal)
    for i in range(size):
        color = lerp(BACKGROUND_TOP, BACKGROUND_BOTTOM, i / (size - 1))
        vd.line([(0, i), (size, i)], fill=color)
        hd.line([(i, 0), (i, size)], fill=color)
    return Image.blend(vertical, horizontal, 0.5)


def draw_glyph(draw, cx, cy, unit, color):
    """波形の棒4本と、テキストカーソル（I 字）1本を、中心 (cx, cy)・大きさ unit で描く"""
    bar_w = 0.085 * unit
    gap = 0.07 * unit
    heights = [0.22, 0.42, 0.62, 0.40]
    count = len(heights) + 1
    x = cx - (count * bar_w + (count - 1) * gap) / 2
    for h in heights:
        half = h * unit / 2
        draw.rounded_rectangle([x, cy - half, x + bar_w, cy + half], radius=bar_w / 2, fill=color)
        x += bar_w + gap
    cursor_h = 0.62 * unit
    stem = bar_w * 0.62
    stem_x = x + (bar_w - stem) / 2
    draw.rounded_rectangle(
        [stem_x, cy - cursor_h / 2, stem_x + stem, cy + cursor_h / 2], radius=stem / 2, fill=color)
    serif_w = bar_w * 2.3
    mid = x + bar_w / 2
    for top in (cy - cursor_h / 2, cy + cursor_h / 2 - stem):
        draw.rounded_rectangle(
            [mid - serif_w / 2, top, mid + serif_w / 2, top + stem], radius=stem / 2, fill=color)


def ios_icon():
    """iOS は正方形・透明なしで渡す（角の丸めは OS が行う）"""
    img = background(CANVAS)
    draw_glyph(ImageDraw.Draw(img), CANVAS / 2, CANVAS / 2, CANVAS * GLYPH_SCALE, FOREGROUND)
    return img


def mac_icon():
    """macOS は角丸の板を余白つきで描く（板の外は透明）"""
    img = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    inset = round(CANVAS * MAC_INSET_RATIO)
    plate = CANVAS - 2 * inset
    mask = Image.new("L", (plate, plate), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        [0, 0, plate - 1, plate - 1], radius=plate * MAC_CORNER_RATIO, fill=255)
    img.paste(background(plate), (inset, inset), mask)
    draw_glyph(ImageDraw.Draw(img), CANVAS / 2, CANVAS / 2, plate * GLYPH_SCALE, FOREGROUND + (255,))
    return img


def main():
    IOS_ICONSET.mkdir(parents=True, exist_ok=True)
    MAC_ICONSET.mkdir(parents=True, exist_ok=True)
    ios_icon().resize((1024, 1024), Image.LANCZOS).save(IOS_ICONSET / "icon-1024.png")
    mac = mac_icon()
    for size in MAC_SIZES:
        for scale in (1, 2):
            pixels = size * scale
            name = f"icon-{size}{'@2x' if scale == 2 else ''}.png"
            mac.resize((pixels, pixels), Image.LANCZOS).save(MAC_ICONSET / name)


if __name__ == "__main__":
    main()
