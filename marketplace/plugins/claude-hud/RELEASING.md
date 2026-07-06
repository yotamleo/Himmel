# Releasing

This project ships as a Claude Code plugin. Releases should include compiled `dist/` output.

## Release Checklist

1) Update release versions:
   - `.claude-plugin/plugin.json` (Claude Code's update/cache key)
   - `package.json`
   - `package-lock.json`
   - `CHANGELOG.md`

   Keep `.claude-plugin/plugin.json` and `package.json` on the same version. The marketplace manifest is distribution metadata for this repo; the plugin update version comes from `plugin.json`.
2) Build:
   ```bash
   npm ci
   npm run build
   npm test
   npm run test:coverage
   ```
3) Verify plugin package contents:
   - `package.json` points to `dist/index.js`
   - `.claude-plugin/plugin.json` includes the release version
4) Commit and tag:
   - `git tag vX.Y.Z`
5) Publish:
   - Push tag
   - Create GitHub release with notes from `CHANGELOG.md`
