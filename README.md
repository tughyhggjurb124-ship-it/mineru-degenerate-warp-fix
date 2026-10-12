# MinerU 4.0.12 — `Unsupported warp settings` fix

A local patch for a MinerU 4.0.12 bug: **one degenerate OCR box kills a whole page window.**

- **Symptom** — parsing a page range fails outright with

  ```json
  { "error": { "type": "engine_error", "code": "parse_failed",
               "message": "Unsupported warp settings", "param": null } }
  ```

  No output file is written, so the entire page range has to be re-done — even
  though only one page, one box, was actually malformed.

- **Scope** — `mineru==4.0.12` + `docvortex==0.5.16` (built and verified against
  exactly these versions; see [Version scope](#version-scope)).
- **Fix** — two one-line clamps, no behaviour change for well-formed input.
- **Status** — verified end to end. The page range that used to fail now parses,
  and `git apply` of this patch reproduces the patched files byte for byte.

---

## Symptom and root cause

The failure always has this shape:

```
ERROR: Parse-server job file failed: job_id=... file='source.pdf' tier=basic page_range='49-55'
Traceback (most recent call last):
  ...
  File ".../mineru/backend/analysis/pdf/ocr.py", line 171, in _ocr_det
    _append_ocr_det_result(crop, ocr_res, need_rec_img)
  ...
  File ".../mineru/model/ocr/results.py", line 67, in get_ocr_result_list
    img_crop = get_rotate_crop_image_for_text_rec(ori_im, tmp_box)
  File ".../mineru/model/ocr/image.py", line 148, in get_rotate_crop_image_for_text_rec
    return rotate_vertical_crop_if_needed(get_rotate_crop_image(img, points))
  File ".../mineru/model/ocr/image.py", line 103, in get_rotate_crop_image
    dst_img = warp_image(img, matrix, (img_crop_width, img_crop_height), border="replicate", interpolation="cubic")
  File ".../docvortex/foundation/_image_numeric.py", line 570, in warp_image
    raise ValueError("Unsupported warp settings")
ValueError: Unsupported warp settings
```

`mineru/model/ocr/image.py` computes the crop size from the quad's side lengths:

```python
img_crop_width  = int(max(np.linalg.norm(points[0] - points[1]), np.linalg.norm(points[2] - points[3])))
img_crop_height = int(max(np.linalg.norm(points[0] - points[3]), np.linalg.norm(points[1] - points[2])))
```

When a detection box is degenerate — four corners within a fraction of a pixel of
each other, which a scanned or noisy page does produce — both sides are `< 1.0`
and `int()` **truncates them to 0**. The kernel then rejects the zero-size target:

```python
# docvortex/foundation/_image_numeric.py, warp_image()
if interpolation not in (...) or border not in (...) or min(size) <= 0:
    raise ValueError("Unsupported warp settings")
```

The `ValueError` is not caught anywhere on the way up, so it propagates out of the
page analysis and takes the whole window with it.

A degenerate box is *expected input*, not a programming error: the box is clamped
away to a 1×1 crop by the patch, and the pipeline continues.

## The fix

Two clamps, `patches/mineru-4.0.12-degenerate-warp.patch`:

```diff
# mineru/model/ocr/image.py — the call site that computes the crop size
-    img_crop_width  = int(max(np.linalg.norm(points[0] - points[1]), np.linalg.norm(points[2] - points[3])))
-    img_crop_height = int(max(np.linalg.norm(points[0] - points[3]), np.linalg.norm(points[1] - points[2])))
+    img_crop_width  = max(1, int(max(np.linalg.norm(points[0] - points[1]), np.linalg.norm(points[2] - points[3]))))
+    img_crop_height = max(1, int(max(np.linalg.norm(points[0] - points[3]), np.linalg.norm(points[1] - points[2]))))

# docvortex/foundation/_image_numeric.py — the kernel, so the seal and table
# warp call sites (which have the same latent bug) are covered too
-    if interpolation not in (...) or border not in (...) or min(size) <= 0:
+    if interpolation not in (...) or border not in (...):
         raise ValueError("Unsupported warp settings")
+    size = (max(1, int(size[0])), max(1, int(size[1])))
```

**Why two places.** The first clamp fixes the failure that was actually observed.
The second fixes the *class*: `seal_crop.py`, `seal_det_warp.py` and the table
recognisers all compute target sizes the same way and all end at this kernel. A
1-pixel render is a harmless placeholder; a hard failure is not.

**Why the guard stays.** `interpolation` and `border` are still validated — those
*are* programming errors. Only a non-positive target size is treated as data.

## Install

`<site-packages>` is the site-packages of the environment that has MinerU, e.g.

| Install style | site-packages |
| --- | --- |
| `uv tool install` (Windows) | `%LOCALAPPDATA%\uv\tools\mineru\Lib\site-packages` |
| `uv tool install` (Linux/macOS) | `~/.local/share/uv/tools/mineru/lib/python3.X/site-packages` |

### 1. With `git apply` (recommended)

```sh
# from the site-packages directory
curl -LO https://raw.githubusercontent.com/<owner>/<repo>/main/patches/mineru-4.0.12-degenerate-warp.patch
git apply --verbose mineru-4.0.12-degenerate-warp.patch
```

Apply it with `-p1` from the site-packages root (the patch paths are
`mineru/...` and `docvortex/...`). If your Git has `core.autocrlf=true`, add
`-c core.autocrlf=false` so the context lines match.

### 2. With the helper script (version-tolerant, idempotent)

The script matches the exact source lines instead of line numbers, reports
`already patched` instead of failing, and finds site-packages by itself:

```powershell
# Windows
pwsh -File patches/apply.ps1                       # or: -SitePackages <path>
```

```sh
# Linux / macOS
sh patches/apply.sh                                # or: patches/apply.sh <site-packages>
```

### 3. By hand

Two edits, exactly as in the diff above — both are `max(1, ...)` clamps.

Then restart the MinerU service so the parse server reloads the code:

```sh
mineru server restart
```

## Verify

```sh
python verify/verify_patch.py
```

It checks that a zero-size warp is clamped instead of raising, that genuinely
invalid `interpolation`/`border` settings still raise, that the real trigger — an
axis-aligned box whose integer bounds collapse — returns a crop, and that an
ordinary box is untouched. Exit code is non-zero on failure.

`repro/reproduce.py` is the minimal reproduction: it fails with
`Unsupported warp settings` on an unpatched install and passes on a patched one.

## After upgrading MinerU

The patch lives in site-packages, so `uv tool upgrade mineru`, `pip install -U mineru`
or any reinstall **overwrites it**. Re-run the helper script (it is idempotent),
then `mineru server restart`.

Keeping a copy of this repository next to the install and running
`patches/apply.ps1` after every upgrade is the intended workflow.

## Version scope

Verified against:

| Package | Version |
| --- | --- |
| `mineru` | 4.0.12 |
| `docvortex` | 0.5.16 |
| `onnxruntime` | 1.31.0 |
| Python | 3.12.10 (Windows 11) |

`docvortex` 0.5.16 is the latest release at the time of writing, so there is no
fixed version to upgrade to. The unified diff in `patches/` will not apply to a
different line layout; the helper scripts match on source text and are more
forgiving, but both assume the code above is still shaped this way. If a newer
MinerU changes `get_rotate_crop_image` or `warp_image`, adjust the anchors (or
just make the same two clamps by hand).

This is a workaround, not an upstream fix — if it helps you, it is worth reporting
upstream to [opendatalab/MinerU](https://github.com/opendatalab/MinerU/issues).

## Files

```
patches/mineru-4.0.12-degenerate-warp.patch   unified diff (git apply -p1)
patches/apply.ps1                             Windows helper, idempotent
patches/apply.sh                              POSIX helper, idempotent
repro/reproduce.py                            minimal reproduction
verify/verify_patch.py                        checks the patch is active
docs/traceback.txt                            the real traceback and error envelope
```

## License

MIT — see [LICENSE](LICENSE). This repository contains only a patch and tooling;
MinerU itself is licensed separately (Apache-2.0 with additional conditions).
