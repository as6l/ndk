#!/usr/bin/env bash
# 构建「运行在 aarch64 Android(Termux 等)上」、且只含 aarch64 目标的 NDK。
# 思路:
#   1. 用官方 Linux x86_64 NDK 当作 交叉编译器 + 目标侧文件(sysroot / compiler-rt / libc++)来源
#   2. 从 LLVM 源码交叉编译出 aarch64-linux-android 主机端的 clang / lld / llvm-* 工具(仅 AArch64 后端)
#   3. 拼装:替换主机二进制,删除所有非 aarch64 的目标文件
set -euxo pipefail

NDK_VER="${NDK_VER:-r27c}"
LLVM_TAG="${LLVM_TAG:-llvmorg-18.1.8}"   # r27c 内置 clang 18.0.x,resource dir 同为 lib/clang/18
HOST_API="${HOST_API:-26}"               # 生成的 clang 运行所需的最低 Android API
W="${WORK:-$PWD/work}"
mkdir -p "$W" && cd "$W"

# ---------- 1. 官方 NDK ----------
if [ ! -d ndk-official ]; then
  curl -fL -o ndk.zip "https://dl.google.com/android/repository/android-ndk-${NDK_VER}-linux.zip"
  unzip -q ndk.zip && mv android-ndk-* ndk-official && rm ndk.zip
fi
OFFICIAL="$W/ndk-official"
LLVM_PREBUILT="$OFFICIAL/toolchains/llvm/prebuilt/linux-x86_64"

# ---------- 2. LLVM 源码 ----------
[ -d llvm-project ] || git clone --depth 1 --branch "$LLVM_TAG" https://github.com/llvm/llvm-project.git

# ---------- 3. 本机 tablegen ----------
cmake -G Ninja -S llvm-project/llvm -B build-native \
  -DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++ \
  -DCMAKE_CXX_FLAGS="-include cstdint" \
  -DCMAKE_BUILD_TYPE=Release -DLLVM_ENABLE_PROJECTS=clang \
  -DLLVM_TARGETS_TO_BUILD=X86 -DLLVM_INCLUDE_TESTS=OFF \
  -DCMAKE_C_COMPILER_LAUNCHER=ccache -DCMAKE_CXX_COMPILER_LAUNCHER=ccache
ninja -C build-native llvm-tblgen llvm-min-tblgen clang-tblgen

# ---------- 4. 交叉编译 aarch64-android 主机工具 ----------
cmake -G Ninja -S llvm-project/llvm -B build-android \
  -DCMAKE_TOOLCHAIN_FILE="$OFFICIAL/build/cmake/android.toolchain.cmake" \
  -DANDROID_ABI=arm64-v8a -DANDROID_PLATFORM="android-${HOST_API}" -DANDROID_STL=c++_static \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_C_FLAGS_RELEASE="-O2 -g0 -DNDEBUG" -DCMAKE_CXX_FLAGS_RELEASE="-O2 -g0 -DNDEBUG" \
  -DLLVM_HOST_TRIPLE=aarch64-linux-android -DLLVM_DEFAULT_TARGET_TRIPLE=aarch64-linux-android \
  -DLLVM_NATIVE_TOOL_DIR="$W/build-native/bin" -DCLANG_TABLEGEN="$W/build-native/bin/clang-tblgen" \
  -DLLVM_ENABLE_PROJECTS="clang;lld" -DLLVM_TARGETS_TO_BUILD=AArch64 \
  -DCLANG_DEFAULT_CXX_STDLIB=libc++ -DCLANG_DEFAULT_RTLIB=compiler-rt \
  -DCLANG_DEFAULT_LINKER=lld -DCLANG_DEFAULT_UNWINDLIB=libunwind \
  -DLLVM_ENABLE_ZLIB=OFF -DLLVM_ENABLE_ZSTD=OFF -DLLVM_ENABLE_LIBXML2=OFF -DLLVM_ENABLE_TERMINFO=OFF \
  -DLLVM_ENABLE_PLUGINS=OFF -DLLVM_INCLUDE_TESTS=OFF -DLLVM_INCLUDE_EXAMPLES=OFF \
  -DLLVM_INCLUDE_BENCHMARKS=OFF -DLLVM_INCLUDE_DOCS=OFF \
  -DCLANG_ENABLE_ARCMT=OFF -DCLANG_ENABLE_STATIC_ANALYZER=OFF -DCLANG_INCLUDE_TESTS=OFF \
  -DLLVM_PARALLEL_LINK_JOBS=1 \
  -DCMAKE_C_COMPILER_LAUNCHER=ccache -DCMAKE_CXX_COMPILER_LAUNCHER=ccache
