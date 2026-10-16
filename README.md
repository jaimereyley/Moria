# Moria

A tiny Finder for encrypted vaults. Nothing is ever mounted: an unlocked vault's key, and every file you open, live
only in Moria's memory, so other apps and agents running as you only ever see encrypted archives. The one exception
is a vault you open in Obsidian, while it's open there.

## Build

```sh
./build.sh          # → Moria.app (drag it to /Applications if you like)
```

Requires macOS 26+ and Xcode. To hack on it, `open Package.swift` in Xcode (the door and icon only show in the built app).

`Door.png` is the artwork: a line drawing of the Doors of Durin, its ink as an alpha mask. `Assets.swift` lights it up
as glowing Spindrift on black for the app icon, in Icon Composer's `.icon` format (macOS 26 puts old `.icns` icons on a
light plate), and writes the Spindrift accent colour; `build.sh` compiles both with `actool`. It also compiles
`Recovery/Recover.applescript` into the Recover.app that every vault carries, and signs Moria with the hardened runtime.

## Vault format

A vault is a folder, `Name.moria`, that Finder shows as a single document (double-click it to open it in Moria):

- `key.kdf` and `key.aea`: a random 256-bit key, encrypted with your stretched password. Moria runs the password
  through 10 million rounds of PBKDF2-SHA256 with the salt in `key.kdf` (about a second), and uses the result, in
  hex, as the password of `key.aea` (Apple Encrypted Archive, scrypt profile, which adds a memory-hard step). Any
  password of 8+ characters works; stretching makes each guess cost an attacker that second. Touch ID keeps the
  stretched result, never your password.
- `files/`: one Apple Encrypted Archive per file or folder (AES-256-CTR + HMAC, keyed with that key), each holding
  an Apple Archive entry with the item's path inside the vault. File names on disk are random, so nothing about your
  files shows outside except their number and rough sizes.
- `Recover.app` and `Read Me.txt`: the way out without Moria (below). Moria rewrites both every time it unlocks the
  vault, undoing any tampering.

There's no index: unlocking decrypts every archive's header (a few milliseconds for hundreds of files), so the files
themselves are the only truth, and each change is one file written whole, then renamed into place.

## Getting files back without Moria

Every piece is Apple's standard format, readable with tools built into macOS:

- **Recover.app**: right-click the vault, **Show Package Contents** (or just open the folder on a Mac without
  Moria), double-click **Recover**, enter the password, pick a folder. It's plain AppleScript; open it in Script
  Editor to read it.
- **Terminal**, from inside the vault:

  ```sh
  read kdf rounds salt < key.kdf
  secret=$(printf %s 'YOUR PASSWORD' | openssl enc -aes-256-cbc -pbkdf2 -md sha256 -iter $rounds -S $salt -pass stdin -P | sed -n 's/^key=//p')
  key=$(aea decrypt -i key.aea -o /dev/stdout -password-value $secret | base64)
  mkdir ~/Desktop/Recovered
  for f in files/*.aea; do aa extract -i "$f" -d ~/Desktop/Recovered -key-value "base64:$key"; done
  ```

