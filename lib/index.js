import { spawn } from 'node:child_process'
import { existsSync, mkdirSync, readFileSync, realpathSync, writeFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { isAbsolute, resolve, dirname, join, sep } from 'node:path'
import { randomUUID } from 'node:crypto'

export const name = 'dsh-quick-backup'
export const inject = ['webServer', 'connection']

const expand = (value) => String(value || '').replace(/%([^%]+)%/g, (_, key) => process.env[key] || '')
const readText = (path) => { try { return readFileSync(path, 'utf8').replace(/^\uFEFF/, '').trim() } catch { return '' } }
const readJson = (path) => { try { return JSON.parse(readFileSync(path, 'utf8').replace(/^\uFEFF/, '')) } catch { return null } }
const configDir = join(process.env.LOCALAPPDATA || process.env.APPDATA || homedir(), 'dsh-quick-backup')
const configPath = join(configDir, 'config.json')
const versionPattern = /^(?:v\d{6}\.\d+\.\d{3,}|v\d+)$/
const jobs = new Map()
let activeJob

function readConfig() {
  return readJson(configPath) || {}
}

function writeConfig(config) {
  mkdirSync(configDir, { recursive: true })
  writeFileSync(configPath, JSON.stringify(config, null, 2), 'utf8')
}

function currentRepo() {
  const fromEnv = expand(process.env.DSH_BACKUP_REPO || '').trim()
  if (fromEnv) return resolve(fromEnv)
  const fromConfig = expand(readConfig().repo || '').trim()
  return fromConfig ? resolve(fromConfig) : ''
}

function pathsFor(repo = currentRepo()) {
  const backupConfig = repo ? (readJson(join(repo, 'backup.config.json')) || {}) : {}
  const profile = resolve(expand(backupConfig.dshProfile || join(homedir(), '.dsh')))
  const installRoot = backupConfig.dshInstallRoot ? resolve(expand(backupConfig.dshInstallRoot)) : ''
  const apiKeyDir = backupConfig.apiKeyDir ? resolve(expand(backupConfig.apiKeyDir)) : ''
  const userDataDir = backupConfig.userDataDir
    ? resolve(expand(backupConfig.userDataDir))
    : (process.env.APPDATA ? resolve(process.env.APPDATA, '@deepseek-ai/dsh-desktop') : '')
  const includeCredentials = backupConfig.includeCredentials === true
  return {
    repo,
    scripts: repo ? join(repo, 'scripts') : '',
    profile,
    installRoot,
    apiKeyDir,
    userDataDir,
    includeCredentials,
    protectedPaths: [repo, profile, installRoot, apiKeyDir, userDataDir].filter(Boolean),
  }
}

function isReady(paths) {
  return !!paths.repo && existsSync(join(paths.scripts, 'backup.ps1'))
}

function readLastRun(paths) {
  if (!paths.repo) return null
  try { return JSON.parse(readText(join(paths.repo, 'state/last-run.json'))) } catch { return null }
}

const quote = (value) => "'" + String(value).replaceAll("'", "''") + "'"
const restoreCommand = (version, paths) => `powershell.exe -NoProfile -ExecutionPolicy Bypass -File "${join(paths.scripts, 'restore-version.ps1')}" ${version}`
const json = (res, status, value) => {
  res.writeHead(status, { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' })
  res.end(JSON.stringify(value))
}

// PowerShell literals are escaped before encoding. No caller-supplied executable or script.
function run(paths, file, args = [], timeoutMs = 900000) {
  return new Promise((done) => {
    if (!paths.repo) return done({ code: 1, output: '请先在设置中填写备份仓库路径。' })
    const scriptPath = join(paths.scripts, file)
    if (!existsSync(scriptPath)) return done({ code: 1, output: `找不到备份脚本：${scriptPath}` })
    const program = `[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false); $global:LASTEXITCODE = 0; try { & { & ${quote(scriptPath)} ${args.map((arg) => arg.startsWith('-') ? arg : quote(arg)).join(' ')} } *>&1 | Out-String -Width 240 | Write-Output; exit $LASTEXITCODE } catch { Write-Output $_; exit 1 }`
    const child = spawn('powershell.exe', ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', Buffer.from(program, 'utf16le').toString('base64')], { cwd: paths.repo, windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'] })
    let output = '', finished = false
    let timer
    const finish = (result) => {
      if (finished) return
      finished = true
      clearTimeout(timer)
      done(result)
    }
    const append = (data) => { output = (output + data.toString('utf8')).slice(-131072) }
    child.stdout.on('data', append)
    child.stderr.on('data', append)
    child.once('error', (error) => finish({ code: 1, output: error.message }))
    child.once('close', (code) => finish({ code: code ?? 1, output }))
    timer = setTimeout(() => {
      child.kill()
      finish({ code: 124, output: `${output}\n命令超过 15 分钟，已停止。` })
    }, timeoutMs)
  })
}

function canonical(path) {
  const tail = []
  let parent = resolve(path)
  while (!existsSync(parent)) {
    const next = dirname(parent)
    if (next === parent) throw new Error('路径所在磁盘不存在。')
    tail.unshift(parent.slice(next.length).replace(/^[\\/]+/, ''))
    parent = next
  }
  return resolve(realpathSync(parent), ...tail)
}

function overlaps(a, b) {
  a = resolve(a).toLowerCase().replace(/[\\/]+$/, '')
  b = resolve(b).toLowerCase().replace(/[\\/]+$/, '')
  return a === b || a.startsWith(b + sep) || b.startsWith(a + sep)
}

function exportTarget(value, paths) {
  if (!paths.repo) throw new Error('请先在设置中填写备份仓库路径。')
  if (typeof value !== 'string' || !isAbsolute(value) || !/^[a-z]:[\\/]/i.test(value) || /[\u0000-\u001f"<>|?*]/.test(value) || value.slice(2).includes(':')) throw new Error('请填写本地磁盘上的绝对路径，例如 D:\\Backups\\restore-copy。')
  if (existsSync(value)) throw new Error('导出目录已存在，请选择一个全新的目录。')
  const target = canonical(value)
  if (paths.protectedPaths.some((path) => overlaps(target, canonical(path)))) throw new Error('导出目录不能与备份仓库、DSH 运行数据或安装目录重叠。')
  return target
}

async function versions() {
  const paths = pathsFor()
  if (!isReady(paths)) return []
  const result = await run(paths, 'restore-version.ps1', ['-List'])
  if (result.code !== 0) throw new Error(result.output)
  return [...new Set([...result.output.matchAll(/^\s+(v\d{6}\.\d+\.\d{3,}|v\d+)\s+/gm)].map((match) => match[1]))]
}

function validateRepo(value) {
  if (typeof value !== 'string') throw new Error('路径必须是字符串。')
  const trimmed = value.trim()
  if (!trimmed) return ''
  if (trimmed.length > 500 || !isAbsolute(trimmed) || !/^[a-z]:[\\/]/i.test(trimmed) || /[\u0000-\u001f"<>|?*]/.test(trimmed) || trimmed.slice(2).includes(':')) {
    throw new Error('请填写本地磁盘上的绝对路径，例如 D:\\DSH-Backups。')
  }
  return resolve(trimmed)
}

function startJob(action, input, paths) {
  if (activeJob) throw new Error('已有操作正在执行，请等待完成。')
  if (!paths.repo) throw new Error('请先在设置中填写备份仓库路径。')
  let file, args = []
  switch (action) {
    case 'backup': file = 'backup.ps1'; args = ['-Trigger', 'manual', ...(input.force === true ? ['-Force'] : [])]; break
    case 'verify': file = 'verify.ps1'; args = input.deep === true ? ['-Deep'] : []; break
    case 'install-autostart': file = 'install-autostart.ps1'; args = ['-StartNow']; break
    case 'uninstall-autostart': file = 'uninstall-autostart.ps1'; break
    case 'watch-once': file = 'watch-dsh.ps1'; args = ['-Once', '-NoBackup']; break
    case 'export': file = 'restore-version.ps1'; args = [input.version, '-ExtractTo', exportTarget(input.destination, paths)]; break
    default: throw new Error('不支持的操作。')
  }
  const job = { id: randomUUID(), action, running: true, startedAt: new Date().toISOString(), output: '' }
  activeJob = job.id
  jobs.set(job.id, job)
  void run(paths, file, args).then((result) => {
    Object.assign(job, result, { running: false, ok: result.code === 0, finishedAt: new Date().toISOString() })
    activeJob = undefined
    while (jobs.size > 10) jobs.delete(jobs.keys().next().value)
  })
  return job
}

async function readBody(req) {
  let body = ''
  for await (const chunk of req) {
    body += chunk.toString()
    if (body.length > 16384) throw new Error('请求过大。')
  }
  return JSON.parse(body || '{}')
}

export function apply(ctx) {
  ctx.effect(() => ctx.webServer.register({
    kind: 'prefix', path: '/dsh-quick-backup',
    handler: async (req, res) => {
      const rejection = ctx.connection.requestRejection(req)
      if (rejection !== undefined) return json(res, rejection, { ok: false, error: '未授权请求。' })
      try {
        const url = new URL(req.url || '/', 'http://localhost')
        const endpoint = url.pathname.slice(url.pathname.indexOf('/dsh-quick-backup') + '/dsh-quick-backup'.length)
        const paths = pathsFor()

        if (req.method === 'GET' && endpoint === '/status') {
          return json(res, 200, {
            ok: true,
            repo: paths.repo,
            configured: !!paths.repo,
            ready: isReady(paths),
            includeCredentials: paths.includeCredentials,
            activeJob: jobs.get(activeJob) || null,
            lastRun: readLastRun(paths),
            version: paths.repo ? readText(join(paths.repo, 'version.txt')) : '',
          })
        }
        if (req.method === 'GET' && endpoint === '/config') {
          return json(res, 200, { ok: true, repo: paths.repo, configured: !!paths.repo, ready: isReady(paths), includeCredentials: paths.includeCredentials })
        }
        if (req.method === 'GET' && endpoint === '/versions') {
          return json(res, 200, { ok: true, versions: await versions() })
        }
        if (req.method === 'GET' && endpoint === '/job') {
          const job = jobs.get(url.searchParams.get('id'))
          return json(res, job ? 200 : 404, job ? { ok: true, job } : { ok: false, error: '任务已过期，请刷新状态。' })
        }
        if (req.method === 'POST' && endpoint === '/config') {
          if (!String(req.headers['content-type'] || '').startsWith('application/json')) return json(res, 415, { ok: false, error: '需要 JSON 请求。' })
          const input = await readBody(req)
          const config = readConfig()
          config.schemaVersion = config.schemaVersion || 1
          config.repo = validateRepo(input.repo)
          writeConfig(config)
          const next = pathsFor()
          return json(res, 200, { ok: true, repo: next.repo, configured: !!next.repo, ready: isReady(next) })
        }
        if (req.method === 'POST' && endpoint === '/options') {
          if (!String(req.headers['content-type'] || '').startsWith('application/json')) return json(res, 415, { ok: false, error: '需要 JSON 请求。' })
          if (!paths.repo) throw new Error('请先在设置中填写备份仓库路径。')
          const input = await readBody(req)
          if (typeof input.includeCredentials !== 'boolean') throw new Error('includeCredentials 必须是布尔值。')
          const backupConfigPath = join(paths.repo, 'backup.config.json')
          const backupConfig = readJson(backupConfigPath) || { schemaVersion: 1 }
          backupConfig.includeCredentials = input.includeCredentials
          writeFileSync(backupConfigPath, JSON.stringify(backupConfig, null, 2), 'utf8')
          const next = pathsFor()
          return json(res, 200, { ok: true, includeCredentials: next.includeCredentials })
        }
        if (req.method === 'POST' && endpoint === '/action') {
          if (!String(req.headers['content-type'] || '').startsWith('application/json')) return json(res, 415, { ok: false, error: '需要 JSON 请求。' })
          const input = await readBody(req)
          if (!input || typeof input !== 'object' || Array.isArray(input)) throw new Error('请求格式错误。')
          if (input.action === 'restore-command' || input.action === 'export') {
            if (!paths.repo) throw new Error('请先在设置中填写备份仓库路径。')
            if (typeof input.version !== 'string' || !versionPattern.test(input.version) || !(await versions()).includes(input.version)) throw new Error('请选择仓库中已有的有效版本。')
            if (input.action === 'restore-command') return json(res, 200, { ok: true, command: restoreCommand(input.version, paths) })
          }
          return json(res, 202, { ok: true, job: startJob(input.action, input, paths) })
        }
        return json(res, 404, { ok: false, error: '找不到接口。' })
      } catch (error) {
        return json(res, 400, { ok: false, error: error.message || String(error) })
      }
    },
  }), 'dsh-quick-backup: routes')
}
