# StoryGraph for KOReader

A KOReader plugin to synchronize your reading progress, notes, and status to [The StoryGraph](https://thestorygraph.com).

> [!NOTE]
> This repository is forked from [burneracc0112/storygraph.koplugin](https://github.com/burneracc0112/storygraph.koplugin) and builds on the work that adapted the original KOReader plugin to StoryGraph.
>
> The StoryGraph plugin was itself derived from [Billiam/hardcoverapp.koplugin](https://github.com/Billiam/hardcoverapp.koplugin). Credit and thanks go to both upstream maintainers for the work this fork is based on.

> [!CAUTION]
> **Disclaimer**: This plugin uses an unofficial API based on session cookies. Because of this, it is inherently brittle and may break if StoryGraph updates their website or cookie structure. If sync stops working, please ensure you are using the latest version of the plugin and try re-fetching your session tokens.

## AI-assisted development

Development of this fork is AI-assisted. AI tools may be used for code analysis, implementation, refactoring, tests, documentation, and assisted code review.

Bugs may still occur. Contributions and bug reports are welcome.

## Installation

1. Download the latest release and extract it to your KOReader `plugins/` folder.
2. Rename `storygraph_config.example.lua` to `storygraph_config.lua`.
   - *Note: If you are upgrading from an older version, the plugin will automatically rename `hardcover_config.lua` to `storygraph_config.lua`.*
3. **Authentication**:
   - Log in to [thestorygraph.com](https://thestorygraph.com) in your browser.
   - Open your browser's Developer Tools (F12) -> Application/Storage -> Cookies.
   - Copy the value of the `_story_graph_session` cookie and paste it into the `session_cookie` field in `storygraph_config.lua`.
   - Copy the value of the `remember_user_token` cookie and paste it into the `remember_user_token` field in `storygraph_config.lua`.

## Usage

The StoryGraph menu is located in the **Bookmark** top menu when a document is active.

### Updating Progress & Notes
The plugin provides a unified **"Update progress: [XX]%"** menu item. This opens a powerful dialog where you can:
- **Set Progress**: Tap the progress button to open a native picker showing both your **KOReader** and **StoryGraph** synced percentages.
- **Add a Note**: Write your thoughts directly in the note field.
- **Location Context**: By default, notes sent via the highlight menu automatically include your current **Chapter, Page, and Percentage**. You can enable this for regular notes in the settings.

### Linking a Book
Before updates can be sent, the plugin needs to link your document to a StoryGraph book.
- Use **"Link book"** to search by metadata or ISBN.
- Use **"Change edition"** to switch to a different edition.
- Audio editions are filtered out of the search results.
- If a book is not currently tracked, the plugin will set its status to Currently Reading
- If another edition of the book is set as 'Currently Reading' or 'Want to Read' then the plugin will automatically link to that edition, but not change the status. You can use "Change edition" to link to a different edition if needed.

### Automatically Track Progress
When enabled, the plugin will periodically sync your progress to StoryGraph:
- Updates are sent when paging, no more than once per minute (configurable).
- When reaching the end of the document, the book is automatically marked as "Read" on StoryGraph.
- Progress can be synced automatically based on time duration, percentage read or pages read (based on edition page count).
- Progress, status changes, and notes created while offline are saved locally and resumed after reconnection. Only the latest pending progress is kept for each document.

## Settings

- **Include location info in regular notes**: Automatically append Chapter, Page, and % info to your regular notes.
- **Automatically link by ISBN/Title**: Attempt to find matching books on StoryGraph automatically when opening a new document.
- **Enable wifi on demand**: Allow the plugin to turn Wi-Fi on temporarily for automatic work. Leave this disabled to synchronize only when a connection is already available. Temporary Wi-Fi is cleaned up even if a sync callback fails; connections that were already on are left on.
- **Confirm changes**: Prompt for confirmation before changing a book's status (e.g., Want to Read -> Read).

Pending offline operations are stored in `storygraphsync_queue.lua` in the KOReader settings directory. The file may temporarily contain note text; each pending entry is removed after StoryGraph confirms its update.

Changing the linked edition remaps pending progress to your current document position and pending notes to their original positions. If an edition change is interrupted, that document's queued updates remain paused, including after restarting KOReader. Retry linking the intended edition to resume them.

Temporary failures retry with increasing waits while connected; reconnecting or turning pages does not reset the wait. A failed document does not block independent documents. Authentication failures wait for updated credentials, while permanent failures need an explicit retry from **Pending synchronization**.

On each connection, automatic synchronization also captures the latest changed reading position, including progress waiting for the tracking timer or below the next page/percentage threshold. It consolidates automatic progress in the existing queue, preserves retry deadlines and explicitly authorized regressions, and does not enable Wi-Fi. Equivalent queued or already observed progress is not added again. Paused editions, disabled synchronization and suspension remain respected. This behavior is automatic; there is no separate connection-sync setting in this release.

Before sending a note, the plugin attempts to read the edition's journal entry IDs. If the POST result is uncertain, it immediately reads the journal again. It confirms delivery only when exactly one new entry appears and its text, date and page/percentage match the submitted note. Existing identical notes do not count as confirmation. These checks use only GET requests and never resend the note.

The journal baseline and submitted date/progress are saved before POST. If the immediate check cannot find the new note or encounters a temporary read failure, the plugin schedules at most three additional GET-only checks, waiting 60, 120 and 240 seconds between attempts (longer if the server requests it). Deadlines and the check budget survive restarts; checks run only while connected and resume on a subsequent connection when due. Suspension cancels the active retry timer. Each check can make up to two GET requests.

Unrecognized or paginated journals, changed entry lists, mismatches and ambiguous results stop automatic checks and leave the note pending. Authentication failures wait for updated credentials. Older pending notes without a saved baseline remain manual-only. No missing result authorizes a POST. If saving an available baseline fails, the note is not sent. The extra baseline read also occurs on successful sends.

**Pending synchronization** distinguishes notes waiting for verification from those requiring a delivery check. Diagnostics include verification reasons, attempt counts, HTTP status and known redirect route templates. They omit note text, credentials, URL query strings/fragments and remote entry IDs; unknown redirect paths are logged only as `other`.

Notes with an uncertain delivery result are never resent automatically. In **Pending synchronization**, view the note and check the StoryGraph reading journal. Choose **Already present on StoryGraph** to acknowledge it, or **Not present: send again** to authorize another attempt. If StoryGraph requires a rereading session, start it on the website before retrying the pending reading-status change.


## Versioning & Mandatory Updates

To prevent data corruption and ensure compatibility with StoryGraph's unofficial API, the plugin includes a remote versioning system.

- **Automatic Checks**: The plugin periodically checks for mandatory updates via GitHub. If the StoryGraph API changes in a way that breaks older versions, the plugin will automatically disable sync to prevent errors.
- **Blocking**: When a mandatory update is required, the plugin menus will be greyed out.
- **Configurable Frequency**: Use the **"Version check frequency"** slider to choose how often the plugin checks for updates (from 1 to 20 days). Default is 1 day.
- **Manual Override**: You can enable **"Ignore version blocks"** to bypass mandatory update requirements. Use this with caution as older versions may break sync if the StoryGraph API changes.
- **Silent Mode**: Disable **"Show version alert dialog"** if you prefer the plugin to silently stop working when an update is required, rather than showing a notification.

## Development tests

Install Python 3 with venv support, GCC, make, curl, unzip, git, and ripgrep. Then run:

```sh
scripts/setup-tests.sh
scripts/test.sh
```

Setup downloads pinned Lua 5.1, LuaRocks, Busted, and HTML parser dependencies into the ignored `lua_modules/` directory. Set `STORYGRAPH_TEST_RUNTIME` to use another installation directory. Tests and syntax checks run without network access or StoryGraph credentials. The HTML fixtures are synthetic; the parser is htmlparser 0.3.9, so a device smoke test remains useful when KOReader changes its bundled parser.

See [TESTING.md](TESTING.md) for coverage and the KOReader device smoke test.
