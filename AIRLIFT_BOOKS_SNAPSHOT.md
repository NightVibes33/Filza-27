# Airlift Books preimage fix

This experimental branch ports upstream Airlift commit `c75b3ea5`'s state model. Existing AFC-visible Books sync files are snapshotted into the app's temporary container, checked for a stable preimage before staging, restored after the canary, and compared byte-for-byte afterward. The experiment does not intentionally discard pre-existing Books state.

Run `scripts/apply-airlift-experiment.sh` before packaging this branch. The script applies a fail-closed transform to `AirliftCanaryExploit.m` and adds `AirliftBooksState.m` plus `AirliftCanaryExploit.m` to the Theos source list. `main` is untouched.

Expected device report keys: `BooksSnapshot`, `BooksPreimageStable`, `BooksRestore`, `BooksRestoreVerified`. Exploit confirmation still requires `AirTrafficSucceeded`, `ExactBytesRecovered`, `BooksRestoreVerified`, and `CleanupComplete` to all be true. CI/source-gate success alone is not device-side exploit proof.
