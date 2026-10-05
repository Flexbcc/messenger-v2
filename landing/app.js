(async () => {
  const versionLabel = document.getElementById('version-label');
  const footerVersion = document.getElementById('footer-version');
  const channelPill = document.getElementById('channel-pill');

  const paths = ['releases/clients/manifest.json', '../releases/clients/manifest.json'];
  let data = null;
  for (const p of paths) {
    try {
      const res = await fetch(p, { cache: 'no-store' });
      if (res.ok) {
        data = await res.json();
        break;
      }
    } catch (_) {}
  }

  if (!data?.products?.messenger) return;

  const m = data.products.messenger;
  const ch = data.channel || m.channel || 'beta';
  const label = `${m.version}+${m.build} (${ch})`;

  if (versionLabel) versionLabel.textContent = m.version;
  if (footerVersion) footerVersion.textContent = label;
  if (channelPill) channelPill.textContent = `канал: ${ch}`;

  const downloadRows = { macos: 'download-macos', android: 'download-android' };
  for (const [platform, rowId] of Object.entries(downloadRows)) {
    const row = document.getElementById(rowId);
    const release = m.platforms?.[platform];
    if (!row || !release?.available || !release.download_url) continue;
    row.classList.add('available');
    const note = row.querySelector('.platform span');
    if (note) note.textContent = `${release.version} beta`;
    const oldAction = row.querySelector('.btn');
    const link = document.createElement('a');
    link.className = 'btn btn-primary';
    link.href = release.download_url;
    link.textContent = platform === 'android' ? 'Скачать APK' : 'Скачать ZIP';
    link.setAttribute('download', '');
    oldAction?.replaceWith(link);
  }
})();

document.querySelectorAll('[data-copy]').forEach((button) => {
  button.addEventListener('click', async () => {
    const target = document.querySelector(button.dataset.copy);
    if (!target) return;
    try {
      await navigator.clipboard.writeText(target.textContent.trim());
      const previous = button.textContent;
      button.textContent = 'Скопировано';
      setTimeout(() => { button.textContent = previous; }, 1600);
    } catch (_) {
      target.focus?.();
    }
  });
});

(async () => {
  const status = document.getElementById('network-status');
  if (!status) return;
  try {
    const [manifest, health] = await Promise.all([
      fetch('/.well-known/ouo-network.json', { cache: 'no-store' }),
      fetch('https://discovery.ouoapp.ru/health', { cache: 'no-store', mode: 'no-cors' }),
    ]);
    if (!manifest.ok || (!health.ok && health.type !== 'opaque')) throw new Error('offline');
    status.innerHTML = '<span class="status-dot ok"></span><span>Публичная сеть доступна</span>';
    status.classList.add('online');
  } catch (_) {
    status.innerHTML = '<span class="status-dot soon"></span><span>Сеть временно недоступна — повторите позже</span>';
  }
})();
