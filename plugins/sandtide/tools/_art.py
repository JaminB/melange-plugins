"""Shared helpers for Sandtide's art generators (make_hud.py, make_sprites.py, make_textures.py).

Everything is rendered with numpy on a supersampled grid (SS samples per output pixel on each axis), using signed
distance fields for the shapes, height fields for the bevels and engraving, and a simple Lambert + Blinn + environment
model for the lighting. Layers are kept premultiplied while compositing and are box-filtered down to the output size,
which is where the anti-aliasing comes from. Seeded numpy generators only: the output is deterministic.
"""
import math

import numpy as np
from PIL import Image, ImageFilter

SS = 4  # supersampling factor per axis

# Light comes from the upper left and towards the viewer. Image axes: x right, y DOWN, z out of the screen.
_L = np.array([-0.48, -0.66, 0.58])
LIGHT = _L / np.linalg.norm(_L)
_H = LIGHT + np.array([0.0, 0.0, 1.0])
HALF = _H / np.linalg.norm(_H)


# ---------------------------------------------------------------- grid and SDF primitives
def grid(w, h, ox=0.0, oy=0.0, ss=SS):
    """Sample centres of a w x h canvas (in output pixels), offset by (ox, oy) canvas units."""
    xs = (np.arange(w * ss, dtype=np.float64) + 0.5) / ss + ox
    ys = (np.arange(h * ss, dtype=np.float64) + 0.5) / ss + oy
    return np.meshgrid(xs, ys)


def cov(d, ss=SS, soft=1.0):
    """Coverage of the inside (d < 0) with a one-sample-wide anti-aliased edge (wider with soft > 1)."""
    return np.clip(0.5 - d * ss / soft, 0.0, 1.0)


def smoothstep(e0, e1, x):
    t = np.clip((x - e0) / (e1 - e0), 0.0, 1.0)
    return t * t * (3.0 - 2.0 * t)


def sd_circle(X, Y, cx, cy, r):
    return np.hypot(X - cx, Y - cy) - r


def sd_ellipse(X, Y, cx, cy, rx, ry):
    """Inigo Quilez's cheap ellipse distance bound: exact on the curve, good enough a few pixels away."""
    px = (X - cx) / rx
    py = (Y - cy) / ry
    k0 = np.hypot(px, py)
    k1 = np.hypot(px / rx, py / ry)
    return k0 * (k0 - 1.0) / np.maximum(k1, 1e-6)


def sd_rbox(X, Y, cx, cy, hx, hy, r):
    qx = np.abs(X - cx) - hx + r
    qy = np.abs(Y - cy) - hy + r
    return np.hypot(np.maximum(qx, 0), np.maximum(qy, 0)) + np.minimum(np.maximum(qx, qy), 0) - r


def sd_vcapsule(X, Y, cx, y0, y1, r):
    return np.hypot(X - cx, Y - np.clip(Y, y0, y1)) - r


def sd_segment(X, Y, ax, ay, bx, by, r):
    pax, pay = X - ax, Y - ay
    bax, bay = bx - ax, by - ay
    h = np.clip((pax * bax + pay * bay) / (bax * bax + bay * bay), 0.0, 1.0)
    return np.hypot(pax - bax * h, pay - bay * h) - r


def smin(a, b, k):
    h = np.clip(0.5 + 0.5 * (b - a) / k, 0.0, 1.0)
    return b * (1 - h) + a * h - k * h * (1 - h)


# ---------------------------------------------------------------- noise
def value_noise(shape, cells, rng, order=3):
    """Smooth value noise: a (cells x cells*aspect) random grid resized up with bicubic filtering, in -1..1."""
    h, w = shape
    gh = max(2, int(round(cells)))
    gw = max(2, int(round(cells * w / h)))
    g = rng.random((gh, gw)).astype(np.float32)
    im = Image.fromarray(g, mode="F").resize((w, h), Image.BICUBIC if order == 3 else Image.BILINEAR)
    return np.asarray(im, dtype=np.float64) * 2.0 - 1.0


def fbm(shape, cells, rng, octaves=4, gain=0.5):
    out = np.zeros(shape)
    amp, tot, c = 1.0, 0.0, cells
    for _ in range(octaves):
        out += amp * value_noise(shape, c, rng)
        tot += amp
        amp *= gain
        c *= 2.0
    return out / tot


