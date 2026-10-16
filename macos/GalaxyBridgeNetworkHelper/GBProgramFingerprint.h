#ifndef GB_PROGRAM_FINGERPRINT_H
#define GB_PROGRAM_FINGERPRINT_H
#include <stddef.h>
#include <stdint.h>
int gb_program_fingerprint(const void *bytes,size_t length,uint8_t hash[32]);
int gb_program_fingerprint_file(const char *path,uint8_t hash[32]);
#endif
