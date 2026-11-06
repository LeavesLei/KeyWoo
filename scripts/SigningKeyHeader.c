#include "SigningKeyHeader.h"

OSStatus KWCopySigningKeyHeader(SecKeyRef key, uint32_t *usage, uint32_t *attributes) {
    if (key == NULL || usage == NULL || attributes == NULL) {
        return errSecParam;
    }
    *usage = 0;
    *attributes = 0;

    // This public legacy API is deprecated but still available to C. The
    // Swift SDK marks pre-10.9 deprecated APIs unavailable, hence this shim.
    const CSSM_KEY *legacy = NULL;
    OSStatus status = SecKeyGetCSSMKey(key, &legacy);
    if (status != errSecSuccess) {
        return status;
    }
    if (legacy == NULL || legacy->KeyHeader.KeyClass != CSSM_KEYCLASS_PRIVATE_KEY) {
        return errSecInvalidKeyRef;
    }

    // Deliberately do not copy the entire CSSM_KEY or touch its KeyData member.
    // Only these two public metadata fields cross the C/Swift boundary.
    *usage = legacy->KeyHeader.KeyUsage;
    *attributes = legacy->KeyHeader.KeyAttr;
    return errSecSuccess;
}
