/*
 * Build-time smoke test for libtmessages: can the dynamic loader actually map
 * it and find its JNI entry points? ldd only lists DT_NEEDED entries; this also
 * catches a wrong RPATH or a missing atlas library.
 *
 * RTLD_LAZY, because atlas's libandroid.so.0 leaves symbols for
 * libtranslation_layer_main.so, which in turn leaves some for the launcher
 * executable (apk_path & co). That chain only closes under atlas's launcher.
 *
 * Usage: dlopen_check <path to libtmessages> <symbol>...
 */
#include <dlfcn.h>
#include <stdio.h>

int main(int argc, char **argv)
{
	if (argc < 2) {
		fprintf(stderr, "usage: %s <library> [symbol]...\n", argv[0]);
		return 2;
	}

	void *handle = dlopen(argv[1], RTLD_LAZY | RTLD_LOCAL);
	if (!handle) {
		fprintf(stderr, "dlopen failed: %s\n", dlerror());
		return 1;
	}

	int failed = 0;
	for (int i = 2; i < argc; i++) {
		void *sym = dlsym(handle, argv[i]);
		if (!sym) {
			fprintf(stderr, "dlsym(%s) failed: %s\n", argv[i], dlerror());
			failed = 1;
		} else {
			printf("    dlsym %s -> %p\n", argv[i], sym);
		}
	}
	return failed;
}
