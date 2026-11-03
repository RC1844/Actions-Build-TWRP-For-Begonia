#!/bin/bash
#
# 当 SHRP manifest 中 `github` remote URL 为错字 `https:/github.com`，
# phhusson/vendor_lptools 无法同步时，需要：
#   - profile 里通过 repo_remove_projects 屏蔽该项目
#   - 但 bootable/recovery/prebuilt/Android.bp 的 soong_namespace imports 是无条件的，
#     必须同步移除，否则 soong bootstrap 会报
#     `namespace external/lptools does not exist`
#
# 同时 Android.mk 里动态分区条件下还会把 lptools 加入构建链，通过 TW_EXCLUDE_LPTOOLS
# 排除。（begonia 未启用 PRODUCT_USE_DYNAMIC_PARTITIONS，这条实际上不会命中，但保险起见。）

set -u

find_top() {
	local d="$1"
	# case A: 工作区根 — bootable/recovery/prebuilt/Android.bp
	if [ -f "$d/bootable/recovery/prebuilt/Android.bp" ]; then
		echo "$d/bootable/recovery"
		return 0
	fi
	# case B: 直接在 bootable/recovery 目录
	if [ -f "$d/prebuilt/Android.bp" ]; then
		echo "$d"
		return 0
	fi
	while [ -n "$d" ] && [ "$d" != "/" ]; do
		d="$(dirname "$d")"
		if [ -f "$d/bootable/recovery/prebuilt/Android.bp" ]; then
			echo "$d/bootable/recovery"
			return 0
		fi
	done
	return 1
}

DIR="$(cd "$(dirname "$0")" && pwd)"
TOP="$(find_top "$DIR" || true)"
[ -n "$TOP" ] || TOP="$(find_top "$PWD" || true)"
if [ -z "$TOP" ]; then
	echo "patch_shrp_prebuilt: bootable/recovery/prebuilt/Android.bp not found, nothing to do"
	exit 0
fi

echo "patch_shrp_prebuilt: recovery source tree: $TOP"

# 1) Android.bp — 移除 soong_namespace 块中指向 external/lptools 的 import
#    TOP 可能是 workspace root (含 bootable/recovery/) 也可能是 bootable/recovery 自身
if [ -f "$TOP/prebuilt/Android.bp" ]; then
	BP="$TOP/prebuilt/Android.bp"
elif [ -f "$TOP/bootable/recovery/prebuilt/Android.bp" ]; then
	BP="$TOP/bootable/recovery/prebuilt/Android.bp"
else
	BP=""
fi

if [ -n "$BP" ]; then
	python3 - "$BP" <<'PY'
import sys, re
path = sys.argv[1]
with open(path) as f:
	text = f.read()

if '"external/lptools"' not in text:
	print("  Android.bp: no external/lptools import, nothing to do")
	sys.exit(0)

# 找到 soong_namespace { ... } 块
ns_re = re.compile(r'soong_namespace\s*\{[^}]*imports\s*:\s*\[(.*?)\]', re.DOTALL)
m = ns_re.search(text)
if not m:
	print("  Android.bp: soong_namespace block has no imports array, nothing to do")
	sys.exit(0)

imports_block = m.group(1)	# 内部内容，如: \n		"external/lptools",\n

# 按逗号分割 imports，过滤掉 external/lptools 和空白
entries = [s.strip() for s in re.split(r',', imports_block) if s.strip() and '"external/lptools"' not in s]

if not entries:
	# 所有 imports 都被剔除了，直接删掉整个 soong_namespace { imports: [...] } 块
	# 注意 Soong 数组最后一个元素通常带 trailing comma：], 不是 }
	full_re = re.compile(r'\s*soong_namespace\s*\{\s*imports\s*:\s*\[[^\]]*\]\s*,?\s*\}\s*\n?', re.DOTALL)
	new_text, n = full_re.subn('', text, count=1)
else:
	# 保留剩余 imports
	new_imports_block = ','.join(entries)
	new_text = text[:m.start(1)] + new_imports_block + text[m.end(1):]

with open(path, 'w') as f:
	f.write(new_text)

if '"external/lptools"' in new_text:
	print("  ::warning::Android.bp still references external/lptools after patch")
	sys.exit(1)
else:
	print("  Android.bp: external/lptools import removed from soong_namespace")
PY
fi

# 2) Android.mk — 通过 TW_EXCLUDE_LPTOOLS=true 排除 lptools 模块
#    即便设备开启 PRODUCT_USE_DYNAMIC_PARTITIONS 也不会真的构建 lptools
if [ -f "$TOP/prebuilt/Android.mk" ]; then
	MK="$TOP/prebuilt/Android.mk"
elif [ -f "$TOP/bootable/recovery/prebuilt/Android.mk" ]; then
	MK="$TOP/bootable/recovery/prebuilt/Android.mk"
else
	MK=""
fi

if [ -n "$MK" ] && grep -q 'lptools' "$MK"; then
	if grep -q 'patch_shrp_prebuilt' "$MK"; then
		echo "  Android.mk: already patched"
	else
		python3 - "$MK" <<'PY'
import sys
path = sys.argv[1]
with open(path) as f:
	lines = f.readlines()
# 找到文件中第一个 LOCAL_PATH := $(call my-dir)，在其后插入 EXCLUDE
for i, line in enumerate(lines):
	if 'LOCAL_PATH' in line and 'call my-dir' in line:
		insert = (
			'\n'
			'# patch_shrp_prebuilt: upstream phhusson/vendor_lptools 同步路径不可用\n'
			'# （manifest github remote URL 少写一个斜杠），用 TW_EXCLUDE_LPTOOLS\n'
			'# 避免 Android.mk 在动态分区条件下强制引用 lptools 模块。\n'
			'TW_EXCLUDE_LPTOOLS := true\n'
		)
		lines.insert(i + 1, insert)
		break
else:
	# 没找到 LOCAL_PATH，顶头加
	insert = (
		'# patch_shrp_prebuilt: 排除 lptools 模块（上游 manifest URL 错字导致同步失败）\n'
		'TW_EXCLUDE_LPTOOLS := true\n\n'
	)
	lines.insert(0, insert)

with open(path, 'w') as f:
	f.writelines(lines)
print("  Android.mk: TW_EXCLUDE_LPTOOLS=true injected")
PY
fi
else
	echo "  Android.mk: no lptools reference, skip"
fi

exit 0
