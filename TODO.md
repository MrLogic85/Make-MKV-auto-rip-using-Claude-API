# TODO

## Script improvements

- [ ] **#1 Redundant MakeMKV disc scan** — `makemkvcon info disc:0` is called twice (drive detection + title info). Combine into a single call.
- [ ] **#2 Movie name not sanitized** — Claude could return a name with characters invalid on Windows (`:`, `?`, `*`, etc.). Sanitize before using as a file/folder name.
- [ ] **#5 No cleanup on copy failure** — if `Copy-Item` to destination fails, `$localFinalMkv` is left on the local SSD. Clean up on failure.
- [ ] **#6 Stale "NAS" references** — comments and log messages still say "NAS" after making the destination generic.
- [ ] **#7 Mixed indentation** — line 176 uses a tab while the rest of the file uses spaces.