TOOLS="clang lld llvm-ar llvm-ranlib llvm-nm llvm-objcopy llvm-strip llvm-objdump llvm-readobj \
       llvm-symbolizer llvm-cxxfilt llvm-size llvm-strings llvm-profdata llvm-cov llvm-as llvm-dis"
ninja -C build-android $TOOLS

# ---------- 5. 拼装 ----------
OUT="$W/android-ndk-${NDK_VER}-aarch64"
rm -rf "$OUT" && cp -a "$OFFICIAL" "$OUT"
P="$OUT/toolchains/llvm/prebuilt/linux-x86_64"

# 5a. 删除所有主机端 x86_64 ELF 与主机库,仅保留 shell/py 脚本与 lib/clang
find "$OUT" -type f -exec sh -c 'head -c4 "$1" | grep -q "^.ELF"' _ {} \; -print -delete
mv "$P/lib/clang" "$W/_clang" && rm -rf "$P/lib" "$P/python3" && mkdir -p "$P/lib" && mv "$W/_clang" "$P/lib/clang"
rm -rf "$OUT"/prebuilt "$OUT"/shader-tools "$OUT"/simpleperf "$OUT"/python-packages "$OUT"/toolchains/llvm/prebuilt/linux-x86_64/musl 2>/dev/null || true

# 5b. 放入 aarch64-android 主机工具
B="$W/build-android/bin"
for t in $TOOLS; do cp -a "$B/$t" "$P/bin/"; done
aarch64-linux-gnu-strip --strip-unneeded "$P"/bin/* 2>/dev/null || true
cd "$P/bin"
ln -sf clang clang++ ; ln -sf clang clang-cpp; ln -sf lld ld.lld; ln -sf lld ld
ln -sf llvm-readobj llvm-readelf; ln -sf llvm-symbolizer llvm-addr2line
ln -sf llvm-objcopy llvm-strip 2>/dev/null || true
CLANGVER=$(ls "$P/lib/clang")
for t in clang clang++; do ln -sf "$t" "${t}-${CLANGVER}"; done
cd "$P"; ln -sfn . ../prebuilt-aarch64 2>/dev/null || true
ln -sfn linux-x86_64 "$OUT/toolchains/llvm/prebuilt/linux-aarch64"

# 5c. 只保留 aarch64 目标文件
cd "$P/sysroot/usr"
for d in arm-linux-androideabi i686-linux-android x86_64-linux-android riscv64-linux-android; do
  rm -rf "lib/$d" "include/$d"
done
rm -rf "$P"/sysroot/usr/lib64 2>/dev/null || true
find "$P/lib/clang" -type f \( -name '*arm*' -o -name '*i686*' -o -name '*x86_64*' -o -name '*riscv*' -o -name '*i386*' -o -name '*hwasan-riscv*' \) \
  ! -name '*aarch64*' -delete
find "$P/lib/clang" -type d -empty -delete
rm -rf "$OUT"/sources/cxx-stl 2>/dev/null || true
# 删除 c++ 头中其他架构的 __config_site 目录(libc++ 头在 include/c++/v1,已通用)

# ---------- 6. 打包 ----------
cd "$W" && tar -cJf "android-ndk-${NDK_VER}-aarch64-android.tar.xz" "$(basename "$OUT")"
ls -lh "$W"/*.tar.xz
