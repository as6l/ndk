#!/usr/bin/env bash
# 构建「运行在 aarch64 Android(Termux 等)上」、且只含 aarch64 目标的 NDK。
# 思路:
#   1. 用官方 Linux x86_64 NDK 当作 交叉编译器 + 目标侧文件(sysroot / compiler-rt / libc++)来源
#   2. 从 LLVM 源码交叉编译出 aarch64-linux-android 主机端的 clang / lld / llvm-* 工具(仅 AArch64 后端)
#   3. 拼装:替换主机二进制,删除所有非 aarch64 的目标文件
set -euxo pipefail

NDK_VER="${NDK_VER:-r30}"
LLVM_TAG="${LLVM_TAG:-llvmorg-22.1.8}"   # r30 内置 clang-r574158c(LLVM 22),resource dir 为 lib/clang/22
HOST_API="${HOST_API:-26}"               # 生成的 clang 运行所需的最低 Android API
TP="${SHEBANG_PREFIX:-/data/data/com.termux/files/usr}"   # shebang 改写目标(Termux 的 $PREFIX)
W="${WORK:-$PWD/work}"
mkdir -p "$W" && cd "$W"

# ---------- 1. 官方 NDK ----------
if [ ! -d ndk-official ]; then
  curl -fL -o ndk.zip "https://dl.google.com/android/repository/android-ndk-${NDK_VER}-linux.zip"
  unzip -q ndk.zip && mv android-ndk-* ndk-official && rm ndk.zip
fi
OFFICIAL="$W/ndk-official"

# ---------- 2. 编译(tools-cache 命中则整段跳过) ----------
if [ -f "$W/tools-cache/DONE" ]; then
  echo "tools-cache 命中,跳过编译"
else
  export W OFFICIAL LLVM_TAG HOST_API
  bash "$(dirname "$(readlink -f "$0")")/compile.sh"
fi

# ---------- 5. 拼装 ----------
OUT="$W/android-ndk-${NDK_VER}-aarch64"
rm -rf "$OUT" && cp -a "$OFFICIAL" "$OUT"
P="$OUT/toolchains/llvm/prebuilt/linux-x86_64"

# 5a. 删除主机端 x86_64 ELF(注意:不碰 sysroot 与 lib/clang,里面的 .so/.o 是 aarch64 目标文件)
find "$OUT" -type f -not -path '*/sysroot/*' -not -path '*/lib/clang/*' -print0 |
while IFS= read -r -d '' f; do
  if [ "$(head -c4 "$f" | tail -c3)" = "ELF" ]; then rm -f "$f"; fi
done
find "$OUT" -xtype l -delete            # 清理指向已删除 ELF 的悬空软链(如 clang -> clang-NN)
mv "$P/lib/clang" "$W/_clang" && rm -rf "$P/lib" "$P/python3" && mkdir -p "$P/lib" && mv "$W/_clang" "$P/lib/clang"
rm -rf "$OUT/prebuilt" "$OUT/shader-tools" "$OUT/simpleperf" "$OUT/python-packages"

