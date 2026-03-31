/*
 * codec2_jni.cpp — JNI wrapper for libcodec2 on Android
 *
 * JNI Package: com.geeksville.mesh.voiceburst.Codec2JNI
 * Library:     libcodec2_jni.so  (links libcodec2.so)
 *
 * Exposed API:
 *   getSamplesPerFrame(mode: Int): Int
 *   getBytesPerFrame(mode: Int): Int
 *   create(mode: Int): Long
 *   encode(ptr: Long, pcm: ShortArray): ByteArray
 *   decode(ptr: Long, frame: ByteArray): ShortArray
 *   destroy(ptr: Long)
 */

// SPDX-License-Identifier: LGPL-2.1
// Copyright (c) 2026 Chris7X
// JNI wrapper for Codec2 - Voice Burst

#include <jni.h>
#include <android/log.h>
#include <cstring>
#include <cstdlib>

#include "include/codec2/codec2.h"

#define LOG_TAG "Codec2JNI"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO,  LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)
#define LOGD(...) __android_log_print(ANDROID_LOG_DEBUG, LOG_TAG, __VA_ARGS__)

// JNI name mangling per il package com.geeksville.mesh.voiceburst.Codec2JNI
#define JNI_METHOD(name) \
    Java_com_geeksville_mesh_voiceburst_Codec2JNI_##name

extern "C" {

// ---------------------------------------------------------------------------
// getSamplesPerFrame(mode: Int): Int
// ---------------------------------------------------------------------------
JNIEXPORT jint JNICALL
JNI_METHOD(getSamplesPerFrame)(JNIEnv* /*env*/, jclass /*cls*/, jint mode) {
    CODEC2* c = codec2_create(mode);
    if (!c) {
        LOGE("getSamplesPerFrame: codec2_create(%d) failed", mode);
        return -1;
    }
    jint spf = (jint)codec2_samples_per_frame(c);
    codec2_destroy(c);
    return spf;
}

// ---------------------------------------------------------------------------
// getBytesPerFrame(mode: Int): Int
// ---------------------------------------------------------------------------
JNIEXPORT jint JNICALL
JNI_METHOD(getBytesPerFrame)(JNIEnv* /*env*/, jclass /*cls*/, jint mode) {
    CODEC2* c = codec2_create(mode);
    if (!c) {
        LOGE("getBytesPerFrame: codec2_create(%d) failed", mode);
        return -1;
    }
    int bits = codec2_bits_per_frame(c);
    jint bpf = (jint)((bits + 7) / 8);
    codec2_destroy(c);
    return bpf;
}

// ---------------------------------------------------------------------------
// create(mode: Int): Long   — returns pointer as Long (opaque handle)
// ---------------------------------------------------------------------------
JNIEXPORT jlong JNICALL
JNI_METHOD(create)(JNIEnv* /*env*/, jclass /*cls*/, jint mode) {
    CODEC2* c = codec2_create(mode);
    if (!c) {
        LOGE("create: codec2_create(%d) failed", mode);
        return 0L;
    }
    LOGI("codec2_create mode=%d: spf=%d bpf=%d",
         mode,
         codec2_samples_per_frame(c),
         (codec2_bits_per_frame(c) + 7) / 8);
    return (jlong)(intptr_t)c;
}

// ---------------------------------------------------------------------------
// destroy(ptr: Long)
// ---------------------------------------------------------------------------
JNIEXPORT void JNICALL
JNI_METHOD(destroy)(JNIEnv* /*env*/, jclass /*cls*/, jlong ptr) {
    if (ptr == 0L) return;
    CODEC2* c = (CODEC2*)(intptr_t)ptr;
    codec2_destroy(c);
    LOGD("codec2_destroy OK");
}

// ---------------------------------------------------------------------------
// encode(ptr: Long, pcm: ShortArray): ByteArray
// Encodes exactly 1 PCM frame (samplesPerFrame samples) into bytesPerFrame bytes.
// ---------------------------------------------------------------------------
JNIEXPORT jbyteArray JNICALL
JNI_METHOD(encode)(JNIEnv* env, jclass /*cls*/, jlong ptr, jshortArray pcm) {
    if (ptr == 0L || !pcm) {
        LOGE("encode: null handle or pcm");
        return nullptr;
    }

    CODEC2* c = (CODEC2*)(intptr_t)ptr;
    int spf  = codec2_samples_per_frame(c);
    int bits = codec2_bits_per_frame(c);
    int bpf  = (bits + 7) / 8;

    jsize len = env->GetArrayLength(pcm);
    if (len < spf) {
        LOGE("encode: input length %d < samplesPerFrame %d", (int)len, spf);
        return nullptr;
    }

    jshort* samples = env->GetShortArrayElements(pcm, nullptr);
    if (!samples) return nullptr;

    unsigned char* out = (unsigned char*)calloc(bpf, 1);
    if (!out) {
        env->ReleaseShortArrayElements(pcm, samples, JNI_ABORT);
        return nullptr;
    }

    codec2_encode(c, out, (short*)samples);

    env->ReleaseShortArrayElements(pcm, samples, JNI_ABORT);

    jbyteArray result = env->NewByteArray(bpf);
    if (result) {
        env->SetByteArrayRegion(result, 0, bpf, (jbyte*)out);
    }
    free(out);
    return result;
}

// ---------------------------------------------------------------------------
// decode(ptr: Long, frame: ByteArray): ShortArray
// Decodes exactly 1 Codec2 frame (bytesPerFrame bytes) into PCM.
// ---------------------------------------------------------------------------
JNIEXPORT jshortArray JNICALL
JNI_METHOD(decode)(JNIEnv* env, jclass /*cls*/, jlong ptr, jbyteArray frame) {
    if (ptr == 0L || !frame) {
        LOGE("decode: null handle or frame");
        return nullptr;
    }

    CODEC2* c = (CODEC2*)(intptr_t)ptr;
    int spf  = codec2_samples_per_frame(c);
    int bits = codec2_bits_per_frame(c);
    int bpf  = (bits + 7) / 8;

    jsize len = env->GetArrayLength(frame);
    if (len < bpf) {
        LOGE("decode: frame length %d < bytesPerFrame %d", (int)len, bpf);
        return nullptr;
    }

    jbyte* bytes = env->GetByteArrayElements(frame, nullptr);
    if (!bytes) return nullptr;

    short* out = (short*)calloc(spf, sizeof(short));
    if (!out) {
        env->ReleaseByteArrayElements(frame, bytes, JNI_ABORT);
        return nullptr;
    }

    codec2_decode(c, out, (unsigned char*)bytes);

    env->ReleaseByteArrayElements(frame, bytes, JNI_ABORT);

    jshortArray result = env->NewShortArray(spf);
    if (result) {
        env->SetShortArrayRegion(result, 0, spf, out);
    }
    free(out);
    return result;
}

} // extern "C"
