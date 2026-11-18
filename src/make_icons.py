# -*- coding: utf-8 -*-
# make_icons.py - build GeYi Group branded ICO from the supplied logo PNG.
# Small sizes use the red "G" mark (recognisable at 16x16 in the tray),
# large sizes use the full wordmark on a white square.
# All ICO frames are 32bpp DIB (works on Win7 / Win10 / Win11, no PNG-in-ICO dependency).
import os
import struct
from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
DELIVERY = os.path.dirname(HERE)
PAYLOAD = os.path.join(DELIVERY, 'payload')
LOGO_SRC = r'C:\Users\mingjiu.wang\.workbuddy\clipboard-images\clipboard-2026-11-14T07-04-05-985Z-aa0d9828.png'

RED = (198, 37, 32, 255)
BLUE = (22, 46, 117, 255)
WHITE = (255, 255, 255, 255)


def rounded_backdrop(n):
    im = Image.new('RGBA', (n, n), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    r = max(2, int(n * 0.18))
    d.rounded_rectangle((0, 0, n - 1, n - 1), radius=r, fill=WHITE)
    return im


def red_mark():
    """Crop the red G block out of the logo and make its white background transparent."""
    src = Image.open(LOGO_SRC).convert('RGBA')
    crop = src.crop((14, 19, 72, 77))  # 58x58 around the red G (bbox 17,22-68,74)
    px = crop.load()
    for y in range(crop.height):
        for x in range(crop.width):
            r, g, b, a = px[x, y]
            if r > 225 and g > 225 and b > 225:
                px[x, y] = (0, 0, 0, 0)
            elif r > 120 and g < 120 and b < 120:
                px[x, y] = RED
            else:
                px[x, y] = (max(0, r - 30), g, b, 255)
    return crop


def small_frame(n, mark):
    im = rounded_backdrop(n)
    side = max(6, int(n * 0.78))
    g = mark.resize((side, side), Image.LANCZOS)
    im.paste(g, ((n - side) // 2, (n - side) // 2), g)
    return im


def large_frame(n):
    src = Image.open(LOGO_SRC).convert('RGBA')
    im = Image.new('RGBA', (n, n), WHITE)
    w = int(n * 0.90)
    h = int(round(src.height * w / float(src.width)))
    logo = src.resize((w, h), Image.LANCZOS)
    im.paste(logo, ((n - w) // 2, (n - h) // 2), logo)
    return im


def dib_bytes(img):
    w, h = img.size
    img = img.convert('RGBA')
    px = img.load()
    xor = bytearray()
    for y in range(h - 1, -1, -1):
        for x in range(w):
            r, g, b, a = px[x, y]
            xor += bytes((b, g, r, a))
    stride = ((w + 31) // 32) * 4
    and_mask = bytearray(stride * h)
    hdr = struct.pack('<IiiHHIIiiII', 40, w, h * 2, 1, 32, 0,
                      len(xor) + len(and_mask), 0, 0, 0, 0)
    return bytes(hdr) + bytes(xor) + bytes(and_mask)


def write_ico(path, frames):
    out = struct.pack('<HHH', 0, 1, len(frames))
    off = 6 + 16 * len(frames)
    blobs = []
    for size, img in frames:
        data = dib_bytes(img)
        b = 0 if size >= 256 else size
        out += struct.pack('<BBBBHHII', b, b, 0, 0, 1, 32, len(data), off)
        blobs.append(data)
        off += len(data)
    for data in blobs:
        out += data
    with open(path, 'wb') as f:
        f.write(out)
    return len(out)


def main():
    if not os.path.isdir(PAYLOAD):
        os.makedirs(PAYLOAD)
    if not os.path.isfile(LOGO_SRC):
        raise SystemExit('LOGO SRC MISSING: ' + LOGO_SRC)
    mark = red_mark()
    frames = []
    for n in (16, 24, 32):
        frames.append((n, small_frame(n, mark)))
    for n in (48, 64, 128, 256):
        frames.append((n, large_frame(n)))

    ico_src = os.path.join(HERE, 'geyi.ico')
    ico_pay = os.path.join(PAYLOAD, 'geyi.ico')
    write_ico(ico_src, frames)
    # The copy embedded in the exe only needs tray/dialog sizes; keeping 256x256
    # DIB out of the payload saves ~360 KB of base64 resource data.
    size = write_ico(ico_pay, frames[:4])

    # banner for the config dialog (keep the original aspect ratio)
    logo = Image.open(LOGO_SRC).convert('RGBA')
    bg = Image.new('RGBA', (logo.width, logo.height), WHITE)
    bg.paste(logo, (0, 0), logo)
    bg.convert('RGB').save(os.path.join(PAYLOAD, 'geyi_logo.png'))

    # quick sanity: Pillow must be able to read every frame back
    chk = Image.open(ico_src)
    print('ICO=' + ico_src)
    print('SIZES=' + str(sorted(chk.ico.sizes())))
    print('BYTES=' + str(size))
    print('PAYLOAD_ICO=' + ico_pay)
    print('BANNER=' + os.path.join(PAYLOAD, 'geyi_logo.png'))


if __name__ == '__main__':
    main()
