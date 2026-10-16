#include "GBCodeTrust.h"
#include <Security/Security.h>
#include <assert.h>
#include <stdlib.h>
#include <string.h>
static void malformed_metadata_is_rejected(void){
 assert(!gb_code_signing_policy(NULL));
 CFMutableDictionaryRef metadata=CFDictionaryCreateMutable(NULL,0,&kCFTypeDictionaryKeyCallBacks,&kCFTypeDictionaryValueCallBacks);
 assert(!gb_code_signing_policy(metadata));
 CFDictionarySetValue(metadata,kSecCodeInfoFlags,CFSTR("runtime"));assert(!gb_code_signing_policy(metadata));
 int flags=kSecCodeSignatureRuntime;CFNumberRef number=CFNumberCreate(NULL,kCFNumberIntType,&flags);
 CFDictionarySetValue(metadata,kSecCodeInfoFlags,number);CFRelease(number);assert(gb_code_signing_policy(metadata));
 CFDictionarySetValue(metadata,kSecCodeInfoEntitlementsDict,CFSTR("invalid"));assert(!gb_code_signing_policy(metadata));
 CFMutableDictionaryRef entitlements=CFDictionaryCreateMutable(NULL,0,&kCFTypeDictionaryKeyCallBacks,&kCFTypeDictionaryValueCallBacks);
 CFDictionarySetValue(entitlements,CFSTR("com.apple.security.cs.allow-jit"),CFSTR("false"));
 CFDictionarySetValue(metadata,kSecCodeInfoEntitlementsDict,entitlements);assert(!gb_code_signing_policy(metadata));
 CFRelease(entitlements);CFRelease(metadata);
}
int main(int argc,char**argv){
 malformed_metadata_is_rejected();
 assert(argc==2||argc==3);int expected=atoi(argv[1]);
 SecStaticCodeRef disk=NULL;
 if(argc==2){
  SecCodeRef live=NULL;assert(SecCodeCopySelf(kSecCSDefaultFlags,&live)==errSecSuccess);
  assert(SecCodeCheckValidity(live,kSecCSStrictValidate,NULL)==errSecSuccess);
  CFDictionaryRef info=NULL;assert(SecCodeCopySigningInformation(live,kSecCSSigningInformation,&info)==errSecSuccess);
  assert(gb_code_signing_policy(info)==expected);CFRelease(info);
  assert(SecCodeCopyStaticCode(live,kSecCSDefaultFlags,&disk)==errSecSuccess);CFRelease(live);
 }else{
  CFURLRef url=CFURLCreateFromFileSystemRepresentation(NULL,(const UInt8*)argv[2],(CFIndex)strlen(argv[2]),false);
  assert(SecStaticCodeCreateWithPath(url,kSecCSDefaultFlags,&disk)==errSecSuccess);CFRelease(url);
 }
 assert(SecStaticCodeCheckValidity(disk,kSecCSStrictValidate,NULL)==errSecSuccess);
 CFDictionaryRef info=NULL;assert(SecCodeCopySigningInformation((SecCodeRef)disk,kSecCSSigningInformation,&info)==errSecSuccess);
 assert(gb_code_signing_policy(info)==expected);CFRelease(info);CFRelease(disk);
 return 0;
}
