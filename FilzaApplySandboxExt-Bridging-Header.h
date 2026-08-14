#pragma once

// Full ByeTunes embeds its original Swift DeviceManager, which talks to the
// same pinned idevice FFI static library already used by the Filza bridge.
#import "idevice.h"

// Shared persistent diagnostics used by the embedded ByeTunes and mond hosts.
#import "FilzaDiagnostics.h"
#import "GestaltManager.h"

// Native 3105 App Data Browser and portable Patches integration.
#import "MCMBridge.h"
#import "ThirdParty/bad_query/bad_query/bad_query.h"
#import "ThirdParty/3105/Sources/AppIconHelper.h"
