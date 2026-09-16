# UsageBar working preferences

- Use the GitHub Actions **Build** workflow (`.github/workflows/build.yml`) for app and DMG builds.
- Never install or replace UsageBar on this machine. Do not run `make install`, `scripts/build-app.sh --install`, or copy app bundles into `/Applications`.
- Local compilation, tests, and offscreen preview rendering are allowed when needed for development verification.
- When shipping an update, use a higher app version and publish a new release through the workflow. An artifact build or a release with the installed version will not appear as an update.
