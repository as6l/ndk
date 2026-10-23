# ndk — aarch64 Android 版 NDK
运行在 aarch64 Android(Termux 等)上、且只含 aarch64 目标的 NDK。
Actions → build-ndk-aarch64-android → Run workflow,产物在 Artifacts。
注意:`ndk-build` 需要设备上自备 `make`(Termux: `pkg install make`);主机目录名保留 `linux-x86_64`(并附 `linux-aarch64` 软链)以兼容官方脚本。
