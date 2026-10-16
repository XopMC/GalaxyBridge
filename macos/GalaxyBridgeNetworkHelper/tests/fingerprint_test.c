#include "GBProgramFingerprint.h"
#include <stdio.h>
int main(int argc,char**argv){if(argc!=2)return 2;unsigned char hash[32];int result=gb_program_fingerprint_file(argv[1],hash);if(result)return result;for(int i=0;i<32;i++)printf("%02x",hash[i]);puts("");return 0;}
