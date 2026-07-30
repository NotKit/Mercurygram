/*
 * Desktop stand-in for the NDK's <android/bitmap.h>.
 *
 * Declarations only — the implementations come from atlas's libandroid.so.0
 * (atlas src/libandroid/bitmap.c), which libtmessages links against. The
 * AndroidBitmapInfo layout matches both the NDK and atlas.
 */
#ifndef LINUX_PORT_ANDROID_BITMAP_H
#define LINUX_PORT_ANDROID_BITMAP_H

#include <jni.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

enum {
	ANDROID_BITMAP_RESULT_SUCCESS = 0,
	ANDROID_BITMAP_RESULT_BAD_PARAMETER = -1,
	ANDROID_BITMAP_RESULT_JNI_EXCEPTION = -2,
	ANDROID_BITMAP_RESULT_ALLOCATION_FAILED = -3,
};

enum AndroidBitmapFormat {
	ANDROID_BITMAP_FORMAT_NONE = 0,
	ANDROID_BITMAP_FORMAT_RGBA_8888 = 1,
	ANDROID_BITMAP_FORMAT_RGB_565 = 4,
	ANDROID_BITMAP_FORMAT_RGBA_4444 = 7,
	ANDROID_BITMAP_FORMAT_A_8 = 8,
	ANDROID_BITMAP_FORMAT_RGBA_F16 = 9,
	ANDROID_BITMAP_FORMAT_RGBA_1010102 = 10,
};

enum {
	ANDROID_BITMAP_FLAGS_ALPHA_PREMUL = 0,
	ANDROID_BITMAP_FLAGS_ALPHA_OPAQUE = 1,
	ANDROID_BITMAP_FLAGS_ALPHA_UNPREMUL = 2,
	ANDROID_BITMAP_FLAGS_ALPHA_MASK = 0x3,
	ANDROID_BITMAP_FLAGS_ALPHA_SHIFT = 0,
	ANDROID_BITMAP_FLAGS_IS_HARDWARE = 1 << 31,
};

typedef struct {
	uint32_t width;
	uint32_t height;
	uint32_t stride;
	int32_t format;
	uint32_t flags;
} AndroidBitmapInfo;

int AndroidBitmap_getInfo(JNIEnv *env, jobject jbitmap, AndroidBitmapInfo *info);
int AndroidBitmap_lockPixels(JNIEnv *env, jobject jbitmap, void **addrPtr);
int AndroidBitmap_unlockPixels(JNIEnv *env, jobject jbitmap);

#ifdef __cplusplus
}
#endif

#endif /* LINUX_PORT_ANDROID_BITMAP_H */
