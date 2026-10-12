# MinerU 4.0.12 —— `Unsupported warp settings` 修复

针对 MinerU 4.0.12 的一个 bug 的本地补丁：**一个退化（degenerate）的 OCR 检测框，会让整段页码范围解析失败。**

- **现象** —— 解析某段页码范围时直接失败：

  ```json
  { "error": { "type": "engine_error", "code": "parse_failed",
               "message": "Unsupported warp settings", "param": null } }
  ```

  不会写出任何结果文件，所以整段范围都得重跑 —— 尽管只是其中一页的某一个框畸形。

- **适用范围** —— `mineru==4.0.12` + `docvortex==0.5.16`（补丁正是针对这两个版本编写并验证的，见[版本范围](#版本范围)）。
- **修复** —— 两处一行 `max(1, ...)` 夹取，对正常输入零行为变化。
- **状态** —— 已端到端验证：原先失败的页码范围现在能正常解析，且用 `git apply` 打本补丁所得文件与线上文件**字节完全一致**。

---

## 现象与根因

失败的调用栈固定是这一条：

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

`mineru/model/ocr/image.py` 用四边形边长算裁剪尺寸：

```python
img_crop_width  = int(max(np.linalg.norm(points[0] - points[1]), np.linalg.norm(points[2] - points[3])))
img_crop_height = int(max(np.linalg.norm(points[0] - points[3]), np.linalg.norm(points[1] - points[2])))
```

当检测框退化时（四角相距不到一个像素 —— 扫描件或噪声页确实会产生这种框），两条边都 `< 1.0`，`int()` 把它们**截断成 0**。于是数值内核拒绝了零尺寸目标：

```python
# docvortex/foundation/_image_numeric.py, warp_image()
if interpolation not in (...) or border not in (...) or min(size) <= 0:
    raise ValueError("Unsupported warp settings")
```

这个 `ValueError` 在往上抛的过程中没有任何一层捕获，于是它冲出页面分析、带走整个窗口。

退化框属于**正常输入**，不是编程错误 —— 补丁把它夹成 1×1 的裁剪后，流程继续往下走。

## 修复内容

两处夹取，见 `patches/mineru-4.0.12-degenerate-warp.patch`：

```diff
# mineru/model/ocr/image.py —— 计算裁剪尺寸的调用点
-    img_crop_width  = int(max(np.linalg.norm(points[0] - points[1]), np.linalg.norm(points[2] - points[3])))
-    img_crop_height = int(max(np.linalg.norm(points[0] - points[3]), np.linalg.norm(points[1] - points[2])))
+    img_crop_width  = max(1, int(max(np.linalg.norm(points[0] - points[1]), np.linalg.norm(points[2] - points[3]))))
+    img_crop_height = max(1, int(max(np.linalg.norm(points[0] - points[3]), np.linalg.norm(points[1] - points[2]))))

# docvortex/foundation/_image_numeric.py —— 内核层，同时兜住印章与表格裁图这两处同类隐患
-    if interpolation not in (...) or border not in (...) or min(size) <= 0:
+    if interpolation not in (...) or border not in (...):
         raise ValueError("Unsupported warp settings")
+    size = (max(1, int(size[0])), max(1, int(size[1])))
```

**为什么改两处。** 第一处修掉实际观测到的崩溃点。第二处修掉**同一类**问题：`seal_crop.py`、`seal_det_warp.py` 和表格识别都以同样方式计算目标尺寸，并且都会落到这个内核上。渲染出 1 像素是无害的占位；硬失败不是。

**为什么保留抛错。** `interpolation` 与 `border` 仍然照旧校验 —— 那些才是真正的编程错误。只有非正的目标尺寸被当作数据处理。

## 安装

`<site-packages>` 指安装了 MinerU 的那个环境的 site-packages，例如：

| 安装方式 | site-packages |
| --- | --- |
| `uv tool install`（Windows） | `%LOCALAPPDATA%\uv\tools\mineru\Lib\site-packages` |
| `uv tool install`（Linux/macOS） | `~/.local/share/uv/tools/mineru/lib/python3.X/site-packages` |

### 1. 用 `git apply`（推荐）

```sh
# 在 site-packages 目录下执行
curl -LO https://raw.githubusercontent.com/<owner>/<repo>/main/patches/mineru-4.0.12-degenerate-warp.patch
git apply --verbose mineru-4.0.12-degenerate-warp.patch
```

在 site-packages 根目录下以 `-p1` 方式应用（补丁里的路径是 `mineru/...` 和 `docvortex/...`）。如果你的 Git 开了 `core.autocrlf=true`，加上 `-c core.autocrlf=false`，否则上下文行对不上。

### 2. 用辅助脚本（按源码文本匹配，幂等）

脚本按精确源码行匹配而非行号，已打过会提示 `already patched` 而不是报错，并且会自己找 site-packages：

```powershell
# Windows
pwsh -File patches/apply.ps1                       # 或 -SitePackages <路径>
```

```sh
# Linux / macOS
sh patches/apply.sh                                # 或 patches/apply.sh <site-packages>
```

### 3. 手工修改

就上面 diff 里的两处，都是 `max(1, ...)` 夹取。

改完重启 MinerU 服务，让解析服务重新加载代码：

```sh
mineru server restart
```

## 验证

```sh
python verify/verify_patch.py
```

它会检查：零尺寸 warp 被夹取而不是抛错；真正非法的 `interpolation`/`border` 仍然抛错；真实触发场景（整数边界塌缩的轴对齐框）能返回裁剪；正常文本框结果不变。失败时退出码非零。

`repro/reproduce.py` 是最小复现：未打补丁时报 `Unsupported warp settings`，打过则通过。

## 升级 MinerU 之后

补丁在 site-packages 里，因此 `uv tool upgrade mineru`、`pip install -U mineru` 或任何重装都会**把它覆盖掉**。重跑一次辅助脚本即可（它是幂等的），然后 `mineru server restart`。

建议把本仓库放在安装目录旁边，每次升级后执行 `patches/apply.ps1`。

## 版本范围

已验证组合：

| 包 | 版本 |
| --- | --- |
| `mineru` | 4.0.12 |
| `docvortex` | 0.5.16 |
| `onnxruntime` | 1.31.0 |
| Python | 3.12.10（Windows 11） |

`docvortex` 0.5.16 是撰写时的最新版本，所以没有「升级到修复版」这条路。`patches/` 里的标准 diff 换一个行布局就应用不上；辅助脚本按源码文本匹配、容错更好，但两者都假设上述代码形状未变。如果新版 MinerU 改动了 `get_rotate_crop_image` 或 `warp_image`，请相应调整锚点（或者干脆手工做同样两处夹取）。

这是权宜修复，不是上游修复 —— 如果它帮到了你，值得顺手报到 [opendatalab/MinerU](https://github.com/opendatalab/MinerU/issues)。

## 文件

```
patches/mineru-4.0.12-degenerate-warp.patch   标准 diff（git apply -p1）
patches/apply.ps1                             Windows 辅助脚本，幂等
patches/apply.sh                              POSIX 辅助脚本，幂等
repro/reproduce.py                            最小复现
verify/verify_patch.py                        校验补丁是否生效
docs/traceback.txt                            真实调用栈与错误信封
```

## 许可

MIT —— 见 [LICENSE](LICENSE)。本仓库只包含补丁与工具；MinerU 自身许可见其项目（Apache-2.0 附加条件）。
