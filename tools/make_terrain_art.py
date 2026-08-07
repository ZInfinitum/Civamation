#!/usr/bin/env python3
"""Generate the placeholder pixel-art terrain tiles in assets/terrain/.

The art in this game is meant to be replaced - drop a PNG into assets/terrain/
and it appears, no import step and no code change. That makes hand-made art the
goal and generated art the floor, and the floor still has to be *good enough to
play on*: readable at a glance, obviously distinct from its neighbours, and
honest about what the tile actually is.

So this is not noise. Every biome gets a small hand-picked palette and a motif
that means something - conifers for forest, stumps for a clearing, ridge lines
that catch the light on one side for mountains, wind-blown crests for dunes.
Tiles wrap seamlessly on both axes so a field of grassland does not show a grid.

Deterministic: same seed, same tiles, every time. Regenerate with

    python3 tools/make_terrain_art.py

Filenames must match Balance.biome_id() - the lowercased biome name with spaces
turned into underscores - because that is the whole of the naming convention
Art.gd uses to find them.
"""

import os
import struct
import zlib

SIZE = 32
OUT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                   "assets", "terrain")


# --- A very small deterministic RNG ----------------------------------------
# Python's `random` is deterministic given a seed, but its internals are free to
# change between versions and these files are checked in. This will not.

class Rng:
    def __init__(self, seed):
        self.s = (seed * 2654435761 + 1013904223) & 0xFFFFFFFF

    def next(self):
        self.s = (self.s * 1664525 + 1013904223) & 0xFFFFFFFF
        return self.s

    def frand(self):
        return self.next() / 0x100000000

    def below(self, n):
        return self.next() % n

    def chance(self, p):
        return self.frand() < p


def hexc(s):
    s = s.lstrip("#")
    return (int(s[0:2], 16), int(s[2:4], 16), int(s[4:6], 16))


def shade(c, f):
    """Lighten (f>1) or darken (f<1) without leaving 8-bit range."""
    return tuple(max(0, min(255, int(round(v * f)))) for v in c)


class Tile:
    def __init__(self, base):
        self.px = [[base for _ in range(SIZE)] for _ in range(SIZE)]

    def set(self, x, y, c):
        self.px[y % SIZE][x % SIZE] = c

    def get(self, x, y):
        return self.px[y % SIZE][x % SIZE]

    def rect(self, x, y, w, h, c):
        for j in range(h):
            for i in range(w):
                self.set(x + i, y + j, c)

    def hline(self, x, y, w, c):
        self.rect(x, y, w, 1, c)

    def vline(self, x, y, h, c):
        self.rect(x, y, 1, h, c)


def write_png(path, tile):
    raw = bytearray()
    for row in tile.px:
        raw.append(0)  # filter type 0
        for r, g, b in row:
            raw += bytes((r, g, b))

    def chunk(tag, data):
        c = struct.pack(">I", len(data)) + tag + data
        return c + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", SIZE, SIZE, 8, 2, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(bytes(raw), 9))
    png += chunk(b"IEND", b"")
    with open(path, "wb") as f:
        f.write(png)


# --- Shared texturing -------------------------------------------------------

def speckle(tile, rng, colors, density):
    """Scatter single pixels. The base layer under almost every biome."""
    n = int(SIZE * SIZE * density)
    for _ in range(n):
        tile.set(rng.below(SIZE), rng.below(SIZE), colors[rng.below(len(colors))])


def tufts(tile, rng, color, count, height=2):
    """Little vertical blades - grass, scrub, reeds."""
    for _ in range(count):
        x, y = rng.below(SIZE), rng.below(SIZE)
        for j in range(height):
            tile.set(x, y - j, color)
        if rng.chance(0.4):
            tile.set(x + 1, y, color)


def conifer(tile, x, y, dark, mid, light, trunk):
    """A seven-pixel fir with a shadow under it.

    The first pass drew these in three greens a few percent apart and they
    vanished into the forest floor - the tile read as flat dark green with
    speckle. A tree has to be lighter than the ground it stands on, have a hard
    dark edge on its shaded side, and cast something. Then it is a tree.
    """
    for j, w in ((5, 0), (4, 1), (3, 1), (2, 2), (1, 3)):
        for i in range(-w, w + 1):
            tile.set(x + i, y - j, light if i < 0 else (mid if i == 0 else dark))
    tile.set(x, y - 5, light)
    tile.vline(x, y, 2, trunk)
    # Shadow, thrown to the lower right away from the light.
    tile.hline(x + 1, y + 1, 2, shade(dark, 0.72))


