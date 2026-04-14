# TODO

## Script improvements

- [x] **#1 Redundant MakeMKV disc scan** — `makemkvcon info disc:0` is called twice (drive detection + title info). Combine into a single call.
- [x] **#2 Movie name not sanitized** — Claude could return a name with characters invalid on Windows (`:`, `?`, `*`, etc.). Sanitize before using as a file/folder name.
- [x] **#5 No cleanup on copy failure** — if `Copy-Item` to destination fails, `$localFinalMkv` is left on the local SSD. Clean up on failure.
- [x] **#6 Stale "NAS" references** — comments and log messages still say "NAS" after making the destination generic.
- [x] **#7 Mixed indentation** — line 176 uses a tab while the rest of the file uses spaces.

## Multi-disc loop

- [x] **#8 Wrap ripping flow in a loop** — keep the destination prompt outside; wrap everything from disc scan to copy complete in a `while ($true)` loop.
- [x] **#9 Eject disc after successful copy** — detect the drive letter from makemkvcon output and eject using Shell.Application.
- [x] **#10 Wait for new disc after eject** — poll `makemkvcon -r info disc:0` until a new disc is detected.
- [x] **#11 Exit if same disc is re-inserted**

## Edge cases

- [ ] **#12 Multi-movie discs** — some discs contain multiple feature films (e.g. double-feature releases). The script currently picks one title; it should detect and handle this case, ripping each movie separately.
- [ ] **#13 TV series discs** — series discs contain multiple episodes across multiple titles. Needs episode identification, season/episode numbering, and a different folder structure (e.g. `Show\Season 01\S01E01 - Title.mkv`). — store the disc name after each rip; if the next disc has the same name, warn and exit.
