# Changelog

## 0.2.9 (2026-09-05)

### Features

* Retry temporary synchronization failures per operation with persisted exponential backoff and jitter. Respect server retry delays and preserve ordering for the same document or edition while allowing independent documents to continue.
* Add a Pending synchronization menu with note previews, explicit retry, and manual reconciliation of uncertain note delivery.

### Fixes

* Stop queued synchronization while the plugin is disabled, including scheduled flushes and blocks applied between sends. Respect the explicit version-block override.
* Retarget pending operations when changing editions: derive progress from the current document position and remap notes from their original positions. Persist an edition-change pause until the new link is saved.
* Separate confirmed, rejected, and uncertain mutation outcomes. Confirm statuses and progress against the requested state; an acknowledged note no longer depends on a subsequent refresh.
* Persist in-flight delivery before sending. Reconcile uncertain progress/status by reading first, and never automatically resend an uncertain note after a timeout, restart, or failed queue deletion.
* Wait for credential updates after authentication failure and for explicit action after permanent errors. Cancel retry timers on suspension/disconnection and do not bypass backoff when progress is coalesced.
* Do not silently start a rereading session after a rejected status request, or accept a rendered login form as a successful note update.
* Refresh confirmed notes independently and ignore stale document-session results. Avoid repeated notifications for unchanged retry errors.

### Compatibility

* Migrate queue schema v1 to v2 without losing pending operations. Older plugins that support only v1 refuse the upgraded queue.

### Tests

* Add a reproducible, pinned Lua 5.1/Busted environment shared by development and release CI, with synthetic HTML fixtures and no live StoryGraph access during tests.
* Cover HTTP outcomes, interrupted delivery, queue persistence and migration, retry timing, independent documents, application lifecycle, and explicit note-recovery confirmation.
* Document a separate KOReader device smoke test in TESTING.md.

## 0.2.8 (2026-09-02)

### Fixes

* Keep progress queued until StoryGraph confirms that the linked edition is currently reading and that the requested progress was applied.
* Explain when progress is waiting for a “Currently Reading” transition instead of reporting a false successful synchronization.
* Send an explicitly confirmed “Currently Reading” status before retained progress so synchronization can recover without losing queue order.

### Security

* Stop writing CSRF tokens to the KOReader crash log during edition switches.

### Tests

* Add regression coverage for to-read editions, unconfirmed remote progress, explicit regressions, persisted queue priority, and recovery after a reading-status transition.

## 0.2.7 (2026-08-29)

### Fixes

* Prevent a completed background Wi-Fi callback from refreshing a book after its document or reader session has closed or changed.
* Use the connection result belonging to the active Wi-Fi attempt instead of accepting an unrelated later network connection.
* Decouple book-cache refreshes from the live reader document so stale callbacks fail safely instead of crashing KOReader.

### Tests

* Add regression coverage for cache refreshes after document teardown and for explicit captured filenames.

## 0.2.6 (2026-08-28)

### Fixes

* Recover automatic synchronization after KOReader's Wi-Fi connectivity check times out, allowing later connections to drain the offline queue.
* Finalize timed-out Wi-Fi attempts exactly once and notify every waiting background consumer without duplicating successful flushes.

### Tests

* Add regression coverage for failed connectivity attempts, late callbacks, and queue recovery after reconnection.

## 0.2.5 (2026-08-27)

### Features

* Use Wi-Fi on demand for automatic background synchronization with a battery-aware cooldown.
* Share the automatic Wi-Fi cooldown across queue sync, read-cache loading, autolinking, and version checks.

### Fixes

* Respect the configured version-check interval across KOReader restarts and avoid duplicate scheduled checks.
* Keep queued operations intact when automatic connectivity is unavailable, without periodic network retries.

### Documentation

* Clarify the repository lineage, upstream attribution, and AI-assisted development disclosure.

## 0.2.4 (2026-08-26)

### Features

* Persist progress, status, and note updates while offline and resume them after reconnection.
* Keep only the latest pending progress for each document while preserving ordered status and note operations.

### Fixes

* Do not treat redirects to the StoryGraph login page as successful updates.
* Do not include POST contents, such as note text, in logs.

## 0.2.3 (2026-08-26)

### Fixes

* Fix linking and invalid remote-page progress updates.
* Coalesce progress synchronization to reduce network and battery usage.
