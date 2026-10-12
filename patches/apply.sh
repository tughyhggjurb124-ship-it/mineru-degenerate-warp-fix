#!/bin/sh
# MinerU 4.0.12 "Unsupported warp settings" fix - POSIX helper.
#
#   sh apply.sh                       # find site-packages automatically
#   sh apply.sh /path/to/site-packages
#   sh apply.sh --revert /path/to/site-packages
#
# Then restart the service:  mineru server restart

set -eu

REVERT=0
if [ "${1:-}" = "--revert" ]; then
  REVERT=1
  shift
fi

SP="${1:-}"
PYTHON=""
if [ -z "$SP" ]; then
  # next to the `mineru` command on PATH
  MINERU_BIN="$(command -v mineru || true)"
  if [ -n "$MINERU_BIN" ]; then
    BINDIR="$(cd "$(dirname "$MINERU_BIN")" && pwd)"
    for candidate in "$BINDIR/../lib"/python3*/site-packages "$BINDIR/../Lib/site-packages" "$BINDIR/../site-packages"; do
      if [ -f "$candidate/mineru/model/ocr/image.py" ]; then SP="$candidate"; break; fi
    done
  fi
fi
if [ -z "$SP" ]; then
  # ask a Python that has MinerU
  for py in python3 python; do
    if command -v "$py" >/dev/null 2>&1; then
      candidate="$("$py" -c 'import os, mineru; print(os.path.dirname(os.path.dirname(mineru.__file__)))' 2>/dev/null || true)"
      if [ -n "$candidate" ] && [ -f "$candidate/mineru/model/ocr/image.py" ]; then SP="$candidate"; PYTHON="$py"; break; fi
    fi
  done
fi
if [ -z "$SP" ]; then
  echo "Could not find a site-packages with MinerU. Pass it explicitly: sh apply.sh /path/to/site-packages" >&2
  exit 1
fi
if [ -z "$PYTHON" ]; then
  for py in python3 python; do
    if command -v "$py" >/dev/null 2>&1; then PYTHON="$py"; break; fi
  done
fi
if [ -z "$PYTHON" ]; then
  echo "python3 is required to edit the files reliably." >&2
  exit 1
fi

echo "site-packages: $SP"

SP="$SP" REVERT="$REVERT" "$PYTHON" - <<'PY'
import os, sys

sp = os.environ["SP"]
revert = os.environ["REVERT"] == "1"
NL = "\n"

EDITS = [
    dict(
        file="mineru/model/ocr/image.py",
        before="    img_crop_width = int(max(np.linalg.norm(points[0] - points[1]), np.linalg.norm(points[2] - points[3])))",
        after="    # A degenerate text box (four nearly coincident points) truncates to 0 through int(), and the{NL}"
              "    # perspective warp kernel rejects a zero-size target: clamp the crop to at least 1 pixel.{NL}"
              "    img_crop_width = max(1, int(max(np.linalg.norm(points[0] - points[1]), np.linalg.norm(points[2] - points[3]))))",
        applied="img_crop_width = max(1, int(",
        pristine="img_crop_width = int(max(np.linalg.norm(",
    ),
    dict(
        file="mineru/model/ocr/image.py",
        before="    img_crop_height = int(max(np.linalg.norm(points[0] - points[3]), np.linalg.norm(points[1] - points[2])))",
        after="    img_crop_height = max(1, int(max(np.linalg.norm(points[0] - points[3]), np.linalg.norm(points[1] - points[2]))))",
        applied="img_crop_height = max(1, int(",
        pristine="img_crop_height = int(max(np.linalg.norm(",
    ),
    dict(
        file="docvortex/foundation/_image_numeric.py",
        before='    if interpolation not in ("nearest", "linear", "cubic") or border not in ("constant", "replicate") or min(size) <= 0:{NL}'
               '        raise ValueError("Unsupported warp settings")',
        after='    if interpolation not in ("nearest", "linear", "cubic") or border not in ("constant", "replicate"):{NL}'
              '        raise ValueError("Unsupported warp settings"){NL}'
              '    # A degenerate region yields a zero-size target (the caller\'s int() truncation). Zero size is{NL}'
              '    # not an invalid setting: clamp to 1 pixel so one bad box cannot fail a whole page.{NL}'
              '    size = (max(1, int(size[0])), max(1, int(size[1])))',
        applied="size = (max(1, int(size[0])), max(1, int(size[1])))",
        pristine=" or min(size) <= 0:",
    ),
]

changed = skipped = 0
for edit in EDITS:
    path = os.path.join(sp, edit["file"])
    with open(path, "r", encoding="utf-8", newline="") as fh:
        text = fh.read()

    frm = edit["after"] if revert else edit["before"]
    to = edit["before"] if revert else edit["after"]
    done = edit["pristine"] if revert else edit["applied"]

    frm = frm.replace("{NL}", NL)
    to = to.replace("{NL}", NL)

    if frm in text:
        with open(path, "w", encoding="utf-8", newline="") as fh:
            fh.write(text.replace(frm, to))
        changed += 1
        print(f"{'reverted' if revert else 'applied '} {edit['file']}")
    elif done in text:
        skipped += 1
    else:
        sys.exit(f"cannot {'revert' if revert else 'apply'} {edit['file']}: "
                 "neither the expected original nor the patched text is present (different MinerU version?)")

if changed == 0:
    print(f"nothing to do: {skipped} edit(s) already in place")
else:
    print(f"done: {changed} edit(s) ({skipped} already in place)")
    print("now restart the service so the parse server reloads: mineru server restart")
PY
