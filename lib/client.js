window.__ModuleLoader__.load({
  id: 'dsh-quick-backup',
  factory: (require) => {
    const module = { exports: {} }
    const exports = module.exports
    const React = require('react')
    const primitives = require('@deepseek-ai/dsh-client-ui-primitives')
    const { Button } = primitives
    const { createElement: h, useCallback, useEffect, useRef, useState } = React

    const NS = 'dsh-quick-backup'
    const CSS = `
      .dsh-backup-section{max-width:760px;color:var(--dsw-alias-label-primary);display:flex;flex-direction:column;gap:14px}
      .dsh-backup-title{margin:0;font-size:18px;font-weight:600;line-height:26px}
      .dsh-backup-muted{margin:0;color:var(--dsw-alias-label-secondary);font-size:13px;line-height:20px}
      .dsh-backup-row{display:flex;flex-wrap:wrap;align-items:center;justify-content:space-between;gap:10px 18px;padding:14px 0;border-bottom:.5px solid var(--dsw-alias-border-l2)}
      .dsh-backup-row:last-child{border-bottom:0}
      .dsh-backup-row>div:first-child{flex:1;min-width:220px}
      .dsh-backup-label{font-size:14px;line-height:20px}
      .dsh-backup-detail{margin-top:3px;color:var(--dsw-alias-label-secondary);font-size:12px;line-height:18px;word-break:break-word}
      .dsh-backup-controls{display:flex;flex-wrap:wrap;align-items:center;gap:8px}
      .dsh-backup-select,.dsh-backup-input{height:32px;min-width:190px;padding:0 8px;border:1px solid var(--dsw-alias-border-l2);border-radius:4px;background:var(--dsw-alias-fill-tertiary);color:var(--dsw-alias-label-primary)}
      .dsh-backup-output{max-height:260px;overflow:auto;margin:0;padding:12px;border:1px solid var(--dsw-alias-border-l2);border-radius:4px;background:var(--dsw-alias-fill-tertiary);font:12px/18px ui-monospace,SFMono-Regular,Consolas,monospace;white-space:pre-wrap;word-break:break-word}
    `
    const style = () => {
      if (document.querySelector('style[data-dsh-backup]')) return
      const el = document.createElement('style'); el.dataset.dshBackup = '1'; el.textContent = CSS; document.head.appendChild(el)
    }
    const call = async (path, init) => {
      try { const response = await fetch(path, init); return await response.json() }
      catch (error) { return { ok: false, error: error?.message || '无法连接备份服务。' } }
    }
    const post = (body) => call('dsh-quick-backup/action', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(body) })

    function BackupSection() {
      const [status, setStatus] = useState(null)
      const [repoPath, setRepoPath] = useState('')
      const [includeCredentials, setIncludeCredentials] = useState(false)
      const [versions, setVersions] = useState([])
      const [selected, setSelected] = useState('')
      const [destination, setDestination] = useState('')
      const [busy, setBusy] = useState(false)
      const [output, setOutput] = useState('')
      const lock = useRef(false)
      const [jobId, setJobId] = useState(null)
      const refresh = useCallback(async () => {
        const [s, v] = await Promise.all([call('dsh-quick-backup/status'), call('dsh-quick-backup/versions')])
        if (s.ok) {
          setStatus(s)
          setRepoPath(s.repo || '')
          setIncludeCredentials(s.includeCredentials === true)
          if (s.activeJob) { setJobId(s.activeJob.id); setBusy(true); lock.current = true }
        } else setOutput(s.error || '读取备份状态失败。')
        if (v.ok) {
          setVersions(v.versions)
          setSelected((old) => old && v.versions.includes(old) ? old : v.versions[0] || '')
        } else setOutput(v.error || '读取版本失败。')
      }, [])
      useEffect(() => { style(); refresh() }, [refresh])
      useEffect(() => {
        if (!jobId) return
        let disposed = false
        let timer
        const poll = async () => {
          const result = await call('dsh-quick-backup/job?id=' + encodeURIComponent(jobId))
          if (disposed) return
          if (!result.ok || !result.job.running) {
            setOutput(result.job ? `${result.job.ok ? '完成' : '失败'}（退出码 ${result.job.code}）\n${result.job.output}` : result.error)
            setBusy(false); lock.current = false; setJobId(null); refresh()
          } else {
            setOutput(result.job.output || '操作正在执行，可离开设置页，稍后回来查看。')
            timer = setTimeout(poll, 1000)
          }
        }
        poll()
        return () => { disposed = true; clearTimeout(timer) }
      }, [jobId, refresh])
      const run = async (body, label) => {
        if (lock.current) return
        lock.current = true; setBusy(true); setOutput(`${label}...`)
        const result = await post(body)
        if (result.ok && result.job) setJobId(result.job.id)
        else { setOutput(result.error || '操作失败。'); setBusy(false); lock.current = false }
      }
      const saveRepo = async () => {
        if (busy) return
        setBusy(true); setOutput('正在保存备份路径...')
        const result = await call('dsh-quick-backup/config', {
          method: 'POST',
          headers: { 'content-type': 'application/json' },
          body: JSON.stringify({ repo: repoPath.trim() }),
        })
        if (result.ok) {
          setOutput(`已保存：${result.repo || '(未设置)'}${result.ready ? '' : '\n该目录还没有备份脚本，请先在该目录运行 setup.ps1。'}`)
          await refresh()
        } else setOutput(result.error || '保存失败。')
        setBusy(false)
      }
      const saveCredentials = async () => {
        if (busy) return
        setBusy(true); setOutput('正在保存凭据选项...')
        const result = await call('dsh-quick-backup/options', {
          method: 'POST',
          headers: { 'content-type': 'application/json' },
          body: JSON.stringify({ includeCredentials }),
        })
        if (result.ok) {
          setOutput(result.includeCredentials
            ? '后续版本将备份 .credentials.yaml 与 APIKey。'
            : '后续版本将排除 .credentials.yaml 与 APIKey。注意：旧 Git 历史不会被自动清理。')
          await refresh()
        } else setOutput(result.error || '保存失败。')
        setBusy(false)
      }
      const restore = async () => {
        if (!selected) return setOutput('请先选择版本。')
        const result = await post({ action: 'restore-command', version: selected })
        if (!result.ok) return setOutput(result.error)
        setOutput(`先停用自动备份并关闭 DSH；在独立 PowerShell 窗口中运行以下命令。请先确认 DSH 程序版本与备份兼容。\n\n${result.command}`)
        try { await navigator.clipboard.writeText(result.command) } catch { /* command remains selectable */ }
      }
      const exportVersion = () => {
        if (!selected) return setOutput('请先选择版本。')
        if (!destination.trim()) return setOutput('请填写一个新的、独立的导出目录。')
        run({ action: 'export', version: selected, destination: destination.trim() }, `正在导出 ${selected}`)
      }
      const last = status?.lastRun
      return h('div', { className: 'dsh-backup-section' }, [
        h('h2', { className: 'dsh-backup-title', key: 'title' }, '备份'),
        h('p', { className: 'dsh-backup-muted', key: 'intro' }, '本地增量备份。备份仓库路径在下方设置；数据不会上传到 GitHub、云端或任何远程地址。'),
        h('div', { className: 'dsh-backup-row', key: 'status' }, [
          h('div', null, [h('div', { className: 'dsh-backup-label' }, '当前状态'), h('div', { className: 'dsh-backup-detail' }, last ? `${last.status || '-'} · ${last.version || '无新版本'} · ${last.finishedAt || ''}` : (!status?.configured ? '尚未设置备份路径' : (!status.ready ? '路径未就绪：请先在该目录运行 setup.ps1' : '尚未读取状态')))]),
          h('div', { className: 'dsh-backup-controls' }, h(Button, { variant: 'outline', size: 'sm', disabled: busy, onClick: refresh }, '刷新')),
        ]),
        h('div', { className: 'dsh-backup-row', key: 'repo' }, [
          h('div', null, [h('div', { className: 'dsh-backup-label' }, '备份仓库路径'), h('div', { className: 'dsh-backup-detail' }, '填写本地数据仓库目录（由 setup.ps1 创建）；留空表示未配置。')]),
          h('div', { className: 'dsh-backup-controls' }, [h('input', { className: 'dsh-backup-input', value: repoPath, disabled: busy, onChange: (event) => setRepoPath(event.target.value), placeholder: 'D:\\DSH-Backups', 'aria-label': '备份仓库路径' }), h(Button, { variant: 'outline', size: 'sm', disabled: busy, onClick: saveRepo }, '保存路径')]),
        ]),
        h('div', { className: 'dsh-backup-row', key: 'credentials' }, [
          h('div', null, [h('div', { className: 'dsh-backup-label' }, '备份凭据与 APIKey'), h('div', { className: 'dsh-backup-detail' }, '默认关闭。开启后，后续版本会备份 .credentials.yaml 和 APIKey；已有 Git 历史不会自动删除。')]),
          h('div', { className: 'dsh-backup-controls' }, [
            h('label', { className: 'dsh-backup-label', style: { display: 'flex', alignItems: 'center', gap: '6px' } }, [
              h('input', { type: 'checkbox', checked: includeCredentials, disabled: busy || !status?.ready, onChange: (event) => setIncludeCredentials(event.target.checked) }),
              includeCredentials ? '开启' : '关闭',
            ]),
            h(Button, { variant: 'outline', size: 'sm', disabled: busy || !status?.ready, onClick: saveCredentials }, '保存设置'),
          ]),
        ]),
        h('div', { className: 'dsh-backup-row', key: 'backup' }, [
          h('div', null, [h('div', { className: 'dsh-backup-label' }, '立即备份'), h('div', { className: 'dsh-backup-detail' }, '使用现有脚本和缓存排除规则创建增量版本；无变化时不创建版本，忽略间隔也不改变此规则。')]),
          h('div', { className: 'dsh-backup-controls' }, [h(Button, { variant: 'outline', size: 'sm', disabled: busy || !status?.ready, onClick: () => run({ action: 'backup' }, '正在备份') }, '备份'), h(Button, { variant: 'outline', size: 'sm', disabled: busy || !status?.ready, onClick: () => run({ action: 'backup', force: true }, '正在备份（忽略间隔）') }, '忽略间隔备份')]),
        ]),
        h('div', { className: 'dsh-backup-row', key: 'verify' }, [
          h('div', null, [h('div', { className: 'dsh-backup-label' }, '仓库校验'), h('div', { className: 'dsh-backup-detail' }, '检查本地仓库、镜像、版本索引和 Git 对象完整性。')]),
          h('div', { className: 'dsh-backup-controls' }, [h(Button, { variant: 'outline', size: 'sm', disabled: busy || !status?.ready, onClick: () => run({ action: 'verify' }, '正在校验') }, '校验'), h(Button, { variant: 'outline', size: 'sm', disabled: busy || !status?.ready, onClick: () => run({ action: 'verify', deep: true }, '正在深度校验') }, '深度校验')]),
        ]),
        h('div', { className: 'dsh-backup-row', key: 'versions' }, [
          h('div', null, [h('div', { className: 'dsh-backup-label' }, '历史版本'), h('div', { className: 'dsh-backup-detail' }, versions.length ? `已发现 ${versions.length} 个版本` : '暂无版本')]),
          h('div', { className: 'dsh-backup-controls' }, [h('select', { className: 'dsh-backup-select', value: selected, disabled: busy || !versions.length, onChange: (event) => setSelected(event.target.value), 'aria-label': '选择版本' }, versions.map((v) => h('option', { key: v, value: v }, v))), h(Button, { variant: 'outline', size: 'sm', disabled: busy || !selected, onClick: restore }, '复制恢复命令'), h(Button, { variant: 'outline', size: 'sm', disabled: busy || !selected, onClick: exportVersion }, '导出')]),
        ]),
        h('div', { className: 'dsh-backup-row', key: 'destination' }, [
          h('div', null, [h('div', { className: 'dsh-backup-label' }, '导出目录'), h('div', { className: 'dsh-backup-detail' }, '请填写本地磁盘上尚不存在的新目录；导出可能包含凭据，请自行保管。')]),
          h('input', { className: 'dsh-backup-input', value: destination, onChange: (event) => setDestination(event.target.value), placeholder: 'D:\\Backups\\restore-copy', 'aria-label': '导出目录' }),
        ]),
        h('div', { className: 'dsh-backup-row', key: 'auto' }, [
          h('div', null, [h('div', { className: 'dsh-backup-label' }, '自动备份'), h('div', { className: 'dsh-backup-detail' }, '登录时启动 watcher；关闭只会移除自动启动，不删除历史版本。')]),
          h('div', { className: 'dsh-backup-controls' }, [h(Button, { variant: 'outline', size: 'sm', disabled: busy || !status?.ready, onClick: () => run({ action: 'install-autostart' }, '正在启用自动备份') }, '启用'), h(Button, { variant: 'outline', size: 'sm', disabled: busy || !status?.ready, onClick: () => run({ action: 'uninstall-autostart' }, '正在停用自动备份') }, '停用')]),
        ]),
        h('div', { className: 'dsh-backup-row', key: 'diagnostic' }, [
          h('div', null, [h('div', { className: 'dsh-backup-label' }, 'Watcher 诊断'), h('div', { className: 'dsh-backup-detail' }, '执行一次不备份的 watcher 检查。')]),
          h(Button, { variant: 'outline', size: 'sm', disabled: busy || !status?.ready, onClick: () => run({ action: 'watch-once' }, '正在诊断 watcher') }, '运行诊断'),
        ]),
        output ? h('pre', { className: 'dsh-backup-output', key: 'output', role: 'status' }, output) : null,
      ])
    }

    function apply(ctx) {
      ctx.effect(() => {
        const dispose = ctx.slots.inject('settings.section', () => ctx.slots.register({ name: 'settings.section', id: NS, order: 6, label: () => '备份', inject: () => ({}) }, BackupSection))
        return () => dispose()
      }, 'dsh-quick-backup: settings section')
    }
    exports.apply = apply
    exports.inject = ['slots']
    return module.exports
  },
})
