"""Zero-dependency unit tests for scripts/generate_icons.py and committed icon assets."""

from __future__ import annotations

from contextlib import redirect_stderr, redirect_stdout
import io
from pathlib import Path
import struct
import sys
import tempfile
import unittest
from unittest import mock
import xml.etree.ElementTree as ET
import zlib

SCRIPTS_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPTS_DIR.parent
if str(SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_DIR))

import generate_icons  # noqa: E402


def _pixel_at(rgba: bytes, width: int, x: int, y: int) -> tuple[int, int, int, int]:
    off = (y * width + x) * 4
    return (rgba[off], rgba[off + 1], rgba[off + 2], rgba[off + 3])


def _point_in_polygon(x: float, y: float, poly: tuple[tuple[float, float], ...]) -> bool:
    inside = False
    n = len(poly)
    for i in range(n):
        x1, y1 = poly[i]
        x2, y2 = poly[(i + 1) % n]
        if (y1 > y) != (y2 > y):
            x_intersect = x1 + (y - y1) * (x2 - x1) / (y2 - y1)
            if x < x_intersect:
                inside = not inside
    return inside


def _oracle_sample_rgba(x: float, y: float, *, dev: bool) -> tuple[int, int, int, int]:
    """Independent geometric point-in-shape oracle for 1024x1024 master verification."""

    def in_rrect(l: float, t: float, r: float, b: float, rad: float) -> bool:
        if not (l <= x <= r and t <= y <= b):
            return False
        cx = min(max(x, l + rad), r - rad)
        cy = min(max(y, t + rad), b - rad)
        return (x - cx) ** 2 + (y - cy) ** 2 <= rad * rad

    if dev and in_rrect(560.0, 800.0, 960.0, 960.0, 52.0):
        # D: right-rounded [636, 839, 710, 925] r=40 minus [654, 857, 692, 907] r=22
        in_d_out = False
        if 636.0 <= x <= 710.0 and 839.0 <= y <= 925.0:
            cx = min(x, 670.0)
            cy = min(max(y, 879.0), 885.0)
            in_d_out = x <= 670.0 or (x - cx) ** 2 + (y - cy) ** 2 <= 40.0 * 40.0
        in_d_in = False
        if 654.0 < x < 692.0 and 857.0 < y < 907.0:
            cx = min(x, 670.0)
            cy = min(max(y, 879.0), 885.0)
            in_d_in = x <= 670.0 or (x - cx) ** 2 + (y - cy) ** 2 < 22.0 * 22.0
        if in_d_out and not in_d_in:
            return generate_icons.COLOR_DEV_TEXT

        # E: stem + 3 horizontal bars
        in_e = (
            (726.0 <= x <= 744.0 and 839.0 <= y <= 925.0)
            or (726.0 <= x <= 782.0 and 839.0 <= y <= 857.0)
            or (726.0 <= x <= 776.0 and 873.0 <= y <= 891.0)
            or (726.0 <= x <= 782.0 and 907.0 <= y <= 925.0)
        )
        if in_e:
            return generate_icons.COLOR_DEV_TEXT

        # V: 7-point polygon
        v_poly = (
            (796.0, 839.0),
            (815.0, 839.0),
            (840.0, 903.0),
            (865.0, 839.0),
            (884.0, 839.0),
            (850.0, 925.0),
            (830.0, 925.0),
        )
        if _point_in_polygon(x, y, v_poly):
            return generate_icons.COLOR_DEV_TEXT

        return generate_icons.COLOR_DEV_PILL

    # B outer silhouette
    in_b_left = False
    if 292.0 <= x <= 572.0 and 250.0 <= y <= 780.0:
        if x < 320.0 and y < 278.0:
            in_b_left = (x - 320.0) ** 2 + (y - 278.0) ** 2 <= 28.0 * 28.0
        elif x < 320.0 and y > 752.0:
            in_b_left = (x - 320.0) ** 2 + (y - 752.0) ** 2 <= 28.0 * 28.0
        else:
            in_b_left = True
    in_b_upper = x >= 572.0 and (x - 572.0) ** 2 + (y - 410.0) ** 2 <= 160.0 * 160.0
    in_b_lower = x >= 572.0 and (x - 572.0) ** 2 + (y - 620.0) ** 2 <= 160.0 * 160.0

    if in_b_left or in_b_upper or in_b_lower:
        in_c_up = (402.0 < x <= 572.0 and 360.0 < y < 460.0) or (
            x > 572.0 and (x - 572.0) ** 2 + (y - 410.0) ** 2 < 50.0 * 50.0
        )
        in_c_lo = (402.0 < x <= 572.0 and 570.0 < y < 670.0) or (
            x > 572.0 and (x - 572.0) ** 2 + (y - 620.0) ** 2 < 50.0 * 50.0
        )
        if not (in_c_up or in_c_lo):
            return generate_icons.COLOR_GLYPH

    if in_rrect(48.0, 48.0, 976.0, 976.0, 200.0):
        return generate_icons.COLOR_GROUND

    return generate_icons.COLOR_TRANSPARENT


