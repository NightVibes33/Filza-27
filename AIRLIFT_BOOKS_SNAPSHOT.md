# Airlift Books preimage fix

This experiment ports upstream Airlift commit `c75b3ea5`'s state model. Existing AFC-visible Books sync files are snapshotted into the app's temporary container, verified stable before staging, restored after the canary, and verified byte-for-byte. Pre-existing Books state is not intentionally discarded.

Use `scripts/apply-airlift-experiment.sh` before building this experimental branch. It applies the guarded canary transform and adds `AirliftBooksState.m` plus `AirliftCanaryExploit.m` to the Theos source list without changing `main`.

Expected report keys are `BooksSnapshot`, `BooksPreimageStable`, `BooksRestore`, and `BooksRestoreVerified`. Device-side confirmation still requires `AirTrafficSucceeded`, `ExactBytesRecovered`, `BooksRestoreVerified`, and `CleanupComplete` to all be true. A green source-gate workflow alone does not establish exploit success.
