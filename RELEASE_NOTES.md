# Release Notes

Keep concrete, user-facing release bullets here as changes land. The release
script reads `## Pending` before building, uses those bullets for GitHub release
notes and the generated in-app changelog, then moves them under `## Released`
after a successful build.

Good bullets describe the behavior users will notice:

- Reduced flicker when Dynamic Stage windows resize.
- Fixed installer queue badges after changing package selection.
- Added an iOS 17 fallback for Disable App Library.

Avoid vague bullets like "Update settings", "Change project files", or
"Misc fixes".

## Pending

- [ ] Added a maintained pending/released release-notes workflow that drives GitHub notes and the in-app changelog without falling back to generic commit subjects.

## Released

### v1.1.22 - 2026-06-02

- [x] Reduced flicker when Dynamic Stage windows resize by staging new scene hosts and retiring old hosts after the remote layer has populated.
- [x] Added stronger transition shielding around Dynamic Stage app open, close, and apply paths.
- [x] Tracked DarkSword toggle apply results independently in Settings.
- [x] Improved Disable App Library handling with an iOS 17 fallback path.
- [x] Refined installer queue, badges, and activity status UI.
- [x] Tightened Log tab typography for dense verbose traces.
- [x] Updated the release script to capture dirty submodule changes before committing and tagging the parent release.
