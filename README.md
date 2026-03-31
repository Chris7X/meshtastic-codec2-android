![Meshtastic Codec2 Android JNI Header](images/header.png)

# Meshtastic Codec2 Android JNI

**Open source speech codec designed for communications quality speech between 700 and 3200 bit/s. The main application is low bandwidth HF/VHF digital radio.**

This repository contains the JNI (Java Native Interface) wrapper and build scripts to compile the [Codec2](https://github.com/drowe67/codec2) library for Android. It was developed to support the **Voice Burst** feature in the Meshtastic Android application.

This module has been isolated in its own repository and licensed under **LGPL-2.1** to maintain strict compliance with the original Codec2 library licensing terms, allowing it to be dynamically linked by the GPLv3 Meshtastic application without licensing conflicts.

## Architecture

This standalone library does not contain the core Android App code. It is responsible solely for:
1. Downloading the upstream Codec2 C source (v1.2.0).
2. Patching and executing CMake for the `arm64-v8a` and `x86_64` Android ABIs.
3. Compiling the JNI wrapper (`cpp/codec2_jni.cpp`) which acts as the bridge between Android's Kotlin/JVM layer and the native C layer.
4. Exporting the `libcodec2.so` and `libcodec2_jni.so` binary files.

### 16 KB Page Alignment (Android 15+)
To ensure compatibility with modern Android 15 devices that enforce 16 KB page sizes, the script explicitly passes `-Wl,-z,max-page-size=16384` to the linker.

## How to Build

### Prerequisites
- Android Studio or Command Line Tools installed.
- **Android NDK** (r25+ recommended).
- **CMake** installed via Android SDK Tools.
- Git for Windows/Linux/macOS.

### Build Instructions
Run the automated build script:

```bash
cd scripts/
bash build_codec2.sh
```

The script will automatically:
1. Fetch Codec2 upstream.
2. Cross-compile `libcodec2.so` via Android CMake toolchains.
3. Compile `libcodec2_jni.so` using `c++_static` to avoid missing libc++ dependencies on the target Android devices.
4. Output the `.so` files for each ABI.

After the build, copy the generated `.so` files into the `jniLibs/` directory of your Android application.

In the [Meshtastic-Android](https://github.com/Chris7X/Meshtastic-Android) fork, these `.so` files are bundled in the `jniLibs` directory, and dynamically loaded at runtime using:
```kotlin
System.loadLibrary("codec2_jni")
```

## License

This project is licensed under the **LGPL-2.1** license. 
See the `LICENSE` file for details.
