/*
 * Desktop stand-in for the NDK's <android/asset_manager_jni.h>.
 * Implemented by atlas's libandroid.so.0.
 */
#ifndef LINUX_PORT_ANDROID_ASSET_MANAGER_JNI_H
#define LINUX_PORT_ANDROID_ASSET_MANAGER_JNI_H

#include <android/asset_manager.h>
#include <jni.h>

#ifdef __cplusplus
extern "C" {
#endif

AAssetManager *AAssetManager_fromJava(JNIEnv *env, jobject assetManager);

#ifdef __cplusplus
}
#endif

#endif /* LINUX_PORT_ANDROID_ASSET_MANAGER_JNI_H */
