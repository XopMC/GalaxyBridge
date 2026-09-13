#include <CoreFoundation/CoreFoundation.h>
#include <Security/Security.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static void galaxybridge_record_keychain_call(const char *name) {
    const char *path = getenv("GALAXYBRIDGE_KEYCHAIN_CALL_MARKER");
    if (path == NULL) return;
    int fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0600);
    if (fd < 0) return;
    (void)write(fd, name, strlen(name));
    (void)write(fd, "\n", 1);
    close(fd);
}

__attribute__((constructor))
static void galaxybridge_keychain_trap_loaded(void) {
    const char *path = getenv("GALAXYBRIDGE_INTERPOSER_LOADED_MARKER");
    if (path == NULL) return;
    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0600);
    if (fd < 0) return;
    (void)write(fd, "loaded\n", 7);
    close(fd);
}

OSStatus SecItemCopyMatching(CFDictionaryRef query, CFTypeRef *result) {
    (void)query;
    (void)result;
    galaxybridge_record_keychain_call("SecItemCopyMatching");
    return errSecInteractionNotAllowed;
}

OSStatus SecItemAdd(CFDictionaryRef attributes, CFTypeRef *result) {
    (void)attributes;
    (void)result;
    galaxybridge_record_keychain_call("SecItemAdd");
    return errSecInteractionNotAllowed;
}

OSStatus SecItemUpdate(CFDictionaryRef query, CFDictionaryRef attributesToUpdate) {
    (void)query;
    (void)attributesToUpdate;
    galaxybridge_record_keychain_call("SecItemUpdate");
    return errSecInteractionNotAllowed;
}

OSStatus SecItemDelete(CFDictionaryRef query) {
    (void)query;
    galaxybridge_record_keychain_call("SecItemDelete");
    return errSecInteractionNotAllowed;
}

OSStatus SecKeychainSetUserInteractionAllowed(Boolean state) {
    (void)state;
    galaxybridge_record_keychain_call("SecKeychainSetUserInteractionAllowed");
    return errSecInteractionNotAllowed;
}