`openssl` (macOS's LibreSSL) recomputes the stretched password exactly as Moria does; it takes about 4 seconds.
Recovery passes the stretched password and key as command-line arguments, which other processes running as you can
see while it runs. It's a last resort, so that trade-off buys working with nothing but a stock Mac. (`aea` and `aa`
can't read secrets from a pipe.)

## Use

- The sidebar lists every vault you've opened. Picking one locks the one that's open.
- **New Vault…** pick a location and a password. **Open Vault…** pick an existing `.moria`, or double-click one in
  Finder.
- Unlock with the password or, after the first unlock with **Remember with Touch ID** on, with your fingerprint.
- Drag files in to encrypt them into the vault. **⌘-drag** moves them instead, so only the encrypted copy remains.
- Double-click opens folders, and shows files right in Moria, decrypted only in memory: images, PDFs, text, Word,
  RTF and OpenDocument text, audio and video.
- **Export…** (right-click, or in the viewer) saves decrypted copies to a folder you pick. Use it for anything else,
  like files to edit in other apps; those copies aren't encrypted.
- **⌘↑** goes back up, **⇧⌘N** makes a new folder, **Delete** removes, **⌘L** locks.
- **Open in Obsidian** (the Obsidian icon in the toolbar) edits the vault in Obsidian. See below.

Vaults from Moria's first version (`.sparsebundle` disk images) don't open in this one. Double-click the old vault in
Finder, enter its password, ⌘-drag its files into a new Moria vault, then eject and delete it.

## Obsidian

Obsidian only works on plain files, so **Open in Obsidian** decrypts the vault into a copy and opens that as an
Obsidian vault, named after yours. Everything works as usual: notes, attachments, plugins, settings.

- Whatever Obsidian saves is encrypted back into the vault within about a second, so Moria shows it and nothing is
  lost if either app crashes. While it's open, Moria only views the vault.
- When you quit that Obsidian or close its window, Moria encrypts its last changes and deletes the copy. Locking the
  vault (⌘L, quitting Moria, sleep, screen lock) quits that Obsidian first. **Close Obsidian** in Moria's banner does
  the same.
- It runs in an Obsidian of its own, beside any other vaults you have open, with its own app data (caches, search
  index, file-recovery snapshots), which is deleted with the copy.
- The copy lives in `~/Library/Application Support/Moria/Obsidian.noindex/`, out of Spotlight and Time Machine.
  Deleted notes go to the vault's own `.trash` folder rather than the macOS Trash. Moria hides that folder and
  Obsidian's `.obsidian` settings.
- If Moria crashes, the next unlock encrypts whatever the copy holds back into the vault, then deletes it.

**While the vault is open in Obsidian, any app running as you, AI agents included, can read the copy.** Close
Obsidian before running one. Big files, like videos, are decrypted too, so keep notes in a vault of their own.

## Cloud sync (Google Cloud Storage)

Needs the Google Cloud CLI (`brew install --cask gcloud-cli`) and a project with billing enabled.

Click the **cloud** button in the toolbar, **Sign in with Google**, pick a project and **Back Up Here**. Moria reuses
the project's private `moria-…` bucket (or creates one in the US multi-region) and gives the vault its own folder in it.

The same sheet lists every vault backed up in the project, with its size and when it last changed:

- **Restore…** downloads one to a new `.moria` and selects it. It stays linked, so it keeps backing up there.
  Vaults already on this Mac say so instead, and backups of first-version disk images say "Old format".
- **Delete** (trash) removes a backup, e.g. of a vault you deleted. A vault on this Mac that backed up there just
  stops backing up. GCS soft delete keeps deleted objects recoverable for 7 days.

Every time the vault locks, Moria mirrors the folder there with `gcloud storage rsync -P`. Only encrypted archives are
uploaded, and only new or changed ones, so a backup costs about what you added. `-P` keeps file modes, so a vault
downloaded by hand still has a runnable Recover.app. The lock screen shows progress and when the last backup
finished; a failed backup alerts with gcloud's error (full output of the latest run is in `~/Library/Logs/Moria.log`).
Backups keep running after you quit.

Unlocking cancels a backup still in progress, and the next lock finishes it. If the project has no billing account,
Connect offers to open its billing settings.

- **Disconnect** stops backups but keeps the bucket and its data.
- By hand: `gcloud storage rsync -r -P gs://moria-…/Secret-… ~/Vaults/Secret.moria`
- The link is just an xattr on the vault: `xattr -w moria.remote gs://bucket/path Secret.moria` sets it by hand.
- Your `gcloud` credentials live in `~/.config/gcloud`, so a process running as you could delete the backup (never read
  it). GCS soft delete keeps deleted objects recoverable for 7 days.

## Security model

- **On disk**, locked or not, a vault is ciphertext. Neither Google nor anything on your Mac can read it without the
  password.
- **Unlocked**, the key and the files you view exist only in Moria's memory. macOS keeps other processes out of it:
  the hardened runtime blocks debuggers and code injection, even from processes running as you (root aside). Moria still locks on
  ⌘L, window close / quit, sleep and screen lock.
- **What still leaks**: anything you **export** is a normal file, and so is a vault **open in Obsidian**, until you
  close it. An app you've granted Screen Recording or
  Accessibility can see what Moria shows on screen. Anything running as you can delete the encrypted files (keep a
  backup), and could swap Recover.app between unlocks (Moria restores it on every unlock).
- **Touch ID** keeps your stretched password (never the password itself) in your login keychain. Its ACL lets only
  Moria's code signature read it silently. Any other process (for example `security find-generic-password`) triggers
  a macOS prompt. Turn the toggle off to delete it.
- **Originals** you delete after copying them in may survive in APFS / Time Machine snapshots.
