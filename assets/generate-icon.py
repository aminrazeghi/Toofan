"""Generates the Toofan CFD icon and logo (toofan-cfd-icon.svg, toofan-cfd-logo.svg).

The mark is exact potential flow, with Kutta circulation, around a Joukowski airfoil:
the streamlines are traced through the analytic velocity field, so they bend the way
real flow around a lifting airfoil does.

Usage: python3 generate-icon.py [output directory, default .]
"""
import cmath, math, sys

ALPHA = math.radians(11)       # angle of attack
MU = complex(-0.13, 0.05)      # circle centre: thickness (-x) and camber (+y)
R = abs(1 - MU)                # circle passes through the trailing edge (zeta = 1)
BETA = math.asin(MU.imag / R)
GAMMA = 4 * math.pi * R * math.sin(ALPHA + BETA)  # Kutta condition, U = 1

def zeta_from_z(z):
    s = cmath.sqrt(z * z - 4)
    a, b = (z + s) / 2, (z - s) / 2
    return a if abs(a - MU) >= abs(b - MU) else b

def velocity(z):
    """Conjugate of the complex velocity -> (u, v) in the airfoil frame."""
    zeta = zeta_from_z(z)
    zp = zeta - MU
    dw_dzeta = cmath.exp(-1j * ALPHA) - R * R * cmath.exp(1j * ALPHA) / (zp * zp) + 1j * GAMMA / (2 * math.pi * zp)
    dz_dzeta = 1 - 1 / (zeta * zeta)
    w = dw_dzeta / dz_dzeta
    return w.conjugate()

# Picture frame: rotate by -ALPHA so the free stream is horizontal and the airfoil pitches nose-up.
ROT = cmath.exp(-1j * ALPHA)
def to_frame(z): return z * ROT
def from_frame(p): return p / ROT

def trace(p0, x_end, ds=0.01):
    pts, p = [p0], p0
    for _ in range(4000):
        def f(q):
            v = velocity(from_frame(q)) * ROT
            return v / abs(v)
        k1 = f(p); k2 = f(p + ds / 2 * k1); k3 = f(p + ds / 2 * k2); k4 = f(p + ds * k3)
        p = p + ds / 6 * (k1 + 2 * k2 + 2 * k3 + k4)
        pts.append(p)
        if p.real > x_end: break
    return pts

# Airfoil outline in the frame.
foil = [to_frame(z + 1 / z) for z in (MU + R * cmath.exp(1j * t) for t in [2 * math.pi * i / 240 for i in range(240)])]
xs = [p.real for p in foil]; ys = [p.imag for p in foil]
cx, cy = (min(xs) + max(xs)) / 2, (min(ys) + max(ys)) / 2
chord = max(xs) - min(xs)

# Icon mapping: 512 canvas, airfoil spans ~52% of the width, centred slightly left/up.
S = 512 * 0.58 / chord
OX, OY = 246, 262
def px(p): return (OX + (p.real - cx) * S, OY - (p.imag - cy) * S)

def catmull(points, closed=False):
    pts = [px(p) for p in points]
    if closed: ext = [pts[-1]] + pts + pts[:2]
    else: ext = [pts[0]] + pts + [pts[-1]]
    d = f"M{pts[0][0]:.1f} {pts[0][1]:.1f}"
    for i in range(1, len(ext) - 2):
        p0, p1, p2, p3 = ext[i - 1], ext[i], ext[i + 1], ext[i + 2]
        c1 = (p1[0] + (p2[0] - p0[0]) / 6, p1[1] + (p2[1] - p0[1]) / 6)
        c2 = (p2[0] - (p3[0] - p1[0]) / 6, p2[1] - (p3[1] - p1[1]) / 6)
        d += f" C{c1[0]:.1f} {c1[1]:.1f} {c2[0]:.1f} {c2[1]:.1f} {p2[0]:.1f} {p2[1]:.1f}"
    return d + (" Z" if closed else "")

def thin(points, step):
    out = points[::step]
    if out[-1] != points[-1]: out.append(points[-1])
    return out

