#!/usr/bin/env python3
"""
Convert image to JD79661 4-color e-paper format (black/white/yellow/red)
Output: C array for embedding in firmware

Strategy — evenly-spaced luminance dithering:
  1. Convert source to grayscale (luminance)
  2. Dither to 4 EVENLY-SPACED gray levels (0, 85, 170, 255)
     → This produces the smoothest possible tonal gradients
  3. Map: level0→black, level1→red, level2→yellow, level3→white
  4. Post-process: where source hue is strongly red or yellow,
     swap the mid-tones to add colour hints

Why evenly-spaced?  The e-paper palette luminances are very uneven
(black=0, red≈60, yellow≈211, white=255).  Dithering to those levels
directly creates ugly banding because the red→yellow gap is huge.
By dithering to even levels first, we get smooth gradients, then we
simply relabel the 4 levels to the 4 e-paper colours.
"""

from PIL import Image, ImageEnhance, ImageFilter
import sys
import os
import numpy as np

# Display specs
WIDTH = 152
HEIGHT = 152

# ── E-paper palette in sRGB (for preview rendering) ──────────────────
PALETTE_SRGB = {
    'black':  (0,   0,   0),
    'white':  (255, 255, 255),
    'yellow': (255, 230, 0),
    'red':    (200, 0,   0),
}

COLOR_CODES = {
    'black':  0b00,
    'white':  0b01,
    'yellow': 0b10,
    'red':    0b11,
}

# 4 evenly-spaced luminance levels for dithering
GRAY_LEVELS = np.array([0.0, 85.0, 170.0, 255.0])
# Mapping from gray level index → e-paper colour name
# 0 (darkest)  → black
# 1 (dark-mid) → red
# 2 (light-mid)→ yellow
# 3 (brightest)→ white
INDEX_TO_NAME = ['black', 'red', 'yellow', 'white']


# ── Floyd-Steinberg on single-channel ────────────────────────────────
def find_nearest_level(val):
    idx = int(np.argmin(np.abs(GRAY_LEVELS - val)))
    return idx, GRAY_LEVELS[idx]


def floyd_steinberg_gray(gray):
    """
    Serpentine Floyd-Steinberg dithering on grayscale image,
    quantised to 4 evenly-spaced levels.
    """
    pixels = gray.astype(np.float64).copy()
    h, w = pixels.shape
    result = np.zeros((h, w), dtype=np.int32)

    for y in range(h):
        if y % 2 == 0:
            xs, d = range(w), 1
        else:
            xs, d = range(w - 1, -1, -1), -1

        for x in xs:
            old = float(np.clip(pixels[y, x], 0.0, 255.0))
            idx, new = find_nearest_level(old)
            result[y, x] = idx
            err = old - new

            xf = x + d
            if 0 <= xf < w:
                pixels[y, xf] += err * 7.0 / 16.0
            if y + 1 < h:
                xb = x - d
                if 0 <= xb < w:
                    pixels[y + 1, xb] += err * 3.0 / 16.0
                pixels[y + 1, x] += err * 5.0 / 16.0
                if 0 <= xf < w:
                    pixels[y + 1, xf] += err * 1.0 / 16.0

    return result


# ── Hue-aware post-process ───────────────────────────────────────────
def hue_post_process(index_map, rgb_arr):
    """
    For pixels assigned to the two mid-tones (red=1, yellow=2),
    check the original colour.  If the source pixel has a strong
    red or yellow hue, swap accordingly.  This adds colour information
    without destroying the luminance structure.
    """
    h, w = index_map.shape
    out = index_map.copy()

    for y in range(h):
        for x in range(w):
            idx = index_map[y, x]
            if idx not in (1, 2):
                continue

            r, g, b = float(rgb_arr[y, x, 0]), float(rgb_arr[y, x, 1]), float(rgb_arr[y, x, 2])
            mx = max(r, g, b)
            mn = min(r, g, b)
            if mx < 1:
                continue
            sat = (mx - mn) / mx
            if sat < 0.20:
                continue

            diff = mx - mn
            if diff < 1:
                continue
            if mx == r:
                hue = (60.0 * ((g - b) / diff)) % 360
            elif mx == g:
                hue = 60.0 * ((b - r) / diff) + 120
            else:
                hue = 60.0 * ((r - g) / diff) + 240
            hue = hue % 360

            # Red/warm hues (330°–40°)
            if (hue > 330 or hue < 40) and sat > 0.30:
                out[y, x] = 1  # red
            # Yellow/green hues (40°–100°)
            elif 40 <= hue < 100 and sat > 0.30:
                out[y, x] = 2  # yellow

    return out


