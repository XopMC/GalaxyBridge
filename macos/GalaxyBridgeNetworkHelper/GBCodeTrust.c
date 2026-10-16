#include "GBCodeTrust.h"
#include <Security/Security.h>

int gb_code_signing_policy(CFDictionaryRef signing){
 if(!signing||CFGetTypeID(signing)!=CFDictionaryGetTypeID())return 0;
 CFTypeRef flags=CFDictionaryGetValue(signing,kSecCodeInfoFlags);
 uint32_t value=0;
 if(!flags||CFGetTypeID(flags)!=CFNumberGetTypeID()||!CFNumberGetValue(flags,kCFNumberSInt32Type,&value)||!(value&kSecCodeSignatureRuntime))return 0;
 CFTypeRef entitlements=CFDictionaryGetValue(signing,kSecCodeInfoEntitlementsDict);
 if(!entitlements)return 1;
 if(CFGetTypeID(entitlements)!=CFDictionaryGetTypeID())return 0;
 const CFStringRef forbidden[]={
  CFSTR("com.apple.security.cs.disable-library-validation"),
  CFSTR("com.apple.security.cs.allow-dyld-environment-variables"),
  CFSTR("com.apple.security.get-task-allow"),CFSTR("get-task-allow"),
  CFSTR("com.apple.security.cs.allow-unsigned-executable-memory"),
  CFSTR("com.apple.security.cs.disable-executable-page-protection"),
  CFSTR("com.apple.security.cs.allow-jit")
 };
 for(size_t i=0;i<sizeof(forbidden)/sizeof(forbidden[0]);i++){
  CFTypeRef entitlement=CFDictionaryGetValue((CFDictionaryRef)entitlements,forbidden[i]);
  /* An absent or explicitly false Boolean grants no exception. Fail closed on malformed values. */
  if(entitlement&&(CFGetTypeID(entitlement)!=CFBooleanGetTypeID()||CFBooleanGetValue((CFBooleanRef)entitlement)))return 0;
 }
 return 1;
}