def _parse_png_chunks(png_bytes: bytes) -> list[tuple[bytes, bytes]]:
    if not png_bytes.startswith(b"\x89PNG\r\n\x1a\n"):
        raise AssertionError("invalid PNG signature")
    pos = 8
    chunks: list[tuple[bytes, bytes]] = []
    while pos < len(png_bytes):
        (length,) = struct.unpack(">I", png_bytes[pos : pos + 4])
        chunk_type = png_bytes[pos + 4 : pos + 8]
        data = png_bytes[pos + 8 : pos + 8 + length]
        (expected_crc,) = struct.unpack(">I", png_bytes[pos + 8 + length : pos + 12 + length])
        actual_crc = zlib.crc32(chunk_type + data) & 0xFFFFFFFF
        if actual_crc != expected_crc:
            raise AssertionError(f"PNG CRC mismatch in {chunk_type!r}")
        chunks.append((chunk_type, data))
        pos += 12 + length
    return chunks


class GenerateIconsTests(unittest.TestCase):
    release_master: bytes
    dev_master: bytes
    bundle: generate_icons.IconBundle

    @classmethod
    def setUpClass(cls) -> None:
        cls.release_master = generate_icons.render_master_rgba(dev=False)
        cls.dev_master = generate_icons.render_master_rgba(dev=True)
        release_frames = generate_icons.downsample_all_sizes(cls.release_master)
        dev_frames = generate_icons.downsample_all_sizes(cls.dev_master)
        cls.bundle = generate_icons.IconBundle(
            release_svg=generate_icons.build_svg(dev=False).encode("utf-8"),
            dev_svg=generate_icons.build_svg(dev=True).encode("utf-8"),
            release_ico=generate_icons.encode_ico(release_frames),
            dev_ico=generate_icons.encode_ico(dev_frames),
            release_frames=release_frames,
            dev_frames=dev_frames,
        )

    def test_committed_repo_icons_and_svgs_are_up_to_date(self) -> None:
        errors = generate_icons.check_icons(REPO_ROOT, self.bundle)
        self.assertEqual(errors, [])

        tray_rel = (REPO_ROOT / generate_icons.ASSET_REL_PATHS["tray_release_ico"]).read_bytes()
        tray_dev = (REPO_ROOT / generate_icons.ASSET_REL_PATHS["tray_dev_ico"]).read_bytes()
        win_rel = (REPO_ROOT / generate_icons.ASSET_REL_PATHS["win_release_ico"]).read_bytes()
        win_dev = (REPO_ROOT / generate_icons.ASSET_REL_PATHS["win_dev_ico"]).read_bytes()
        win_app = (REPO_ROOT / generate_icons.ASSET_REL_PATHS["win_app_ico"]).read_bytes()

        self.assertEqual(win_rel, tray_rel)
        self.assertEqual(win_dev, tray_dev)
        self.assertEqual(win_app, tray_dev)
        self.assertNotEqual(tray_rel, tray_dev)

    def test_svg_masters_follow_canonical_spec_and_lf_hygiene(self) -> None:
        for name, raw, is_dev in (
            ("blink.svg", self.bundle.release_svg, False),
            ("blink-dev.svg", self.bundle.dev_svg, True),
        ):
            with self.subTest(name):
                self.assertFalse(raw.startswith(b"\xef\xbb\xbf"))
                self.assertNotIn(b"\r\n", raw)
                text = raw.decode("utf-8")
                self.assertTrue(text.endswith("\n"))
                root = ET.fromstring(text)
                self.assertEqual(root.attrib.get("width"), "1024")
                self.assertEqual(root.attrib.get("height"), "1024")
                self.assertEqual(root.attrib.get("viewBox"), "0 0 1024 1024")
                self.assertIn('x="48" y="48" width="928" height="928" rx="200" fill="#3C4043"', text)
                self.assertIn(generate_icons.LETTER_B_SVG_PATH, text)
                if is_dev:
                    self.assertIn('x="560" y="800" width="400" height="160" rx="52" fill="#F3A115"', text)
                    self.assertIn(generate_icons.DEV_TEXT_SVG_PATH, text)
                else:
                    self.assertNotIn("#F3A115", text)
                    self.assertNotIn("#202124", text)

    def test_master_geometry_colors_and_counters(self) -> None:
        # Top 800 rows (above DEV pill at y=800) are identical between release and dev.
        self.assertEqual(self.release_master[: 800 * 1024 * 4], self.dev_master[: 800 * 1024 * 4])

        # Transparent padding and outer rounded-corner cutouts.
        for x, y in ((0, 0), (47, 512), (512, 47), (976, 512), (512, 976), (60, 60), (964, 60), (60, 964)):
            self.assertEqual(_pixel_at(self.release_master, 1024, x, y), generate_icons.COLOR_TRANSPARENT)
            self.assertEqual(_pixel_at(self.dev_master, 1024, x, y), generate_icons.COLOR_TRANSPARENT)
        self.assertEqual(_pixel_at(self.release_master, 1024, 964, 964), generate_icons.COLOR_TRANSPARENT)

        # Ground #3C4043 including 20-unit gap (y=790) between B bottom (780) and DEV pill (800).
        for x, y in ((200, 512), (820, 220), (512, 790), (760, 790)):
            self.assertEqual(_pixel_at(self.dev_master, 1024, x, y), generate_icons.COLOR_GROUND)

        # Letter B strokes (#FFFFFF) and rounded outer left corners vs sharp inner counters.
        for x, y in ((347, 515), (480, 305), (480, 515), (480, 725), (677, 410), (677, 620), (680, 515)):
            self.assertEqual(_pixel_at(self.release_master, 1024, x, y), generate_icons.COLOR_GLYPH)

        # Waist pinch at y=515 (bowls meet at ~692.73), r=28 outer-left corners, sharp inner counters.
        for x, y in (
            (705, 515),
            (296, 254),
            (296, 776),
            (405, 363),
            (405, 457),
            (405, 573),
            (405, 667),
            (500, 410),
            (600, 410),
            (500, 620),
            (600, 620),
        ):
            self.assertEqual(_pixel_at(self.release_master, 1024, x, y), generate_icons.COLOR_GROUND)

        # Dev badge pill (#F3A115) and DEV glyph strokes (#202124) + inner holes.
        for x, y in ((600, 880), (670, 882), (765, 865), (765, 899), (840, 860), (920, 880)):
            self.assertEqual(_pixel_at(self.dev_master, 1024, x, y), generate_icons.COLOR_DEV_PILL)
        for x, y in ((645, 882), (701, 882), (735, 882), (765, 848), (765, 882), (765, 916), (806, 842), (840, 914), (874, 842)):
            self.assertEqual(_pixel_at(self.dev_master, 1024, x, y), generate_icons.COLOR_DEV_TEXT)

    def test_scanline_supersampler_matches_independent_point_oracle(self) -> None:
        sample_xs = (
            47, 48, 90, 248, 292, 298, 320, 401, 402, 500, 572, 621, 622,
            636, 654, 670, 692, 693, 710, 726, 732, 744, 776, 782, 796, 815, 840, 865, 884, 944, 960, 976,
        )
        sample_ys = (
            47, 48, 90, 250, 256, 278, 360, 410, 460, 515, 570, 620, 670,
            752, 780, 790, 800, 839, 857, 879, 882, 885, 903, 907, 925, 944, 960, 976,
        )
        for dev, master in ((False, self.release_master), (True, self.dev_master)):
            for py in sample_ys:
                for px in sample_xs:
                    sub = [
                        _oracle_sample_rgba(px + 0.25, py + 0.25, dev=dev),
                        _oracle_sample_rgba(px + 0.75, py + 0.25, dev=dev),
                        _oracle_sample_rgba(px + 0.25, py + 0.75, dev=dev),
                        _oracle_sample_rgba(px + 0.75, py + 0.75, dev=dev),
                    ]
                    a_sum = sum(c[3] for c in sub)
                    if a_sum == 0:
                        expected = (0, 0, 0, 0)
                    else:
                        expected = (
                            round(sum(c[0] * c[3] for c in sub) / a_sum),
                            round(sum(c[1] * c[3] for c in sub) / a_sum),
                            round(sum(c[2] * c[3] for c in sub) / a_sum),
                            round(a_sum / 4),
                        )
                    actual = _pixel_at(master, 1024, px, py)
                    self.assertEqual(actual, expected, f"mismatch at ({px}, {py}) dev={dev}")
                    self.assertEqual(
                        generate_icons.sample_point_rgba(px + 0.25, py + 0.25, dev=dev),
                        sub[0],
                    )

    def test_alpha_weighted_downsampling_preserves_border_rgb_and_small_counters(self) -> None:
        # 2x2 image: 2 transparent pixels + 2 #3C4043 pixels -> RGB stays exact #3C4043, alpha=128.
        src_2x2 = bytes((0, 0, 0, 0, 0, 0, 0, 0, 0x3C, 0x40, 0x43, 255, 0x3C, 0x40, 0x43, 255))
        down_1x1 = generate_icons.downsample_rgba(src_2x2, 2, 1)
        self.assertEqual(tuple(down_1x1), (0x3C, 0x40, 0x43, 128))

        # Direct box downsampling matches the exact integer pyramid at non-power-of-two 24 and 16.
        self.assertEqual(
            self.bundle.dev_frames[24],
            generate_icons.downsample_rgba(self.dev_master, 1024, 24),
        )
        self.assertEqual(
            self.bundle.release_frames[16],
            generate_icons.downsample_rgba(self.release_master, 1024, 16),
        )

        # At 16x16, both B counters stay open (darker than stem/bars) and dev has bottom-right amber pill.
        f16_rel = self.bundle.release_frames[16]
        stem_luma = _pixel_at(f16_rel, 16, 5, 8)[0]
        top_bar_luma = _pixel_at(f16_rel, 16, 7, 4)[0]
        upper_counter_luma = _pixel_at(f16_rel, 16, 7, 6)[0]
        mid_bar_luma = _pixel_at(f16_rel, 16, 7, 8)[0]
        lower_counter_luma = _pixel_at(f16_rel, 16, 7, 9)[0]
        bottom_bar_luma = _pixel_at(f16_rel, 16, 7, 11)[0]
        self.assertGreater(stem_luma, 220)
        self.assertEqual(top_bar_luma, 255)
        self.assertEqual(upper_counter_luma, 0x3C)
        self.assertGreater(mid_bar_luma, 220)
        self.assertEqual(lower_counter_luma, 0x3C)
        self.assertEqual(bottom_bar_luma, 255)

        f16_dev = self.bundle.dev_frames[16]
        badge_px = _pixel_at(f16_dev, 16, 12, 14)
        rel_px = _pixel_at(f16_rel, 16, 12, 14)
        self.assertGreater(badge_px[0], badge_px[2] + 80, "16x16 dev icon must retain warm amber badge")
        self.assertNotEqual(badge_px, rel_px)

    def test_ico_container_png_chunks_and_win32_loader(self) -> None:
        for label, ico_bytes in (("blink.ico", self.bundle.release_ico), ("blink-dev.ico", self.bundle.dev_ico)):
            with self.subTest(label):
                reserved, ico_type, count = struct.unpack("<HHH", ico_bytes[:6])
                self.assertEqual((reserved, ico_type, count), (0, 1, len(generate_icons.SIZES)))

                expected_offset = 6 + 16 * count
                for idx, sz in enumerate(generate_icons.SIZES):
                    entry_off = 6 + idx * 16
                    w, h, colors, res0, planes, bpp, size_in_bytes, img_off = struct.unpack(
                        "<BBBBHHII", ico_bytes[entry_off : entry_off + 16]
                    )
                    expected_dim = 0 if sz == 256 else sz
                    self.assertEqual((w, h, colors, res0, planes, bpp), (expected_dim, expected_dim, 0, 0, 1, 32))
                    self.assertEqual(img_off, expected_offset)

                    png_payload = ico_bytes[img_off : img_off + size_in_bytes]
                    chunks = _parse_png_chunks(png_payload)
                    self.assertEqual(chunks[0][0], b"IHDR")
                    self.assertEqual(chunks[-1][0], b"IEND")
                    pw, ph, depth, ctype, comp, filt, interlace = struct.unpack(">IIBBBBB", chunks[0][1])
                    self.assertEqual((pw, ph, depth, ctype, comp, filt, interlace), (sz, sz, 8, 6, 0, 0, 0))
                    idat = b"".join(data for ctype_name, data in chunks if ctype_name == b"IDAT")
                    raw_scanlines = zlib.decompress(idat)
                    self.assertEqual(len(raw_scanlines), sz * (sz * 4 + 1))

                    expected_offset += size_in_bytes

                self.assertEqual(expected_offset, len(ico_bytes))

        if sys.platform == "win32":
            import ctypes

            user32 = ctypes.windll.user32
            user32.LoadImageW.argtypes = [
                ctypes.c_void_p,
                ctypes.c_wchar_p,
                ctypes.c_uint,
                ctypes.c_int,
                ctypes.c_int,
                ctypes.c_uint,
            ]
            user32.LoadImageW.restype = ctypes.c_void_p
            user32.DestroyIcon.argtypes = [ctypes.c_void_p]
            user32.DestroyIcon.restype = ctypes.c_int

            image_icon = 1
            lr_loadfromfile = 0x0010
            for rel_key in ("tray_release_ico", "tray_dev_ico"):
                ico_path = str(REPO_ROOT / generate_icons.ASSET_REL_PATHS[rel_key])
                for sz in (16, 32, 256):
                    hicon = user32.LoadImageW(None, ico_path, image_icon, sz, sz, lr_loadfromfile)
                    self.assertIsNotNone(hicon, f"Win32 LoadImageW failed for {rel_key} at {sz}px")
                    self.assertNotEqual(hicon, 0)
                    user32.DestroyIcon(hicon)

    def test_cli_write_check_and_tamper_detection(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            td = Path(tmp)
            preview_path = td / "preview" / "sheet.png"
            out = io.StringIO()
            err = io.StringIO()
            with (
                mock.patch.object(generate_icons, "build_icon_bundle", return_value=self.bundle),
                redirect_stdout(out),
                redirect_stderr(err),
            ):
                self.assertEqual(generate_icons.main(["--root", str(td)]), 0)
                self.assertEqual(
                    generate_icons.main(["--check", "--root", str(td), "--preview", str(preview_path)]),
                    0,
                )

                chunks = _parse_png_chunks(preview_path.read_bytes())
                pw, ph = struct.unpack(">II", chunks[0][1][:8])
                self.assertEqual((pw, ph), (1024, 1216))

                # Corrupting any tracked icon file must fail --check.
                target_ico = td / generate_icons.ASSET_REL_PATHS["win_app_ico"]
                target_ico.write_bytes(target_ico.read_bytes()[:-1] + b"\xff")
                self.assertEqual(generate_icons.main(["--check", "--root", str(td)]), 1)

                # Missing file must also fail --check.
                target_ico.unlink()
                self.assertEqual(generate_icons.main(["--check", "--root", str(td)]), 1)


if __name__ == "__main__":
    unittest.main()
