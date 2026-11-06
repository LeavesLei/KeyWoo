#ifndef KEYWOO_SIGNING_KEY_HEADER_H
#define KEYWOO_SIGNING_KEY_HEADER_H

#include <stdint.h>
#include <Security/SecKey.h>

// Reads only fixed header flags from a legacy file-keychain private key.
// The caller retains key for the call. No key bytes are returned or exported.
OSStatus KWCopySigningKeyHeader(SecKeyRef key, uint32_t *usage, uint32_t *attributes);

#endif
