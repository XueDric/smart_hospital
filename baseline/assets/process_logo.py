# -*- coding: utf-8 -*-
"""把 logo.jpg（居中圆形 logo）转成鸿蒙所需的各种图标资源。

- 去白底（从四边 flood-fill 相连的白色像素 → 透明）
- 裁剪到内容 bbox 后等比居中缩放
- 图标前景用 78%（更大，接近遮罩极限），登录 logo 铺满 100%，startIcon 用 90%
"""
from PIL import Image
import os
import numpy as np
from collections import deque

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
SRC = os.path.join(HERE, 'logo.jpg')


def load_clean():
    """打开 logo.jpg 并把白底 flood-fill 成透明。"""
    im = Image.open(SRC).convert('RGBA')
    arr = np.array(im)
    h, w = arr.shape[:2]
    r, g, b = arr[:, :, 0].astype(int), arr[:, :, 1].astype(int), arr[:, :, 2].astype(int)
    white = (r > 235) & (g > 235) & (b > 235)
    visited = np.zeros((h, w), bool)
    q = deque()
    for x in range(w):
        for y in (0, h - 1):
            if white[y, x] and not visited[y, x]:
                visited[y, x] = True
                q.append((y, x))
    for y in range(h):
        for x in (0, w - 1):
            if white[y, x] and not visited[y, x]:
                visited[y, x] = True
                q.append((y, x))
    while q:
        y, x = q.popleft()
        arr[y, x, 3] = 0
        for dy, dx in ((1, 0), (-1, 0), (0, 1), (0, -1)):
            ny, nx = y + dy, x + dx
            if 0 <= ny < h and 0 <= nx < w and white[ny, nx] and not visited[ny, nx]:
                visited[ny, nx] = True
                q.append((ny, nx))
    return Image.fromarray(arr)


CLEAN = load_clean()


def fit(canvas_size, fill):
    """裁剪内容后等比缩放到 fill*canvas_size 最长边，居中贴在透明 canvas 上。"""
    bbox = CLEAN.getchannel('A').getbbox()
    cropped = CLEAN.crop(bbox)
    target = int(canvas_size * fill)
    cw, ch = cropped.size
    scale = target / max(cw, ch)
    nw, nh = int(cw * scale), int(ch * scale)
    resized = cropped.resize((nw, nh), Image.LANCZOS)
    canvas = Image.new('RGBA', (canvas_size, canvas_size), (0, 0, 0, 0))
    canvas.alpha_composite(resized, ((canvas_size - nw) // 2, (canvas_size - nh) // 2))
    return canvas


def white_bg(canvas_size):
    return Image.new('RGB', (canvas_size, canvas_size), (255, 255, 255))


def on_white(canvas_size, fill):
    bg = white_bg(canvas_size).convert('RGBA')
    bg.alpha_composite(fit(canvas_size, fill))
    return bg


# 1) 登录页 logo（透明 512，铺满 100%）
fit(512, 1.0).save(os.path.join(ROOT, 'entry', 'src', 'main', 'resources', 'base', 'media', 'logo.png'))

# 2) AppScope 分层图标（1024，前景 78%）
fit(1024, 0.78).save(os.path.join(ROOT, 'AppScope', 'resources', 'base', 'media', 'foreground.png'))
white_bg(1024).save(os.path.join(ROOT, 'AppScope', 'resources', 'base', 'media', 'background.png'))

# 3) entry 模块分层图标（288）
fit(288, 0.78).save(os.path.join(ROOT, 'entry', 'src', 'main', 'resources', 'base', 'media', 'foreground.png'))
white_bg(288).save(os.path.join(ROOT, 'entry', 'src', 'main', 'resources', 'base', 'media', 'background.png'))

# 4) startIcon（144，白底 90%）
on_white(144, 0.90).save(os.path.join(ROOT, 'entry', 'src', 'main', 'resources', 'base', 'media', 'startIcon.png'))

print('OK: 已从 logo.jpg（去白底、居中）重新生成全部图标')
