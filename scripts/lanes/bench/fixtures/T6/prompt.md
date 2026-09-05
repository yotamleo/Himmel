The `left-pad` dependency in this repository needs to move from version
`1.1.0` to `1.3.0`.

Update every `package.json` file in the repository that declares `left-pad`
so it points at `1.3.0` instead of `1.1.0`, and update the corresponding
entries in `package-lock.json` so the lockfile matches (including any
`resolved` tarball URLs that embed the old version number). Leave every
other dependency and every other field untouched.

When you're done, there should be no remaining references to the old
`1.1.0` version anywhere in the repository, and every JSON file must still
be valid JSON.
