# Airlift Application-container reader stability patch (v12)

## Re-analysis

The v11 post-restore verification checked `/var/mobile/Containers/Data/Application/<UUID>` through AFC and required the path to be visible. Another established path in this Rust source explicitly documents that AFC is rooted in a different namespace and cannot reliably stat the protected `/var/mobile` destination. This could make the reader report a 30-second restore failure even when AirTraffic had consumed the restore asset.

## Changes

- The restore check no longer requires an AFC stat/listing of the protected absolute destination or a symlink alias. Those probes are diagnostic only.
- The success gate requires three consecutive *actual AFC ObjectNotFound* responses for the restore recovery asset. Other AFC errors reset the counter and are never treated as proof that the asset was consumed.
- The existing 2-second ATC settle window is retained. No additional postflight reads are attempted: wrapping repeated `read_exact` calls in short timeouts risks consuming a partial ATC frame and desynchronizing the stream.
- The pre-restore direct-child count remains available in the log as supporting diagnostic data; no inaccessible destination listing is treated as an integrity check.
- The export now includes `.com.apple.mobile_container_manager.metadata.plist` rather than silently omitting it from the container dump.
- If enumeration or ZIP creation fails after the original container restore is accepted, the local partial export directory is retained and its path is included in the error instead of deleting the only available export.
- The bundled `.a` libraries remain unchanged. The GitHub Actions workflow rebuilds them from the modified Rust source.

## Validation status

The source-level workflow assertions and ZIP integrity checks can be run locally. This environment does not have the Rust toolchain or an attached iPhone, so this change is not yet a successful compile or new device test. The observed v11 behavior is the reason for this correction; after building v12, first test on a disposable/non-critical container.
