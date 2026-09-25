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
})();