x0 = cx - (OX + 40) / S        # start just beyond the left edge
x1 = cx + (512 - OX + 40) / S  # end beyond the right edge
# Streamline start heights (picture units, relative to airfoil centre), and their weights.
lines = [(+0.84, 16, 0.5), (+0.32, 22, 0.95), (-0.56, 22, 0.95), (-1.06, 16, 0.5)]
paths = []
for dy, width, opacity in lines:
    pts = thin(trace(complex(x0, cy + dy * chord / 2), x1), 12)
    # Cut exactly at the tile's left and right edges (x = 0 and 512): no clip path needed, which
    # Qt's SVG renderer ignores inside transformed groups.
    left, right = (0 - OX) / S + cx, (512 - OX) / S + cx
    def cut(a, b, x): return a + (b - a) * ((x - a.real) / (b.real - a.real))
    i = next(k for k, q in enumerate(pts) if q.real >= left)
    j = next(k for k, q in enumerate(pts) if q.real >= right)
    pts = [cut(pts[i - 1], pts[i], left)] + pts[i:j] + [cut(pts[j - 1], pts[j], right)]
    paths.append((catmull(pts), width, opacity))

foil_d = catmull(thin(foil, 2), closed=True)

def mark():
    """Defs and shapes of the icon on a 512 x 512 canvas."""
    out = f'''  <defs>
    <linearGradient id="bg" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0" stop-color="#16345F"/>
      <stop offset="1" stop-color="#081427"/>
    </linearGradient>
    <radialGradient id="glow" cx="0.3" cy="0.2" r="0.8">
      <stop offset="0" stop-color="#2E6BB0" stop-opacity="0.45"/>
      <stop offset="1" stop-color="#2E6BB0" stop-opacity="0"/>
    </radialGradient>
    <linearGradient id="flow" x1="0" y1="0" x2="512" y2="0" gradientUnits="userSpaceOnUse">
      <stop offset="0" stop-color="#5EEAD4" stop-opacity="0"/>
      <stop offset="0.22" stop-color="#5EEAD4"/>
      <stop offset="0.7" stop-color="#7DD3FC"/>
      <stop offset="1" stop-color="#E0F2FE" stop-opacity="0.9"/>
    </linearGradient>
    <linearGradient id="foil" x1="0" y1="0" x2="1" y2="0.35">
      <stop offset="0" stop-color="#FF5A3C"/>
      <stop offset="0.35" stop-color="#FF9F2E"/>
      <stop offset="1" stop-color="#FFD166"/>
    </linearGradient>
  </defs>
  <rect width="512" height="512" rx="112" fill="url(#bg)"/>
  <rect width="512" height="512" rx="112" fill="url(#glow)"/>
  <g fill="none" stroke="url(#flow)" stroke-linecap="butt">
'''
    for d, w, o in paths:
        out += f'    <path d="{d}" stroke-width="{w}" opacity="{o}"/>\n'
    out += f'''  </g>
  <path d="{foil_d}" fill="url(#foil)"/>
'''
    return out

ICON = f'''<svg xmlns="http://www.w3.org/2000/svg" width="512" height="512" viewBox="0 0 512 512" role="img">
  <title>Toofan CFD</title>
{mark()}</svg>
'''

FONT = "'Segoe UI', 'Helvetica Neue', Arial, sans-serif"
LOGO = f'''<svg xmlns="http://www.w3.org/2000/svg" width="680" height="300" viewBox="0 0 680 300" role="img">
  <title>Toofan CFD</title>
  <g transform="translate(60 60) scale({180 / 512})">
{mark()}  </g>
  <text x="276" y="160" font-family="{FONT}" font-size="68" font-weight="600" letter-spacing="-1" fill="#0B1F3A">Toofan</text>
  <text x="280" y="202" font-family="{FONT}" font-size="22" font-weight="600" letter-spacing="10" fill="#0EA5E9">CFD</text>
  <line x1="280" y1="218" x2="372" y2="218" stroke="#FF9F2E" stroke-width="3" stroke-linecap="round"/>
  <text x="280" y="242" font-family="{FONT}" font-size="13" fill="#5B6B80">Wind tunnel simulation</text>
</svg>
'''

if __name__ == "__main__":
    out_dir = sys.argv[1] if len(sys.argv) > 1 else "."
    with open(f"{out_dir}/toofan-cfd-icon.svg", "w") as f: f.write(ICON)
    with open(f"{out_dir}/toofan-cfd-logo.svg", "w") as f: f.write(LOGO)
