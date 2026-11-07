// golcondad's optional script: live updates from the system's event stream, presence, job
// output as it comes, and forms sent without a full reload. Every page works without it.
"use strict";
(function () {
  var holder = document.querySelector("[data-system]");
  var main = document.querySelector("main.main");
  if (!main) return;

  // a page fetched again: its main and strip replace this one's, unless someone is typing
  function typing() {
    var a = document.activeElement;
    return a && /^(INPUT|TEXTAREA|SELECT)$/.test(a.tagName) && a.value !== a.defaultValue;
  }
  function swap(html, url) {
    var doc = new DOMParser().parseFromString(html, "text/html");
    var m = doc.querySelector("main.main");
    if (!m) { location.href = url; return; }
    main.innerHTML = m.innerHTML;
    // the strip (lock, presence) and the rail (the Changes count) change with it
    [".strip", ".rail"].forEach(function (sel) {
      var theirs = doc.querySelector(sel), mine = document.querySelector(sel);
      if (theirs && mine) mine.innerHTML = theirs.innerHTML;
    });
    document.title = doc.title;
    hook(main);
    present();
  }
  function refresh() {
    if (typing()) return notice("The candidate changed: reload to see it.");
    fetch(location.href, { headers: { Accept: "text/html" } })
      .then(function (r) { return r.text(); })
      .then(function (t) { swap(t, location.href); });
  }

  var bar = null;

  // who else has a page of this system open, in the strip
  var viewers = [];
  function present() {
    var here = document.getElementById("presence");
    if (!here) return;
    var others = viewers.filter(function (v) {
      return v.name !== here.dataset.me || v.page !== location.pathname;
    });
    here.textContent = others.length ? "also here: " + others.map(function (v) {
      return v.name + (v.page === location.pathname ? "" : " (" + v.page.replace(/^\/systems\/[^/]+/, "") + ")");
    }).join(", ") : "";
  }
  function notice(text) {
    if (!bar) {
      bar = document.createElement("div");
      bar.className = "banner sky live";
      // where the page's own banners are: above the rail and the main part
      var body = document.querySelector(".body");
      body.parentNode.insertBefore(bar, body);
    }
    bar.textContent = text;
  }

  // forms: sent with fetch; the page the daemon answers with (after its redirect) is shown
  function hook(root) {
    root.querySelectorAll("form[method=post]").forEach(function (f) {
      if (f.dataset.live) return;
      f.dataset.live = "1";
      f.addEventListener("submit", function (ev) {
        ev.preventDefault();
        var body = new URLSearchParams(new FormData(f));
        fetch(f.action, { method: "POST", body: body, headers: { Accept: "text/html" } })
          .then(function (r) {
            return r.text().then(function (t) {
              if (r.redirected) history.replaceState(null, "", r.url);
              swap(t, r.url);
            });
          })
          .catch(function () { f.submit(); });
      });
    });
  }
  hook(main);

  if (!holder || !window.EventSource) return;
  var system = holder.dataset.system;
  var src = new EventSource("/systems/" + encodeURIComponent(system) + "/events?page=" +
    encodeURIComponent(location.pathname));

  src.addEventListener("presence", function (ev) {
    viewers = JSON.parse(ev.data);
    present();
  });

  // a new revision, a commit or a discard: say who, and refresh the pages that show the candidate
  src.addEventListener("rev", function (ev) {
    var d = JSON.parse(ev.data), who = (d.by && d.by.name) || "someone";
    var what = d.commit ? "committed the candidate (" + d.commit.slice(0, 10) + ")"
      : d.discarded !== undefined ? "discarded the candidate"
      : (d.op === "set" ? "set " : "deleted ") + d.module + " " + (d.path || []).join(".") +
        (d.op === "set" ? " = " + d.value : "") + " (rev " + d.rev + ")";
    notice(who + " " + what + ".");
    if (/\/(changes|config)(\/|$)/.test(location.pathname)) refresh();
  });

  src.addEventListener("lock", function () {
    if (/\/(changes|config)(\/|$)/.test(location.pathname)) refresh();
  });

  // a job's output, on its own page; its end shows the page as it is now
  src.addEventListener("job", function (ev) {
    var log = document.querySelector("pre.log[data-job]");
    var d = JSON.parse(ev.data);
    if (!log || String(d.id) !== log.dataset.job) {
      if (/\/machines$/.test(location.pathname) && d.state) refresh();
      return;
    }
    if (d.line !== undefined) {
      var at = document.createElement("span");
      at.className = "m";
      at.textContent = new Date().toISOString().slice(0, 19) + "Z";
      log.appendChild(at);
      log.appendChild(document.createTextNode("  " + d.line + "\n"));
    }
    if (d.state) refresh();
  });
})();
