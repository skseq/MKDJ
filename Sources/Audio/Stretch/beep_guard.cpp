// beep_guard.cpp — NSBeep suppression via runtime rebinding,
// split from the retired stretch shim.
#include "vendor/fishhook.h"


// ── NSBeep suppression via runtime rebinding ─────────────────────────────
// NSSound.beep() is only a Swift/AppKit overlay; AppKit internals (menu-
// equivalent misses, responder-chain failures) beep through the NSBeep() C
// symbol. Static __interpose is ignored under arm64 chained fixups, so the
// rebinding is done with fishhook at launch — process-wide, every caller.

#include "vendor/fishhook.h"

extern "C" void NSBeep(void);

static int32_t mk_beep_counter = 0;

extern "C" void MKNSBeepReplaced(void) {
    __sync_fetch_and_add(&mk_beep_counter, 1);
}

extern "C" int32_t mk_beep_suppressed_count(void) {
    return __sync_add_and_fetch(&mk_beep_counter, 0);
}

extern "C" int mk_beep_rebind_install(void) {
    struct rebinding r{"NSBeep", (void *)&MKNSBeepReplaced, nullptr};
    int result = rebind_symbols(&r, 1);
    // A direct reference keeps the symbol alive even when nothing else
    // references it, and lets the test hook exercise the real function.
    return result;   // 0 on success
}

extern "C" void mk_call_nsbeep(void) {
    NSBeep();
}
