<p align="center">
  <a href="./README.md">简体中文</a> ·
  <b>English</b>
</p>

# dsh-quick-backup

Local-only, Git-based incremental backup for the **DeepSeek Harness (DSH)** user environment, with a **Settings → Backup** panel.

> This repository contains **only the plugin and workflow scripts**.
> Your DSH profile, sessions, credentials, API keys, and backup data are **never** part of it.
> Backups live in a **separate local repository** that you create with `setup.ps1`.

## What you get

- One-click backup from **DSH Settings → Backup**
- Local Git history with date-based versions: `vYYMMDD.E.SSS`
- Automatic backup when DSH starts (optional watcher)
- Version list, export, and copy-safe restore command
- Cache-aware: restarting DSH does not create meaningless versions
- No network, no remote, no cloud

## ⚠️ Data and credential warning (read this)

> [!WARNING]
> **If you enable “Back up credentials and APIKey”, the local data repository stores `.credentials.yaml` and `APIKey` in plaintext, and Git history never forgets.**
>
> These files are excluded by default. If you enable them and then sync the backup folder to cloud storage, a network drive, or any other sync service, or forward it to another person, any resulting credential or privacy leak is **your responsibility**. The author assumes **no liability** for such leaks.

## Requirements

- Windows 10/11
- PowerShell 5.1 (built in)
- [Git for Windows](https://git-scm.com/download/win) (the scripts prefer `C:\Program Files\Git\cmd\git.exe`)
- DSH desktop `>= 0.2.1-rc.2`

## Quick start

### 1. Get the files

```powershell
git clone https://github.com/SShiRkiT/dsh-quick-backup.git
cd dsh-quick-backup
```

### 2. Create the local backup repository

**The backup path has no default.** You must pass `-RepoPath` explicitly:

```powershell
powershell -ExecutionPolicy Bypass -File .\setup.ps1 -RepoPath "D:\DSH-Backups" -EnableAutostart
```

`setup.ps1` will:

- detect/depend on your `.dsh` profile (default `%USERPROFILE%\.dsh`)
- create the backup repository at the path you specify
- copy the workflow scripts and write `backup.config.json`
- initialize local Git and create the first baseline version
- register the plugin discovery config
- optionally install the logon watcher (`-EnableAutostart`)

Useful options:

```powershell
# custom profile / install locations
.\setup.ps1 -RepoPath "D:\DSH-Backups" -DshProfile "$env:USERPROFILE\.dsh"

# DSH installed in a custom directory
.\setup.ps1 -RepoPath "D:\DSH-Backups" -InstallRoot "D:\DSH\Desktop"

# copy scripts/config only, do not copy the profile yet
.\setup.ps1 -RepoPath "D:\DSH-Backups" -SkipInitial

# include .credentials.yaml / APIKey (excluded by default)
.\setup.ps1 -RepoPath "D:\DSH-Backups" -IncludeCredentials
```

### 3. Install the plugin

Open **DSH Settings → Plugins**, choose install from repository, and enter:

```text
https://github.com/SShiRkiT/dsh-quick-backup
```

Then restart DSH. You should see **Settings → Backup**.

> A private repository requires GitHub authentication first; a public repository does not.
> For development, you can point DSH at your local repository directory instead.

### 4. Use it

Open **Settings → Backup**. If the backup path was not configured by setup, type it into **Backup repository path** and click **Save path**.

| Control | Action |
| --- | --- |
| Backup repository path | Set or change the local data repository |
| Back up credentials and APIKey | Disabled by default; enable to include `.credentials.yaml` and APIKey |
| Backup | incremental backup (respects the 60 s guard) |
| Force backup | force a backup now |
| Verify / Deep verify | verify repository and Git objects |
| Versions | select a version |
| Copy restore command | copy a safe restore command |
| Export | export the selected version to a new folder |
| Enable / Disable | install/remove the logon watcher |
| Run diagnostic | one watcher check without backing up |

## Backup repository path

- The plugin's default path is **empty**; nothing is assumed.
- `setup.ps1` writes the chosen path to `%LOCALAPPDATA%\dsh-quick-backup\config.json`.
- The plugin also reads `DSH_BACKUP_REPO` (highest priority) and the same config file.
- The path must be an absolute local path such as `D:\DSH-Backups`.
- The folder must be a data repository created by `setup.ps1` (it contains `scripts\backup.ps1`). If it is not initialized, the panel shows “not ready” and asks you to run setup.
- Changing the path in the plugin takes effect immediately; no DSH restart is needed.

## Credential backup switch

- **Disabled by default**: `.credentials.yaml` and `APIKey` are not backed up.
- Enable it in **Settings → Backup → Back up credentials and APIKey**, or with `setup.ps1 -IncludeCredentials`.
- When enabled, later versions include these files. Disabling only excludes later versions; **old Git history is not rewritten automatically**. If credentials were backed up before, rebuild the data repository or clean its Git history to remove the old copies.

## Version model

Format: `vYYMMDD.E.SSS`

| Part | Meaning |
| --- | --- |
| `YYMMDD` | date the current **environment baseline** was created |
| `E` | environment change sequence that day (`1`, `2`, …; resets on a new date) |
| `SSS` | minor change sequence in that baseline (`001`, …; resets when `E` changes) |

Increments when:

- **major / environment**: DSH upgrade, plugin install/update/removal, `dsh-ops` or runtime update
- **minor**: sessions, attachments, settings, credentials, workspace state, docs/scripts

Example:

```text
v261025.1.001   baseline
v261025.1.002   new conversation
v261025.2.001   same day, plugin update
v261026.1.001   next day, DSH upgrade
```

See [docs/VERSIONING.md](docs/VERSIONING.md) for details.

## Repository layout

```text
dsh-quick-backup/          # this repo (no personal data)
├─ package.json            # DSH plugin package root
├─ lib/                    # plugin host + client
├─ cordis.patch.yml
├─ scripts/                # copied into the data repo
├─ setup.ps1               # creates the local data repo
├─ docs/
└─ test/                   # plugin self-test

<your chosen path>/        # data repo (local only, never committed here)
├─ .git/                   # backup history
├─ mirror/                 # current DSH state mirror
├─ state/                  # logs, per-version metadata (gitignored)
├─ backup.config.json      # local config (gitignored)
├─ version.txt
├─ VERSIONS.md
└─ scripts/
```

The data repository is a **separate** Git repository. This project's `.gitignore` never tracks backup data.

## Command line

All commands run inside the **data repo**:

```powershell
$B = "D:\DSH-Backups"

# backup now
powershell -ExecutionPolicy Bypass -File "$B\scripts\backup.ps1" -Trigger manual

# list versions
powershell -ExecutionPolicy Bypass -File "$B\scripts\restore-version.ps1" -List

# restore (closes DSH!)
powershell -ExecutionPolicy Bypass -File "$B\scripts\restore-version.ps1" v261025.1.002 -Force

# export only
powershell -ExecutionPolicy Bypass -File "$B\scripts\restore-version.ps1" v261025.1.002 -ExtractTo "D:\DSH-restore-261025-1-002"

# verify
powershell -ExecutionPolicy Bypass -File "$B\scripts\verify.ps1" -Deep
```

## Caches are not backed up

The following are intentionally excluded so a simple restart does not create a new version:

- `.dsh\cache`, `.dsh\logs`
- `storages\session_projcache*`
- `storages\cost-meter\` (including `ledger.json`; **cost history is not backed up**)
- `studymate\reach\`
- Electron `Cache`, `Code Cache`, `GPU*`, `logs`, `Local Storage`, `Session Storage`, `Network`, `Shared Dictionary`, `blob_storage`, `WebStorage`, `Preferences`, `LOG*`, `lockfile`, `Cookies*`, `DIPS*`
- `profiles\node_modules` (stale junctions)
- the DSH application itself

Conversation content (`sessions`, `attachments`) and settings **are** backed up.

## Restore safety

- The restore script closes DSH (current session ends).
- The current profile is renamed to `.dsh.pre-restore-<timestamp>` instead of being deleted.
- A restore is **not** executed from the settings page; the plugin only copies a command for you to run in a separate PowerShell window.
- Match the DSH app version of the selected version first (the repository stores `install-info.txt`).
- After a restore, the next backup records the restored state as a new version.

## Privacy and security

- The backup data repository is **local-only**; `push.default=nothing` and a `pre-push` hook block accidental pushes.
- The data repo contains sessions, attachments, and settings; if credential backup is enabled, it also contains **plaintext credentials** (`.credentials.yaml`, `APIKey`). Treat it as sensitive.
- This GitHub repository contains **no** credentials, sessions, profile copy, or backup data.
- Do not upload the data repo to GitHub or a cloud drive.

See [docs/SECURITY.md](docs/SECURITY.md).

## Uninstall

```powershell
# remove the logon watcher installed by setup
powershell -ExecutionPolicy Bypass -File "D:\DSH-Backups\scripts\uninstall-autostart.ps1"

# remove the plugin
dsh plugin --profile desktop remove dsh-quick-backup
```

Delete the data repository only if you no longer need the history.

## Troubleshooting

- Plugin missing in Settings: check `dsh plugin --profile <name> list`, then restart DSH.
- `not ready` in the panel: the path is empty or the folder is not a data repo; run `setup.ps1 -RepoPath <path>` or save the correct path.
- Backup errors: `state\logs\backup.log`, `state\last-run.json`.
- Git authentication is **not** needed for normal use. This tool never pushes.
- Use `verify.ps1 -Deep` for object integrity.

## Development

```powershell
# PowerShell syntax check (Windows PowerShell 5.1)
powershell -File .\scripts\verify.ps1   # after a data repo exists

# plugin self-test
node .\plugin\verify.mjs
```

`test/verify.mjs` uses a temporary fixture and does not touch your DSH data.

## License

MIT. See [LICENSE](LICENSE).
