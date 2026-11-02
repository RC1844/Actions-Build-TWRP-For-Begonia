#!/bin/bash
#
# 保持 FBE 设备 DE key 在 /data 挂载切换期间不失效
#
# 现象：TWRP/PBRP/SHRP/OrangeFox 启动后 /data 已挂载且 DE key 已安装（能读到
# /data/system_de/0/spblob 与 /data/system/users/0.xml），但进入解密页提交
# pattern 时 Get_Password_Type() 读不到 spblob，报 "Unknown password type"。
#
# 原因：Setup_Data_Partition() 安装 DE key 之后，Setup_Data_Media() 中的
# UnMount(true) 以及 UnMount_Main_Partitions() 中的 UnMount_By_Path("/data")
# 会把 /data 卸载。卸载会销毁 fscrypt 的 superblock keyring，重新挂载后
# DE key 不再生效，于是 system_de 变成密文目录。
#
# 本脚本给 recovery 源码打两处最小补丁：FBE 状态下不卸载 /data。
# 适配 TWRP / PBRP / SHRP / OrangeFox 各自的代码排版差异：
#   · partition.cpp 两行之间可能夹着 #ifndef TW_INCLUDE_CRYPTO 等预处理行
#   · partitionmanager.cpp 的 UnMount_By_Path("/data", true) 可能和 if 同行

set -u

DIR="$(cd "$(dirname "$0")" && pwd)"

find_top() {
	local d="$1"
	while [ -n "$d" ] && [ "$d" != "/" ]; do
		if [ -f "$d/bootable/recovery/partition.cpp" ] && [ -f "$d/bootable/recovery/partitionmanager.cpp" ]; then
			echo "$d"
			return 0
		fi
		d="$(dirname "$d")"
	done
	return 1
}

# 先在脚本所在目录向上找；脚本被拷到工作区根目录执行时当前目录即命中
TOP="$(find_top "$DIR" || true)"
[ -n "$TOP" ] || TOP="$(find_top "$PWD" || true)"
if [ -z "$TOP" ]; then
	echo "patch_fbe_unmount: recovery source tree not found, nothing to do"
	exit 0
fi

echo "patch_fbe_unmount: recovery source tree: $TOP"

RC=0
P="$TOP/bootable/recovery/partition.cpp"
PM="$TOP/bootable/recovery/partitionmanager.cpp"

# 1) partition.cpp / Setup_Data_Media(): FBE 下保留已安装 DE key 的 /data 挂载
if grep -q "FBE_DE_KEY_KEEP" "$P"; then
	echo "patch_fbe_unmount: partition.cpp already patched"
else
	perl -0777 -i -pe 's{(DataManager::SetValue\(TW_INTERNAL_PATH, Mount_Point \+ "/media/0"\);[^\n]*\n)((?:[^\n]*\n){0,8}?)([ \t]*)UnMount\(true\);}{$1$2${3}if (!DataManager::GetIntValue(TW_IS_FBE)) // FBE_DE_KEY_KEEP\n${3}\tUnMount(true);}s' "$P"
	if grep -q "FBE_DE_KEY_KEEP" "$P"; then
		echo "patch_fbe_unmount: partition.cpp patched"
	else
		echo "::warning::patch_fbe_unmount: partition.cpp patch failed"
		RC=1
	fi
fi

# 2) partitionmanager.cpp / UnMount_Main_Partitions(): FBE 下不卸载 /data
if grep -q "FBE_DE_KEY_KEEP" "$PM"; then
	echo "patch_fbe_unmount: partitionmanager.cpp already patched"
else
	perl -0777 -i -pe 's{if \(!datamedia\)([ \t]*\n?[ \t]*)UnMount_By_Path\("/data", true\);}{if (!datamedia && !DataManager::GetIntValue(TW_IS_FBE))$1UnMount_By_Path("/data", true); // FBE_DE_KEY_KEEP}' "$PM"
	if grep -q "FBE_DE_KEY_KEEP" "$PM"; then
		echo "patch_fbe_unmount: partitionmanager.cpp patched"
	else
		echo "::warning::patch_fbe_unmount: partitionmanager.cpp patch failed"
		RC=1
	fi
fi

exit "$RC"
