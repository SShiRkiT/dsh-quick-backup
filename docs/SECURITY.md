# Security

> [!WARNING]
> **The local data repository stores `.credentials.yaml` and `APIKey` in plaintext, and Git history never forgets.**
> If you sync the backup folder to cloud storage, a network drive, or any other sync service, or forward it to another person, any resulting credential or privacy leak is **your responsibility**. The author assumes **no liability**.

## Two repositories, very different trust levels

| Repository | Contents | GitHub? |
| --- | --- | --- |
| `dsh-quick-backup` (this project) | plugin, scripts, docs, setup | Yes — no personal data |
| `<your chosen backup path>` (data) | mirror of `.dsh`, sessions, credentials, APIKey, history | **Never** |

The data repository is created by `setup.ps1 -RepoPath <path>` at a separate path. It is not a submodule, not a remote, and not tracked here.

## What the data repo contains

- `.dsh` profile: plugins, settings, sessions, attachments, `storages`, `.credentials.yaml`
- Electron user data (caches and cookies excluded)
- `APIKey` directory if configured
- install identity metadata

**Credentials are plaintext** in the data repo. Treat the whole folder as sensitive.

## Credential backup switch

- `.credentials.yaml` and `APIKey` are backed up **by default**.
- Disable with `setup.ps1 -SkipCredentials` or the **Back up credentials and APIKey** checkbox in the panel.
- The switch affects **future versions only**. Git history is never rewritten automatically; old copies remain until you rebuild the data repository or clean its history.

## Local-only controls

- no remote is configured by `setup.ps1`
- `git config push.default nothing`
- `.git/hooks/pre-push` blocks all pushes with exit code 1
- `.gitignore` in the data repo excludes `state\`, `backup.config.json`, and restore backups
- `install-info.txt` stores only version/hash fields, not the install path

These are accident guards, not encryption. If an attacker can read your disk, they can read the backups.

## Publishing checklist for this project

Before making this repository public:

1. `git status` — only source/docs listed.
2. No `mirror/`, `state/`, `backup.config.json`, `version.txt`, `VERSIONS.md`, or `*.tgz`.
3. Search for personal paths and secrets:

   ```powershell
   rg -n "Users\\|AppData\\|D:\\|sk-|ghp_|github_pat_|session-" .
   ```

4. Check that no session IDs, credentials, or API keys appear.
5. Do not add the data repository as a remote.

## Restore safety

- The panel does not perform a live restore; it only copies a command.
- Close DSH before running a restore command.
- Verify the target DSH version matches `install-info.txt` in the selected version.
- The old profile is renamed to `.dsh.pre-restore-<timestamp>`, not deleted.
