/*
 * Desktop stand-in for the NDK's <android/asset_manager.h>.
 *
 * Declarations only — atlas's libandroid.so.0 (src/libandroid/asset_manager.c)
 * implements these on top of libandroidfw, reading from the built APK.
 * AAssetManager/AAsset are opaque; atlas names them struct AssetManager/Asset.
 */
#ifndef LINUX_PORT_ANDROID_ASSET_MANAGER_H
#define LINUX_PORT_ANDROID_ASSET_MANAGER_H

#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

struct AAssetManager;
typedef struct AAssetManager AAssetManager;
struct AAssetDir;
typedef struct AAssetDir AAssetDir;
struct AAsset;
typedef struct AAsset AAsset;

enum {
	AASSET_MODE_UNKNOWN = 0,
	AASSET_MODE_RANDOM = 1,
	AASSET_MODE_STREAMING = 2,
	AASSET_MODE_BUFFER = 3,
};

AAssetDir *AAssetManager_openDir(AAssetManager *mgr, const char *dirName);
AAsset *AAssetManager_open(AAssetManager *mgr, const char *filename, int mode);
const char *AAssetDir_getNextFileName(AAssetDir *assetDir);
void AAssetDir_close(AAssetDir *assetDir);
int AAsset_read(AAsset *asset, void *buf, size_t count);
off_t AAsset_seek(AAsset *asset, off_t offset, int whence);
off64_t AAsset_seek64(AAsset *asset, off64_t offset, int whence);
void AAsset_close(AAsset *asset);
const void *AAsset_getBuffer(AAsset *asset);
off_t AAsset_getLength(AAsset *asset);
off64_t AAsset_getLength64(AAsset *asset);
off_t AAsset_getRemainingLength(AAsset *asset);
off64_t AAsset_getRemainingLength64(AAsset *asset);
int AAsset_openFileDescriptor(AAsset *asset, off_t *outStart, off_t *outLength);

#ifdef __cplusplus
}
#endif

#endif /* LINUX_PORT_ANDROID_ASSET_MANAGER_H */
