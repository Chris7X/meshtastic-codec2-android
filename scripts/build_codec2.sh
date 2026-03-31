#!/usr/bin/env bash
# =============================================================================
# build_codec2.sh — Compile libcodec2 for Android (arm64-v8a + x86_64)
#
# Resolves:
#   - ExternalProject_Add(codec2_native) removed
#   - generate_codebook replaced with bash/awk function
#   - Codebook pre-generated before cmake configure
#
# Prerequisites:
#   - Android NDK r25+ (from Android Studio: Ctrl+Alt+S > SDK Tools > NDK)
#   - CMake (from Android Studio: Ctrl+Alt+S > SDK Tools > CMake)
#   - Git for Windows (bash, awk, grep, sed included)
#
# Usage:
#   cd <repo_root>
#   bash feature/voiceburst/scripts/build_codec2.sh
# =============================================================================

set -euo pipefail

# --- Configuration --------------------------------------------------------
CODEC2_TAG="${CODEC2_TAG:-1.2.0}"
CODEC2_REPO="https://github.com/drowe67/codec2.git"
ABIS=("arm64-v8a" "x86_64")
MIN_API=26

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE_DIR="$(dirname "$SCRIPT_DIR")"
JNI_LIBS_DIR="$MODULE_DIR/src/androidMain/jniLibs"
HEADERS_DIR="$MODULE_DIR/src/androidMain/cpp/include/codec2"
BUILD_DIR="/tmp/codec2_android_build"

echo ""
echo "================================================================"
echo "  Meshtastic - Build libcodec2 for Android"
echo "================================================================"
echo "  Tag:     $CODEC2_TAG"
echo "  ABIs:    ${ABIS[*]}"
echo "  Min API: $MIN_API"
echo "  Output:  $JNI_LIBS_DIR"
echo ""

