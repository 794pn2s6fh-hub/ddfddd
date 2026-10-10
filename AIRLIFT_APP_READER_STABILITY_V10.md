# Application-container AirTraffic stability patch (v10)

## Observed failure

The v9 reader sent both `FileComplete` messages and immediately dropped the ATC stream before polling AFC. The established AirTraffic write paths in the same Rust source hold the ATC session for 2 seconds after the final `FileComplete` before dropping it. This was an inconsistency in the read path and a plausible cause of intermittent materialization.

## Changes

- The shared `stage_remote_object` path now holds the ATC session for the same 2-second settle window as the established write paths before closing the stream and polling AFC. This applies to the app-folder reader and the other readers that share this primitive.
- If the recovered AFC object still does not appear after 30 seconds, the reader logs read-only visibility checks for the source, source link, link destination, and recovered name. It does not delete those paths or automatically retry while the location of the original object is ambiguous.
- House Arrest was not added or invoked by this patch. The application-container read path remains AirTraffic/AFC-only.

## Validation limits

The archive can be checked for structural integrity, and the patch was inspected in context. This environment does not provide `cargo`/`rustc`, so the Rust crate was not compiled here and the behavior still requires a device-side test.
