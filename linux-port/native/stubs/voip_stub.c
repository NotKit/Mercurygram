/*
 * Stubs for the entry points jni.c expects from the excluded voip/ tree.
 *
 * jni.c's JNI_OnLoad calls tgvoipOnJNILoad() unconditionally (its return value
 * is ignored there). voip/webrtc/tgcalls/libtgvoip are not built for the
 * desktop port, so provide a no-op. Calls are a Non-Goal for this milestone.
 */
#include <jni.h>

int tgvoipOnJNILoad(JavaVM *vm, JNIEnv *env)
{
	(void)vm;
	(void)env;
	return JNI_TRUE;
}
