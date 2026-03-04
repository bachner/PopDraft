#!/usr/bin/env python3
"""Generate a DMG background image for PopDraft drag-to-install installer.

Pure Python stdlib implementation (struct + zlib) — no Pillow needed.
Generates a 660x400 PNG with gradient background, centered arrow, and instruction text.

Usage: python3 scripts/create-dmg-background.py [output_path]
"""

import struct
import sys
import zlib

WIDTH = 660
HEIGHT = 400


def create_png(pixels, width, height):
    """Create a PNG file from raw RGBA pixel data."""

    def chunk(chunk_type, data):
        c = chunk_type + data
        crc = struct.pack(">I", zlib.crc32(c) & 0xFFFFFFFF)
        return struct.pack(">I", len(data)) + c + crc

    signature = b"\x89PNG\r\n\x1a\n"
    ihdr = chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))

    # Build raw image data with filter bytes
    raw = bytearray()
    for y in range(height):
        raw.append(0)  # No filter
        offset = y * width * 4
        raw.extend(pixels[offset : offset + width * 4])

    compressed = zlib.compress(bytes(raw), 9)
    idat = chunk(b"IDAT", compressed)
    iend = chunk(b"IEND", b"")

    return signature + ihdr + idat + iend


def blend(bg, fg, alpha):
    """Alpha-blend fg over bg."""
    a = alpha / 255.0
    return int(bg * (1 - a) + fg * a)


def draw_filled_circle(pixels, cx, cy, r, color, width):
    """Draw a filled circle."""
    r2 = r * r
    for dy in range(-r, r + 1):
        for dx in range(-r, r + 1):
            if dx * dx + dy * dy <= r2:
                px, py = cx + dx, cy + dy
                if 0 <= px < width and 0 <= py < HEIGHT:
                    offset = (py * width + px) * 4
                    pixels[offset : offset + 4] = color


def draw_rect(pixels, x1, y1, x2, y2, color, width):
    """Draw a filled rectangle."""
    for y in range(max(0, y1), min(HEIGHT, y2 + 1)):
        for x in range(max(0, x1), min(width, x2 + 1)):
            offset = (y * width + x) * 4
            pixels[offset : offset + 4] = color


def draw_antialiased_line(pixels, x1, y1, x2, y2, color, width_img, thickness=2):
    """Draw a line with basic anti-aliasing."""
    dx = abs(x2 - x1)
    dy = abs(y2 - y1)
    steps = max(dx, dy, 1)
    for i in range(steps + 1):
        t = i / steps
        x = x1 + (x2 - x1) * t
        y = y1 + (y2 - y1) * t
        for oy in range(-thickness, thickness + 1):
            for ox in range(-thickness, thickness + 1):
                px, py = int(x + ox), int(y + oy)
                if 0 <= px < width_img and 0 <= py < HEIGHT:
                    dist = (ox * ox + oy * oy) ** 0.5
                    if dist <= thickness:
                        alpha = max(0, min(255, int(255 * (1 - dist / (thickness + 0.5)))))
                        offset = (py * width_img + px) * 4
                        for c in range(3):
                            pixels[offset + c] = blend(
                                pixels[offset + c], color[c], alpha
                            )
                        pixels[offset + 3] = max(pixels[offset + 3], alpha)


