# Pouch for Android (Delphi / FireMonkey)

The list of saved links on your phone, synced with the same PHP server
as the Firefox add-on (`../server/`).

- **Tap** a link: it opens in the default browser.
- **Search box** above the list: filters by title and address, ignoring letter case.
- **Edit** next to a link: change its title and address, open it, or delete it.
  The app does not accept an address that is already on the list.
- **Swipe** a link sideways: a *Delete* button appears.
- **Pull the list down**, or tap ⟳: sync now.
- **+**: add an address by hand (the app suggests one from the clipboard).
- **In the browser, Share → Pouch**: the page is saved and appears at the top of the list.
- **ⓘ**: server address and token. Use the same ones as in the add-on options.

Sync works the same way as in the add-on. Local changes are sent to the
server about 2 seconds after the last change, and also when the app returns
to the foreground or goes to the background. Changes from other devices are
pulled at the same moments. The data is stored in `pouch.json` in the app's
private folder.

## Files

| File                           | What it contains                                                        |
|--------------------------------|-------------------------------------------------------------------------|
| `Pouch.dpr`                    | program                                                                 |
| `Pouch.Main.pas/.fmx`          | the screen: list and sync settings                                      |
| `Pouch.Store.pas`              | local data (port of `../extension/lib/store.js`): records, tombstones, merging      |
| `Pouch.Sync.pas`               | server client and sync (port of `../extension/lib/remote.js` and `sync.js`)      |
| `Pouch.Platform.pas`           | opening the browser, receiving `ACTION_SEND` (Share)                    |
| `AndroidManifest.template.xml` | Delphi's default template plus an `intent-filter` for `SEND text/plain` |

## Building (RAD Studio 13)

1. Open `Pouch.dpr` in RAD Studio. The IDE creates `Pouch.dproj` and `Pouch.res`.
2. In *Projects → Target Platforms*, add **Android 64-bit** (and optionally
   Android 32-bit) and make it the active platform.
3. In *Project → Options → Application → Version Info*, set `package` to, for example,
   `net.norbertdudek.pouch`, and set `label` to `Pouch`.
4. In *Project → Options → Application → Uses Permissions*, make sure
   **Internet** is checked (it is by default).
5. *Run* (F9) with the phone connected, or *Project → Deploy*.

Keep `AndroidManifest.template.xml` in the project folder. The IDE uses it
instead of generating its own, and it registers the app as a share target.
After you change the template, use *Clean* before building again.

The app also builds for **Windows 32/64-bit**, which is handy for debugging the
list and sync. *Share* is not available there. On Windows the data is stored in
`Documents\pouch.json`.

### Server over plain `http://`

Android blocks unencrypted connections by default, so use `https://`. If you
need `http://` (for example a server on your local network), add
`android:usesCleartextTraffic="true"` to the `<application>` element in
`AndroidManifest.template.xml`.
