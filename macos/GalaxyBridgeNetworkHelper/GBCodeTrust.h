#ifndef GB_CODE_TRUST_H
#define GB_CODE_TRUST_H
#include <CoreFoundation/CoreFoundation.h>
/* Additional policy after strict signature validation; shared by install and IPC. */
int gb_code_signing_policy(CFDictionaryRef signing);
#endif
