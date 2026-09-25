# SignPath configuration

The Windows release workflow uses two version-controlled SignPath artifact configurations:

- `windows-app-zip` — signs the standalone `RuSwitcher.exe` application.
- `windows-installer-zip` — signs the Inno Setup installer.

Create both configurations in the SignPath `RuSwitcher` project with the exact slugs above and
paste the XML from `artifact-configurations/`. The configurations intentionally use a `<zip-file>`
root because GitHub Actions uploads each unsigned file as a ZIP artifact.

Both configurations require a `version` parameter. The workflow supplies the release version and
the configuration enforces matching PE product/file versions, product name, company, copyright and
original filename before allowing a signature.
