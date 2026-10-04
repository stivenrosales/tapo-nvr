# Pixel-art SVG: Claude mascot caught by the security camera's object detector.
S = 6                      # px per pixel cell
W, H = 120, 52             # grid size in cells
out = []
def r(x, y, w, h, c, extra=""):
    out.append(f'<rect x="{x*S}" y="{y*S}" width="{w*S}" height="{h*S}" fill="{c}"{extra}/>')

BG, GROUND, CURB = "#161A24", "#232838", "#30364A"
O, Od, K = "#D97757", "#B5583D", "#1B1712"
WH, WHd, GR, GRd = "#F2EFE8", "#CFCAC0", "#8D8A84", "#55524D"
LENS, HL, RED, GRN = "#23222B", "#7FB2E5", "#E5484D", "#3DDC84"

out.append(f'<rect width="{W*S}" height="{H*S}" rx="18" fill="{BG}"/>')
# stars + moon
for x, y in [(30,4),(44,8),(57,3),(70,9),(86,5),(97,11),(104,4),(38,14),(79,15),(112,13),(64,13)]:
    r(x, y, 1, 1, "#4A5270")
for x, y, w in [(101,5,4),(100,6,6),(100,7,6),(100,8,6),(101,9,4)]:
    r(x, y, w, 1, "#E9E4D4")
r(103, 6, 2, 1, "#CFC9B5"); r(102, 8, 1, 1, "#CFC9B5")
# ground
r(0, 43, W, 9, GROUND, ' rx="0"'); r(0, 43, W, 1, CURB)
for x in range(4, W, 14): r(x, 47, 7, 1, "#2C3244")
# pole + wall mount
r(10, 16, 3, 27, GRd); r(10, 16, 1, 27, GR)
r(9, 42, 5, 1, GR)
r(12, 18, 6, 2, GR)
# antennas
for x in (19, 27):
    r(x, 6, 1, 7, GRd); r(x, 5, 1, 1, GR)
# camera body (Tapo-ish white box) with lens on the right
r(17, 12, 14, 9, WH); r(17, 19, 14, 2, WHd); r(31, 13, 2, 7, WHd)
r(33, 14, 3, 5, LENS); r(34, 15, 1, 1, HL)
r(19, 14, 1, 1, RED)                                   # REC led
# field of view cone
out.append(f'<clipPath id="frame"><rect width="{W*S}" height="{H*S}" rx="18"/></clipPath>')
out.append(f'<polygon clip-path="url(#frame)" points="{36*S},{15*S} {(W+4)*S},{22*S} {(W+4)*S},{112*S}" fill="#F2C94C" opacity="0.10"/>')
# Claude (each logical pixel = 2x2 cells)
cx, cy = 66, 31
shape = [
    "..OOOOOOOOOO..",
    "..OKOOOOOOKO..",
    "..OKOOOOOOKO..",
    "OOOOOOOOOOOOOO",
    "..OOOOOOOOOO..",
    "..O.O....O.O..",
]
for j, row in enumerate(shape):
    for i, ch in enumerate(row):
        if ch == "O": r(cx+i*2-0, cy+j*2-0, 2, 2, O)
        if ch == "K": r(cx+i*2, cy+j*2, 2, 2, K)
for i in range(2, 12):                                   # bottom shading
    if shape[4][i] == "O": r(cx+i*2, cy+9, 2, 1, Od)
# detection box + label
bx, by, bw, bh = cx-3, cy-3, 34, 18
out.append(f'<rect x="{bx*S}" y="{by*S}" width="{bw*S}" height="{bh*S}" fill="none" stroke="{GRN}" stroke-width="{S/2}"/>')
r(bx, by-5, 23, 5, GRN)
out.append(f'<text x="{(bx+1)*S}" y="{(by-1.4)*S}" font-family="ui-monospace,SFMono-Regular,Menlo,monospace" font-size="{S*3.1}" font-weight="700" fill="{K}">claude 0.99</text>')
out.append(f'<text x="{(bx+bw+2)*S}" y="{(by+3)*S}" font-family="ui-monospace,SFMono-Regular,Menlo,monospace" font-size="{S*2.6}" font-weight="700" fill="{GRN}">→ upload</text>')
# REC badge
out.append(f'<circle cx="{40*S}" cy="{6.5*S}" r="{S*1.1}" fill="{RED}"/>')
out.append(f'<text x="{42.2*S}" y="{7.6*S}" font-family="ui-monospace,SFMono-Regular,Menlo,monospace" font-size="{S*2.8}" font-weight="700" fill="{RED}">REC</text>')

svg = (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W*S} {H*S}" width="{W*S}" height="{H*S}" '
       f'shape-rendering="crispEdges" role="img" aria-label="Pixel-art Claude mascot caught by a security camera, tagged claude 0.99 and uploaded">'
       + "".join(out) + "</svg>")
open("docs/claude-cam.svg", "w").write(svg)
print(len(svg))
