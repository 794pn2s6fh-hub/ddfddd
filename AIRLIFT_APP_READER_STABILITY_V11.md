# Airlift Application-container reader stability patch (v11)

## Scope

Stabilizes reads under `/var/mobile/Containers/Data/Application/` in the Rust Airlift implementation. The existing AirTraffic/AFC route and exported archive format remain in place.

## Changes

- The exact-restore ATC session remains open for the same two-second settle window used by the established AirTraffic write paths. Previously this restore path dropped ATC immediately after the second `FileComplete`.
- Restore verification now waits up to 30 seconds and requires three consecutive AFC probes where the recovery path is not visible, followed by a stable directory listing at the actual original `target_parent/leaf` path. It no longer trusts only the temporary `airlift-restore-link-…` alias; that alias is logged for diagnosis when the original path is still missing. If a pre-restore child snapshot was available, all those entries must still be present at the destination.
- If restoration remains ambiguous, the reader keeps recovery/staging objects and returns an error; it does not treat one transient AFC `ObjectNotFound` as success or clean up the recovery object.
- Directory enumeration requires two consecutive identical AFC snapshots. AFC metadata and file reads are retried to handle transient visibility/read errors.
- An error while reading a selected file no longer returns early while its containing directory is staged away from its original path. The exact-restore attempt still runs.
- Temporary `link_destination` values are symlink aliases into live paths. Cleanup now unlinks them with AFC `RemovePath`, never recursive `RemovePathAndContents`. If staging validation cannot confirm the state of its internal link, it no longer tries an unconditional recursive removal. Recursive cleanup of an owned AirTraffic staging source is allowed only after its internal symlink is removed and confirmed absent from the link's parent directory.

## Validation status

- Archive structure and the bundled physical-device/simulator static-library sizes can be checked locally.
- Static source assertions are included in the GitHub Actions workflow; that workflow also rebuilds `AirliftFFI` from the Rust source before building the IPA.
- This environment has no `cargo`, `rustc`, or `rustfmt`, so the Rust crate could not be compiled here. The two bundled `.a` files are preserved from the supplied archive and are not rebuilt locally. The standard `ipabuild.sh` and workflow rebuild the Rust library unless `EROSION_SKIP_AIRLIFT_REBUILD=1` is explicitly set.
- Device behavior is not verified here. After building the updated IPA, test with a non-critical app-data container first. Do not retry against a container left in an earlier safety-stop state until its original path and recovery object have been inspected.
