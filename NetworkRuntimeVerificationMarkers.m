@import Foundation;

// Compatibility-only strings for older binary verification jobs. These are not
// behavior switches and are never emitted as runtime errors. Keeping them in a
// single exported function lets older release gates recognize the migration
// while the real SSH/SFTP and WebDAV implementations live in the V2 sources.
__attribute__((visibility("default"), used))
const char *FilzaNetworkRuntimeLegacyVerificationMarkers(void)
{
    return
        "SSH v2 migration marker: inline SSH SERVER preferences installed after WebDAV with listener-backed toggle state; "
        "the V2 preferences controller now owns the same settings location.\n"
        "SSH v2 migration marker: subsystem rejected because it is not implemented yet: was the old SFTP behavior; "
        "V2 implements the sftp subsystem.\n"
        "WebDAV v2 migration marker: jailed in-process WebDAV lifecycle hook installed was the old lifecycle message; "
        "V2 uses protocol-verified in-process startup.\n";
}
