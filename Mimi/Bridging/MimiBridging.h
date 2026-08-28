//
//  MimiBridging.h
//  Mimi
//
//  Exposes the NeMo-Speech stable C ABI (as installed by scripts/build_runtime.sh)
//  to Swift. Symbols are bound at runtime via dlopen/dlsym in NativeASREngine so
//  the app builds and runs even before the native runtime is present.
//

#ifndef MimiBridging_h
#define MimiBridging_h

#include "nemo_speech/asr.h"

#endif /* MimiBridging_h */
