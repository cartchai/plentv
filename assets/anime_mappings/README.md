# Anime mappings — staged self-host copy (NOT wired into the build)

## What this is

`anime-mappings.bin.gz` is the combined tracker ID-mappings file (Fribb's
anime-lists + Anime-Lists episode mappings in one binary file, magic `AMAP`).
Upstream 2.26.0 (`178441bff`) rewrote the tracker mappings stack to fetch
this file at runtime from the creator's release:

`https://github.com/edde746/anime-mappings/releases/latest/download/anime-mappings.bin.gz`

This copy was fetched from that public URL on 2026-11-19 and staged here so
the 1.5 builder can self-host it instead of calling the creator's release
at runtime (standing rule: the app sends nothing to the creator's services).

## Measured, not claimed

- Fetched 2026-11-19: **2,167,147 bytes gzipped**, 5,888,565 bytes
  decompressed. The upstream store comment says "~0.65 MB" — the file as
  released today is ~2.1 MB gzipped, ~5.6 MB decoded. It is still much
  smaller than the old multi-file fetch (~8 MB), just not under 1 MB.
- Valid gzip (`gzip -t` passes), magic `AMAP`, first section `fribb`.
- The file is released **daily** — this snapshot goes stale the next day.

## Status: staged only, NOT wired in

Nothing in the app references this file. It is NOT in `pubspec.yaml`'s
assets, and `AnimeMappingsStore` (upstream's new store, not yet ported)
still points at the creator's URL. The 1.5 builder decides:

- **(a) Fork release asset (recommended):** upload this file (freshly
  re-fetched) as an asset on a `cartchai/pleztv` release and point the
  ported store's `_sourceUrl` at the fork's copy. Keeps the store's daily
  conditional GET working against the fork's own release. Needs a release
  action — do it when the 1.5 build lands, not in prep.
- **(b) Bundled asset:** add this file to `pubspec.yaml` assets and teach
  the ported store to load it from the bundle first. Simpler, but the
  bundled copy freezes at each app release — no daily refresh until the
  next app update. Only worth it if (a) is refused.

Either way, re-fetch the file fresh when the builder wires it up — do not
ship this 2026-11-19 snapshot without checking it is still current.
