# kogrim

A KOReader plugin for [Grimmory](https://github.com/grimmory-tools/grimmory) — browse your
self-hosted library and download books straight to the device.

Grimmory ships a purpose-built app API that returns read status, reading progress, personal
ratings and series information alongside each book. kogrim uses that API rather than the
server's OPDS feed, so lists show you what you've already read and how far you got — things a
bare OPDS catalogue throws away. (If you only want a plain catalogue, KOReader's built-in OPDS
plugin already does that and you don't need this.)

## Status

v0.1.0 — browse, download, and cover art in the detail sheet, the book lists and a grid view.
Reading-progress sync back to Grimmory and shelf editing are not implemented yet.

## Install

This repository *is* the plugin — its root is what KOReader loads. The directory it lives in
on the device **must** be named `kogrim.koplugin`; KOReader derives the plugin's identity from
that name.

**Kobo, over USB:**

```sh
./tools/install-kobo.sh          # install or update
./tools/install-kobo.sh --log    # pull crash.log off the device
./tools/install-kobo.sh --remove # uninstall
```

It syntax-checks every file before writing, so it can't push a plugin that would stop KOReader
starting. Eject and unplug afterwards, then restart KOReader.

**Anything else** — download `kogrim.koplugin-vX.Y.Z.zip` from the
[releases page](https://github.com/sam-don/kogrim.koplugin/releases), extract it, and put the
`kogrim.koplugin` folder it contains into KOReader's `plugins/`:

| Platform | Path |
|---|---|
| Kobo | `.adds/koreader/plugins/kogrim.koplugin/` |
| Kindle / Android | `koreader/plugins/kogrim.koplugin/` |
| Linux | `~/.config/koreader/plugins/kogrim.koplugin/` |

`tests/`, `tools/` and `.github/` are development-only and don't need to go on the device.

Then set up the connection under **Search ▸ Grimmory ▸ Server and account**: enter your server
URL (`https://…`), username and password, and kogrim will verify the login immediately.

## Use

**Search ▸ Grimmory ▸ Browse library** opens a hub:

- **Continue reading** — books Grimmory has you part-way through
- **Recently added** — newest arrivals
- **Libraries** / **Shelves** — drill into either
- **All books** — the whole catalogue
- **Search** — free-text over title, author and series

Tap a book for details, its cover, and a Download button. **Long-press a book to download it
immediately**, skipping the detail sheet.

Book lists can be drawn three ways, switched from the **view button at the left of the title
bar** (or Settings ▸ Show books as): a plain text list, a list with a thumbnail on each row, or
a grid of covers. The text list stays the default so an upgrade doesn't change how the plugin
looks, and so the extra requests are opt-in. Covers arrive *after* the page draws — the list is
usable immediately and fills in behind you, one cover at a time, with a single redraw at the
end rather than a flicker per cover. Books the server has no artwork for get a panel with the
title and author set in text. A `✓` in the right-hand column means the file is already in your
download folder; `paper` means it's a physical book with no file to fetch.

Lists page continuously. Books are fetched from the server in batches, but you just turn pages
normally — reaching the end of what's loaded quietly pulls in the next batch, so the batch
boundary never shows up as a thing you have to click through.

Both *Browse library* and *Search* can be bound to a gesture or key via KOReader's usual
Dispatcher (Settings ▸ Gesture manager), where they appear as *Grimmory: browse library* and
*Grimmory: search*.

### Settings

| Setting | Default |
|---|---|
| Download folder | `<your home folder>/Grimmory` |
| Books loaded at a time | 100 — lower it on a slow connection |
| Show books as | Text list — or *List with covers* / *Cover grid* |
| Show cover art | on |
| Open books after downloading | on |

Covers are downloaded once and cached under `<koreader>/cache/kogrim-covers`, keyed by the
server's `coverUpdatedOn` so replaced artwork is picked up automatically. The cache is capped
at 400 files and prunes itself oldest-first; deleting it by hand costs nothing but a re-fetch.

They are fetched from `/api/v1/media/book/{id}/thumbnail`, falling back to `.../cover`.
**Grimmory's own `thumbnailUrl` field is deliberately unused**: `AppBookMapper.mapThumbnailUrl`
hardcodes `/api/books/{id}/cover`, which no controller is mapped to, so the request falls
through to the Angular frontend's catch-all and returns `index.html` with a 200 status. Any
client trusting that field gets 2.3 KB of HTML instead of a picture.

## Security notes

Read these before pointing kogrim at a server you care about.

### KOReader does not verify TLS certificates

This is a KOReader platform limitation, not something this plugin can fix. LuaSec's
`ssl.https` defaults to `verify = "none"`, KOReader ships no CA bundle, and its own HTTP client
sets `verify_ca = false`. So **HTTPS here gives you encryption but not authentication**: the
traffic is unreadable to a passive eavesdropper, but an active attacker who can intercept your
connection can present any certificate and read everything — including your password on login.

In practice that means: fine on your home network, and fine over the internet against a server
you control. Be aware of it on public Wi-Fi. If that matters to you, reach your server over a
VPN or Tailscale rather than exposing it publicly.

### Credentials are stored in plain text

Your Grimmory username, password and session tokens live in
`<koreader>/settings/kogrim.lua`, unencrypted. There is no keychain on these devices, and this
is the same approach KOReader's own OPDS plugin takes for catalogue credentials — but it does
mean anyone with filesystem access to your device can read them. Consider a dedicated Grimmory
account for the device if that matters to you.

The password is kept (not just the tokens) because it is what lets kogrim recover silently
when a session expires. **Sign out** clears the password and the tokens, keeping only the URL
and username.

### What the plugin does defend against

- **Redirects never carry your token off-origin.** kogrim follows redirects itself rather than
  letting LuaSocket do it, because LuaSocket forwards headers verbatim to whatever host a
  `Location` names. A hop to a different scheme, host or port drops the `Authorization` header
  first; HTTPS-to-HTTP redirects are refused outright.
- **Server-supplied filenames cannot escape the download folder.** Separators are replaced and
  names consisting only of dots are rejected, so a hostile `primaryFileName` can't write
  outside the download directory.
- **Book ids are validated as integers** before being concatenated into a request path.
- **Cover URLs are built, not taken from the server.** The `thumbnailUrl` field in Grimmory's
  responses is ignored (it points at a route that doesn't exist — see below), and cover paths
  are constructed from the validated integer book id instead. So no server-supplied URL ever
  receives a request carrying your token.
- **Nothing sensitive is logged.** No credential or token reaches `crash.log`.

## Development

```sh
./tests/run.sh
```

Needs `luajit` — LuaJIT is what KOReader actually runs, so it enforces the same 5.1 dialect as
the device. `msgfmt` (gettext) is used for the translation check if present. The suite covers
Lua syntax, a scan for accidental global writes, and the plumbing that has no device
dependency: URL building, settings defaults, base-URL normalisation, auth headers and filename
derivation.

It cannot cover drawing — everything in `lib/kogrim_browser.lua` builds widgets, which need a
real device. **Open each screen once before releasing.**

### Layout

```
_meta.lua                  plugin identity and version
main.lua                   wiring only: menu, Dispatcher, event handlers
lib/kogrim_i18n.lua        .po loader, falls back to KOReader's gettext
lib/kogrim_settings.lua    preferences, in settings/kogrim.lua
lib/kogrim_http.lua        socket/ltn12 primitives: GET, POST, download, Wi-Fi gate
lib/kogrim_api.lua         Grimmory endpoints + JWT lifecycle
lib/kogrim_account.lua     the server/credentials sheet
lib/kogrim_download.lua    filenames, destinations, download UX
lib/kogrim_browser.lua     the browse UI
```

### Adding a language

Copy `locale/kogrim.pot` to `locale/<lang>.po` (e.g. `locale/de.po`), fill in the `msgstr`
values, done — no code changes needed.

## Grimmory endpoints used

| Purpose | Endpoint |
|---|---|
| Login / refresh | `POST /api/v1/auth/login`, `POST /api/v1/auth/refresh` |
| Current user | `GET /api/v1/app/users/me` |
| Book list | `GET /api/v1/app/books?page&size&sort&dir&libraryId&shelfId` |
| Search | `GET /api/v1/app/books/search?q&page&size` |
| Continue reading / recently added | `GET /api/v1/app/books/continue-reading`, `…/recently-added` |
| Book detail | `GET /api/v1/app/books/{id}` |
| Libraries / shelves | `GET /api/v1/app/libraries`, `GET /api/v1/app/shelves` |
| Download | `GET /api/v1/books/{id}/download` |

Auth is a JWT in `Authorization: Bearer …`. On a 401, kogrim refreshes the token once, then
falls back to a full re-login, then retries the original request — so an expired session is
invisible unless the credentials themselves have gone bad.
