#include "AudioAtomics.h"
#include <stdatomic.h>
#include <stdlib.h>
_Static_assert(ATOMIC_LLONG_LOCK_FREE == 2, "KeyWoo requires lock-free 64-bit atomics");
struct KWAtomicCounter { _Atomic(uint64_t) value; };
KWAtomicCounter *KWAtomicCounterCreate(uint64_t initial) {
    KWAtomicCounter *counter = malloc(sizeof(*counter));
    if (counter) atomic_init(&counter->value, initial);
    return counter;
}
void KWAtomicCounterDestroy(KWAtomicCounter *counter) { free(counter); }
uint64_t KWAtomicCounterLoad(const KWAtomicCounter *counter) {
    return atomic_load_explicit(&counter->value, memory_order_acquire);
}
void KWAtomicCounterStore(KWAtomicCounter *counter, uint64_t value) {
    atomic_store_explicit(&counter->value, value, memory_order_release);
}
