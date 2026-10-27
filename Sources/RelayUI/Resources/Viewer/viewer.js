// Hook's document viewer: renders the Markdown in #hook-source into #hook-doc.
// Runs as a WKUserScript in Hook's own content world, after marked.umd.js and
// purify.min.js. The page itself runs no script (content JavaScript is off), so this
// file, marked and DOMPurify are the only code on the page.
(function () {
  "use strict";
  var source = document.getElementById("hook-source");
  var target = document.getElementById("hook-doc");
  if (!source || !target) { return; }
  if (typeof marked === "undefined" || typeof DOMPurify === "undefined") {
    var pre = document.createElement("pre");
    pre.className = "plain";
    pre.textContent = source.textContent;
    target.replaceChildren(pre);
    source.remove();
    return;
  }
  var html = marked.parse(source.textContent, { gfm: true, breaks: false, async: false });
  var clean = DOMPurify.sanitize(html, {
    USE_PROFILES: { html: true },
    FORBID_TAGS: ["style", "form", "button", "textarea", "select", "option",
                  "iframe", "frame", "object", "embed", "link", "meta", "base",
                  "audio", "video", "source", "track", "picture", "svg", "math"],
    FORBID_ATTR: ["style", "srcset", "target", "ping", "formaction", "background", "poster"],
    ALLOW_DATA_ATTR: false
  });
  target.innerHTML = clean;
  // Only a relative image may load: Hook serves it from the document's own folder.
  // Anything with a scheme ("https:", "file:", "data:") or a host ("//…") is shown as text.
  var images = target.querySelectorAll("img");
  for (var i = 0; i < images.length; i++) {
    var img = images[i];
    var src = img.getAttribute("src") || "";
    if (src !== "" && !/^[a-z][a-z0-9+.-]*:/i.test(src) && src.indexOf("//") !== 0) { continue; }
    var note = document.createElement("span");
    note.className = "hook-blocked";
    note.textContent = "Image not loaded: " + (img.getAttribute("alt") || src || "no address");
    img.replaceWith(note);
  }
  source.remove();
})();