# ── Main conversion ──────────────────────────────────────────────────
def convert_image(input_path, output_path):
    print(f"Loading image: {input_path}")
    img = Image.open(input_path)

    # ── Center crop to square ──
    w, h = img.size
    if w != h:
        crop_size = min(w, h)
        left = (w - crop_size) // 2
        top = (h - crop_size) // 2
        img = img.crop((left, top, left + crop_size, top + crop_size))
        print(f"Center-cropped to {crop_size}x{crop_size}")

    img = img.resize((WIDTH, HEIGHT), Image.Resampling.LANCZOS).convert('RGB')

    # ── Preprocessing ──
    # Gentle denoise
    img = img.filter(ImageFilter.GaussianBlur(radius=0.3))

    # Auto-level on luminance (preserve colour ratios)
    arr = np.array(img, dtype=np.float64)
    gray = 0.299 * arr[:, :, 0] + 0.587 * arr[:, :, 1] + 0.114 * arr[:, :, 2]
    lo, hi = np.percentile(gray, [0.5, 99.5])
    if hi - lo > 10:
        scale = 255.0 / (hi - lo)
        arr = np.clip((arr - lo) * scale, 0, 255)
    img = Image.fromarray(arr.astype(np.uint8), 'RGB')

    # Slight brightness boost to compensate for dark palette (red is very dark)
    img = ImageEnhance.Brightness(img).enhance(1.08)
    # Moderate contrast
    img = ImageEnhance.Contrast(img).enhance(1.15)
    # Saturation boost for hue detection
    img = ImageEnhance.Color(img).enhance(1.3)
    # Mild sharpen
    img = ImageEnhance.Sharpness(img).enhance(1.1)

    rgb_arr = np.array(img, dtype=np.float64)

    # ── Luminance for dithering ──
    gray = 0.299 * rgb_arr[:, :, 0] + 0.587 * rgb_arr[:, :, 1] + 0.114 * rgb_arr[:, :, 2]

    print(f"Image resized to {WIDTH}x{HEIGHT}")
    print("Applying even-level Floyd-Steinberg dithering (4 gray levels)...")

    # ── Dither ──
    index_map = floyd_steinberg_gray(gray)

    # ── Hue refinement ──
    print("Applying hue-aware colour refinement...")
    index_map = hue_post_process(index_map, rgb_arr)

    # ── Build byte buffer ──
    buffer = []
    for y in range(HEIGHT):
        for x in range(0, WIDTH, 4):
            byte_val = 0
            for i in range(4):
                if x + i < WIDTH:
                    name = INDEX_TO_NAME[index_map[y, x + i]]
                    byte_val |= COLOR_CODES[name] << ((3 - i) * 2)
            buffer.append(byte_val)

    print(f"Buffer size: {len(buffer)} bytes")

    # ── Stats ──
    color_count = {n: 0 for n in INDEX_TO_NAME}
    for y in range(HEIGHT):
        for x in range(WIDTH):
            color_count[INDEX_TO_NAME[index_map[y, x]]] += 1
    total = WIDTH * HEIGHT
    print("Color distribution:")
    for c in ['black', 'red', 'yellow', 'white']:
        print(f"  {c}: {color_count[c] / total * 100:.1f}%")

    # ── C header ──
    var_name = os.path.splitext(os.path.basename(output_path))[0]
    with open(output_path, 'w') as f:
        f.write(f"/* Auto-generated from {os.path.basename(input_path)} */\n")
        f.write(f"/* Image size: {WIDTH}x{HEIGHT}, 4-color (black/white/yellow/red) */\n\n")
        f.write(f"#ifndef IMAGE_{var_name.upper()}_H\n")
        f.write(f"#define IMAGE_{var_name.upper()}_H\n\n")
        f.write(f"#include <stdint.h>\n\n")
        f.write(f"#define IMAGE_{var_name.upper()}_SIZE {len(buffer)}\n\n")
        f.write(f"static const uint8_t image_{var_name}[{len(buffer)}] = {{\n")
        for i in range(0, len(buffer), 16):
            row = buffer[i:i + 16]
            f.write(f"    {', '.join(f'0x{b:02X}' for b in row)},\n")
        f.write("};\n\n")
        f.write(f"#endif /* IMAGE_{var_name.upper()}_H */\n")
    print(f"Generated: {output_path}")

    # ── Preview ──
    preview_data = np.zeros((HEIGHT, WIDTH, 3), dtype=np.uint8)
    for y in range(HEIGHT):
        for x in range(WIDTH):
            name = INDEX_TO_NAME[index_map[y, x]]
            preview_data[y, x] = PALETTE_SRGB[name]
    preview_img = Image.fromarray(preview_data, 'RGB')
    preview_path = output_path.replace('.h', '_preview.png')
    preview_img.save(preview_path)
    print(f"Preview saved: {preview_path}")


if __name__ == '__main__':
    if len(sys.argv) != 3:
        print("Usage: python convert_image.py <input_image> <output.h>")
        print("Example: python convert_image.py photo.jpg src/image_photo.h")
        sys.exit(1)

    input_path = sys.argv[1]
    output_path = sys.argv[2]

    if not os.path.exists(input_path):
        print(f"Error: Input file not found: {input_path}")
        sys.exit(1)

    convert_image(input_path, output_path)
    print("\nDone! Include this file in your code:")
    print(f'  #include "{os.path.basename(output_path)}"')