def tile_noise(n, cells, rng, octaves=4, gain=0.5):
    """Seamlessly tileable fBm on an n x n square (each octave is a periodic random grid upsampled by FFT)."""
    out = np.zeros((n, n))
    amp, tot, c = 1.0, 0.0, cells
    for _ in range(octaves):
        g = rng.random((c, c)) * 2.0 - 1.0
        # periodic upsample: zero-pad the spectrum
        F = np.fft.fftshift(np.fft.fft2(g))
        P = np.zeros((n, n), dtype=complex)
        o = (n - c) // 2
        P[o:o + c, o:o + c] = F
        up = np.real(np.fft.ifft2(np.fft.ifftshift(P))) * (n * n) / (c * c)
        up /= np.abs(up).max() + 1e-9
        out += amp * up
        tot += amp
        amp *= gain
        c = min(c * 2, n // 2)
    return out / tot


def _box(a, r, axis):
    """Box filter of half-width r samples along one axis (edge-clamped), via a cumulative sum."""
    if r < 1:
        return a
    pad = [(0, 0)] * a.ndim
    pad[axis] = (r + 1, r)
    p = np.pad(a, pad, mode="edge")
    c = np.cumsum(p, axis=axis)
    n = a.shape[axis]
    hi = np.take(c, np.arange(2 * r + 1, 2 * r + 1 + n), axis=axis)
    lo = np.take(c, np.arange(0, n), axis=axis)
    return (hi - lo) / (2 * r + 1)


def blur(a, radius):
    """Gaussian-like blur (three box passes per axis) with standard deviation `radius` samples."""
    if radius <= 0:
        return a
    # box half-widths for 3 passes approximating a gaussian of this sigma
    w = math.sqrt(12.0 * radius * radius / 3.0 + 1.0)
    r = max(0, int(round((w - 1) / 2)))
    out = a.astype(np.float64)
    for axis in (0, 1):
        for _ in range(3):
            out = _box(out, r, axis)
    if r == 0:
        # tiny radius: one 3-tap pass
        k = radius * radius / (1 + radius * radius)
        for axis in (0, 1):
            out = out * (1 - k) + (np.roll(out, 1, axis) + np.roll(out, -1, axis)) * k / 2
    return out


# ---------------------------------------------------------------- layers (premultiplied RGB + alpha, 0..1 floats)
class Layer:
    def __init__(self, shape):
        self.rgb = np.zeros(shape + (3,))
        self.a = np.zeros(shape)

    def paint(self, color, alpha):
        """Composite `color` (an RGB tuple 0..255 or an HxWx3 array 0..1) with coverage `alpha` OVER this layer."""
        alpha = np.clip(alpha, 0.0, 1.0)
        if isinstance(color, tuple):
            c = np.array(color, dtype=np.float64) / 255.0
            src = alpha[..., None] * c
        else:
            src = alpha[..., None] * np.clip(color, 0.0, 1.0)
        self.rgb = src + self.rgb * (1.0 - alpha[..., None])
        self.a = alpha + self.a * (1.0 - alpha)

    def under(self, other):
        """Composite `other` UNDER this layer (in place)."""
        self.rgb = self.rgb + other.rgb * (1.0 - self.a[..., None])
        self.a = self.a + other.a * (1.0 - self.a)

    def over(self, other):
        """Composite `other` OVER this layer (in place)."""
        self.rgb = other.rgb + self.rgb * (1.0 - other.a[..., None])
        self.a = other.a + self.a * (1.0 - other.a)

    def mask(self, m):
        self.rgb = self.rgb * m[..., None]
        self.a = self.a * m

    def copy(self):
        c = Layer(self.a.shape)
        c.rgb = self.rgb.copy()
        c.a = self.a.copy()
        return c


def down(arr, ss=SS):
    h, w = arr.shape[0] // ss, arr.shape[1] // ss
    if arr.ndim == 2:
        return arr.reshape(h, ss, w, ss).mean(axis=(1, 3))
    return arr.reshape(h, ss, w, ss, arr.shape[2]).mean(axis=(1, 3))


def to_image(layer, ss=SS, crop=None, bleed=True):
    """Box-filter a supersampled premultiplied layer down to an RGBA PIL image (straight alpha). Fully transparent
    pixels get the colour of the nearest visible ones, so mip levels and bilinear filtering never pull in black."""
    rgb = down(layer.rgb, ss)
    a = down(layer.a, ss)
    if crop is not None:
        x0, y0, x1, y1 = crop
        rgb = rgb[y0:y1, x0:x1]
        a = a[y0:y1, x0:x1]
    straight = rgb / np.maximum(a, 1e-6)[..., None]
    if bleed and (a < 1e-4).any():
        fill = np.zeros_like(rgb)
        got = np.zeros_like(a)
        for rad in (1.5, 4, 10, 24, 60):
            pa = blur(a, rad)
            prgb = np.stack([blur(rgb[..., i], rad) for i in range(3)], axis=-1)
            c = prgb / np.maximum(pa, 1e-9)[..., None]
            take = (got < 0.5) & (pa > 1e-5)
            fill[take] = c[take]
            got[take] = 1.0
        mean = rgb.sum(axis=(0, 1)) / max(a.sum(), 1e-6)
        fill[got < 0.5] = mean
        empty = a < 1e-4
        straight[empty] = fill[empty]
    out = np.concatenate([np.clip(straight, 0, 1), np.clip(a, 0, 1)[..., None]], axis=-1)
    return Image.fromarray((out * 255.0 + 0.5).astype(np.uint8), mode="RGBA")


def alpha_sprite(alpha, ss=SS):
    """White RGB everywhere, shape only in alpha (the Kindjal sprite convention: the client tints at draw time)."""
    a = down(alpha, ss) if ss > 1 else alpha
    out = np.empty(a.shape + (4,))
    out[..., :3] = 1.0
    out[..., 3] = np.clip(a, 0, 1)
    return Image.fromarray((out * 255.0 + 0.5).astype(np.uint8), mode="RGBA")


# ---------------------------------------------------------------- shading
def normals(h, ss=SS, strength=1.0):
    """Unit normals from a height field given in canvas pixels."""
    gy, gx = np.gradient(h)
    nx = -gx * ss * strength
    ny = -gy * ss * strength
    nz = np.ones_like(h)
    inv = 1.0 / np.sqrt(nx * nx + ny * ny + 1.0)
    return nx * inv, ny * inv, nz * inv


def ramp(t, stops):
    """Piecewise-linear colour ramp: stops = [(t, (r,g,b)), ...] with t ascending, colours 0..255. Returns HxWx3 0..1."""
    t = np.clip(t, stops[0][0], stops[-1][0])
    out = np.zeros(t.shape + (3,))
    for (t0, c0), (t1, c1) in zip(stops[:-1], stops[1:]):
        m = (t >= t0) & (t <= t1)
        u = ((t - t0) / max(t1 - t0, 1e-9))[m]
        for i in range(3):
            out[..., i][m] = (c0[i] + (c1[i] - c0[i]) * u) / 255.0
    return out


BRASS = [(0.0, (46, 26, 10)), (0.30, (112, 70, 26)), (0.58, (182, 130, 52)), (0.80, (226, 182, 96)),
         (1.0, (255, 236, 170))]
BONE = [(0.0, (70, 56, 40)), (0.35, (150, 130, 98)), (0.65, (214, 198, 160)), (0.88, (238, 228, 200)),
        (1.0, (252, 248, 232))]
ENAMEL = [(0.0, (20, 6, 4)), (0.5, (88, 26, 14)), (1.0, (170, 70, 36))]
IRON = [(0.0, (8, 6, 5)), (0.5, (36, 28, 22)), (1.0, (90, 76, 62))]


def shade(nx, ny, nz, stops, spec_pow=48.0, spec=0.9, env=0.35, rough_spec=None):
    """Polished-material shading: Lambert into a colour ramp, a fake sky/ground environment reflection from the
    normal's vertical component, and a Blinn highlight. Returns HxWx3 0..1."""
    lam = np.clip(nx * LIGHT[0] + ny * LIGHT[1] + nz * LIGHT[2], 0.0, 1.0)
    base = ramp(0.12 + 0.88 * lam, stops)
    sky = np.clip(0.5 - 0.5 * ny + 0.25 * nz, 0.0, 1.0)  # facing up -> bright
    env_c = ramp(sky, stops)
    nh = np.clip(nx * HALF[0] + ny * HALF[1] + nz * HALF[2], 0.0, 1.0)
    sp = nh ** spec_pow * spec
    if rough_spec is not None:
        sp = sp * rough_spec
    col = base * (1.0 - env) + env_c * env + sp[..., None] * np.array([1.0, 0.95, 0.82])
    return np.clip(col, 0.0, 1.0)


def save(img, path):
    path.parent.mkdir(parents=True, exist_ok=True)
    img.save(path, optimize=True)
