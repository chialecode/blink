"""Deterministic brand, tray, and installer icon generator for BLINK.

Usage:
    python -B scripts/generate_icons.py
    python -B scripts/generate_icons.py --check
    python -B scripts/generate_icons.py --preview <output.png>

Renders the canonical 1024x1024 geometric letter "B" icon (and "DEV" channel
badge variant) using 2x2 supersampling and exact alpha-weighted box averaging
down to 16, 24, 32, 48, 64, 128, and 256 px 32bpp RGBA PNG .ico frames alongside
matching .svg vector masters. Uses Python 3.12 standard library only.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import math
from pathlib import Path
import struct
import sys
import zlib

sys.dont_write_bytecode = True

MASTER_SIZE = 1024
SUPERSAMPLE = 2
SUB_SIZE = MASTER_SIZE * SUPERSAMPLE
SIZES: tuple[int, ...] = (16, 24, 32, 48, 64, 128, 256)
PREVIEW_SIZES: tuple[int, ...] = (256, 64, 32, 24, 16)

RGBA = tuple[int, int, int, int]

COLOR_TRANSPARENT: RGBA = (0, 0, 0, 0)
COLOR_GROUND: RGBA = (0x3C, 0x40, 0x43, 0xFF)  # #3C4043
COLOR_GLYPH: RGBA = (0xFF, 0xFF, 0xFF, 0xFF)  # #FFFFFF
COLOR_DEV_PILL: RGBA = (0xF3, 0xA1, 0x15, 0xFF)  # #F3A115
COLOR_DEV_TEXT: RGBA = (0x20, 0x21, 0x24, 0xFF)  # #202124

PALETTE: tuple[RGBA, ...] = (
    COLOR_TRANSPARENT,
    COLOR_GROUND,
    COLOR_GLYPH,
    COLOR_DEV_PILL,
    COLOR_DEV_TEXT,
)

IDX_TRANSPARENT = 0
IDX_GROUND = 1
IDX_GLYPH = 2
IDX_DEV_PILL = 3
IDX_DEV_TEXT = 4

LETTER_B_SVG_PATH = (
    "M320 250H572A160 160 0 0 1 692.75 515A160 160 0 0 1 572 780H320"
    "A28 28 0 0 1 292 752V278A28 28 0 0 1 320 250Z"
    "M402 360V460H572A50 50 0 0 0 572 360Z"
    "M402 570V670H572A50 50 0 0 0 572 570Z"
)

DEV_TEXT_SVG_PATH = (
    "M636 839H670A40 40 0 0 1 710 879V885A40 40 0 0 1 670 925H636Z"
    "M654 857V907H670A22 22 0 0 0 692 885V879A22 22 0 0 0 670 857Z"
    "M726 839H782V857H744V873H776V891H744V907H782V925H726Z"
    "M796 839H815L840 903L865 839H884L850 925H830Z"
)

ASSET_REL_PATHS: dict[str, str] = {
    "release_svg": "apps/blink_client/assets/icons/blink.svg",
    "dev_svg": "apps/blink_client/assets/icons/blink-dev.svg",
    "tray_release_ico": "apps/blink_client/assets/icons/blink.ico",
    "tray_dev_ico": "apps/blink_client/assets/icons/blink-dev.ico",
    "win_release_ico": "apps/blink_client/windows/runner/resources/blink.ico",
    "win_dev_ico": "apps/blink_client/windows/runner/resources/blink-dev.ico",
    "win_app_ico": "apps/blink_client/windows/runner/resources/app_icon.ico",
}


@dataclass(frozen=True)
class IconBundle:
    """Generated vector and multi-resolution icon payloads."""

    release_svg: bytes
    dev_svg: bytes
    release_ico: bytes
    dev_ico: bytes
    release_frames: dict[int, bytes]
    dev_frames: dict[int, bytes]

    def expected_repo_files(self, root: Path) -> dict[Path, bytes]:
        return {
            root / ASSET_REL_PATHS["release_svg"]: self.release_svg,
            root / ASSET_REL_PATHS["dev_svg"]: self.dev_svg,
            root / ASSET_REL_PATHS["tray_release_ico"]: self.release_ico,
            root / ASSET_REL_PATHS["tray_dev_ico"]: self.dev_ico,
            root / ASSET_REL_PATHS["win_release_ico"]: self.release_ico,
            root / ASSET_REL_PATHS["win_dev_ico"]: self.dev_ico,
            root / ASSET_REL_PATHS["win_app_ico"]: self.dev_ico,
        }


def build_svg(*, dev: bool) -> str:
    """Build canonical 1024x1024 SVG markup with LF line endings."""
    lines = [
        '<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024" fill="none">',
        '  <rect x="48" y="48" width="928" height="928" rx="200" fill="#3C4043"/>',
        f'  <path fill="#FFFFFF" fill-rule="evenodd" d="{LETTER_B_SVG_PATH}"/>',
    ]
    if dev:
        lines.append('  <rect x="560" y="800" width="400" height="160" rx="52" fill="#F3A115"/>')
        lines.append(f'  <path fill="#202124" fill-rule="evenodd" d="{DEV_TEXT_SVG_PATH}"/>')
    lines.append("</svg>")
    return "\n".join(lines) + "\n"


def _rounded_rect_span(
    y: float,
    left: float,
    top: float,
    right: float,
    bottom: float,
    radius: float,
) -> tuple[float, float] | None:
    if y < top or y > bottom:
        return None
    if y < top + radius:
        dy = (top + radius) - y
        dx = math.sqrt(max(0.0, radius * radius - dy * dy))
        return (left + radius - dx, right - radius + dx)
    if y > bottom - radius:
        dy = y - (bottom - radius)
        dx = math.sqrt(max(0.0, radius * radius - dy * dy))
        return (left + radius - dx, right - radius + dx)
    return (left, right)


def _letter_b_outer_span(y: float) -> tuple[float, float] | None:
    if y < 250.0 or y > 780.0:
        return None
    if y < 278.0:
        dy = 278.0 - y
        x_left = 320.0 - math.sqrt(max(0.0, 28.0 * 28.0 - dy * dy))
    elif y > 752.0:
        dy = y - 752.0
        x_left = 320.0 - math.sqrt(max(0.0, 28.0 * 28.0 - dy * dy))
    else:
        x_left = 292.0

    bowl_cy = 410.0 if y <= 515.0 else 620.0
    dy_bowl = y - bowl_cy
    x_right = 572.0 + math.sqrt(max(0.0, 160.0 * 160.0 - dy_bowl * dy_bowl))
    return (x_left, x_right)


def _letter_b_counter_span(y: float) -> tuple[float, float] | None:
    if 360.0 < y < 460.0:
        dy = y - 410.0
    elif 570.0 < y < 670.0:
        dy = y - 620.0
    else:
        return None
    x_right = 572.0 + math.sqrt(max(0.0, 50.0 * 50.0 - dy * dy))
    return (402.0, x_right)


def _dev_d_outer_span(y: float) -> tuple[float, float] | None:
    if y < 839.0 or y > 925.0:
        return None
    if y < 879.0:
        dy = 879.0 - y
        x_right = 670.0 + math.sqrt(max(0.0, 40.0 * 40.0 - dy * dy))
    elif y > 885.0:
        dy = y - 885.0
        x_right = 670.0 + math.sqrt(max(0.0, 40.0 * 40.0 - dy * dy))
    else:
        x_right = 710.0
    return (636.0, x_right)


def _dev_d_counter_span(y: float) -> tuple[float, float] | None:
    if not (857.0 < y < 907.0):
        return None
    if y < 879.0:
        dy = 879.0 - y
        x_right = 670.0 + math.sqrt(max(0.0, 22.0 * 22.0 - dy * dy))
    elif y > 885.0:
        dy = y - 885.0
        x_right = 670.0 + math.sqrt(max(0.0, 22.0 * 22.0 - dy * dy))
    else:
        x_right = 692.0
    return (654.0, x_right)


def _dev_e_span(y: float) -> tuple[float, float] | None:
    if y < 839.0 or y > 925.0:
        return None
    if y <= 857.0 or y >= 907.0:
        return (726.0, 782.0)
    if 873.0 <= y <= 891.0:
        return (726.0, 776.0)
    return (726.0, 744.0)


def _dev_v_spans(y: float) -> tuple[tuple[float, float], ...]:
    if y < 839.0 or y > 925.0:
        return ()
    t_out = (y - 839.0) * (34.0 / 86.0)
    if y <= 903.0:
        t_in = (y - 839.0) * (25.0 / 64.0)
        return (
            (796.0 + t_out, 815.0 + t_in),
            (865.0 - t_in, 884.0 - t_out),
        )
    return ((796.0 + t_out, 884.0 - t_out),)


def sample_point_rgba(x: float, y: float, *, dev: bool) -> RGBA:
    """Evaluate exact continuous 1024x1024 icon color at point (x, y)."""
    if dev:
        pill = _rounded_rect_span(y, 560.0, 800.0, 960.0, 960.0, 52.0)
        if pill is not None and pill[0] <= x <= pill[1]:
            d_out = _dev_d_outer_span(y)
            if d_out is not None and d_out[0] <= x <= d_out[1]:
                d_in = _dev_d_counter_span(y)
                if d_in is None or not (d_in[0] < x < d_in[1]):
                    return COLOR_DEV_TEXT
            e_span = _dev_e_span(y)
            if e_span is not None and e_span[0] <= x <= e_span[1]:
                return COLOR_DEV_TEXT
            for vx0, vx1 in _dev_v_spans(y):
                if vx0 <= x <= vx1:
                    return COLOR_DEV_TEXT
            return COLOR_DEV_PILL

    b_out = _letter_b_outer_span(y)
    if b_out is not None and b_out[0] <= x <= b_out[1]:
        b_in = _letter_b_counter_span(y)
        if b_in is None or not (b_in[0] < x < b_in[1]):
            return COLOR_GLYPH

    bg = _rounded_rect_span(y, 48.0, 48.0, 976.0, 976.0, 200.0)
    if bg is not None and bg[0] <= x <= bg[1]:
        return COLOR_GROUND

    return COLOR_TRANSPARENT


def _closed_subpixel_slice(x0: float, x1: float) -> tuple[int, int]:
    start = max(0, math.ceil(x0 * SUPERSAMPLE - 0.5))
    end = min(SUB_SIZE, math.floor(x1 * SUPERSAMPLE - 0.5) + 1)
    return (start, max(start, end))


def _open_subpixel_slice(x0: float, x1: float) -> tuple[int, int]:
    # Strict interior (x0 < x < x1) for subtracted counters.
    start = max(0, math.floor(x0 * SUPERSAMPLE - 0.5) + 1)
    end = min(SUB_SIZE, math.ceil(x1 * SUPERSAMPLE - 0.5))
    return (start, max(start, end))


def _paint_interval(
    runs: list[tuple[int, int, int]],
    start: int,
    end: int,
    color_idx: int,
) -> list[tuple[int, int, int]]:
    if start >= end:
        return runs
    out: list[tuple[int, int, int]] = []
    inserted = False
    for r_start, r_end, r_col in runs:
        if r_end <= start or r_start >= end:
            if r_start >= end and not inserted:
                out.append((start, end, color_idx))
                inserted = True
            out.append((r_start, r_end, r_col))
            continue
        if r_start < start:
            out.append((r_start, start, r_col))
        if not inserted:
            out.append((start, end, color_idx))
            inserted = True
        if r_end > end:
            out.append((end, r_end, r_col))
    if not inserted:
        out.append((start, end, color_idx))
    return out


def _subpixel_runs_for_y(y: float, *, dev: bool) -> list[tuple[int, int, int]]:
    runs: list[tuple[int, int, int]] = [(0, SUB_SIZE, IDX_TRANSPARENT)]

    bg = _rounded_rect_span(y, 48.0, 48.0, 976.0, 976.0, 200.0)
    if bg is not None:
        s, e = _closed_subpixel_slice(bg[0], bg[1])
        runs = _paint_interval(runs, s, e, IDX_GROUND)

    b_out = _letter_b_outer_span(y)
    if b_out is not None:
        s, e = _closed_subpixel_slice(b_out[0], b_out[1])
        runs = _paint_interval(runs, s, e, IDX_GLYPH)
        b_in = _letter_b_counter_span(y)
        if b_in is not None:
            cs, ce = _open_subpixel_slice(b_in[0], b_in[1])
            runs = _paint_interval(runs, cs, ce, IDX_GROUND)

    if dev:
        pill = _rounded_rect_span(y, 560.0, 800.0, 960.0, 960.0, 52.0)
        if pill is not None:
            ps, pe = _closed_subpixel_slice(pill[0], pill[1])
            runs = _paint_interval(runs, ps, pe, IDX_DEV_PILL)

            d_out = _dev_d_outer_span(y)
            if d_out is not None:
                ds, de = _closed_subpixel_slice(d_out[0], d_out[1])
                runs = _paint_interval(runs, ds, de, IDX_DEV_TEXT)
                d_in = _dev_d_counter_span(y)
                if d_in is not None:
                    dcs, dce = _open_subpixel_slice(d_in[0], d_in[1])
                    runs = _paint_interval(runs, dcs, dce, IDX_DEV_PILL)

            e_span = _dev_e_span(y)
            if e_span is not None:
                es, ee = _closed_subpixel_slice(e_span[0], e_span[1])
                runs = _paint_interval(runs, es, ee, IDX_DEV_TEXT)

            for vx0, vx1 in _dev_v_spans(y):
                vs, ve = _closed_subpixel_slice(vx0, vx1)
                runs = _paint_interval(runs, vs, ve, IDX_DEV_TEXT)

    return runs


def _build_2x2_lut() -> tuple[list[bytes], list[bytes]]:
    lut: list[bytes] = [b"\x00\x00\x00\x00"] * (5**4)
    solid = [bytes(rgba) for rgba in PALETTE]
    for p0 in range(5):
        r0, g0, b0, a0 = PALETTE[p0]
        for p1 in range(5):
            r1, g1, b1, a1 = PALETTE[p1]
            for p2 in range(5):
                r2, g2, b2, a2 = PALETTE[p2]
                for p3 in range(5):
                    r3, g3, b3, a3 = PALETTE[p3]
                    a_sum = a0 + a1 + a2 + a3
                    idx = ((p0 * 5 + p1) * 5 + p2) * 5 + p3
                    if a_sum == 0:
                        lut[idx] = b"\x00\x00\x00\x00"
                    else:
                        out_r = round((r0 * a0 + r1 * a1 + r2 * a2 + r3 * a3) / a_sum)
                        out_g = round((g0 * a0 + g1 * a1 + g2 * a2 + g3 * a3) / a_sum)
                        out_b = round((b0 * a0 + b1 * a1 + b2 * a2 + b3 * a3) / a_sum)
                        out_a = round(a_sum / 4)
                        lut[idx] = bytes((out_r, out_g, out_b, out_a))
    return lut, solid


_SUBPIXEL_LUT, _SOLID_BYTES = _build_2x2_lut()


def _color_at_subx(runs: list[tuple[int, int, int]], sub_x: int) -> int:
    for r_start, r_end, r_col in runs:
        if r_start <= sub_x < r_end:
            return r_col
    return IDX_TRANSPARENT


def _resolve_master_row(
    runs0: list[tuple[int, int, int]],
    runs1: list[tuple[int, int, int]],
) -> bytes:
    out = bytearray(MASTER_SIZE * 4)
    i0 = 0
    i1 = 0
    n0 = len(runs0)
    n1 = len(runs1)
    px = 0
    while px < MASTER_SIZE:
        sub_x = px * 2
        while i0 < n0 and runs0[i0][1] <= sub_x:
            i0 += 1
        while i1 < n1 and runs1[i1][1] <= sub_x:
            i1 += 1

        s0, e0, c0 = runs0[i0]
        s1, e1, c1 = runs1[i1]
        min_end = e0 if e0 < e1 else e1

        if c0 == c1 and min_end >= sub_x + 2:
            end_px = min_end // 2
            count = end_px - px
            out[px * 4 : end_px * 4] = _SOLID_BYTES[c0] * count
            px = end_px
        else:
            p0 = c0
            p1 = c0 if sub_x + 1 < e0 else _color_at_subx(runs0, sub_x + 1)
            p2 = c1
            p3 = c1 if sub_x + 1 < e1 else _color_at_subx(runs1, sub_x + 1)
            out[px * 4 : (px + 1) * 4] = _SUBPIXEL_LUT[((p0 * 5 + p1) * 5 + p2) * 5 + p3]
            px += 1
    return bytes(out)


def render_master_rgba(*, dev: bool) -> bytes:
    """Render 1024x1024 RGBA master buffer using 2x2 supersampling."""
    rows: list[bytes] = []
    for py in range(MASTER_SIZE):
        y0 = py + 0.25
        y1 = py + 0.75
        runs0 = _subpixel_runs_for_y(y0, dev=dev)
        runs1 = _subpixel_runs_for_y(y1, dev=dev)
        rows.append(_resolve_master_row(runs0, runs1))
    return b"".join(rows)


AccumCell = tuple[int, int, int, int]  # (sum_ra, sum_ga, sum_ba, sum_a)


def _accumulate_box_grid(
    src: bytes,
    src_size: int,
    dst_size: int,
) -> tuple[list[list[AccumCell]], int]:
    """Integrate premultiplied RGBA over exact rational [src_size -> dst_size] boxes."""
    if len(src) != src_size * src_size * 4:
        raise ValueError(f"expected {src_size * src_size * 4} RGBA bytes, got {len(src)}")

    # Precompute exact integer overlap weights per output coordinate.
    x_spans: list[tuple[tuple[int, int], ...]] = []
    for tx in range(dst_size):
        u0 = tx * src_size
        u1 = (tx + 1) * src_size
        mx_start = u0 // dst_size
        mx_end = (u1 + dst_size - 1) // dst_size
        weights: list[tuple[int, int]] = []
        for mx in range(mx_start, mx_end):
            v0 = mx * dst_size
            v1 = (mx + 1) * dst_size
            w = (u1 if u1 < v1 else v1) - (u0 if u0 > v0 else v0)
            if w > 0:
                weights.append((mx * 4, w))
        x_spans.append(tuple(weights))

    row_stride = src_size * 4
    h_cache: dict[bytes, list[AccumCell]] = {}
    h_rows: list[list[AccumCell]] = []

    for my in range(src_size):
        row_bytes = src[my * row_stride : (my + 1) * row_stride]
        cached = h_cache.get(row_bytes)
        if cached is None:
            h_row: list[AccumCell] = []
            for weights in x_spans:
                sum_ra = 0
                sum_ga = 0
                sum_ba = 0
                sum_a = 0
                for off, w in weights:
                    a = row_bytes[off + 3]
                    if a:
                        wa = w * a
                        sum_ra += row_bytes[off] * wa
                        sum_ga += row_bytes[off + 1] * wa
                        sum_ba += row_bytes[off + 2] * wa
                        sum_a += wa
                h_row.append((sum_ra, sum_ga, sum_ba, sum_a))
            h_cache[row_bytes] = h_row
            cached = h_row
        h_rows.append(cached)

    grid: list[list[AccumCell]] = []
    for ty in range(dst_size):
        u0 = ty * src_size
        u1 = (ty + 1) * src_size
        my_start = u0 // dst_size
        my_end = (u1 + dst_size - 1) // dst_size
        y_weights: list[tuple[list[AccumCell], int]] = []
        for my in range(my_start, my_end):
            v0 = my * dst_size
            v1 = (my + 1) * dst_size
            wy = (u1 if u1 < v1 else v1) - (u0 if u0 > v0 else v0)
            if wy > 0:
                y_weights.append((h_rows[my], wy))

        out_row: list[AccumCell] = []
        for tx in range(dst_size):
            total_ra = 0
            total_ga = 0
            total_ba = 0
            total_a = 0
            for h_row, wy in y_weights:
                ra, ga, ba, a = h_row[tx]
                if a:
                    total_ra += ra * wy
                    total_ga += ga * wy
                    total_ba += ba * wy
                    total_a += a * wy
            out_row.append((total_ra, total_ga, total_ba, total_a))
        grid.append(out_row)

    return grid, src_size * src_size


def _downsample_accum_2x2(
    grid: list[list[AccumCell]],
    denom: int,
) -> tuple[list[list[AccumCell]], int]:
    half = len(grid) // 2
    out: list[list[AccumCell]] = []
    for y in range(half):
        r0 = grid[2 * y]
        r1 = grid[2 * y + 1]
        row: list[AccumCell] = []
        for x in range(half):
            c00 = r0[2 * x]
            c01 = r0[2 * x + 1]
            c10 = r1[2 * x]
            c11 = r1[2 * x + 1]
            row.append(
                (
                    c00[0] + c01[0] + c10[0] + c11[0],
                    c00[1] + c01[1] + c10[1] + c11[1],
                    c00[2] + c01[2] + c10[2] + c11[2],
                    c00[3] + c01[3] + c10[3] + c11[3],
                )
            )
        out.append(row)
    return out, denom * 4


def _finalize_accum_grid(grid: list[list[AccumCell]], denom: int) -> bytes:
    size = len(grid)
    out = bytearray(size * size * 4)
    pos = 0
    for row in grid:
        for sum_ra, sum_ga, sum_ba, sum_a in row:
            out_a = round(sum_a / denom)
            if out_a == 0 or sum_a == 0:
                out[pos : pos + 4] = b"\x00\x00\x00\x00"
            else:
                out[pos] = round(sum_ra / sum_a)
                out[pos + 1] = round(sum_ga / sum_a)
                out[pos + 2] = round(sum_ba / sum_a)
                out[pos + 3] = out_a
            pos += 4
    return bytes(out)


def downsample_rgba(src: bytes, src_size: int, dst_size: int) -> bytes:
    """Downsample RGBA image from src_size to dst_size via alpha-weighted box averaging."""
    if dst_size == src_size:
        if len(src) != src_size * src_size * 4:
            raise ValueError(f"expected {src_size * src_size * 4} RGBA bytes, got {len(src)}")
        return bytes(src)
    grid, denom = _accumulate_box_grid(src, src_size, dst_size)
    return _finalize_accum_grid(grid, denom)


def downsample_all_sizes(
    master: bytes,
    sizes: tuple[int, ...] = SIZES,
) -> dict[int, bytes]:
    """Downsample a 1024x1024 master to all target icon sizes with exact integer sums."""
    result: dict[int, bytes] = {}
    wanted = set(sizes)

    if wanted & {256, 128, 64, 32, 16}:
        grid, denom = _accumulate_box_grid(master, MASTER_SIZE, 256)
        for sz in (256, 128, 64, 32, 16):
            if sz < 256:
                grid, denom = _downsample_accum_2x2(grid, denom)
            if sz in wanted:
                result[sz] = _finalize_accum_grid(grid, denom)

    if wanted & {48, 24}:
        grid48, denom48 = _accumulate_box_grid(master, MASTER_SIZE, 48)
        if 48 in wanted:
            result[48] = _finalize_accum_grid(grid48, denom48)
        if 24 in wanted:
            grid24, denom24 = _downsample_accum_2x2(grid48, denom48)
            result[24] = _finalize_accum_grid(grid24, denom24)

    for sz in sizes:
        if sz not in result:
            result[sz] = downsample_rgba(master, MASTER_SIZE, sz)

    return {sz: result[sz] for sz in sizes}


def _png_chunk(chunk_type: bytes, data: bytes) -> bytes:
    crc = zlib.crc32(chunk_type + data) & 0xFFFFFFFF
    return struct.pack(">I", len(data)) + chunk_type + data + struct.pack(">I", crc)


def encode_png_rgba(width: int, height: int, rgba: bytes) -> bytes:
    """Encode raw 8-bit RGBA pixels as a deterministic PNG image."""
    if len(rgba) != width * height * 4:
        raise ValueError(f"expected {width * height * 4} RGBA bytes, got {len(rgba)}")
    stride = width * 4
    scanlines = bytearray(height * (stride + 1))
    for y in range(height):
        dst_off = y * (stride + 1)
        scanlines[dst_off] = 0  # Filter type 0 (None)
        scanlines[dst_off + 1 : dst_off + 1 + stride] = rgba[y * stride : (y + 1) * stride]

    ihdr = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)
    idat = zlib.compress(bytes(scanlines), level=9)
    return (
        b"\x89PNG\r\n\x1a\n"
        + _png_chunk(b"IHDR", ihdr)
        + _png_chunk(b"IDAT", idat)
        + _png_chunk(b"IEND", b"")
    )


def encode_ico(frames_rgba: dict[int, bytes], sizes: tuple[int, ...] = SIZES) -> bytes:
    """Pack multi-resolution 32bpp RGBA PNG frames into a Windows .ico container."""
    png_frames: list[tuple[int, bytes]] = []
    for sz in sizes:
        if sz < 1 or sz > 256:
            raise ValueError(f"unsupported ICO dimension: {sz}")
        png_frames.append((sz, encode_png_rgba(sz, sz, frames_rgba[sz])))

    header = struct.pack("<HHH", 0, 1, len(png_frames))
    offset = 6 + 16 * len(png_frames)
    entries: list[bytes] = []
    payloads: list[bytes] = []
    for sz, png_bytes in png_frames:
        dim = 0 if sz == 256 else sz
        entries.append(
            struct.pack(
                "<BBBBHHII",
                dim,
                dim,
                0,
                0,
                1,
                32,
                len(png_bytes),
                offset,
            )
        )
        payloads.append(png_bytes)
        offset += len(png_bytes)

    return header + b"".join(entries) + b"".join(payloads)


def build_icon_bundle() -> IconBundle:
    """Render both release and dev icon masters, downsampled frames, SVGs, and ICOs."""
    release_master = render_master_rgba(dev=False)
    dev_master = render_master_rgba(dev=True)

    release_frames = downsample_all_sizes(release_master, SIZES)
    dev_frames = downsample_all_sizes(dev_master, SIZES)

    return IconBundle(
        release_svg=build_svg(dev=False).encode("utf-8"),
        dev_svg=build_svg(dev=True).encode("utf-8"),
        release_ico=encode_ico(release_frames, SIZES),
        dev_ico=encode_ico(dev_frames, SIZES),
        release_frames=release_frames,
        dev_frames=dev_frames,
    )


def _blend_over(
    canvas: bytearray,
    canvas_w: int,
    canvas_h: int,
    dst_x: int,
    dst_y: int,
    src: bytes,
    src_w: int,
    src_h: int,
    *,
    scale: int = 1,
) -> None:
    for sy in range(src_h):
        for sx in range(src_w):
            s_off = (sy * src_w + sx) * 4
            sa = src[s_off + 3]
            if sa == 0:
                continue
            sr = src[s_off]
            sg = src[s_off + 1]
            sb = src[s_off + 2]
            for dy in range(scale):
                cy = dst_y + sy * scale + dy
                if cy < 0 or cy >= canvas_h:
                    continue
                for dx in range(scale):
                    cx = dst_x + sx * scale + dx
                    if cx < 0 or cx >= canvas_w:
                        continue
                    c_off = (cy * canvas_w + cx) * 4
                    if sa == 255:
                        canvas[c_off] = sr
                        canvas[c_off + 1] = sg
                        canvas[c_off + 2] = sb
                        canvas[c_off + 3] = 255
                    else:
                        inv = 255 - sa
                        canvas[c_off] = round((sr * sa + canvas[c_off] * inv) / 255)
                        canvas[c_off + 1] = round((sg * sa + canvas[c_off + 1] * inv) / 255)
                        canvas[c_off + 2] = round((sb * sa + canvas[c_off + 2] * inv) / 255)
                        canvas[c_off + 3] = 255


def _fill_rect(
    canvas: bytearray,
    canvas_w: int,
    x0: int,
    y0: int,
    w: int,
    h: int,
    rgba: RGBA,
) -> None:
    row_chunk = bytes(rgba) * w
    for y in range(y0, y0 + h):
        off = (y * canvas_w + x0) * 4
        canvas[off : off + w * 4] = row_chunk


def render_preview_png(bundle: IconBundle | None = None) -> bytes:
    """Render a multi-size light/dark contact sheet (256, 64, 32, 24, 16 + zoomed tray)."""
    active = bundle if bundle is not None else build_icon_bundle()
    width = 1024
    row_h = 304
    height = row_h * 4
    canvas = bytearray(width * height * 4)

    light_bg: RGBA = (0xF6, 0xF7, 0xF8, 0xFF)
    dark_bg: RGBA = (0x14, 0x16, 0x19, 0xFF)
    divider_light: RGBA = (0xE6, 0xE8, 0xEB, 0xFF)
    divider_dark: RGBA = (0x2B, 0x30, 0x38, 0xFF)

    rows = (
        (active.release_frames, light_bg, divider_light),
        (active.release_frames, dark_bg, divider_dark),
        (active.dev_frames, light_bg, divider_light),
        (active.dev_frames, dark_bg, divider_dark),
    )

    for row_idx, (frames, bg, divider) in enumerate(rows):
        y_top = row_idx * row_h
        _fill_rect(canvas, width, 0, y_top, width, row_h, bg)
        if row_idx > 0:
            _fill_rect(canvas, width, 0, y_top, width, 1, divider)

        # Native 1:1 icons across (256, 64, 32, 24, 16)
        cursor_x = 24
        for sz in PREVIEW_SIZES:
            cy = y_top + (row_h - sz) // 2
            _blend_over(canvas, width, height, cursor_x, cy, frames[sz], sz, sz, scale=1)
            cursor_x += sz + 28

        # Nearest-neighbor magnified tray previews (32x32 @ 4x, 24x24 @ 5x, 16x16 @ 8x)
        cursor_x += 16
        for sz, zoom in ((32, 4), (24, 5), (16, 8)):
            scaled = sz * zoom
            cy = y_top + (row_h - scaled) // 2
            _blend_over(canvas, width, height, cursor_x, cy, frames[sz], sz, sz, scale=zoom)
            cursor_x += scaled + 20

    return encode_png_rgba(width, height, bytes(canvas))


def write_icons(root: Path, bundle: IconBundle | None = None) -> list[Path]:
    """Write all SVG and ICO icon files under root using exact bytes (UTF-8 no BOM, LF)."""
    root = root.resolve()
    active = bundle if bundle is not None else build_icon_bundle()
    written: list[Path] = []
    for path, expected in active.expected_repo_files(root).items():
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(expected)
        written.append(path)
    return written


def check_icons(root: Path, bundle: IconBundle | None = None) -> list[str]:
    """Verify that all committed SVG and ICO icon files exist and match exact generated bytes."""
    root = root.resolve()
    active = bundle if bundle is not None else build_icon_bundle()
    errors: list[str] = []
    for path, expected in active.expected_repo_files(root).items():
        rel = path.relative_to(root).as_posix()
        if not path.is_file():
            errors.append(f"{rel}: missing generated icon file")
            continue
        actual = path.read_bytes()
        if actual != expected:
            errors.append(
                f"{rel}: out of date ({len(actual)} bytes on disk vs {len(expected)} expected; "
                "run `python -B scripts/generate_icons.py`)"
            )
    return errors


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--root",
        type=Path,
        default=Path(__file__).resolve().parents[1],
        help="Repository root directory.",
    )
    parser.add_argument(
        "--check",
        action="store_true",
        help="Verify committed SVG and ICO files are up to date without modifying files.",
    )
    parser.add_argument(
        "--preview",
        type=Path,
        default=None,
        metavar="PNG_PATH",
        help="Optional output path for a multi-size light/dark preview sheet PNG.",
    )
    args = parser.parse_args(argv)

    bundle = build_icon_bundle()

    if args.preview is not None:
        preview_path = args.preview.resolve()
        preview_path.parent.mkdir(parents=True, exist_ok=True)
        preview_path.write_bytes(render_preview_png(bundle))
        print(f"Wrote preview sheet: {preview_path.name}")

    if args.check:
        errors = check_icons(args.root, bundle)
        if errors:
            for err in errors:
                print(f"FAIL: {err}", file=sys.stderr)
            return 1
        print("PASS: all 7 SVG and ICO icon assets are up to date.")
        return 0

    written = write_icons(args.root, bundle)
    print(f"Generated {len(written)} SVG and ICO icon assets.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