# 5b. 放入 aarch64-android 主机工具(cp -L 解引用,保证 clang 是真实文件而不是指向 clang-NN 的软链)
B="$W/tools-cache/bin"
REAL="clang lld llvm-ar llvm-nm llvm-objcopy llvm-objdump llvm-readobj llvm-symbolizer llvm-cxxfilt llvm-size llvm-strings llvm-profdata llvm-cov llvm-as llvm-dis"
mkdir -p "$P/bin"
for t in $REAL; do cp -fL --remove-destination "$B/$t" "$P/bin/$t"; done
CLANGVER=$(ls "$P/lib/clang" | sort -n | tail -1)
OURVER=$(cat "$W/tools-cache/clang-resource-version")
[ "$CLANGVER" = "$OURVER" ] || echo "::warning::resource dir 版本不一致: 官方 NDK=$CLANGVER, 自编 clang=$OURVER, 请调整 LLVM_TAG"
cd "$P/bin"
for l in clang++ clang-cpp "clang-${CLANGVER}"; do ln -sf clang "$l"; done      # clang* 全部指向 clang(真实文件)
ln -sf lld ld.lld; ln -sf lld ld
ln -sf llvm-ar llvm-ranlib; ln -sf llvm-objcopy llvm-strip
ln -sf llvm-readobj llvm-readelf; ln -sf llvm-symbolizer llvm-addr2line
chmod +x "$P"/bin/* 2>/dev/null || true
ln -sfn linux-x86_64 "$OUT/toolchains/llvm/prebuilt/linux-aarch64"

# 5c. 用 find 按关键字精简其他架构(只匹配文件/目录名;linux-x86_64 / linux-aarch64 / arm64* 除外)
cd "$W"
find "$OUT" -depth \( -iname '*riscv*' -o -iname '*x86*' -o -iname '*arm*' -o -iname '*i686*' -o -iname '*i386*' \) \
  ! -iname '*arm64*' ! -name 'linux-x86_64' ! -name 'linux-aarch64' -print0 > prune.list
tr '\0' '\n' < prune.list > prune.log; head -n 50 prune.log || true; echo "共精简 $(tr -cd '\0' < prune.list | wc -c) 项,完整列表见 prune.log"
xargs -0 -r rm -rf < prune.list
find "$OUT" -type d -empty -delete

# 5c2. 去掉 Python 相关:*.py / __pycache__ / python 为解释器的脚本 / 依赖 python 的包装脚本(ndk-gdb、ndk-stack 等)
find "$OUT" -type d \( -name '__pycache__' -o -name 'python*' \) -not -path '*/sysroot/*' -prune -exec rm -rf {} + 2>/dev/null || true
find "$OUT" -type f \( -name '*.py' -o -name '*.pyc' -o -name '*.pyi' \) -not -path '*/sysroot/*' -print -delete > "$W/python-removed.log" || true
find "$OUT" -type f -not -path '*/sysroot/*' -not -path '*/lib/clang/*' -print0 |
while IFS= read -r -d '' f; do
  if [ "$(head -c2 "$f")" = '#!' ] && head -n1 "$f" | grep -q python; then
    echo "$f" >> "$W/python-removed.log"; rm -f "$f"
  fi
done
for f in "$OUT"/* "$P/bin"/*; do   # 顶层/bin 里仍引用 python 的包装脚本
  if [ -f "$f" ] && [ ! -L "$f" ] && [ "$(head -c2 "$f")" = '#!' ] && grep -qi python "$f"; then
    echo "$f" >> "$W/python-removed.log"; rm -f "$f"
  fi
done
echo "已移除 $(wc -l < "$W/python-removed.log") 个 Python 相关文件(见 python-removed.log)"
find "$OUT" -xtype l -delete; find "$OUT" -type d -empty -delete

# 5d. 修复 shebang:所有 sh/bash/dash -> /system/bin/sh;其余 -> $TP/bin/xxx
find "$OUT" -type f -not -path '*/sysroot/*' -not -path '*/lib/clang/*' -print0 |
while IFS= read -r -d '' f; do
  [ "$(head -c2 "$f")" = '#!' ] || continue
  sed -i -E '1{
    s@^#![[:space:]]*/usr/bin/env[[:space:]]+(-S[[:space:]]+)?(ba|da|a)?sh([[:space:]]|$)@#!/system/bin/sh\3@
    t
    s@^#![[:space:]]*/(usr/)?(s?bin)/(ba|da|a)?sh([[:space:]]|$)@#!/system/bin/sh\4@
    t
    s@^#![[:space:]]*/usr/bin/env[[:space:]]+(-S[[:space:]]+)?([^[:space:]]+)@#!'"$TP"'/bin/\2@
    t
    s@^#![[:space:]]*/(usr/)?(s?bin)/([^[:space:]]+)@#!'"$TP"'/bin/\3@
  }' "$f"
done
grep -rIl --exclude-dir=sysroot '^#!' "$OUT" 2>/dev/null | head -n 5 | while read -r f; do echo "$f: $(head -n1 "$f")"; done || true

# 5e. ndk-build 要找 prebuilt/<host>/bin/make:指向设备上的 make(构建机上是悬空软链,必须放在所有清理步骤之后)
mkdir -p "$OUT/prebuilt/linux-x86_64/bin"
ln -sf "$TP/bin/make" "$OUT/prebuilt/linux-x86_64/bin/make"

# ---------- 6. 打包 ----------
cd "$W" && tar -cJf "android-ndk-${NDK_VER}-aarch64-android.tar.xz" "$(basename "$OUT")"
ls -lh "$W"/*.tar.xz
