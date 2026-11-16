"""Stamp technology-logo badges on the participant boxes of the Mermaid sequence diagrams.

Reads seq-<name>.png (rendered from seq-<name>.mmd by mermaid-cli) and writes
seq-<name>-logos.png next to it. The .mmd sources are untouched, so they still
equal docs/sequence-diagrams.md. Badges come from tech-logos.tex (Simple Icons,
CC0), compiled once with pdflatex and rendered with pdftocairo.

    python report/figures/seq_logos.py
"""
import os
import re
import subprocess
import tempfile

from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
FILL = (236, 236, 255)            # mermaid's default participant fill
LOGO = [                          # first match on the participant label wins
    ('nginx', 'nginx'), ('postgres', 'postgresql'), ('rabbitmq', 'rabbitmq'),
    ('redis', 'redis'), ('order service', 'dotnet'), ('inventory service', 'dotnet'),
    ('outbox publisher', 'dotnet'), ('process worker', 'dotnet'),
    # generic participants of the failure-scenario diagrams (all .NET code)
    ('consumer', 'dotnet'), ('reconciliation', 'dotnet'), ('attempt', 'dotnet'),
]
NAMES = ['happy-path', 'rejection', 'planned-processing',
         # failure-scenario diagrams (rendered with render_mmd.cjs)
         'fail-c0-race', 'fail-cross-store', 'fail-crash-before-ack', 'fail-broker-down',
         'fail-publish-before-mark', 'fail-duplicates', 'fail-retry-dlq', 'fail-reconciliation',
         'fail-worker-killed', 'fail-overload-refusal']


def participants(mmd):
    labels = []
    for line in open(mmd, encoding='utf8'):
        m = re.match(r'\s*participant\s+\S+(?:\s+as\s+(.+))?$', line.rstrip())
        if m:
            labels.append((m.group(1) or line.split()[1]).strip())
    return labels


def slug_for(label):
    low = label.lower()
    for key, slug in LOGO:
        if key in low:
            return slug
    raise ValueError(f'no logo for participant {label!r}')


def badges(slugs, px):
    """Render each badge to a transparent PNG about px pixels wide."""
    out = {}
    tmp = tempfile.mkdtemp(prefix='seq-logos-')
    for s in sorted(slugs):
        tex = os.path.join(tmp, f'{s}.tex')
        with open(tex, 'w', encoding='utf8') as f:
            f.write('\\documentclass[tikz,border=0pt]{standalone}\n'
                    f'\\input{{{os.path.join(HERE, "tech-logos.tex").replace(os.sep, "/")}}}\n'
                    f'\\begin{{document}}\\techbadge[0.6]{{{s}}}\\end{{document}}\n')
        subprocess.run(['pdflatex', '-interaction=nonstopmode', '-output-directory', tmp, tex],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        subprocess.run(['pdftocairo', '-png', '-transp', '-singlefile', '-r', '600',
                        os.path.join(tmp, f'{s}.pdf'), os.path.join(tmp, s)],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        im = Image.open(os.path.join(tmp, f'{s}.png')).convert('RGBA')
        out[s] = im.resize((px, round(im.height * px / im.width)), Image.LANCZOS)
    return out


def boxes(im, rows, expected):
    """x-extents of the participant boxes on the first row (from `rows`) that crosses them.

    A wrapped label can split one box's fill on that row; if the plain runs do not
    give `expected` boxes, runs separated by less than 30 px are merged."""
    w = im.width
    first_plain = []
    for y in rows:
        runs, x = [], 0
        while x < w:
            if im.getpixel((x, y))[:3] == FILL:
                x0 = x
                while x < w and im.getpixel((x, y))[:3] == FILL:
                    x += 1
                if x - x0 > 12:
                    runs.append((x0, x, y))
            x += 1
        if not runs:
            continue
        plain = [r for r in runs if r[1] - r[0] > 40]
        if len(plain) == expected:
            return plain
        merged = [runs[0]]
        for r in runs[1:]:
            if r[0] - merged[-1][1] < 30:
                merged[-1] = (merged[-1][0], r[1], y)
            else:
                merged.append(r)
        merged = [r for r in merged if r[1] - r[0] > 40]
        if len(merged) == expected:
            return merged
        if plain and not first_plain:
            first_plain = plain
    return first_plain


def top_edge(im, x, y, step):
    while 0 <= y + step < im.height and im.getpixel((x, y + step))[:3] == FILL:
        y += step
    return y


def main():
    for name in NAMES:
        src = os.path.join(HERE, f'seq-{name}.png')
        labels = participants(os.path.join(HERE, f'seq-{name}.mmd'))
        im = Image.open(src).convert('RGBA')
        # the fail-* diagrams are rendered at twice the scale (render_mmd.cjs), so larger badges
        size = 72 if name.startswith('fail-') else 44
        art = badges({slug_for(l) for l in labels}, size)
        top = boxes(im, range(5, 140), len(labels))
        bottom = boxes(im, range(im.height - 5, im.height - 140, -1), len(labels))
        assert len(top) == len(labels) == len(bottom), (name, len(top), len(bottom), labels)
        pad = size + 12
        canvas = Image.new('RGBA', (im.width, im.height + 2 * pad), (255, 255, 255, 255))
        canvas.alpha_composite(im, (0, pad))
        for (x0, x1, y), label in zip(top, labels):          # centred just above the top box
            b = art[slug_for(label)]
            yt = top_edge(im, x0 + 5, y, -1)
            canvas.alpha_composite(b, ((x0 + x1) // 2 - b.width // 2, pad + yt - b.height - 4))
        for (x0, x1, y), label in zip(bottom, labels):       # centred just below the bottom box
            b = art[slug_for(label)]
            yb = top_edge(im, x0 + 5, y, 1)
            canvas.alpha_composite(b, ((x0 + x1) // 2 - b.width // 2, pad + yb + 6))
        im = canvas
        im.convert('RGB').save(os.path.join(HERE, f'seq-{name}-logos.png'), optimize=True)
        print(f'seq-{name}-logos.png: {len(labels)} participants')


if __name__ == '__main__':
    main()
