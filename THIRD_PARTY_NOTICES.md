# Third-party notices

Hook's document viewer bundles two open-source libraries, unmodified. They are in
`Sources/RelayUI/Resources/Viewer/` and in `Hook.app/Contents/Resources/Viewer/`, each
with its licence file.

| Library | Version | File | Licence |
|---|---|---|---|
| [marked](https://github.com/markedjs/marked) | 18.0.14 | `marked.umd.js` | MIT (`LICENSE-marked.md`) |
| [DOMPurify](https://github.com/cure53/DOMPurify) | 3.4.16 | `purify.min.js` | Apache-2.0 or MPL-2.0, at your choice (`LICENSE-dompurify.txt`, `LICENSE-dompurify-MPL.txt`) |

Both files are copied byte for byte from the npm tarballs, whose `dist.integrity` hashes
were checked when they were added:

- `marked-18.0.14.tgz`: `sha512-mBHK6FBHuBAlhgRe88w9F0O1AbwwXJUcQibUbC/QcdTbVGAD7aWza+xt3N6oT/jCZx3/OMeS+8rnuiHZcQ9s7A==`
- `dompurify-3.4.16.tgz`: `sha512-sqo+pNp3qRhCIpbgRi1y8Tgk27Bo2Ry7w0dC1NBeNTdZChWjz9Xb/KOoZbRP/R6pQZ80Qw8YhXw13hWWBbMRnQ==`

SHA-256 of the copied files:

- `marked.umd.js`: `21568877a938d2c4e7d74e27f18e60da96bb73a68809610ca39216e1efebae62`
- `purify.min.js`: `2c90a9b46d6463f26038a29b686e82bc91de01fdac9d5229e7cfe3b360134ea2`

To update one, pick a version published at least 5 days ago, download its tarball,
check its integrity against `npm view <package>@<version> dist.integrity`, copy the
browser build and the licence, and update this file.
