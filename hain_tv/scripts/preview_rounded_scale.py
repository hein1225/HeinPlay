from pathlib import Path
from PIL import Image, ImageDraw

base = Path(__file__).parent.parent
src_path = base / '..' / 'plan' / 'mo_ico.png'
im = Image.open(src_path).convert('RGBA')

bg_color = (0x0A, 0x0A, 0x0F, 0xFF)
size = 432
radius_ratio = 0.22
scales = [0.85, 0.90, 1.0]

def make_preview(scale):
    src_size = int(size * scale)
    scaled = im.resize((src_size, src_size), Image.LANCZOS)
    left = (size - src_size) // 2
    top = (size - src_size) // 2
    fg = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    fg.paste(scaled, (left, top))

    bg = Image.new('RGBA', (size, size), bg_color)
    bg.alpha_composite(fg)

    mask = Image.new('L', (size, size), 0)
    draw = ImageDraw.Draw(mask)
    radius = int(size * radius_ratio)
    draw.rounded_rectangle((0, 0, size, size), radius=radius, fill=255)

    out = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    out.paste(bg, (0, 0), mask)
    return out

previews = [make_preview(s) for s in scales]
composite = Image.new('RGBA', (size * len(scales), size), (0, 0, 0, 0))
for i, p in enumerate(previews):
    composite.paste(p, (i * size, 0))

out_path = base / 'scripts' / 'rounded_scale_preview.png'
composite.save(out_path)
print('saved', out_path)
for s in scales:
    print(s)
