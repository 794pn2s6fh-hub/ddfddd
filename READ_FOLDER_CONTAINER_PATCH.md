# Airlift Application Data Reader (v8)

This change removes House Arrest from Erosion's active build and uses AirTraffic/AFC for `/var/mobile/Containers/Data/Application`.

- The Application root is staged through AirTraffic and listed one level deep through AFC. Its ZIP contains the observed UUID directory names and optional `container-info.json` metadata from InstallationProxy; it does not recursively export all apps.
- A selected UUID directory or a path beneath it is handled by a separate Airlift reader. It stages the selected directory only to enumerate regular files, restores the exact original directory object, then reads each file individually and restores that exact file before returning the local copy.
- If an individual read fails, exact restoration is still attempted. Cleanup of staging is skipped unless the original path is independently confirmed and the recovered object is no longer present.
- The AFC visibility poll now allows up to 30 seconds before reporting that AirTraffic did not expose the recovered object. This addresses a possible timing issue in the prior 4-second window; it is not a guarantee that every directory will materialize.
- House Arrest is not enabled in Erosion's Rust feature set or invoked by the Airlift reader. Its upstream optional code is left untouched but disabled.

## Verification status

The changed Swift file parses successfully and Cargo manifests parse as TOML. A Cargo/Xcode build and on-device iOS test were not available in this environment, so this patch must be built and tested on the target device before relying on it. Start with the Application root listing and then a small, non-critical app-data directory. If AirTraffic cannot expose the recovered object after 30 seconds, the reader retains staging instead of deleting it.
