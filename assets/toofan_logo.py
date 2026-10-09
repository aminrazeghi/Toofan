# toofan_logo.py: generates the Toofan tornado-T logo as one continuous coil

# Coil turning points, alternating left (even index) / right (odd index).
# The first 10 form the crossbar, the next 4 form the funnel join, the rest form the stem.
POINTS = [
    (104, 88), (578, 102), (98, 118), (584, 131), (106, 147),
    (574, 161), (112, 177), (566, 190), (124, 206), (556, 219),
    (190, 236), (448, 252), (256, 267), (424, 282),
    (262, 297), (418, 311), (268, 326), (412, 340), (274, 355),
    (406, 369), (280, 384), (400, 398), (288, 412), (392, 426),
    (296, 440), (384, 453), (304, 467), (376, 480), (314, 494),
    (366, 507),
]

# Per half-turn: k = vertical bulge of the curve, o = how far the control
# points extend past the turning points (larger o = rounder ends).
K = [15, 14, 16, 14, 15, 13, 14, 13, 14,   # crossbar
     13, 12, 11, 10, 10,                   # funnel join
     10, 9, 9, 8, 8, 7, 7, 6, 6, 5, 5, 4, 4, 4, 3]  # stem
O = [10, 8, 10, 12, 9, 10, 8, 11, 10,
     10, 8, 7, 6, 5,
     5, 5, 4, 4, 4, 3, 3, 3, 3, 2, 2, 2, 2, 2, 2]

TAIL = "C366,520 348,534 340,548"  # final curve down to the tip


def build_coil_path(points=POINTS, k=K, o=O, tail=TAIL):
    d = [f"M{points[0][0]},{points[0][1]}"]
    for i in range(len(points) - 1):
        (xa, ya), (xb, yb) = points[i], points[i + 1]
        if i % 2 == 0:   # left -> right, curve passes below
            c1 = (xa - o[i], ya + k[i])
            c2 = (xb + o[i], yb + k[i])
        else:            # right -> left, curve passes above
            c1 = (xa + o[i], ya - k[i])
            c2 = (xb - o[i], yb - k[i])
        d.append(f"C{c1[0]},{c1[1]} {c2[0]},{c2[1]} {xb},{yb}")
    d.append(tail)
    return " ".join(d)


def mark(color="#111111", stroke_width=6, background=None):
    return f"""
  <path d="{build_coil_path()}" fill="none" stroke="{color}"
        stroke-width="{stroke_width}" stroke-linecap="round" stroke-linejoin="round"/>
  <g fill="{color}">
    <path d="M210,556 Q340,546 470,556 Q340,564 210,556 Z"/>
    <path d="M260,570 Q340,565 420,570 Q340,575 260,570 Z"/>
  </g>
    """

def build_svg(color="#111111", stroke_width=6, background=None):
    bg = f'<rect width="680" height="600" fill="{background}"/>' if background else ""
    return f"""<svg width="680" height="600" viewBox="0 0 680 600" xmlns="http://www.w3.org/2000/svg">
  <title>Toofan logo</title>
  {bg}
        {mark()}
</svg>
"""

if __name__ == "__main__":
    with open("toofan_logo.svg", "w", encoding="utf-8") as f:
        f.write(build_svg())
    print("Saved toofan_logo.svg")
