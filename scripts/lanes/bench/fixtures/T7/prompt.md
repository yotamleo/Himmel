Bump the pinned `graphify` version in this repository from `0.12.3` to `0.13.0`.

The pin appears in more than one place. Update every occurrence of the old
version that refers to graphify, including the pin list and the installer
script (the installer embeds the version in a download URL as well as in a
variable). Leave the other tools' pins (shellcheck, ripgrep, jq) exactly as
they are.

Then record the change in `CHANGELOG.md` by adding a single new line to the
existing `## Unreleased` section, in the same format the other pin-bump lines
already use:

```
- Bump graphify pin to 0.13.0
```

Add it as the last entry of the `## Unreleased` list. Do not add a new
heading, do not restructure the file, and do not edit any released section.

Do not change anything else in the repository.
