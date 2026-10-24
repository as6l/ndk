#!/usr/bin/env bash
# 编译阶段:LLVM 源码 -> aarch64-android 主机端 clang/lld/llvm-*。产物存到 $W/tools-cache。
# 由 build.sh 在缓存未命中时调用;需要 W、OFFICIAL、LLVM_TAG、HOST_API 环境变量。
set -euxo pipefail
cd "$W"
# ---------- 2. LLVM 源码 ----------
[ -d llvm-project ] || git clone --depth 1 --branch "$LLVM_TAG" https://github.com/llvm/llvm-project.git

# ---------- 3. 本机 tablegen ----------
cmake -G Ninja -S llvm-project/llvm -B build-native \
  -DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++ -DLLVM_USE_LINKER=lld \
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
REAL_TOOLS="clang lld llvm-ar llvm-nm llvm-objcopy llvm-objdump llvm-readobj llvm-symbolizer llvm-cxxfilt llvm-size llvm-strings llvm-profdata llvm-cov llvm-as llvm-dis"
TOOLS="clang lld llvm-ar llvm-ranlib llvm-nm llvm-objcopy llvm-strip llvm-objdump llvm-readobj \
       llvm-symbolizer llvm-cxxfilt llvm-size llvm-strings llvm-profdata llvm-cov llvm-as llvm-dis"
ninja -C build-android $TOOLS

# ---------- 5. 把需要的产物单独存进 tools-cache(供 Actions 缓存,下次跳过编译) ----------
rm -rf "$W/tools-cache" && mkdir -p "$W/tools-cache/bin"
for t in $REAL_TOOLS; do cp -fL "$W/build-android/bin/$t" "$W/tools-cache/bin/$t"; done
aarch64-linux-gnu-strip --strip-unneeded "$W/tools-cache/bin"/* 2>/dev/null || true
ls "$W/build-android/lib/clang" | sort -n | tail -1 > "$W/tools-cache/clang-resource-version"
touch "$W/tools-cache/DONE"
du -sh "$W/tools-cache"

