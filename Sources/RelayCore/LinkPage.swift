import CryptoKit
import Foundation

/// The page an "Open in Hook" link (`GET /i/<uuid>`) answers with. The body is
/// the same for a known id (200) and an unknown one (404), and never contains
/// the id, so a request learns nothing from it.
public enum LinkPage {
    /// The inline script, exactly as it appears between the `<script>` tags.
    /// The CSP hash is computed from this constant.
    // Browsers let a script close a tab opened from outside with a single-entry history (Chrome, usually Firefox) and refuse otherwise (often Safari).
    static let script = """
        setTimeout(function(){window.close();setTimeout(function(){if(document.visibilityState==="visible"){var n=document.getElementById("note");if(n){n.textContent="You can close this tab."}}},400)},700);
        """

    static let style = """
        :root{color-scheme:light dark;--bg:#F5F5F7;--card:#FFFFFF;--ink:#1B1C22;--muted:#6E6E76;\
        --mark:#EDEDFB;--accent:#4C4CC4;--edge:rgba(0,0,0,.06);--shadow:0 1px 2px rgba(0,0,0,.04),0 8px 24px rgba(0,0,0,.06)}
        @media (prefers-color-scheme:dark){:root{--bg:#1C1C1E;--card:#2C2C2E;--ink:#F2F2F7;--muted:#A1A1A8;\
        --mark:#34345A;--accent:#9D9DF5;--edge:rgba(255,255,255,.08);--shadow:0 1px 2px rgba(0,0,0,.3),0 8px 24px rgba(0,0,0,.35)}}
        *{box-sizing:border-box}
        html,body{height:100%;margin:0}
        body{background:var(--bg);color:var(--ink);display:flex;align-items:center;justify-content:center;padding:16px;\
        font:15px/1.4 -apple-system,BlinkMacSystemFont,"SF Pro Text","Helvetica Neue",Helvetica,Arial,sans-serif;\
        -webkit-font-smoothing:antialiased}
        main{background:var(--card);border:1px solid var(--edge);border-radius:14px;box-shadow:var(--shadow);\
        padding:24px 28px;max-width:320px;width:100%;display:flex;align-items:center;gap:14px;\
        animation:in .24s ease-out both}
        .mark{flex:none;width:40px;height:40px;border-radius:10px;background:var(--mark);color:var(--accent);\
        display:flex;align-items:center;justify-content:center}
        .mark svg{width:22px;height:22px;display:block}
        h1{font-size:15px;font-weight:600;margin:0;letter-spacing:-.01em}
        p{margin:2px 0 0;font-size:13px;color:var(--muted)}
        @keyframes in{from{opacity:0;transform:translateY(4px)}to{opacity:1;transform:none}}
        @media (prefers-reduced-motion:reduce){main{animation:none}}
        """

    static let mark = """
        <svg viewBox="0 0 22 22" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" \
        stroke-linejoin="round" aria-hidden="true"><path d="M3 6.5l1.6 1.6L7.6 5"/><path d="M10.5 6.5h8"/>\
        <path d="M10.5 11.5h8"/><path d="M10.5 16.5h8"/><path d="M4 11.5h1.5"/><path d="M4 16.5h1.5"/></svg>
        """

    /// The full HTML document.
    public static let html = """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="color-scheme" content="light dark">
        <title>Hook</title>
        <link rel="icon" href="data:,">
        <style>\(style)</style>
        </head>
        <body>
        <main>
        <div class="mark">\(mark)</div>
        <div><h1>Handed to Hook</h1><p id="note" role="status">This tab closes by itself.</p></div>
        </main>
        <script>\(script)</script>
        </body>
        </html>
        """

    /// `sha256-<base64>` of the inline script, as a CSP source expression.
    public static var scriptHash: String {
        let digest = SHA256.hash(data: Data(script.utf8))
        return "sha256-" + Data(digest).base64EncodedString()
    }

    public static var contentSecurityPolicy: String {
        "default-src 'none'; style-src 'unsafe-inline'; script-src '\(scriptHash)'; img-src data:; "
            + "base-uri 'none'; form-action 'none'; frame-ancestors 'none'"
    }

    public static var headers: [String: String] {
        [
            "Content-Type": "text/html; charset=utf-8",
            "Cache-Control": "no-store",
            "Content-Security-Policy": contentSecurityPolicy,
            "X-Content-Type-Options": "nosniff",
            "Referrer-Policy": "no-referrer",
        ]
    }

    /// The response for status 200 (known id) or 404 (unknown id).
    public static func response(status: Int) -> HTTPResponse {
        HTTPResponse(status: status, headers: headers, body: Data(html.utf8))
    }
}
