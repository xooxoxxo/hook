# Security policy

## Reporting a vulnerability

Please report vulnerabilities privately through GitHub private vulnerability
reporting: open the repo's **Security** tab and choose **Report a vulnerability**.
Don't open a public issue for a security problem.

Include what you found, how to reproduce it, and the Hook version (`relay --version`).

## Scope

- The app's loopback API on `127.0.0.1`, including the Host, Origin and server-proof
  checks.
- Token handling: the local token, the Pond token file and file permissions.
- The clients: the `relay` CLI and the MCP server.
- The installer, `scripts/install.sh`.

The design is described in [docs/security.md](docs/security.md).

## Opening files from asks

An ask can name a file (a step's `file`, a link's `path`). Hook touches it only when you press
a button, and then:

- **It opens only these types**, by exact type identifier: Markdown, plain text, CSV, JSON, logs
  (`.log`), YAML, PDF, PNG, JPEG, HEIC, GIF, TIFF, MP3, MPEG-4 audio (`.m4a`) and video, QuickTime,
  Word, Excel and PowerPoint documents and shows (`.doc`, `.docx`, `.xls`, `.xlsx`, `.ppt`,
  `.pptx`, `.pps`, `.ppsx`), and Pages, Numbers and Keynote. Images in the viewer load only as
  PNG, JPEG, GIF or HEIC, from the document's folder.
- **It refuses everything else**: apps, scripts, installers, disk images, folders, HTML, XML,
  SVG, WebP, RTF, calendar, contact and location files, Office macros, add-ins and templates, and
  any file with an execute bit. It never opens a file in a terminal, Script Editor, Automator,
  Python Launcher, or an app Script Editor or Automator saved.
- **Local disks only.** Network paths (`/net`, `/Network`, `/home`, in any spelling), hidden
  roots (`/.vol`, `/.nofollow`) and a first folder name that isn't plain ASCII are never touched.
  Hook walks the path one folder at a time by descriptor, never following a link it hasn't
  checked, and stops before any step the mount table lists as a network or non-local mount, or
  that isn't on APFS, HFS+, FAT, exFAT or `/dev`.

**Known limit.** To open a file in another app, Hook hands that app a path. Right before, Hook
checks the path still names the file it checked, but a process already running as you could
swap the file in the instant after that last check. Hook's own viewer isn't affected: it shows
the bytes it read from the checked file's descriptor.

## Supported versions

Fixes go into the latest release.
