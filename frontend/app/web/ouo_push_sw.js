self.addEventListener('push', (event) => {
  let data = {};
  try {
    data = event.data ? event.data.json() : {};
  } catch (_) {}
  const isCall = data.type === 'incoming_call';
  event.waitUntil(self.registration.showNotification(
    isCall ? 'Входящий звонок' : 'Новое сообщение',
    {
      body: isCall ? 'Откройте приложение, чтобы ответить' : 'Откройте приложение для просмотра',
      icon: '../icons/Icon-192.png',
      badge: '../icons/Icon-192.png',
      tag: isCall ? `call-${data.call_id || 'new'}` : 'new-message',
      renotify: true,
      data: {url: '../'},
    }
  ));
});

self.addEventListener('notificationclick', (event) => {
  event.notification.close();
  event.waitUntil((async () => {
    const target = new URL(event.notification.data?.url || '../', self.location.href).href;
    const windows = await clients.matchAll({type: 'window', includeUncontrolled: true});
    for (const client of windows) {
      if ('focus' in client) {
        await client.focus();
        if ('navigate' in client) await client.navigate(target);
        return;
      }
    }
    if (clients.openWindow) await clients.openWindow(target);
  })());
});