def broadleaf(tile, x, y, dark, mid, light, trunk):
    """A rounder, blobbier tree so rainforest does not read as forest."""
    for j in range(-5, 0):
        w = 3 if j in (-4, -3, -2) else 2
        for i in range(-w, w + 1):
            tile.set(x + i, y + j, mid if i <= 0 else dark)
    for i, j in ((-3, -3), (-2, -4), (-2, -3), (-1, -5), (-3, -2)):
        tile.set(x + i, y + j, light)
    tile.vline(x, y, 2, trunk)
    tile.hline(x + 1, y + 1, 2, shade(dark, 0.72))


def waves(tile, rng, crest, count):
    """Short broken horizontal strokes. Water, and dune crests."""
    for _ in range(count):
        x, y = rng.below(SIZE), rng.below(SIZE)
        w = 3 + rng.below(4)
        tile.hline(x, y, w, crest)
        if rng.chance(0.35):
            tile.hline(x + 1, y + 1, max(1, w - 2), crest)


# --- The biomes -------------------------------------------------------------
# Palettes are anchored on the flat colour each biome already uses on the zoomed
# out map (Balance.BIOME_INFO), so zooming in never changes what the land is.

def ocean(t, rng):
    deep, mid, crest = hexc("14283f"), hexc("1b3652"), hexc("2d5378")
    speckle(t, rng, [deep, mid], 0.35)
    waves(t, rng, crest, 7)


def lake(t, rng):
    deep, mid, crest = hexc("245572"), hexc("2f6b93"), hexc("4a8cb4")
    speckle(t, rng, [deep, mid], 0.3)
    waves(t, rng, crest, 6)


def river(t, rng):
    deep, crest = hexc("336d90"), hexc("5fa3c8")
    speckle(t, rng, [deep], 0.3)
    waves(t, rng, crest, 9)


def coast(t, rng):
    dark, light, wet = hexc("b3a478"), hexc("ded1a4"), hexc("8fa08c")
    speckle(t, rng, [dark, light], 0.4)
    # A damp line, so a shore reads as an edge rather than as pale desert.
    for _ in range(3):
        x, y = rng.below(SIZE), rng.below(SIZE)
        t.hline(x, y, 5 + rng.below(5), wet)
    for _ in range(14):
        t.set(rng.below(SIZE), rng.below(SIZE), hexc("efe6c4"))


def plains(t, rng):
    dark, light, dry = hexc("83984f"), hexc("aec076"), hexc("b7b96a")
    speckle(t, rng, [dark, light, dry], 0.45)
    tufts(t, rng, hexc("768c46"), 18, 2)
    # Open ground with flowers in it, against grassland's dense blades. Two
    # tiles this close in hue need something categorical between them, not just
    # a difference of degree.
    for _ in range(9):
        t.set(rng.below(SIZE), rng.below(SIZE), hexc("e0d68a"))
    for _ in range(5):
        t.set(rng.below(SIZE), rng.below(SIZE), hexc("d8a0a8"))


def grassland(t, rng):
    dark, light = hexc("688345"), hexc("93af69")
    speckle(t, rng, [dark, light], 0.45)
    tufts(t, rng, hexc("5c7a3c"), 40, 3)
    tufts(t, rng, hexc("a8c07d"), 14, 2)


def forest(t, rng):
    floor_a, floor_b = hexc("2e4d2c"), hexc("264024")
    speckle(t, rng, [floor_a, floor_b], 0.5)
    dark, mid, light, trunk = hexc("23431f"), hexc("47773f"), hexc("6fa552"), hexc("2e2418")
    # Offset rows rather than random placement: trees that clump look like a
    # bug, and trees on a grid look like a farm.
    for row in range(3):
        y = 9 + row * 9
        for col in range(3):
            x = 5 + col * 11 + (5 if row % 2 else 0) + rng.below(3) - 1
            conifer(t, x, y + rng.below(3) - 1, dark, mid, light, trunk)


def rainforest(t, rng):
    speckle(t, rng, [hexc("174024"), hexc("1e4d2c")], 0.55)
    dark, mid, light, trunk = hexc("143a20"), hexc("2f7742"), hexc("52a866"), hexc("241c14")
    for row in range(3):
        y = 9 + row * 9
        for col in range(3):
            x = 4 + col * 11 + (5 if row % 2 else 0) + rng.below(3) - 1
            broadleaf(t, x, y + rng.below(3) - 1, dark, mid, light, trunk)
    # Undergrowth, which is what makes a rainforest a rainforest.
    tufts(t, rng, hexc("3d7f4a"), 22, 2)


