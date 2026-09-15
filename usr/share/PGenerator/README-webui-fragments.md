# Web UI fragments

The `webui.html`, `webui-*.html`, `webui-*.css`, and `webui-*.js` files in this directory are
the byte-sensitive inputs to the server-side Web UI assembler in `webui.pm`.
They are deliberately stored as separate files so front-end changes have
normal editor and diff boundaries while the server continues to emit one
HTML response. The allowlisted page currently contains twelve fragments,
including the Full Automation HTML and JavaScript fragments.

Do not run Prettier, ESLint `--fix`, a formatter-on-save rule, or a tabs-to-
spaces conversion over these files. Changing whitespace, line endings, or
placeholder lines changes the rendered response. `icc_profile.html` is
spliced into the same page; `icc_profile.css`, `icc_profile.js`, and
`hcfr_chc.js` are served verbatim from `/assets/`.

`webui.html` emits two inline `<script>` blocks. The first concatenates
`webui-colour-math.js` and `webui-app.js`; colour-math opens with
`'use strict';`, so the directive governs both. The second block concatenates
`webui-workspace.js` and `webui-automation.js` with no directive, so those two
run in sloppy mode. Code added to the first block must be strict-mode clean:
no undeclared assignments, no `with`, no block-scoped function declarations
relied on across blocks. Do not add `'use strict';` to the second block
without auditing `webui-workspace.js` for the same.

The extraction script and golden-hash test were added by the original heredoc
split and removed later when regression tests were kept local. Validate an intentional fragment change by checking the
allowlist, marker splices, LF endings, and JavaScript syntax, then run the
normal Perl suite:

```bash
rg -n 'webui-automation|__PG_AUTOMATION' usr/share/PGenerator/webui.pm usr/share/PGenerator/webui.html usr/share/PGenerator/webui-body.html
node --check usr/share/PGenerator/webui-automation.js
prove -v t/
```

The loader reads every fragment with Perl's `<:raw>` layer. Keep UTF-8 source
bytes and LF endings intact, and do not add banner comments inside fragments.
Migration notes and explanations belong here instead.

Before publishing an OTA archive, verify that the cumulative overlay contains
all twelve exact fragment paths with content, plus the four page assets the
served UI also reads from disk (`icc_profile.html`, `icc_profile.css`,
`icc_profile.js`, `hcfr_chc.js`). The package checker from the old split was
removed; inspect the archive manifest and run the same syntax and suite checks
against the staged overlay.

```bash
tar -tf <release>.tar.gz | rg 'usr/share/PGenerator/webui(-automation)?|icc_profile|hcfr_chc.js'
```