# Simple 5x7 bitmap font for uppercase + lowercase + space + punctuation
FONT = {
    "A": ["01110", "10001", "10001", "11111", "10001", "10001", "10001"],
    "B": ["11110", "10001", "10001", "11110", "10001", "10001", "11110"],
    "C": ["01110", "10001", "10000", "10000", "10000", "10001", "01110"],
    "D": ["11110", "10001", "10001", "10001", "10001", "10001", "11110"],
    "E": ["11111", "10000", "10000", "11110", "10000", "10000", "11111"],
    "F": ["11111", "10000", "10000", "11110", "10000", "10000", "10000"],
    "G": ["01110", "10001", "10000", "10111", "10001", "10001", "01110"],
    "H": ["10001", "10001", "10001", "11111", "10001", "10001", "10001"],
    "I": ["01110", "00100", "00100", "00100", "00100", "00100", "01110"],
    "J": ["00111", "00010", "00010", "00010", "00010", "10010", "01100"],
    "K": ["10001", "10010", "10100", "11000", "10100", "10010", "10001"],
    "L": ["10000", "10000", "10000", "10000", "10000", "10000", "11111"],
    "M": ["10001", "11011", "10101", "10101", "10001", "10001", "10001"],
    "N": ["10001", "11001", "10101", "10011", "10001", "10001", "10001"],
    "O": ["01110", "10001", "10001", "10001", "10001", "10001", "01110"],
    "P": ["11110", "10001", "10001", "11110", "10000", "10000", "10000"],
    "Q": ["01110", "10001", "10001", "10001", "10101", "10010", "01101"],
    "R": ["11110", "10001", "10001", "11110", "10100", "10010", "10001"],
    "S": ["01110", "10001", "10000", "01110", "00001", "10001", "01110"],
    "T": ["11111", "00100", "00100", "00100", "00100", "00100", "00100"],
    "U": ["10001", "10001", "10001", "10001", "10001", "10001", "01110"],
    "V": ["10001", "10001", "10001", "10001", "10001", "01010", "00100"],
    "W": ["10001", "10001", "10001", "10101", "10101", "11011", "10001"],
    "X": ["10001", "10001", "01010", "00100", "01010", "10001", "10001"],
    "Y": ["10001", "10001", "01010", "00100", "00100", "00100", "00100"],
    "Z": ["11111", "00001", "00010", "00100", "01000", "10000", "11111"],
    "a": ["00000", "00000", "01110", "00001", "01111", "10001", "01111"],
    "b": ["10000", "10000", "10110", "11001", "10001", "10001", "11110"],
    "c": ["00000", "00000", "01110", "10000", "10000", "10001", "01110"],
    "d": ["00001", "00001", "01101", "10011", "10001", "10001", "01111"],
    "e": ["00000", "00000", "01110", "10001", "11111", "10000", "01110"],
    "f": ["00110", "01001", "01000", "11100", "01000", "01000", "01000"],
    "g": ["00000", "00000", "01111", "10001", "01111", "00001", "01110"],
    "h": ["10000", "10000", "10110", "11001", "10001", "10001", "10001"],
    "i": ["00100", "00000", "01100", "00100", "00100", "00100", "01110"],
    "j": ["00010", "00000", "00110", "00010", "00010", "10010", "01100"],
    "k": ["10000", "10000", "10010", "10100", "11000", "10100", "10010"],
    "l": ["01100", "00100", "00100", "00100", "00100", "00100", "01110"],
    "m": ["00000", "00000", "11010", "10101", "10101", "10001", "10001"],
    "n": ["00000", "00000", "10110", "11001", "10001", "10001", "10001"],
    "o": ["00000", "00000", "01110", "10001", "10001", "10001", "01110"],
    "p": ["00000", "00000", "11110", "10001", "11110", "10000", "10000"],
    "q": ["00000", "00000", "01111", "10001", "01111", "00001", "00001"],
    "r": ["00000", "00000", "10110", "11001", "10000", "10000", "10000"],
    "s": ["00000", "00000", "01110", "10000", "01110", "00001", "11110"],
    "t": ["01000", "01000", "11100", "01000", "01000", "01001", "00110"],
    "u": ["00000", "00000", "10001", "10001", "10001", "10011", "01101"],
    "v": ["00000", "00000", "10001", "10001", "10001", "01010", "00100"],
    "w": ["00000", "00000", "10001", "10001", "10101", "10101", "01010"],
    "x": ["00000", "00000", "10001", "01010", "00100", "01010", "10001"],
    "y": ["00000", "00000", "10001", "10001", "01111", "00001", "01110"],
    "z": ["00000", "00000", "11111", "00010", "00100", "01000", "11111"],
    " ": ["00000", "00000", "00000", "00000", "00000", "00000", "00000"],
    ".": ["00000", "00000", "00000", "00000", "00000", "00000", "00100"],
    "-": ["00000", "00000", "00000", "11111", "00000", "00000", "00000"],
    ":": ["00000", "00000", "00100", "00000", "00000", "00100", "00000"],
}


