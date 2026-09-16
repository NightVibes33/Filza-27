# Airlift Books preimage fix

This experiment ports the upstream `c75b3ea5` state model: existing AFC-visible Books sync files are snapshotted into the app's temporary container, verified stable before staging, restored after the canary, and verified byte-for-byte. Pre-existing Books state is never intentionally discarded.

The verification workflow applies the guarded source transform and compiles both `AirliftCanaryExploit.m` and `AirliftBooksState.m`. Expected report keys after installation are `BooksSnapshot`, `BooksPreimageStable`, `BooksRestore`, and `BooksRestoreVerified`.

A successful build does not establish exploit success. Device-side confirmation still requires `AirTrafficSucceeded`, `ExactBytesRecovered`, `BooksRestoreVerified`, and `CleanupComplete` to all be true.
