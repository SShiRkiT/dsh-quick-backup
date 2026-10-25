# Versioning

Versions are annotated Git tags in the **local data repository**.

## Format

```text
vYYMMDD.E.SSS
```

- `YYMMDD`: date the current **environment baseline** was created, Asia/Shanghai.
- `E`: environment change sequence **within that date**. Starts at 1 and resets on a new date.
- `SSS`: minor change sequence **within that baseline**. Starts at 001 and resets when `E` changes.

The date is **not** the date of each backup. A minor update on a later day keeps the baseline date.

## What increments `E` (major)

- DSH application version / `app.asar` hash / install identity changed
- plugin set changed:
  - `profiles\desktop\package.json`
  - `pnpm-lock.yaml`
  - `pnpm-workspace.yaml`
  - anything under `profiles\desktop\node_modules\`
  - the same paths under `profiles\web\` if present
- `dsh-ops\` or `dsh-runtimes\` changed

When `E` increments, `SSS` becomes `001`.

## What increments `SSS` (minor)

- new or updated conversation/session files
- attachments
- settings (`cordis.patch.yml`, `settings.yaml.imported`)
- credentials
- `storages\workspace.json`
- workflow scripts/docs in the data repo

## Examples

| Event | Version |
| --- | --- |
| baseline on 2026-10-25 | `v261025.1.001` |
| new conversation | `v261025.1.002` |
| plugin install/update, same day | `v261025.2.001` |
| another plugin update, same day | `v261025.3.001` |
| DSH upgrade next day | `v261026.1.001` |
| conversation next day | `v261026.1.002` |
| settings change two days later | `v261026.1.003` |

If a major and minor change arrive in the same backup run, it is recorded as **one major** version (`E+1`, `SSS=001`).

## No-op behavior

`backup.ps1` runs `git add -A` and creates a version only when tracked files changed. Caches are excluded from the data repo entirely, so a simple DSH restart normally does not create a version.

## Where the data lives

Inside the **data repository** (not this GitHub repo):

- `version.txt` — current version
- `VERSIONS.md` — human-readable index (regenerated)
- `state\versions\vYYMMDD.E.SSS.json` — machine metadata (commit, kind, counts, sessions)
- `state\versions\vYYMMDD.E.SSS.changes.txt` — changed paths
- `state\last-run.json` — last run status
- `state\logs\` — logs

`state\` is gitignored.

## Inspecting history

```powershell
$B = "$env:USERPROFILE\DSH-Backups"
git -C $B log --oneline --decorate --graph
git -C $B tag -n
git -C $B show v261025.1.002 --stat
```
