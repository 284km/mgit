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
objects, so a delta fifty deep inflates fifty streams. On the Mere repository
(16,235 objects) that is about 43 s.

Memory is counted by the runtime (`MERE_REGION_STATS=1`), not by peak RSS: on a
busy macOS machine the peak of one binary on one input moved by a factor of three
between runs, because what is never freed is larger than RAM and the compressor
decides how much of it is resident.

| built with Mere | given back as each object's block ends | in the default region, kept to the end |
|---|---|---|
| up to v0.1.563 | 1.8 GB | 34.7 GB |
| v0.1.564 | 24.8 GB | 11.5 GB |

(Mere repository at 17,505 objects.) Up to v0.1.563 most of it was in the default
region because `store_read` reaches its allocations through an inner function of a
`let rec ... and` group, which a region parameter did not reach, and because
`let (out, _e, ok) = zlib_inflate raw hp in` generalised `out`'s region (ByteBuf was
missing from the value restriction). Mere v0.1.564 fixed both. What is still in the
default region is what no function's type names: the inflater's Huffman tables and
bit readers, made and dropped inside `zlib_inflate` (Mere's Q-134: an allocation
that does not appear in a function's type goes to the default region). Recorded as
the reason, not worked around.

Not implemented: writing anything, `status` (needs stat fields Mere does not
expose), SHA-256 repositories, multi-pack-index.