def hills(t, rng):
    speckle(t, rng, [hexc("7a7757"), hexc("9a976f")], 0.45)
    tufts(t, rng, hexc("6f7d4e"), 16, 2)
    # Rounded crests, lit on top. Three of them, none touching.
    for cx, cy, w in ((7, 20, 11), (21, 12, 9), (26, 26, 8)):
        for i in range(w):
            x = cx - w // 2 + i
            lift = int(round((1.0 - abs(i - w / 2.0) / (w / 2.0)) * 3.0))
            t.hline(x, cy - lift, 1, hexc("b0ad84"))
            t.hline(x, cy - lift + 1, 1, hexc("8a8763"))
            t.hline(x, cy - lift + 2, 1, hexc("6d6a4c"))


def mountain(t, rng):
    speckle(t, rng, [hexc("5f5f65"), hexc("6f6f74")], 0.4)
    rock, lit, shadow, snow = hexc("6f6f74"), hexc("94949c"), hexc("4a4a51"), hexc("e6ebf0")
    # Two peaks. The left face catches the light, the right falls into shadow -
    # one consistent light direction is most of what makes pixel art legible.
    for px, py, h in ((10, 27, 14), (23, 24, 10)):
        for j in range(h):
            w = j + 1
            for i in range(-w, w + 1):
                t.set(px + i, py - h + j + 1, lit if i < 0 else (rock if i == 0 else shadow))
        for j in range(max(2, h // 4)):
            w = j + 1
            for i in range(-w, w + 1):
                t.set(px + i, py - h + j + 1, snow if i <= 0 else shade(snow, 0.82))


def desert(t, rng):
    speckle(t, rng, [hexc("bd9e60"), hexc("d8bc7d"), hexc("c9ab6d")], 0.5)
    waves(t, rng, hexc("e3cd97"), 8)
    for _ in range(5):  # stones
        x, y = rng.below(SIZE), rng.below(SIZE)
        t.rect(x, y, 2, 1, hexc("a08a58"))


def tundra(t, rng):
    speckle(t, rng, [hexc("7e8b87"), hexc("9caaa4")], 0.45)
    tufts(t, rng, hexc("6d7c6a"), 18, 2)
    for _ in range(9):  # patches of old snow
        x, y = rng.below(SIZE), rng.below(SIZE)
        t.rect(x, y, 2 + rng.below(3), 1 + rng.below(2), hexc("cdd7d3"))


def ice(t, rng):
    speckle(t, rng, [hexc("d3dee5"), hexc("eef4f8")], 0.4)
    # Pressure cracks: short diagonals, which nothing else in the set uses.
    for _ in range(7):
        x, y = rng.below(SIZE), rng.below(SIZE)
        for k in range(3 + rng.below(4)):
            t.set(x + k, y + (k // 2), hexc("aec2cf"))


def clearing(t, rng):
    speckle(t, rng, [hexc("7c7c4a"), hexc("98985c")], 0.45)
    tufts(t, rng, hexc("8a9a52"), 20, 2)
    # Stumps. A felled wood has to look felled, not merely look like grass -
    # this tile is the visible consequence of sending woodcutters somewhere.
    for cx, cy in ((8, 11), (20, 17), (12, 25), (26, 8)):
        x, y = cx + rng.below(3) - 1, cy + rng.below(3) - 1
        t.rect(x - 1, y - 1, 3, 2, hexc("6b5638"))
        t.rect(x - 1, y - 1, 3, 1, hexc("8a7049"))
        t.set(x, y - 1, hexc("a3865a"))


BIOMES = {
    "ocean": ocean, "lake": lake, "river": river, "coast": coast,
    "plains": plains, "grassland": grassland, "forest": forest,
    "rainforest": rainforest, "hills": hills, "mountain": mountain,
    "desert": desert, "tundra": tundra, "ice": ice, "clearing": clearing,
}

BASE = {
    "ocean": "1b3652", "lake": "2f6b93", "river": "3f83ab", "coast": "cbbd8f",
    "plains": "9aae62", "grassland": "7d9b57", "forest": "3f6b3c",
    "rainforest": "245a35", "hills": "8a8763", "mountain": "6f6f74",
    "desert": "c9ab6d", "tundra": "8d9a95", "ice": "dfe8ee", "clearing": "8a8a52",
}


def main():
    os.makedirs(OUT, exist_ok=True)
    for i, (name, draw) in enumerate(sorted(BIOMES.items())):
        tile = Tile(hexc(BASE[name]))
        draw(tile, Rng(7717 + i * 101))
        write_png(os.path.join(OUT, name + ".png"), tile)
        print("assets/terrain/%s.png" % name)
    print("%d tiles, %dx%d" % (len(BIOMES), SIZE, SIZE))


if __name__ == "__main__":
    main()
