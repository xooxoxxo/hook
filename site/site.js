/* Hook homepage: Copy buttons, and the reveal-on-scroll motion.
   Loaded in <head> without defer so the "motion" class lands before first paint.
   Content is visible by default; only with this class (motion allowed, IntersectionObserver
   present) does CSS hide the .rv / .h-in elements until they are revealed. */
(function () {
  "use strict";
  var root = document.documentElement;
  var reduce = window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  var motion = !reduce && "IntersectionObserver" in window && "requestAnimationFrame" in window;
  if (motion) root.classList.add("motion");

  function ready(fn) {
    if (document.readyState !== "loading") fn();
    else document.addEventListener("DOMContentLoaded", fn);
  }

  function each(sel, fn, scope) {
    Array.prototype.forEach.call((scope || document).querySelectorAll(sel), fn);
  }

  function copyButtons() {
    each("[data-copy]", function (btn) {
      btn.addEventListener("click", function () {
        var el = document.getElementById(btn.getAttribute("data-copy"));
        var text = el.textContent;
        function done(label) {
          btn.textContent = label;
          setTimeout(function () { btn.textContent = "Copy"; }, 1600);
        }
        function fallback() {
          var r = document.createRange();
          r.selectNodeContents(el);
          var s = window.getSelection();
          s.removeAllRanges();
          s.addRange(r);
          done("Selected");
        }
        if (navigator.clipboard && navigator.clipboard.writeText) {
          navigator.clipboard.writeText(text).then(function () { done("Copied"); }, fallback);
        } else {
          fallback();
        }
      });
    });
  }

  function stickyNav() {
    var nav = document.querySelector(".nav");
    if (!nav) return;
    var queued = false;
    function update() {
      queued = false;
      nav.classList.toggle("scrolled", window.scrollY > 8);
    }
    window.addEventListener("scroll", function () {
      if (!queued) { queued = true; requestAnimationFrame(update); }
    }, { passive: true });
    update();
  }

  function splitLetters(el) {
    var text = el.textContent;
    el.setAttribute("aria-label", text);
    el.textContent = "";
    text.split("").forEach(function (ch, i) {
      var s = document.createElement("span");
      s.className = "ch";
      s.setAttribute("aria-hidden", "true");
      s.style.setProperty("--i", i);
      s.textContent = ch;
      el.appendChild(s);
    });
  }

  function reveal() {
    each("[data-letters]", splitLetters);

    // Children of a [data-stagger] group reveal one after another.
    each("[data-stagger]", function (group) {
      var step = parseInt(group.getAttribute("data-stagger"), 10) || 60;
      Array.prototype.forEach.call(group.children, function (child, i) {
        child.classList.add("rv");
        child.style.setProperty("--d", Math.min(i * step, 480) + "ms");
      });
    });

    // The hero reveals on load, after one painted frame.
    requestAnimationFrame(function () {
      requestAnimationFrame(function () { root.classList.add("loaded"); });
    });

    var io = new IntersectionObserver(function (entries) {
      entries.forEach(function (e) {
        if (e.isIntersecting) {
          var el = e.target;
          el.classList.add("in");
          io.unobserve(el);
          // Once revealed, drop the stagger delay so hover lifts respond at once.
          el.addEventListener("transitionend", function settle(ev) {
            if (ev.target !== el || ev.propertyName !== "opacity") return;
            el.style.setProperty("--d", "0ms");
            el.removeEventListener("transitionend", settle);
          });
        }
      });
    }, { rootMargin: "0px 0px -6% 0px", threshold: 0.08 });
    each(".rv", function (el) { io.observe(el); });
  }

  ready(function () {
    copyButtons();
    stickyNav();
    if (motion) reveal();
  });
})();
