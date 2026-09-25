window.ouoPushSupported =
  'serviceWorker' in navigator && 'PushManager' in window;

function ouoUrlBase64ToUint8Array(value) {
  const padding = '='.repeat((4 - value.length % 4) % 4);
  const base64 = (value + padding).replace(/-/g, '+').replace(/_/g, '/');
  const raw = atob(base64);
  return Uint8Array.from([...raw].map((char) => char.charCodeAt(0)));
}

window.ouoPushSubscribe = async function(vapidPublicKey) {
  if (!window.ouoPushSupported) throw new Error('Web Push is not supported');
  const registration = await navigator.serviceWorker.register(
    'ouo_push_sw.js',
    {scope: './push/'}
  );
  await navigator.serviceWorker.ready;
  let subscription = await registration.pushManager.getSubscription();
  if (!subscription) {
    subscription = await registration.pushManager.subscribe({
      userVisibleOnly: true,
      applicationServerKey: ouoUrlBase64ToUint8Array(vapidPublicKey),
    });
  }
  return JSON.stringify(subscription.toJSON());
};

window.ouoPushUnsubscribe = async function() {
  if (!window.ouoPushSupported) return;
  const registrations = await navigator.serviceWorker.getRegistrations();
  for (const registration of registrations) {
    if (!registration.scope.endsWith('/push/')) continue;
    const subscription = await registration.pushManager.getSubscription();
    if (subscription) await subscription.unsubscribe();
    await registration.unregister();
  }
};
