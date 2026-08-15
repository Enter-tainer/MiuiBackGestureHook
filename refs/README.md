# Reference policy

Only redistributable source references belong in Git.

- Android 16 AOSP snippets are tracked under `android16/aosp_back_16/`.
- Future Android 17 AOSP snippets should use a distinct `android17/aosp_back_17/` tree.
- Xiaomi APKs, framework JARs, native libraries, decompilation output, device dumps, and
  extracted resources are local research inputs only. Keep them in the ignored vendor paths
  under `android17/`; do not stage or publish them.

The root `.gitignore` excludes the known Xiaomi reference directories and common Android/native
binary formats as a second guard. Reports may record hashes, versions, paths, offsets, and small
original analysis excerpts, but must not embed proprietary binaries or bulk decompiled sources.
