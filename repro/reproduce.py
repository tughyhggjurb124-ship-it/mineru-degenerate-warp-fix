"""Minimal reproduction of the MinerU 4.0.12 "Unsupported warp settings" failure.

Run it with the Python that has MinerU installed:

    python repro/reproduce.py

It reproduces the bug at the two levels the real traceback passes through:

  stage 1  the numeric kernel itself      (docvortex.foundation._image_numeric.warp_image)
  stage 2  the OCR crop helper            (mineru.model.ocr.image.get_rotate_crop_image)

Stage 2 is the one that actually fires in production: an axis-aligned detection box
whose integer bounds collapse (e.g. 10.0 .. 10.4) falls through the fast path, and
both `int(max(norm(...)))` values truncate to 0.

Unpatched: each stage prints FAILED with ValueError("Unsupported warp settings").
Patched:   each stage prints OK and the clamped crop shape.
"""

import sys

import numpy as np

failures = []


def stage1():
    """The kernel rejects a zero-size target."""
    from docvortex.foundation._image_numeric import warp_image

    image = np.zeros((20, 20, 3), np.uint8)
    try:
        out = warp_image(image, np.eye(3), (0, 5), interpolation="cubic", border="replicate")
    except ValueError as exc:
        failures.append("stage 1")
        print(f"stage 1 FAILED  warp_image(size=(0, 5)) raised {exc!r}")
        return
    print(f"stage 1 OK      warp_image(size=(0, 5)) -> shape {out.shape}")


def stage2():
    """The real trigger: a degenerate axis-aligned box in the text-recognition crop."""
    from mineru.model.ocr.image import get_rotate_crop_image

    image = np.full((50, 50, 3), 200, np.uint8)
    points = np.float32([[10, 10], [10.4, 10], [10.4, 10.4], [10, 10.4]])
    try:
        out = get_rotate_crop_image(image, points)
    except ValueError as exc:
        failures.append("stage 2")
        print(f"stage 2 FAILED  get_rotate_crop_image raised {exc!r}")
        return
    print(f"stage 2 OK      get_rotate_crop_image -> shape {out.shape}")


def stage2_control():
    """A normal box must be untouched by the patch (40 x 15 -> transposed when tall)."""
    from mineru.model.ocr.image import get_rotate_crop_image

    image = np.full((50, 50, 3), 200, np.uint8)
    points = np.float32([[5, 5], [45, 5], [45, 20], [5, 20]])
    out = get_rotate_crop_image(image, points)
    ok = out.shape == (15, 40, 3)
    print(f"{'OK     ' if ok else 'FAILED '} control        normal box -> shape {out.shape} (expected (15, 40, 3))")
    if not ok:
        failures.append("control")


if __name__ == "__main__":
    stage1()
    stage2()
    stage2_control()
    if failures:
        print(f"\nBug present ({', '.join(failures)}). Apply the patch: patches/apply.ps1 or patches/apply.sh")
        sys.exit(1)
    print("\nPatch is active: degenerate boxes are clamped to a 1-pixel crop.")
