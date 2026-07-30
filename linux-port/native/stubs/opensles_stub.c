/* No-op OpenSL ES stub: satisfies libtmessages linking; no audio.
   slCreateEngine reports "unsupported" so Telegram's audio init bails cleanly. */
#include <stdint.h>
typedef uint32_t SLuint32;
typedef SLuint32 SLresult;
#define SL_RESULT_FEATURE_UNSUPPORTED ((SLuint32)0x0000000C)

/* Interface IDs are pointers to 128-bit UUIDs; a dummy is fine while unused. */
static const uint8_t dummy_iid[16];
const void *SL_IID_ENGINE                   = dummy_iid;
const void *SL_IID_PLAY                     = dummy_iid;
const void *SL_IID_RECORD                   = dummy_iid;
const void *SL_IID_BUFFERQUEUE              = dummy_iid;
const void *SL_IID_VOLUME                   = dummy_iid;
const void *SL_IID_ANDROIDSIMPLEBUFFERQUEUE = dummy_iid;
const void *SL_IID_ANDROIDCONFIGURATION     = dummy_iid;

SLresult slCreateEngine(void *pEngine, SLuint32 numOptions, const void *opts,
                        SLuint32 numIfaces, const void *ids, const void *req)
{
    (void)pEngine;(void)numOptions;(void)opts;(void)numIfaces;(void)ids;(void)req;
    return SL_RESULT_FEATURE_UNSUPPORTED;
}
