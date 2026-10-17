# Fixed upstream notice texts

`upstream/` retains 22 original files from the exact Git revisions declared by
23 selected crates' `.cargo_vcs_info.json`. These are additional source-delivery
materials, not edits to the Cargo vendor trees or their checksums.

`Linux/native-notice-supplements.json` binds each file to its raw upstream URL,
Git blob ID, SHA-256, byte count and package scope. It also binds the local
original Cargo manifest and `src/lib.rs` to byte-identical upstream files at
that revision. The same immutable revision is required by the crate's own VCS
record. The source packager verifies all of these inputs offline before
retaining the texts in `native-dependencies/notice-supplements/`.

Complete notice text locations were added for 22 packages. For zune-inflate,
the Zlib text is present but the referenced MIT/Apache texts are still absent
at this revision; its record remains incomplete. Its root `LICENSE.md` is a
declaration, not a complete MIT or Apache text. fon's license templates remain
paired with the original source copyright declarations already collected.
No notice is applied to unrelated or nested components by inference.

The older local collection found complete texts for four other packages.
Thus 26 of the original 45 records now have full-text location followups;
19 records do not, including missing manifest declarations. This count is not
a legal compatibility decision or a conclusion that 19 packages lack licenses.
The full source/license release audit remains incomplete.

See [the source material report](../docs/native-source-materials.md) and
[the new evidence](../../Evidence/LinuxHost/2026-10-17-native-upstream-notices/README.md).
