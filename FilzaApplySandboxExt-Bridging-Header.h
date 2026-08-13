#pragma once

// Full ByeTunes embeds its original Swift DeviceManager, which talks to the
// same pinned idevice FFI static library already used by the Filza bridge.
#import "idevice.h"

// Shared persistent diagnostics used by the embedded ByeTunes and mond hosts.
#import "FilzaDiagnostics.h"
#import "GestaltManager.h"
