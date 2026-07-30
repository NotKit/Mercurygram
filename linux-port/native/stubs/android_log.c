/*
 * liblog replacement for the desktop port: __android_log_* on stderr.
 *
 * Everything the app logs (LOGI/LOGD/LOGE in c_utils.h, tgnet's FileLog, the
 * exoplayer JNI wrappers) lands in linux-port/out/run.log through this file.
 * Set TMESSAGES_LOG_LEVEL to an android_LogPriority number (2=VERBOSE ..
 * 7=FATAL, default 3=DEBUG) to raise the threshold.
 */
/* -std=c11 hides flockfile/funlockfile behind the POSIX feature test macro. */
#define _POSIX_C_SOURCE 200809L

#include <android/log.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const char priority_letter[] = "??VDIWEFS";

static int min_priority(void)
{
	static int cached = -1;
	if (cached < 0) {
		const char *env = getenv("TMESSAGES_LOG_LEVEL");
		cached = env ? atoi(env) : ANDROID_LOG_DEBUG;
	}
	return cached;
}

int __android_log_vprint(int prio, const char *tag, const char *fmt, va_list ap)
{
	if (prio < min_priority())
		return 0;

	char letter = (prio >= 0 && prio <= ANDROID_LOG_SILENT) ? priority_letter[prio] : '?';
	size_t len = fmt ? strlen(fmt) : 0;

	flockfile(stderr);
	fprintf(stderr, "%c/%s: ", letter, tag ? tag : "");
	int written = vfprintf(stderr, fmt ? fmt : "", ap);
	/* liblog terminates every record; only add one if the caller did not. */
	if (len == 0 || fmt[len - 1] != '\n')
		fputc('\n', stderr);
	funlockfile(stderr);
	return written;
}

int __android_log_print(int prio, const char *tag, const char *fmt, ...)
{
	va_list ap;
	va_start(ap, fmt);
	int written = __android_log_vprint(prio, tag, fmt, ap);
	va_end(ap);
	return written;
}

int __android_log_write(int prio, const char *tag, const char *text)
{
	return __android_log_print(prio, tag, "%s", text);
}

void __android_log_assert(const char *cond, const char *tag, const char *fmt, ...)
{
	va_list ap;
	va_start(ap, fmt);
	if (fmt)
		__android_log_vprint(ANDROID_LOG_FATAL, tag, fmt, ap);
	else
		__android_log_print(ANDROID_LOG_FATAL, tag, "assertion failed: %s",
		                    cond ? cond : "(unknown)");
	va_end(ap);
	abort();
}