# === FUNCTION: Find NDK ====================================================
find_ndk() {
    if [[ -n "${ANDROID_NDK_HOME:-}" && -d "$ANDROID_NDK_HOME" ]]; then
        echo "$ANDROID_NDK_HOME"; return 0
    fi
    if [[ -n "${ANDROID_HOME:-}" ]]; then
        local ndk_latest
        ndk_latest=$(ls -1d "$ANDROID_HOME/ndk/"* 2>/dev/null | sort -V | tail -1)
        if [[ -n "$ndk_latest" ]]; then echo "$ndk_latest"; return 0; fi
    fi
    local win_paths=(
        "$LOCALAPPDATA/Android/Sdk/ndk"
        "$HOME/AppData/Local/Android/Sdk/ndk"
        "/c/Users/$USER/AppData/Local/Android/Sdk/ndk"
    )
    for base in "${win_paths[@]}"; do
        if [[ -d "$base" ]]; then
            local ndk_latest
            ndk_latest=$(ls -1d "$base"/* 2>/dev/null | sort -V | tail -1)
            if [[ -n "$ndk_latest" ]]; then echo "$ndk_latest"; return 0; fi
        fi
    done
    local sdk_ndk
    sdk_ndk=$(ls -1d ~/Android/Sdk/ndk/* 2>/dev/null | sort -V | tail -1 || true)
    if [[ -n "$sdk_ndk" ]]; then echo "$sdk_ndk"; return 0; fi
    return 1
}

NDK_HOME=$(find_ndk) || {
    echo "ERROR: Android NDK not found."
    echo "  Installa from Android Studio: Ctrl+Alt+S > SDK Tools > NDK"
    echo "  Or set ANDROID_NDK_HOME"
    exit 1
}
echo "  NDK: $NDK_HOME"

TOOLCHAIN="$NDK_HOME/build/cmake/android.toolchain.cmake"
[[ -f "$TOOLCHAIN" ]] || { echo "ERROR: Toolchain not found: $TOOLCHAIN"; exit 1; }

find_sdk_tool() {
    local tool_name="$1"
    if command -v "$tool_name" &>/dev/null; then
        command -v "$tool_name"; return 0
    fi
    local sdk_bases=(
        "$LOCALAPPDATA/Android/Sdk/cmake"
        "$HOME/AppData/Local/Android/Sdk/cmake"
    )
    for base in "${sdk_bases[@]}"; do
        if [[ -d "$base" ]]; then
            local found
            found=$(find "$base" -name "${tool_name}.exe" -o -name "$tool_name" 2>/dev/null | sort -V | tail -1)
            if [[ -n "$found" ]]; then echo "$found"; return 0; fi
        fi
    done
    return 1
}

CMAKE_BIN=$(find_sdk_tool "cmake") || { echo "ERROR: cmake not found"; exit 1; }
NINJA_BIN=$(find_sdk_tool "ninja") || NINJA_BIN=""

echo "  CMake: $CMAKE_BIN"
if [[ -n "$NINJA_BIN" ]]; then
    echo "  Ninja: $NINJA_BIN"
    GENERATOR="Ninja"
    GENERATOR_ARGS=(-DCMAKE_MAKE_PROGRAM="$NINJA_BIN")
else
    echo "  Ninja: not found, using Unix Makefiles"
    GENERATOR="Unix Makefiles"
    GENERATOR_ARGS=()
fi
echo ""

# =============================================================================
# bash/awk replacement for generate_codebook.c
# =============================================================================
generate_codebook_sh() {
    local prefix="$1"
    shift
    local files=("$@")
    local tmpdir
    tmpdir=$(mktemp -d)

    cat <<'CHEADER'
/* THIS FILE WAS AUTOMATICALLY GENERATED - DO NOT EDIT */

#include <stddef.h>
#include "defines.h"

CHEADER

    local idx=0
    for f in "${files[@]}"; do
        if [[ ! -f "$f" ]]; then
            echo "ERROR: codebook file not found: $f" >&2
            rm -rf "$tmpdir"
            return 1
        fi

        local k m
        read -r k m < <(head -1 "$f" | tr -d '\r')

        if [[ -z "$k" || -z "$m" ]] || ! [[ "$k" =~ ^[0-9]+$ && "$m" =~ ^[0-9]+$ ]]; then
            echo "ERROR: invalid header in $(basename "$f"): '$k $m'" >&2
            rm -rf "$tmpdir"
            return 1
        fi

        if [[ "$k" -eq 0 || "$m" -eq 0 ]]; then
            echo "ERROR: k=$k o m=$m is zero in $(basename "$f")" >&2
            rm -rf "$tmpdir"
            return 1
        fi

        echo "static const float codes${idx}[] = {"
        awk '
        NR == 1 { next }
        NF > 0 && !/^#/ && !/^[[:space:]]*$/ {
            gsub(/\r/, "")
            printf "  "
            for (i = 1; i <= NF; i++) {
                printf "  %g,", $i + 0.0
            }
            printf "\n"
        }
        ' "$f"
        echo "};"
        echo ""

        echo "${k} ${m}" > "$tmpdir/meta_${idx}"
        idx=$((idx + 1))
    done

    echo "const struct lsp_codebook ${prefix}[] = {"
    for ((i = 0; i < idx; i++)); do
        local ki mi log2mi
        read -r ki mi < "$tmpdir/meta_${i}"

        log2mi=0
        local tmp=1
        while [[ $tmp -lt $mi ]]; do
            tmp=$((tmp * 2))
            log2mi=$((log2mi + 1))
        done

        echo "  { ${ki}, ${log2mi}, ${mi}, codes${i} },"
    done
    echo "  { 0, 0, 0, NULL }"
    echo "};"

    rm -rf "$tmpdir"
}

