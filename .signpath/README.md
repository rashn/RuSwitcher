# SignPath configuration

The Windows release workflow uses two version-controlled SignPath artifact configurations and two
signing requests per release:

- `windows-apps-zip` — signs the standalone x64 and ARM64 applications in one request.
- `windows-installers-zip` — signs the x64 and ARM64 Inno Setup installers in one request.

Create both configurations in the SignPath `RuSwitcher` project with the exact slugs above and
paste the XML from `artifact-configurations/`. The configurations intentionally use a `<zip-file>`
root because GitHub Actions uploads each unsigned file as a ZIP artifact.

Both configurations require a `version` parameter. The workflow supplies the release version and
the configuration enforces matching PE product/file versions, product name, company, copyright and
original filename before allowing a signature.

The jobs are deliberately ordered as build apps -> sign apps -> build installers -> sign installers.
This ensures each signed installer contains an already-signed application while requiring only two
manual production approvals (one for both app architectures and one for both installers).
