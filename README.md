# Moria

A tiny Finder for encrypted vaults. A vault is an AES-256 encrypted APFS sparse bundle (`Name.sparsebundle`).

## Build

```sh
./build.sh          # → Moria.app (drag it to /Applications if you like)
```

Requires macOS 26+ and Xcode. To hack on it, `open Package.swift` in Xcode (the door and icon only show in the built app).

`Door.png` is the artwork: a line drawing of the Doors of Durin, its ink as an alpha mask. `Assets.swift` lights it up
as glowing Spindrift on black for the app icon, in Icon Composer's `.icon` format (macOS 26 puts old `.icns` icons on a
light plate), and writes the Spindrift accent colour; `build.sh` compiles both with `actool`.

## Use

- The sidebar lists every vault you've opened. Picking one locks the one that's open.
- **New Vault…** pick a location and a password. **Open Vault…** pick an existing `.sparsebundle`.
- Unlock with the password or, after the first unlock with **Remember with Touch ID** on, with your fingerprint.
- Drag files in to copy them into the vault. **⌘-drag** moves them instead, so only the encrypted copy remains.
- Double-click opens files and folders. **⌘↑** goes back up, **⇧⌘N** makes a new folder, **Delete** removes, **⌘L** locks.
- Drag rows out to export decrypted copies.

## Cloud sync (Google Cloud Storage)

Needs the Google Cloud CLI (`brew install --cask gcloud-cli`) and a project with billing enabled.

Click the **cloud** button in the toolbar, **Sign in with Google**, pick a project and **Back Up Here**. Moria reuses
the project's private `moria-…` bucket (or creates one in the US multi-region) and gives the vault its own folder in it.

The same sheet lists every vault backed up in the project, with its size and when it last changed:

- **Restore…** downloads one to a new `.sparsebundle` and selects it. It stays linked, so it keeps backing up there.
  Vaults already on this Mac say so instead.
- **Delete** (trash) removes a backup, e.g. of a vault you deleted. A vault on this Mac that backed up there just
  stops backing up. GCS soft delete keeps deleted objects recoverable for 7 days.

Every time the vault locks, Moria mirrors the bundle there with `gcloud storage rsync`. Only encrypted bands are
uploaded, and only changed ones. Vaults use 1 MiB bands, so a typical backup is a few MB. (Vaults made before this
used 64 MiB bands and re-upload ~60 MB per lock; make a new vault and drag the files across to fix that.) Syncing after the image detaches guarantees a consistent snapshot. The lock screen
shows progress and when the last backup finished; a failed backup alerts with gcloud's error (full output of the latest
run is in `~/Library/Logs/Moria.log`). Backups keep running after you quit.

Unlocking cancels a backup still in progress (mounting writes to the image), and the next lock finishes it. If the
project has no billing account, Connect offers to open its billing settings.

- **Disconnect** stops backups but keeps the bucket and its data.
- By hand: `gcloud storage rsync -r gs://moria-…/Secret-… ~/Vaults/Secret.sparsebundle`
- The link is just an xattr on the bundle: `xattr -w moria.remote gs://bucket/path Secret.sparsebundle` sets it by hand.
- Your `gcloud` credentials live in `~/.config/gcloud`, so a process running as you could delete the backup (never read
  it). GCS soft delete keeps deleted objects recoverable for 7 days.

## Security model

- **Locked**, a vault is ciphertext. Neither Google nor anything on your Mac can read it without the password.
- **Unlocked**, it is mounted at a hidden path in your private temp folder, invisible to Finder and not indexed by
  Spotlight, but **any process running as you can read it while it is unlocked**. Moria therefore locks on ⌘L,
  window close / quit, sleep and screen lock. Keep it locked when you're not using it.
- **Touch ID** keeps the password in your login keychain. Its ACL lets only Moria's code signature read it silently.
  Any other process (for example `security find-generic-password`) triggers a macOS prompt. Turn the toggle off to
  delete the stored password.
- **Originals** you delete after copying them in may survive in APFS / Time Machine snapshots.
