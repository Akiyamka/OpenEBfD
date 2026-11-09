#!/usr/bin/env python3
"""Generate the integer quarter-wave tables used by SimMath."""
import argparse
import math
import json
from pathlib import Path

OUT = Path('scripts/sim/sim_math.gd')
GOLDENS = Path('tests/sim/sim_math_goldens.json')
TURN = 1 << 32
Q30 = 1 << 30

def table_values():
    sine = [round(math.sin(math.pi * i / 512) * Q30) for i in range(257)]
    atan = [round(math.atan(i / 256) * TURN / (2 * math.pi)) for i in range(257)]
    return sine, atan

def render_table(name, values):
    lines = [f'static var {name} := PackedInt64Array([']
    for i in range(0, len(values), 8):
        lines.append('\t' + ', '.join(map(str, values[i:i+8])) + (',' if i + 8 < len(values) else ''))
    return '\n'.join(lines + ['])'])

def golden_data(sine, atan):
    def bearing(x, z):
        if x == 0:
            return (TURN // 4 if z > 0 else -TURN // 4) if z else 0
        if z == 0:
            return TURN // 2 if x < 0 else 0
        ax, az = abs(x), abs(z)
        def octant(small, large):
            scaled = int(small / large * 256 * 1048576)
            index, fraction = divmod(scaled, 1048576)
            if index == 256:
                return atan[256]
            return atan[index] + ((atan[index+1] - atan[index]) * fraction + 524288) // 1048576
        angle = octant(az, ax) if ax >= az else TURN // 4 - octant(ax, az)
        return (-1 if z < 0 else 1) * (TURN // 2 - angle if x < 0 else angle)
    def sine_at(angle):
        wrapped = angle % TURN
        quadrant, within = divmod(wrapped, TURN // 4)
        if quadrant in (1, 3):
            within = TURN // 4 - within
        index, fraction = divmod(within, TURN // 1024)
        value = sine[index]
        if index < 256:
            value += ((sine[index+1] - value) * fraction + (TURN // 2048)) // (TURN // 1024)
        return -value if quadrant >= 2 else value
    vectors = [(3, 7), (-9, 4), (-8, -5), (7, -11), (1, 1), (256, 37)]
    angles = [123456789, 765432109, -345678901, 2048000001]
    return {'bearings': [[x, z, bearing(x, z)] for x,z in vectors],
            'pairs': [[a, sine_at(a + TURN//4), sine_at(a)] for a in angles]}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    sine, atan = table_values()
    table = render_table('_sine_q30_table', sine) + '\n\n' + render_table('_atan_units_table', atan)
    goldens = json.dumps(golden_data(sine, atan), indent=2) + '\n'
    if args.check:
        assert GOLDENS.read_text() == goldens
        source = OUT.read_text()
        assert source[source.index('static var _sine_q30_table'):source.index('\n\n# END GENERATED')] == table
        print('AP9 tables: OK')
    else:
        source = OUT.read_text()
        start = source.index('static var _sine_q30_table')
        end = source.index('\n\n# END GENERATED')
        OUT.write_text(source[:start] + table + source[end:])
        GOLDENS.write_text(goldens)

if __name__ == '__main__':
    main()
