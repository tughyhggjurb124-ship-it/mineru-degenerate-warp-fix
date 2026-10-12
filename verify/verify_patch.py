"""Checks that the "Unsupported warp settings" patch is applied and has no side effects.

    python verify/verify_patch.py

Exit code 0 only when every check passes. Run it with the Python that has MinerU.
"""

import sys

import numpy as np

results = []


def check(name, ok, detail=""):
    results.append((name, ok, detail))
    print(f"{'PASS' if ok else 'FAIL'}  {name}{('  # ' + detail) if detail else ''}")


def expect_ok(name, fn, expectation):
    try:
        out = fn()
    except Exception as exc:                      # noqa: BLE001 - the point is to catch everything
        check(name, False, f"raised {exc!r}")
        return
    got = expectation(out)
    check(name, got, f"shape {getattr(out, 'shape', out)}")


def expect_raise(name, fn, exc_type=ValueError):
    try:
        fn()
    except exc_type as exc:
        check(name, True, f"{exc_type.__name__}: {exc}")
        return
    except Exception as exc:                      # noqa: BLE001
        check(name, False, f"raised {type(exc).__name__} instead of {exc_type.__name__}: {exc}")
        return
    check(name, False, "did not raise")


def main():
    from docvortex.foundation._image_numeric import warp_image
    from mineru.model.ocr.image import get_rotate_crop_image

    kernel_img = np.zeros((20, 20, 3), np.uint8)
    ocr_img = np.full((50, 50, 3), 200, np.uint8)

    # 1. a non-positive target size is data, not an error: it is clamped to one pixel
    expect_ok("kernel clamps zero width", lambda: warp_image(kernel_img, np.eye(3), (0, 5)),
              lambda out: out.shape == (5, 1, 3))
    expect_ok("kernel clamps zero height", lambda: warp_image(kernel_img, np.eye(3), (5, 0)),
              lambda out: out.shape == (1, 5, 3))
    expect_ok("kernel clamps zero both", lambda: warp_image(kernel_img, np.eye(3), (0, 0)),
              lambda out: out.shape == (1, 1, 3))
    expect_ok("kernel clamps negative size", lambda: warp_image(kernel_img, np.eye(3), (-1, 4)),
              lambda out: out.shape == (4, 1, 3))

    # 2. genuinely invalid settings are still rejected - the patch must not disable the guard
    expect_raise("kernel still rejects bad interpolation",
                 lambda: warp_image(kernel_img, np.eye(3), (3, 3), interpolation="bogus"))
    expect_raise("kernel still rejects bad border",
                 lambda: warp_image(kernel_img, np.eye(3), (3, 3), border="bogus"))

    # 3. the real-world trigger: an axis-aligned box whose integer bounds collapse
    degenerate = np.float32([[10, 10], [10.4, 10], [10.4, 10.4], [10, 10.4]])
    expect_ok("ocr crop survives a degenerate box",
              lambda: get_rotate_crop_image(ocr_img, degenerate),
              lambda out: out.size > 0)

    thin = np.float32([[10, 10], [10.4, 10], [10.4, 12.4], [10, 12.4]])
    expect_ok("ocr crop survives a thin box",
              lambda: get_rotate_crop_image(ocr_img, thin),
              lambda out: out.size > 0)

    # 4. and well-formed boxes are untouched
    normal = np.float32([[5, 5], [45, 5], [45, 20], [5, 20]])
    expect_ok("ocr crop unchanged for a normal box",
              lambda: get_rotate_crop_image(ocr_img, normal),
              lambda out: out.shape == (15, 40, 3))

    failed = [name for name, ok, _ in results if not ok]
    if failed:
        print(f"\n{len(failed)} check(s) failed: {', '.join(failed)}")
        print("If the clamps are missing, apply the patch: patches/apply.ps1 or patches/apply.sh")
        return 1
    print(f"\nAll {len(results)} checks passed: the patch is applied.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
