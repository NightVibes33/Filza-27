# Airlift Books preimage fix

Ports upstream Airlift `c75b3ea5`'s safer state model to the Filza-27 experiment. Existing AFC-visible Books sync files are snapshotted into the app temporary container, checked for a stable preimage, restored after the canary, and compared byte-for-byte. Pre-existing Books state is not intentionally discarded.

`scripts/apply-airlift-experiment.sh` applies the guarded transform and adds the Airlift canary/state implementation to the experimental Theos source list. `main` is untouched.

Device report gates: `BooksSnapshot`, `BooksPreimageStable`, `BooksRestore`, `BooksRestoreVerified`. Full canary confirmation still requires `AirTrafficSucceeded`, `ExactBytesRecovered`, `BooksRestoreVerified`, and `CleanupComplete` all true. CI success alone is not exploit proof.
