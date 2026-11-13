#!/usr/bin/env python3
"""tools/gen_amiibo_list.py - writes runtime/amiibo_list.inc, every amiibo WSword's amiibo bar offers, from
AmiiboAPI's database (https://github.com/N3evin/AmiiboAPI, MIT licence: database/amiibo.json - the figures' public ids
and names, nothing of a figure's own data).

    tools/gen_amiibo_list.py <AmiiboAPI checkout> [--out runtime/amiibo_list.inc]

Order: the Breath of the Wild figures (their own drops in the game), the rest of the Zelda series, every other figure,
yarn, band and block by game series, then the cards.
"""
import argparse
import json
import os

BOTW_FIRST = [0x01030000024f0902, 0x0100000003530902, 0x0100000003540902, 0x0101000003560902, 0x0140000003550902,
              0x01410000035c0902, 0x0105000003580902, 0x01070000035a0902, 0x01080000035b0902, 0x0106000003590902]


def c_str(s):
    return '"' + s.replace('\\', '\\\\').replace('"', '\\"') + '"'


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('db')
    ap.add_argument('--out', default=os.path.join(os.path.dirname(__file__), '..', 'runtime', 'amiibo_list.inc'))
    a = ap.parse_args()
    d = json.load(open(os.path.join(a.db, 'database', 'amiibo.json'), encoding='utf-8'))
    gs, ty = d['game_series'], d['types']
    rows = []
    for k, v in d['amiibos'].items():
        h = k[2:].lower()
        i = int(h, 16)
        series = gs.get('0x' + h[0:3], 'Other')
        kind = ty.get('0x' + h[6:8], 'Figure')
        rows.append((i, v['name'], series, kind))

    def key(r):
        i, name, series, kind = r
        if i in BOTW_FIRST:
            return (0, BOTW_FIRST.index(i), '', '')
        zelda = series == 'The Legend of Zelda'
        return (1 if zelda and kind != 'Card' else 3 if kind == 'Card' else 2, 0, series.lower(), name.lower())
    rows.sort(key=key)
    groups = []
    out = ['// Written by tools/gen_amiibo_list.py from AmiiboAPI (https://github.com/N3evin/AmiiboAPI, MIT licence):',
           '// every amiibo, its public id and name. Do not edit.']
    ents = []
    for i, name, series, kind in rows:
        g = series + (' (cards)' if kind == 'Card' else '')
        if g not in groups:
            groups.append(g)
        ents.append(f'    {{0x{i:016x}ull, {c_str(name)}, {groups.index(g)}}},')
    out.append('static const char *const k_amiibo_groups[] = {' + ', '.join(c_str(g) for g in groups) + '};')
    out.append('static const AmiiboDef k_amiibo[] = {')
    out += ents
    out.append('};')
    with open(a.out, 'w', encoding='utf-8') as f:
        f.write('\n'.join(out) + '\n')
    print(f'{a.out}: {len(ents)} amiibo in {len(groups)} groups')


main()
