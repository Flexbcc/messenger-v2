(function installOwnerPanelAuth() {
  const storageKey = "owner_panel_secret";
  const nativeFetch = window.fetch.bind(window);
  let prompting = false;

  function currentSecret() {
    try {
      return sessionStorage.getItem(storageKey) || "";
    } catch (_) {
      return "";
    }
  }

  function saveSecret(secret) {
    try {
      if (secret) sessionStorage.setItem(storageKey, secret);
      else sessionStorage.removeItem(storageKey);
    } catch (_) {}
  }

  function requestSecret(message) {
    if (prompting) return false;
    prompting = true;
    const value = window.prompt(
      message || "Введите OWNER_PANEL_SECRET для доступа к Home Node:",
      "",
    );
    prompting = false;
    if (!value || !value.trim()) return false;
    saveSecret(value.trim());
    return true;
  }

  window.fetch = async function ownerAuthenticatedFetch(input, init = {}) {
    const url = typeof input === "string" ? input : input?.url || "";
    const isMonitorApi =
      url.startsWith("/monitor/") || url.includes("/monitor/");
    if (!isMonitorApi) return nativeFetch(input, init);

    const headers = new Headers(init.headers || {});
    const secret = currentSecret();
    if (secret) headers.set("X-Owner-Panel-Secret", secret);
    const response = await nativeFetch(input, { ...init, headers });
    if (response.status !== 401 || init.__ownerAuthRetried) return response;

    const latestSecret = currentSecret();
    if (latestSecret && latestSecret !== secret) {
      const concurrentRetryHeaders = new Headers(init.headers || {});
      concurrentRetryHeaders.set("X-Owner-Panel-Secret", latestSecret);
      return nativeFetch(input, {
        ...init,
        headers: concurrentRetryHeaders,
        __ownerAuthRetried: true,
      });
    }
    saveSecret("");
    if (!requestSecret(secret ? "Секрет неверный. Введите OWNER_PANEL_SECRET заново:" : null)) {
      return response;
    }
    const retryHeaders = new Headers(init.headers || {});
    retryHeaders.set("X-Owner-Panel-Secret", currentSecret());
    return nativeFetch(input, {
      ...init,
      headers: retryHeaders,
      __ownerAuthRetried: true,
    });
  };
})();
