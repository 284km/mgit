# mgit

The read side of git in pure [Mere](https://github.com/merelang/mere): loose
objects, packs (idx v2, offset and ref deltas), refs and packed-refs, annotated
tags, trees and history.

```
mgit [-C <dir>] cat-file -t|-s|-p <object>
mgit [-C <dir>] cat-file --batch-all-objects    # as `git cat-file --batch-all-objects --batch`
mgit [-C <dir>] rev-parse <ref>
mgit [-C <dir>] log --first-parent [<ref>]      # one id per line
mgit [-C <dir>] rev-list --all
mgit [-C <dir>] ls-tree -r <tree-ish>
mgit [-C <dir>] verify-ids                      # every object's content hashed again
```

Depends on [mgz](https://github.com/284km/mgz) (`zlib_inflate`) and
[msha](https://github.com/284km/msha) (`sha1_hex2`).

## How it is checked

`verify.sh` builds a repository with git -- a merge, both kinds of tag, an
executable, a symlink, nested directories, a file rewritten a little per commit
so that `git gc` stores it as deltas, and loose objects after the gc -- and
compares every command with git. The object store's oracle is the whole of
`git cat-file --batch-all-objects --batch`, byte for byte. `MGIT_BIG=<repo>`
adds a real repository; the Mere compiler's own (15,869 objects,
1.2 GB of content, delta chains 50 deep) is identical.

## What it costs

Each object is read inside a `region` block and nothing is cached across
objects, so a delta fifty deep inflates fifty streams. On the Mere repository:
54 s, and **1.9 GB peak RSS** -- the block does not get its memory back,
because the allocations are made by functions it calls (Mere's Q-134: an
allocation that does not appear in a function's type goes to the default
region). Recorded as the reason, not worked around.

Not implemented: writing anything, `status` (needs stat fields Mere does not
expose), SHA-256 repositories, multi-pack-index.
