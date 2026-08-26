# Changelog

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
