# ndk — aarch64 Android 版 NDK
运行在 aarch64 Android(Termux 等)上、且只含 aarch64 目标的 NDK。
Actions → build-ndk-aarch64-android → Run workflow,产物在 Artifacts。
注意:`ndk-build` 的 make 指向 Termux 的 `make`(`pkg install make`);使用时请设置 `APP_ABI := arm64-v8a`;主机目录名保留 `linux-x86_64`(附 `linux-aarch64` 软链);shebang 已改写为 Termux 路径。