def draw_text(pixels, text, cx, cy, color, width, scale=2):
    """Draw centered text using bitmap font."""
    char_w = 5 * scale + scale  # character width + spacing
    total_w = len(text) * char_w - scale
    start_x = cx - total_w // 2

    for ci, ch in enumerate(text):
        glyph = FONT.get(ch, FONT.get(" "))
        if glyph is None:
            continue
        for row_i, row in enumerate(glyph):
            for col_i, bit in enumerate(row):
                if bit == "1":
                    for sy in range(scale):
                        for sx in range(scale):
                            px = start_x + ci * char_w + col_i * scale + sx
                            py = cy + row_i * scale + sy
                            if 0 <= px < width and 0 <= py < HEIGHT:
                                offset = (py * width + px) * 4
                                for c in range(3):
                                    pixels[offset + c] = blend(
                                        pixels[offset + c], color[c], color[3]
                                    )
                                pixels[offset + 3] = max(
                                    pixels[offset + 3], color[3]
                                )


def generate_background(output_path):
    """Generate the DMG background image."""
    pixels = bytearray(WIDTH * HEIGHT * 4)

    # Light gradient background (macOS-style)
    for y in range(HEIGHT):
        t = y / HEIGHT
        r = int(240 - t * 15)  # 240 -> 225
        g = int(240 - t * 15)
        b = int(245 - t * 10)  # Slight blue tint
        for x in range(WIDTH):
            offset = (y * WIDTH + x) * 4
            pixels[offset] = r
            pixels[offset + 1] = g
            pixels[offset + 2] = b
            pixels[offset + 3] = 255

    # Arrow pointing right: bar + triangle head
    # Centered between app icon (165) and Applications (495)
    arrow_cx = 330  # center x
    arrow_cy = 200  # center y (same as icons)
    arrow_color = bytearray([120, 120, 130, 220])

    # Arrow bar (horizontal line)
    bar_left = arrow_cx - 45
    bar_right = arrow_cx + 25
    bar_thickness = 5
    draw_rect(
        pixels,
        bar_left,
        arrow_cy - bar_thickness,
        bar_right,
        arrow_cy + bar_thickness,
        arrow_color,
        WIDTH,
    )

    # Arrow head (triangle pointing right)
    head_tip = arrow_cx + 50
    head_base = arrow_cx + 15
    head_half_h = 18
    # Draw triangle by filling rows
    for dy in range(-head_half_h, head_half_h + 1):
        # Linear interpolation: at dy=0 -> tip, at dy=+/-head_half_h -> base
        frac = 1.0 - abs(dy) / head_half_h
        row_right = int(head_base + (head_tip - head_base) * frac)
        y = arrow_cy + dy
        if 0 <= y < HEIGHT:
            for x in range(head_base, row_right + 1):
                if 0 <= x < WIDTH:
                    offset = (y * WIDTH + x) * 4
                    pixels[offset : offset + 4] = arrow_color

    # Instruction text
    text_color = bytearray([100, 100, 110, 200])
    draw_text(
        pixels,
        "Drag PopDraft to Applications to install",
        WIDTH // 2,
        340,
        text_color,
        WIDTH,
        scale=2,
    )

    # Write PNG
    png_data = create_png(pixels, WIDTH, HEIGHT)
    with open(output_path, "wb") as f:
        f.write(png_data)
    print(f"Background image generated: {output_path} ({len(png_data)} bytes)")


if __name__ == "__main__":
    output = sys.argv[1] if len(sys.argv) > 1 else "dmg-background.png"
    generate_background(output)
