# Testing synchronization

## Automated checks

Run `scripts/setup-tests.sh` once, then `scripts/test.sh`. Setup installs the pinned versions in `scripts/test-dependencies.txt`; the tests themselves require no network or credentials. CI and release packaging use the same commands. Set `STORYGRAPH_TEST_RUNTIME` to reuse a separately installed runtime.

Coverage includes:

- Real htmlparser 0.3.9 parsing of synthetic edition/progress HTML.
- Acknowledged notes without a dependent refresh, rejected statuses, login forms, HTTP authentication/validation failures, rate limits and uncertain writes.
- Persisted in-flight markers and queue reconstruction after a lost response or a failed local write.
- Read-only reconciliation of uncertain progress before another mutation.
- Immediate read-only verification of uncertain notes using a pre-POST journal ID baseline, one new remote ID, and exact note/date/progress fields. Tests cover ambiguous/older entries, wrong editions, partial journals, login pages, read failures, Unicode and durable queue removal only after confirmation.
- Exponential retry delays, server-requested waits, coalescing during backoff and unrelated documents making progress without reordering dependent operations.
- Suspended/authenticated/disabled application states and cancellation of retry timers.
- Explicit user confirmation before resending uncertain notes.
- Edition remapping and legacy queue migration.
- Syntax checks for the repository's unignored Lua files.

The queue migrates schema v1 to v2 on persistence. Schema v2 records in-flight delivery, retry metadata and authentication suspension. Releases that only support v1 refuse to overwrite a v2 queue.

The journal fixtures use synthetic data and field names/structure observed through read-only StoryGraph requests on 2026-09-27. The parser was also checked locally against a real journal and note form without copying their private contents into the repository. All 11 journal verification tests additionally passed using the htmlparser files from the connected Kobo. No live note was created, edited or resent for this validation. This does not replace an end-to-end device test of an uncertain POST response. The current verification baseline is held only during the send call; interrupted attempts and previously blocked notes retain manual recovery.

## Device smoke test

These steps complement the automated tests; they have not been executed by the headless test runner. Use a test document and a StoryGraph test account.

1. Install the plugin on KOReader, link the document and send a progress update. Verify the remote edition and progress.
2. Disable Wi-Fi, create a note and advance the document. Reconnect and verify that the note appears once and the latest progress is synchronized.
3. Open **Pending synchronization** and verify that note previews and confirmation dialogs render correctly. For uncertain-delivery handling, use the automated lost-response fixture to inspect the persisted state; do not assume that turning off Wi-Fi at an arbitrary instant reliably reproduces a lost POST response.
4. Suspend and resume KOReader with pending operations. Verify that no retry occurs during suspension and that the remaining delay is respected after resume.
5. Change the linked edition with pending progress/notes. Verify that the note's original position and the current reading position are mapped separately.
6. Verify the plugin against KOReader's bundled htmlparser version: the headless fixtures pin htmlparser 0.3.9 and cannot establish live website compatibility or device UI behavior.
