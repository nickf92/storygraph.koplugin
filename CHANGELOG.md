# Changelog

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
