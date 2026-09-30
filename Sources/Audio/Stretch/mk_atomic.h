// mk_atomic.h — C11 atomics for Swift.
// Swift has no stdlib atomics and the project is zero-dependency; the C shim
// layer already exists. These are the three operations the wait-free scrub
// path needs: relaxed 64-bit store/load and a release-acquire exchange for
// the scrubbing flag. Everything is a header-only static inline — no object
// file, no linking change.
#ifndef mk_atomic_h
#define mk_atomic_h

#include <stdint.h>
#include <stdatomic.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct { _Atomic int64_t v; } mk_atomic_i64_t;
typedef struct { _Atomic int8_t v; } mk_atomic_i8_t;

static inline void mk_at_init_i64(mk_atomic_i64_t *a, int64_t init) {
    atomic_init(&a->v, init);
}
static inline void mk_at_init_i8(mk_atomic_i8_t *a, int8_t init) {
    atomic_init(&a->v, init);
}

static inline void mk_at_store_i64(mk_atomic_i64_t *a, int64_t v) {
    atomic_store_explicit(&a->v, v, memory_order_release);
}
static inline int64_t mk_at_load_i64(const mk_atomic_i64_t *a) {
    return atomic_load_explicit(&a->v, memory_order_acquire);
}
static inline void mk_at_store_i8(mk_atomic_i8_t *a, int8_t v) {
    atomic_store_explicit(&a->v, v, memory_order_release);
}
static inline int8_t mk_at_load_i8(const mk_atomic_i8_t *a) {
    return atomic_load_explicit(&a->v, memory_order_acquire);
}

#ifdef __cplusplus
}
#endif

#endif
