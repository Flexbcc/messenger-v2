(function () {
  const BASE = "../spec/";
  const navEl = document.getElementById("nav");
  const docEl = document.getElementById("doc");
  const searchEl = document.getElementById("search");
  const sidebarEl = document.getElementById("sidebar");
  const menuToggle = document.getElementById("menuToggle");

  let sections = [];
  let byPath = new Map();   // path -> {title, path}
  let byName = new Map();   // filename without extension -> path (for [[wikilinks]])

  function baseName(path) {
    const file = path.split("/").pop();
    return file.replace(/\.md$/i, "");
  }

  function normalizePath(fromPath, relPath) {
    const baseDir = fromPath.includes("/") ? fromPath.slice(0, fromPath.lastIndexOf("/")) : "";
    const parts = (baseDir ? baseDir.split("/") : []).concat(relPath.split("/"));
    const stack = [];
    for (const part of parts) {
      if (part === "" || part === ".") continue;
      if (part === "..") stack.pop();
      else stack.push(part);
    }
    return stack.join("/");
  }

  function renderNav(activePath) {
    navEl.innerHTML = "";
    sections.forEach((sec) => {
      const h = document.createElement("div");
      h.className = "nav-section";
      h.textContent = sec.section;
      navEl.appendChild(h);
      sec.items.forEach((item) => {
        const a = document.createElement("a");
        a.className = "nav-item" + (item.path === activePath ? " active" : "");
        a.textContent = item.title;
        a.href = "#" + encodeURIComponent(item.path);
        a.addEventListener("click", (e) => {
          e.preventDefault();
          loadDoc(item.path);
          sidebarEl.classList.remove("open");
        });
        navEl.appendChild(a);
      });
    });
  }

  function preprocessWikilinks(text) {
    return text.replace(/\[\[([A-Za-z0-9_\-]+)\]\]/g, (match, name) => {
      const target = byName.get(name.toLowerCase());
      if (!target) return match;
      return `[${name}](wikilink:${target})`;
    });
  }

  function interceptLinks(container, currentPath) {
    container.querySelectorAll("a[href]").forEach((a) => {
      const raw = a.getAttribute("href");
      if (!raw) return;

      if (raw.startsWith("wikilink:")) {
        const target = raw.slice("wikilink:".length);
        a.href = "#" + encodeURIComponent(target);
        a.addEventListener("click", (e) => {
          e.preventDefault();
          loadDoc(target);
        });
        return;
      }

      if (/^https?:\/\//i.test(raw) || raw.startsWith("mailto:")) {
        a.target = "_blank";
        a.rel = "noopener";
        return;
      }

      if (raw.startsWith("#")) return;

      const [pathPart] = raw.split("#");
      if (!pathPart) return;

      const resolved = normalizePath(currentPath, pathPart);
      if (byPath.has(resolved)) {
        a.href = "#" + encodeURIComponent(resolved);
        a.addEventListener("click", (e) => {
          e.preventDefault();
          loadDoc(resolved);
        });
      } else {
        a.href = BASE + resolved;
        a.target = "_blank";
        a.rel = "noopener";
      }
    });
  }

  let mermaidReady = false;
  function ensureMermaid() {
    if (!window.mermaid || mermaidReady) return;
    mermaid.initialize({
      startOnLoad: false,
      theme: window.matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "default",
    });
    mermaidReady = true;
  }

  async function renderDiagrams(container) {
    const blocks = container.querySelectorAll("pre code.language-mermaid");
    if (!blocks.length || !window.mermaid) return;
    ensureMermaid();
    for (const codeEl of blocks) {
      const pre = codeEl.parentElement;
      const div = document.createElement("div");
      div.className = "mermaid";
      div.textContent = codeEl.textContent;
      pre.replaceWith(div);
    }
    try {
      await mermaid.run({ querySelector: "#doc .mermaid" });
    } catch (e) {
      console.warn("Mermaid render failed:", e);
    }
  }

  async function loadDoc(path) {
    docEl.innerHTML = "Загрузка…";
    try {
      const res = await fetch(BASE + path);
      if (!res.ok) throw new Error(res.status + " " + res.statusText);
      const raw = await res.text();
      const processed = preprocessWikilinks(raw);
      docEl.innerHTML = marked.parse(processed);
      await renderDiagrams(docEl);
      interceptLinks(docEl, path);
      renderNav(path);
      location.hash = encodeURIComponent(path);
      const titleMatch = raw.match(/^#\s+(.+)$/m);
      document.title = titleMatch ? titleMatch[1] + " — Спецификация" : "Спецификация проекта";
      window.scrollTo(0, 0);
    } catch (err) {
      docEl.innerHTML =
        "<p>Не удалось загрузить документ <code>" + path + "</code>: " + err.message +
        "</p><p>Убедитесь, что сайт запущен через локальный сервер (см. webview/serve.sh), а не открыт напрямую как file://.</p>";
    }
  }

  function applySearch(query) {
    const q = query.trim().toLowerCase();
    document.querySelectorAll(".nav-item").forEach((a) => {
      a.style.display = !q || a.textContent.toLowerCase().includes(q) ? "" : "none";
    });
  }

  searchEl.addEventListener("input", (e) => applySearch(e.target.value));
  menuToggle.addEventListener("click", () => sidebarEl.classList.toggle("open"));

  fetch("manifest.json")
    .then((r) => r.json())
    .then((data) => {
      sections = data;
      sections.forEach((sec) =>
        sec.items.forEach((item) => {
          byPath.set(item.path, item);
          byName.set(baseName(item.path).toLowerCase(), item.path);
        })
      );
      const initial = decodeURIComponent(location.hash.replace(/^#/, "")) || "README.md";
      renderNav(initial);
      loadDoc(byPath.has(initial) ? initial : "README.md");
    });
})();
