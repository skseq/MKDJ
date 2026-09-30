#ifndef beep_guard_h
#define beep_guard_h
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
int32_t mk_beep_suppressed_count(void);
int mk_beep_rebind_install(void);
void mk_call_nsbeep(void);
#ifdef __cplusplus
}
#endif
#endif
