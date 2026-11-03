// Exposes the engine contracts and the small C/ObjC runtime helpers to Swift.
// The contract headers (host/include/va_host.h, gfx/include/va_gfx.h) are owned
// by the coordinator; the app only includes them.
#include "va_host.h"
#include "va_gfx.h"
#include "VARingBuffer.h"
#include "VAEngineRuntime.h"
