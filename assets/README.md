# Verified application assets

The binary sound recordings, original generated effects, development-only music fixtures and application icon are stored as compressed archive parts. `manifest.json` records each part and original file size and SHA-256 checksum.

Run `python3 scripts/prepare-assets.py` after checkout to verify and restore them before building. The helper accepts only the listed resource paths and verifies all contents before replacing files. Original attribution, source manifests and license texts stay beside the resources in the source tree.

Music fixtures support internal regression tests; music mode is hidden and its audio resources are excluded from the published application package.
