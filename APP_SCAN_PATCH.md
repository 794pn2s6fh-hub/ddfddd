# Airlift App Container Scanner

Adds a passive `Scan Apps` action to the Erosion Home Actions section.

Flow:
`InstallationProxy -> get_apps(Any, None) -> Bundle ID + Container -> JSON -> Erosion Logs`

The scanner does not call:
- `al_exploit_read_file`
- `al_exploit_read_folder`
- AFC read
- any PosterBoard read/write
- wallpaper injection
- respring

The existing PosterBoard Fetch Path and read/write code are otherwise left unchanged.
