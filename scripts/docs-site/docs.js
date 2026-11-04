/* Hook docs pages: the light and dark switch, Copy buttons on code, and "On this page"
   following the reader. Loaded in <head> so a saved theme applies before first paint. */
(function () {
  "use strict";
  var root = document.documentElement;
  var KEY = "hook-docs-theme";
  try {
    var saved = localStorage.getItem(KEY);
    if (saved === "light" || saved === "dark") root.setAttribute("data-theme", saved);
  } catch (e) { /* storage blocked: follow the system */ }

  function isDark() {
    var t = root.getAttribute("data-theme");
    if (t) return t === "dark";
    return window.matchMedia && window.matchMedia("(prefers-color-scheme: dark)").matches;
  }

  function each(sel, fn) { Array.prototype.forEach.call(document.querySelectorAll(sel), fn); }

  function themeButton() {
    each(".theme", function (btn) {
      btn.addEventListener("click", function () {
        var next = isDark() ? "light" : "dark";
        root.setAttribute("data-theme", next);
        try { localStorage.setItem(KEY, next); } catch (e) { /* not saved */ }
      });
    });
  }

  function copyButtons() {
    each(".code .copy", function (btn) {
      btn.addEventListener("click", function () {
        var code = btn.parentNode.querySelector("code");
        var text = code.textContent;
        function done(label) {
          btn.textContent = label;
          setTimeout(function () { btn.textContent = "Copy"; }, 1600);
        }
        function select() {
          var r = document.createRange();
          r.selectNodeContents(code);
          var s = window.getSelection();
          s.removeAllRanges();
          s.addRange(r);
          done("Selected");
        }
        if (navigator.clipboard && navigator.clipboard.writeText) {
          navigator.clipboard.writeText(text).then(function () { done("Copied"); }, select);
        } else {
          select();
        }
      });
    });
  }

  function followHeadings() {
    var links = document.querySelectorAll(".toc-side a");
    if (!links.length) return;
    var byId = {};
    Array.prototype.forEach.call(links, function (a) { byId[a.getAttribute("href").slice(1)] = a; });
    var heads = Array.prototype.filter.call(document.querySelectorAll("article h2[id], article h3[id]"),
      function (h) { return byId[h.id]; });
    var current = null;
    function mark(id) {
      if (current) current.classList.remove("on");
      current = byId[id] || null;
      if (current) current.classList.add("on");
    }
    var queued = false;
    function update() {
      queued = false;
      var top = heads[0];
      heads.forEach(function (h) { if (h.getBoundingClientRect().top < window.innerHeight * 0.3) top = h; });
      mark(top.id);
    }
    window.addEventListener("scroll", function () {
      if (!queued) { queued = true; requestAnimationFrame(update); }
    }, { passive: true });
    if (heads.length) update();
  }

  function activeTabInView() {
    var on = document.querySelector(".tabs a.on");
    var strip = document.querySelector(".tabs");
    if (!on || !strip || strip.scrollWidth <= strip.clientWidth) return;
    strip.scrollLeft = on.offsetLeft - (strip.clientWidth - on.offsetWidth) / 2;
  }

  function ready(fn) {
    if (document.readyState !== "loading") fn();
    else document.addEventListener("DOMContentLoaded", fn);
  }
  ready(function () {
    themeButton();
    copyButtons();
    followHeadings();
    activeTabInView();
  });
})();
