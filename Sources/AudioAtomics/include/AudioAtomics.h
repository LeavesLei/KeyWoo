#ifndef KEYWOO_AUDIO_ATOMICS_H
#define KEYWOO_AUDIO_ATOMICS_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct KWAtomicCounter KWAtomicCounter;
KWAtomicCounter *KWAtomicCounterCreate(uint64_t initial);
void KWAtomicCounterDestroy(KWAtomicCounter *counter);
uint64_t KWAtomicCounterLoad(const KWAtomicCounter *counter);
void KWAtomicCounterStore(KWAtomicCounter *counter, uint64_t value);
#ifdef __cplusplus
}
#endif
#endif