# =============================================================================
# Generate all necessary .c codebooks for codec2 v1.2.0
# =============================================================================
pre_generate_codebooks() {
    local src_dir="$1"
    local cb_dir="$src_dir/src/codebook"
    local out_dir="$src_dir/src"

    echo "--- Pre-generatedng codebooks ---"

    if [[ ! -d "$cb_dir" ]]; then
        echo "  ERROR: codebook directory not found: $cb_dir"
        return 1
    fi

    local configs=(
        "codebook.c|lsp_cb|lsp1.txt lsp2.txt lsp3.txt lsp4.txt lsp5.txt lsp6.txt lsp7.txt lsp8.txt lsp9.txt lsp10.txt"
        "codebookd.c|lsp_cbd|dlsp1.txt dlsp2.txt dlsp3.txt dlsp4.txt dlsp5.txt dlsp6.txt dlsp7.txt dlsp8.txt dlsp9.txt dlsp10.txt"
        "codebookjmv.c|lsp_cbjmv|lspjmv1.txt lspjmv2.txt lspjmv3.txt"
        "codebookge.c|ge_cb|gecb.txt"
        "codebooknewamp1.c|newamp1vq_cb|train_120_1.txt train_120_2.txt"
        "codebooknewamp1_energy.c|newamp1_energy_cb|newamp1_energy_q.txt"
        "codebooknewamp2.c|newamp2vq_cb|train_120_1.txt train_120_2.txt"
        "codebooknewamp2_energy.c|newamp2_energy_cb|newamp2_energy_q.txt"
    )

    local generated=0
    local failed=0

    for config in "${configs[@]}"; do
        IFS='|' read -r outfile prefix input_list <<< "$config"

        local -a input_paths=()
        local all_exist=true

        for txt in $input_list; do
            if [[ -f "$cb_dir/$txt" ]]; then
                input_paths+=("$cb_dir/$txt")
            else
                all_exist=false
            fi
        done

        if [[ "$all_exist" == false || ${#input_paths[@]} -eq 0 ]]; then
            echo "  STUB  $outfile (missing .txt files)"
            cat > "$out_dir/$outfile" <<STUBEOF
/* STUB - source codebook files not found */
#include <stddef.h>
#include "defines.h"
const struct lsp_codebook ${prefix}[] = {
    { 0, 0, 0, NULL }
};
STUBEOF
            failed=$((failed + 1))
            continue
        fi

        if generate_codebook_sh "$prefix" "${input_paths[@]}" > "$out_dir/$outfile"; then
            local size
            size=$(wc -c < "$out_dir/$outfile" | tr -d ' ')
            echo "  OK    $outfile ($size bytes, ${#input_paths[@]} file)"
            generated=$((generated + 1))
        else
            echo "  FAIL  $outfile (generatedon error)"
            cat > "$out_dir/$outfile" <<STUBEOF2
/* STUB - generatedon error */
#include <stddef.h>
#include "defines.h"
const struct lsp_codebook ${prefix}[] = {
    { 0, 0, 0, NULL }
};
STUBEOF2
            failed=$((failed + 1))
        fi
    done

    local cmake_file="$src_dir/src/CMakeLists.txt"
    if [[ -f "$cmake_file" ]]; then
        local referenced
        referenced=$(grep -oE 'codebook[a-z0-9_]*\.c' "$cmake_file" | sort -u)
        while IFS= read -r cb_ref; do
            [[ -z "$cb_ref" ]] && continue
            if [[ ! -f "$out_dir/$cb_ref" ]]; then
                echo "  STUB  $cb_ref (referenced in CMake but not in mapping)"
                local stub_prefix
                stub_prefix=$(echo "$cb_ref" | sed 's/codebook//;s/\.c//')
                [[ -z "$stub_prefix" ]] && stub_prefix="unknown"
                cat > "$out_dir/$cb_ref" <<STUBEOF3
/* STUB per $cb_ref */
#include <stddef.h>
#include "defines.h"
const struct lsp_codebook ${stub_prefix}_cb[] = {
    { 0, 0, 0, NULL }
};
STUBEOF3
                failed=$((failed + 1))
            fi
        done <<< "$referenced"
    fi

    echo ""
    echo "  Result: $generated generated, $failed stub"
    echo ""
}

# =============================================================================
# Patch CMakeLists.txt
# =============================================================================
patch_cmake_for_android() {
    local src_dir="$1"

    echo "--- Patch CMakeLists.txt for Android ---"

    local cmake_files
    cmake_files=$(grep -rl "codec2_native\|generate_codebook" "$src_dir" \
        --include="CMakeLists.txt" --include="*.cmake" 2>/dev/null || true)

    if [[ -z "$cmake_files" ]]; then
        echo "  No references found (already patched?)"
        return 0
    fi

    echo "  Files to patch:"
    while IFS= read -r f; do
        echo "    ${f#$src_dir/}"
    done <<< "$cmake_files"
    echo ""

    while IFS= read -r cmake_file; do
        [[ -f "$cmake_file" ]] || continue

        local relpath="${cmake_file#$src_dir/}"
        [[ -f "${cmake_file}.orig" ]] || cp "$cmake_file" "${cmake_file}.orig"

        awk '
        BEGIN {
            cross = 0; cross_depth = 0
            buffering = 0; cmd_depth = 0; buf = ""
        }
        cross == 0 && /^[[:space:]]*if[[:space:]]*\([[:space:]]*CMAKE_CROSSCOMPILING/ {
            cross = 1; cross_depth = 1; next
        }
        cross == 1 {
            if (/^[[:space:]]*if[[:space:]]*\(/) cross_depth++
            if (/^[[:space:]]*endif[[:space:]]*\(/) {
                cross_depth--
                if (cross_depth <= 0) cross = 0
            }
            next
        }
        buffering == 0 && /^[[:space:]]*[a-zA-Z_][a-zA-Z0-9_]*[[:space:]]*\(/ {
            buf = $0 "\n"; cmd_depth = 0
            for (i = 1; i <= length($0); i++) {
                c = substr($0, i, 1)
                if (c == "(") cmd_depth++
                if (c == ")") cmd_depth--
            }
            if (cmd_depth > 0) { buffering = 1 }
            else {
                if (buf !~ /generate_codebook/ && buf !~ /codec2_native/) printf "%s", buf
                buf = ""
            }
            next
        }
        buffering == 1 {
            buf = buf $0 "\n"
            for (i = 1; i <= length($0); i++) {
                c = substr($0, i, 1)
                if (c == "(") cmd_depth++
                if (c == ")") cmd_depth--
            }
            if (cmd_depth <= 0) {
                buffering = 0
                if (buf !~ /generate_codebook/ && buf !~ /codec2_native/) printf "%s", buf
                buf = ""
            }
            next
        }
        /generate_codebook|codec2_native/ && !/^[[:space:]]*#/ { next }
        { print }
        ' "${cmake_file}.orig" > "${cmake_file}.phase12"

        sed \
            -e 's|\${CMAKE_CURRENT_BINARY_DIR}/codebook|\${CMAKE_CURRENT_SOURCE_DIR}/codebook|g' \
            "${cmake_file}.phase12" > "$cmake_file"

        rm -f "${cmake_file}.phase12"

        local orig_lines new_lines
        orig_lines=$(wc -l < "${cmake_file}.orig" | tr -d ' ')
        new_lines=$(wc -l < "$cmake_file" | tr -d ' ')
        echo "  OK  $relpath: $orig_lines -> $new_lines lines"

    done <<< "$cmake_files"

    echo ""
    local src_cmake="$src_dir/src/CMakeLists.txt"
    if [[ -f "$src_cmake" ]]; then
        local bad_refs
        bad_refs=$(grep -v '^[[:space:]]*#' "$src_cmake" \
            | grep -c 'generate_codebook\|codec2_native' 2>/dev/null \
            | head -1 | tr -d '[:space:]') || bad_refs="0"
        if [[ "$bad_refs" -gt 0 ]] 2>/dev/null; then
            echo "  WARNING: $bad_refs residual references"
        else
            echo "  Verification: ZERO residual references"
        fi
        local op cl
        op=$(tr -cd '(' < "$src_cmake" | wc -c | tr -d '[:space:]')
        cl=$(tr -cd ')' < "$src_cmake" | wc -c | tr -d '[:space:]')
        if [[ "$op" -eq "$cl" ]] 2>/dev/null; then
            echo "  Verification: balanced parentheses ($op)"
        else
            echo "  WARNING: unbalanced parentheses (open=$op closed=$cl)"
        fi
        local binary_refs
        binary_refs=$(grep -c 'BINARY_DIR.*codebook' "$src_cmake" 2>/dev/null \
            | head -1 | tr -d '[:space:]') || binary_refs="0"
        echo "  Verification: $binary_refs residual BINARY_DIR paths for codebook"
    fi
    echo ""
}

# =============================================================================
# MAIN
# =============================================================================

CODEC2_SRC="$BUILD_DIR/codec2"

if [[ -d "$CODEC2_SRC/.git" ]]; then
    echo "codec2 source present, restoring and checking out tag $CODEC2_TAG..."
    cd "$CODEC2_SRC"
    git clean -fdx -q
    git checkout . -q
    git fetch --tags origin 2>/dev/null || true
    git checkout "$CODEC2_TAG" 2>/dev/null || git checkout "tags/$CODEC2_TAG"
    cd - > /dev/null
else
    echo "Clone codec2 @ $CODEC2_TAG..."
    rm -rf "$CODEC2_SRC"
    mkdir -p "$BUILD_DIR"
    git clone "$CODEC2_REPO" "$CODEC2_SRC"
    cd "$CODEC2_SRC"
    git checkout "$CODEC2_TAG" 2>/dev/null || git checkout "tags/$CODEC2_TAG"
    cd - > /dev/null
fi
echo ""

pre_generate_codebooks "$CODEC2_SRC"
patch_cmake_for_android "$CODEC2_SRC"

echo "--- Copy headers ---"
mkdir -p "$HEADERS_DIR"
for h in codec2.h codec2_fdmdv.h codec2_cohpsk.h codec2_fm.h codec2_ofdm.h \
         comp.h comp_prim.h modem_stats.h freedv_api.h; do
    if [[ -f "$CODEC2_SRC/src/$h" ]]; then
        cp "$CODEC2_SRC/src/$h" "$HEADERS_DIR/"
        echo "  OK  $h"
    fi
done
echo ""

# --- Build for ABI -------------------------------------------------------
for ABI in "${ABIS[@]}"; do
    echo "================================================================"
    echo "  Build per ABI: $ABI"
    echo "================================================================"

    ABI_BUILD_DIR="$BUILD_DIR/build_${ABI}"
    ABI_OUT_DIR="$JNI_LIBS_DIR/$ABI"

    rm -rf "$ABI_BUILD_DIR"
    mkdir -p "$ABI_BUILD_DIR" "$ABI_OUT_DIR"

    echo "  Configuration CMake libcodec2..."

    "$CMAKE_BIN" \
        -G "$GENERATOR" \
        "${GENERATOR_ARGS[@]}" \
        -S "$CODEC2_SRC" \
        -B "$ABI_BUILD_DIR" \
        -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN" \
        -DANDROID_ABI="$ABI" \
        -DANDROID_PLATFORM="android-$MIN_API" \
        -DCMAKE_BUILD_TYPE=Release \
        -DBUILD_SHARED_LIBS=ON \
        -DUNITTEST=OFF \
        -DCMAKE_C_FLAGS="-Os -fPIC -ffunction-sections -fdata-sections -DNDEBUG" \
        -DCMAKE_SHARED_LINKER_FLAGS="-Wl,--gc-sections -Wl,--strip-all -Wl,-z,max-page-size=16384" \
        -Wno-dev \
        2>&1 | tee "$ABI_BUILD_DIR/cmake_configure.log" | tail -5

    if [[ ${PIPESTATUS[0]} -ne 0 ]]; then
        echo "  ERROR: CMake configure failed for $ABI"
        tail -50 "$ABI_BUILD_DIR/cmake_configure.log"
        exit 1
    fi

    echo "  Compiling libcodec2..."
    "$CMAKE_BIN" --build "$ABI_BUILD_DIR" \
        --config Release \
        --target codec2 \
        --parallel \
        2>&1 | tee "$ABI_BUILD_DIR/cmake_build.log"

    if [[ ${PIPESTATUS[0]} -ne 0 ]]; then
        echo "  ERROR: libcodec2 build failed for $ABI"
        grep -n "error:" "$ABI_BUILD_DIR/cmake_build.log" || true
        tail -20 "$ABI_BUILD_DIR/cmake_build.log"
        exit 1
    fi

    SO_FILE=$(find "$ABI_BUILD_DIR" -name "libcodec2*.so" -type f | head -1)
    if [[ -z "$SO_FILE" ]]; then
        echo "  ERROR: libcodec2.so not found after build"
        exit 1
    fi
    cp "$SO_FILE" "$ABI_OUT_DIR/libcodec2.so"

    VERSION_H=$(find "$ABI_BUILD_DIR" -name "version.h" -type f | head -1)
    if [[ -n "${VERSION_H:-}" && -f "$VERSION_H" ]]; then
        cp "$VERSION_H" "$HEADERS_DIR/"
    fi

    SIZE=$(du -sh "$ABI_OUT_DIR/libcodec2.so" | cut -f1)
    echo "  COMPLETED: $ABI -> libcodec2.so ($SIZE)"
    file "$ABI_OUT_DIR/libcodec2.so" 2>/dev/null | sed 's/^/    /' || true
    echo ""

    # =========================================================================
    # Compile libcodec2_jni.so via CMake + NDK con ANDROID_STL=c++_static
    # This eliminates the dependency on libc++_shared.so (not present in APK)
    # =========================================================================
    echo "  Compiling JNI wrapper (libcodec2_jni.so) con c++_static..."

    JNI_SRC="$MODULE_DIR/src/androidMain/cpp/codec2_jni.cpp"
    JNI_INCLUDE="$MODULE_DIR/src/androidMain/cpp"

    if [[ ! -f "$JNI_SRC" ]]; then
        echo "  ERROR: $JNI_SRC not found"
        exit 1
    fi

    JNI_BUILD_DIR="$ABI_BUILD_DIR/jni"
    rm -rf "$JNI_BUILD_DIR"
    mkdir -p "$JNI_BUILD_DIR"

    # Write CMakeLists.txt for the JNI wrapper
    # Note: delimiter has NO quotes -> bash variables are expanded
    # CMake variables use the syntax ${VAR} which is passed as a string
    JNI_CMAKE="$JNI_BUILD_DIR/CMakeLists.txt"
    {
        echo 'cmake_minimum_required(VERSION 3.22)'
        echo 'project(codec2_jni)'
        echo ''
        echo '# codec2 prebuilt'
        echo 'add_library(codec2 SHARED IMPORTED)'
        echo 'set_target_properties(codec2 PROPERTIES'
        echo '    IMPORTED_LOCATION "${CODEC2_SO_PATH}"'
        echo ')'
        echo ''
        echo '# Wrapper JNI'
        echo 'add_library(codec2_jni SHARED "${JNI_SRC_PATH}")'
        echo ''
        echo 'target_include_directories(codec2_jni PRIVATE'
        echo '    "${JNI_INCLUDE_PATH}"'
        echo '    "${JNI_INCLUDE_PATH}/include"'
        echo ')'
        echo ''
        echo 'target_compile_options(codec2_jni PRIVATE'
        echo '    -O2 -fPIC -DANDROID -DNDEBUG'
        echo ')'
        echo ''
        echo 'target_link_libraries(codec2_jni'
        echo '    codec2'
        echo '    log'
        echo '    android'
        echo ')'
        echo ''
        echo '# 16KB page alignment (Android 15+)'
        echo 'target_link_options(codec2_jni PRIVATE'
        echo '    -Wl,-z,max-page-size=16384'
        echo ')'
    } > "$JNI_CMAKE"

    "$CMAKE_BIN" \
        -G "$GENERATOR" \
        "${GENERATOR_ARGS[@]}" \
        -S "$JNI_BUILD_DIR" \
        -B "$JNI_BUILD_DIR/build" \
        -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN" \
        -DANDROID_ABI="$ABI" \
        -DANDROID_PLATFORM="android-$MIN_API" \
        -DANDROID_STL="c++_static" \
        -DCMAKE_BUILD_TYPE=Release \
        -DJNI_SRC_PATH="$JNI_SRC" \
        -DJNI_INCLUDE_PATH="$JNI_INCLUDE" \
        -DCODEC2_SO_PATH="$ABI_OUT_DIR/libcodec2.so" \
        -Wno-dev \
        2>&1 | tee "$JNI_BUILD_DIR/cmake_configure.log" | tail -5

    if [[ ${PIPESTATUS[0]} -ne 0 ]]; then
        echo "  ERROR: CMake configure JNI failed for $ABI"
        cat "$JNI_BUILD_DIR/cmake_configure.log"
        exit 1
    fi

    "$CMAKE_BIN" --build "$JNI_BUILD_DIR/build" \
        --config Release \
        --target codec2_jni \
        --parallel \
        2>&1 | tee "$JNI_BUILD_DIR/cmake_build.log"

    if [[ ${PIPESTATUS[0]} -ne 0 ]]; then
        echo "  ERROR: JNI build failed for $ABI"
        cat "$JNI_BUILD_DIR/cmake_build.log"
        exit 1
    fi

    JNI_SO_BUILT=$(find "$JNI_BUILD_DIR/build" -name "libcodec2_jni.so" -type f | head -1)
    if [[ -z "$JNI_SO_BUILT" ]]; then
        echo "  ERROR: libcodec2_jni.so not found after JNI build"
        exit 1
    fi

    cp "$JNI_SO_BUILT" "$ABI_OUT_DIR/libcodec2_jni.so"
    JNI_SIZE=$(du -sh "$ABI_OUT_DIR/libcodec2_jni.so" | cut -f1)
    echo "  COMPLETED: $ABI -> libcodec2_jni.so ($JNI_SIZE)"
    file "$ABI_OUT_DIR/libcodec2_jni.so" 2>/dev/null | sed 's/^/    /' || true
    echo ""
done

# --- Summary ----------------------------------------------------------------
echo "================================================================"
echo "  BUILD COMPLETED"
echo "================================================================"
echo ""
echo "  Artifacts:"
for ABI in "${ABIS[@]}"; do
    SIZE=$(du -sh "$JNI_LIBS_DIR/$ABI/libcodec2.so" 2>/dev/null | cut -f1 || echo "?")
    echo "    $JNI_LIBS_DIR/$ABI/libcodec2.so  ($SIZE)"
    JNI_SIZE=$(du -sh "$JNI_LIBS_DIR/$ABI/libcodec2_jni.so" 2>/dev/null | cut -f1 || echo "MISSING")
    echo "    $JNI_LIBS_DIR/$ABI/libcodec2_jni.so  ($JNI_SIZE)"
done
echo ""
echo "  Headers in: $HEADERS_DIR/"
ls -1 "$HEADERS_DIR/" 2>/dev/null | sed 's/^/    /'
echo ""
echo "  Next steps:"
echo "    1. Copy the generated .so files into your App's jniLibs directory."
echo "    2. Load library in Android via System.loadLibrary(\"codec2_jni\")"
echo "    3. Test audio playback on an Android device."
echo ""
