# Installation details

## Path rules

- **The backup path has no default.** `setup.ps1` requires `-RepoPath`.
- The plugin also starts with an **empty** path; set it in **Settings → Backup → Backup repository path**.
- After `setup.ps1`, the path is stored in `%LOCALAPPDATA%\dsh-quick-backup\config.json`, so the plugin picks it up automatically.
- `DSH_BACKUP_REPO` overrides both the config file and the plugin field.

## Fresh DSH client

1. Confirm DSH has been started at least once, so `%USERPROFILE%\.dsh` exists.
2. Clone/copy this project somewhere permanent (not inside the future data repo).
3. Create the data repo at an explicit path:

   ```powershell
   powershell -ExecutionPolicy Bypass -File .\setup.ps1 -RepoPath "D:\DSH-Backups" -EnableAutostart
   ```

   Add `-SkipCredentials` if you do not want `.credentials.yaml` / `APIKey` in the backup.

4. Install the plugin from **DSH Settings → Plugins** by entering:

   ```text
   https://github.com/SShiRkiT/dsh-quick-backup
   ```

   The repository root is the plugin package (`package.json`, `lib/`, `cordis.patch.yml`), so no `.tgz` is needed. If the repository is private, complete GitHub authentication first.

5. Restart DSH → **Settings → Backup**.

6. If the path is not already filled in, type it into **Backup repository path** and click **Save path**. The panel becomes ready when the folder contains `scripts\backup.ps1`.

## Custom paths

```powershell
.\setup.ps1 `
  -RepoPath "D:\DSH-Backups" `
  -DshProfile "$env:USERPROFILE\.dsh" `
  -InstallRoot "D:\DSH\Desktop" `
  -ApiKeyDir "D:\DSH\APIKey" `
  -UserDataDir "$env:APPDATA\@deepseek-ai\dsh-desktop"
```

`InstallRoot` is only used for version metadata. If omitted, the script tries:

1. the running `DeepSeek​ Harness.exe` process path
2. `%LOCALAPPDATA%\Programs\@deepseek-ai\dsh-desktop`
3. `%LOCALAPPDATA%\Programs\DeepSeek Harness`
4. `%ProgramFiles%\DeepSeek Harness`

If none match, pass `-InstallRoot` explicitly.

## Plugin discovery

The plugin finds the data repository through:

1. `DSH_BACKUP_REPO` environment variable
2. `%LOCALAPPDATA%\dsh-quick-backup\config.json` (`repo` field), written by `setup.ps1` or the plugin's **Save path** button
3. **No default** — if both are empty, the panel shows “not configured” and asks for a path

The path field accepts an absolute local path such as `D:\DSH-Backups`. It does not need to exist when you type it, but it becomes usable only after `setup.ps1` has initialized the folder.

## Credential backup switch

- Default: **enabled** — `.credentials.yaml` and `APIKey` are backed up.
- Disable with `setup.ps1 -SkipCredentials` or the checkbox **Back up credentials and APIKey** in the panel.
- Disabling affects **future versions only**. Old Git history is not rewritten; rebuild the data repository or clean its history if you need to remove old credential copies.

## Automatic backup

`setup.ps1 -EnableAutostart` runs `install-autostart.ps1` in the data repo. It tries a Scheduled Task first; if Windows denies task creation (`Access is denied`), it falls back to a Startup-folder shortcut:

```text
%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\DSH Auto Backup.lnk
  -> state\start-watcher.vbs
  -> powershell.exe -File ...\scripts\watch-dsh.ps1
```

The watcher polls the DSH main process (not renderer/tool subprocesses) and triggers a backup after a new launch.

## Updating the workflow scripts

After pulling a new version of this project:

```powershell
powershell -ExecutionPolicy Bypass -File .\setup.ps1 -RepoPath "D:\DSH-Backups" -Force -SkipInitial
```

This overwrites the scripts in the data repo. The change is committed as a minor version on the next backup.

## Uninstall

```powershell
powershell -ExecutionPolicy Bypass -File "D:\DSH-Backups\scripts\uninstall-autostart.ps1"
dsh plugin --profile desktop remove dsh-quick-backup
```

Delete the data repo only if you no longer want history.
