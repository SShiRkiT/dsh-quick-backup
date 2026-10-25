import assert from 'node:assert/strict'
import { existsSync, mkdtempSync, mkdirSync, readFileSync, realpathSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir, homedir } from 'node:os'
import * as path from 'node:path'
import { randomUUID } from 'node:crypto'
import { EventEmitter } from 'node:events'
import vm from 'node:vm'

const fixture = mkdtempSync(path.join(tmpdir(), 'dsh-quick-backup-test-'))
mkdirSync(path.join(fixture, 'scripts'), { recursive: true })
for (const name of ['backup.ps1', 'restore-version.ps1', 'verify.ps1', 'install-autostart.ps1', 'uninstall-autostart.ps1', 'watch-dsh.ps1']) {
  writeFileSync(path.join(fixture, 'scripts', name), '')
}
process.env.DSH_BACKUP_REPO = fixture
process.env.LOCALAPPDATA = path.join(fixture, 'localappdata')

const commands = []
let pending
function spawnMock(command, args) {
  assert.equal(command, 'powershell.exe')
  const program = Buffer.from(args.at(-1), 'base64').toString('utf16le')
  commands.push(program)
  const child = new EventEmitter()
  child.stdout = new EventEmitter(); child.stderr = new EventEmitter()
  if (program.includes("'-List'") || program.includes(' -List')) {
    queueMicrotask(() => {
      child.stdout.emit('data', Buffer.from('Available versions:\n  v261025.1.002  2026-10-25\n  v261025.1.001  2026-10-25\n'))
      child.emit('close', 0)
    })
  } else pending = child
  return child
}

async function main() {
  const source = readFileSync(new URL('../lib/index.js', import.meta.url), 'utf8')
  const body = source.replace(/^import .+\n/gm, '').replace(/^export /gm, '')
  const host = new Function(
    'spawn', 'existsSync', 'readFileSync', 'realpathSync', 'isAbsolute', 'resolve', 'dirname', 'join', 'sep', 'randomUUID', 'homedir', 'mkdirSync', 'writeFileSync',
    body + '\nreturn { apply }'
  )(spawnMock, existsSync, readFileSync, realpathSync, path.isAbsolute, path.resolve, path.dirname, path.join, path.sep, randomUUID, homedir, mkdirSync, writeFileSync)

  let route, rejected
  host.apply({ effect: (f) => f(), webServer: { register: (r) => { route = r } }, connection: { requestRejection: () => rejected } })

  async function request(endpoint, input) {
    let status, value
    const req = {
      method: input === undefined ? 'GET' : 'POST',
      url: '/dsh-quick-backup' + endpoint,
      headers: { 'content-type': 'application/json' },
      async *[Symbol.asyncIterator]() { yield Buffer.from(JSON.stringify(input)) },
    }
    await route.handler(req, { writeHead(code) { status = code }, end(text) { value = JSON.parse(text) } })
    return { status, ...value }
  }

  rejected = 403
  assert.equal((await request('/status')).status, 403)
  rejected = undefined
  assert.equal((await request('/status')).ready, true)
  assert.equal((await request('/status')).configured, true)
  assert.equal((await request('/config')).repo, fixture)
  assert.equal((await request('/config', { repo: 'relative' })).ok, false)
  assert.equal((await request('/config', { repo: fixture })).ok, true)
  assert.equal((await request('/status')).includeCredentials, true)
  assert.equal((await request('/options', { includeCredentials: false })).includeCredentials, false)
  assert.equal((await request('/status')).includeCredentials, false)
  assert.equal((await request('/options', { includeCredentials: true })).includeCredentials, true)
  assert.deepEqual((await request('/versions')).versions, ['v261025.1.002', 'v261025.1.001'])

  assert.equal((await request('/action', { action: 'arbitrary-script' })).ok, false)
  assert.equal((await request('/action', { action: 'restore', confirm: true })).ok, false)
  assert.equal((await request('/action', { action: 'export', version: 'v261025.1.002; exit' })).ok, false)
  assert.equal((await request('/action', { action: 'export', version: 'v261025.1.002', destination: path.join(fixture, 'mirror') })).ok, false)
  assert.equal((await request('/action', { action: 'export', version: 'v261025.1.002', destination: path.join(homedir(), '.dsh', 'new-export') })).ok, false)

  const restore = await request('/action', { action: 'restore-command', version: 'v261025.1.002' })
  assert.equal(restore.ok, true)
  assert.ok(!restore.command.includes('-Force'))

  const backup = await request('/action', { action: 'backup', force: true })
  assert.equal(backup.status, 202)
  assert.match(commands.at(-1), /-Trigger 'manual' -Force/)

  assert.equal((await request('/action', { action: 'verify' })).ok, false)
  pending.stdout.emit('data', Buffer.from('No changes; skipped.'))
  pending.emit('close', 0)
  await new Promise((resolve) => setImmediate(resolve))
  assert.equal((await request('/job?id=' + backup.job.id)).job.ok, true)

  const enabled = await request('/action', { action: 'install-autostart' })
  assert.equal(enabled.status, 202)
  assert.match(commands.at(-1), /-StartNow/)
  pending.emit('close', 0)
  await new Promise((resolve) => setImmediate(resolve))

  let client, section
  const React = {
    createElement: (type, props, ...children) => ({ type, props, children }),
    useState: (value) => [value, () => {}],
    useRef: (value) => ({ current: value }),
    useCallback: (f) => f,
    useEffect: () => {},
  }
  vm.runInNewContext(readFileSync(new URL('../lib/client.js', import.meta.url), 'utf8'), {
    window: { __ModuleLoader__: { load(definition) { client = definition.factory((id) => id === 'react' ? React : { Button: 'button' }) } } },
  })
  assert.equal(typeof client.apply, 'function')
  client.apply({ effect: (f) => f(), slots: { inject: (_, f) => f(), register: (options, Component) => { section = options; assert.ok(Component()); return () => {} } } })
  assert.equal(section.label(), '备份')
  console.log('PASS: plugin factory, settings section, host auth, version list, allow-list, guarded export, job flow, backup/autostart flags. No real backup was executed.')
}

try {
  await main()
} finally {
  rmSync(fixture, { recursive: true, force: true })
}
