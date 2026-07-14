# Qwen3 clone artifact format

Vocello persists reusable clone prompts as a versioned, atomic artifact. The runtime source and
integrity tests are authoritative; this specification describes the compatibility contract.

## File set

A completed artifact contains the manifest and exactly the tensor files required by its mode:

- `manifest.json`
- `integrity.json`
- `ref_codes.safetensors` when reference codes are present
- `speaker_embedding.safetensors` when a speaker embedding is present

Unexpected, missing, empty, or duplicate files fail validation. Temporary staging directories are
not valid artifacts.

## Manifest identity

The manifest binds schema version, model repository/revision, language, source-audio fingerprint,
transcript presence/digest, x-vector mode, runtime-profile signature, artifact version, and creation
time. Raw audio, transcript text, user paths, and voice descriptions are not stored as identity
metadata.

## Integrity

`integrity.json` records the exact file set, byte count, SHA-256 digest, and each tensor’s key,
shape, and dtype. Validation fails closed when any digest, length, tensor key, shape, dtype, model,
mode requirement, or runtime-profile signature differs.

## Publication

Writers create and verify a complete sibling staging directory, synchronize its files, and replace
the destination atomically. An interrupted write must leave the previous valid artifact intact and
remove or ignore incomplete staging data.

## Compatibility and rebuild

Readers may accept only explicitly supported schema versions. A model revision, artifact version,
runtime-profile, required-file, tensor-layout, or integrity-schema change requires rebuilding the
artifact unless a tested migration is added. Silent partial reuse is forbidden.

Deterministic coverage lives in
`Tests/Qwen3RuntimeTests/Qwen3CloneArtifactIntegrityTests.swift`; semantic ownership is
`CLONE-001` in `PATCHES.json`.
