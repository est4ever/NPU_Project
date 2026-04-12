# Security

## Open WebUI secret (`.webui_secret_key`)

That file is auto-generated and listed in `.gitignore`. If it was **ever committed** or pushed:

1. **Rotate the secret** in Open WebUI (or whatever consumes it). Treat the old value as compromised.
2. **Remove it from Git history** on every clone/fork. Prefer [git-filter-repo](https://github.com/newren/git-filter-repo) over deprecated `git filter-branch`:

   ```bash
   pip install git-filter-repo
   git filter-repo --path .webui_secret_key --invert-paths
   ```

   Then coordinate a **force-push** with anyone who has cloned the repo (`git push --force-with-lease`).

3. **Verify** it is gone: `git log --all --full-history -- .webui_secret_key`

## Registry JSON

`registry/models_registry.json` and `registry/backends_registry.json` are machine-specific (paths, backend IDs). They are not tracked; use `registry/*.example.json` as templates or run `.\portable_setup.ps1` to create defaults.

## Reporting

Open a private security advisory on GitHub or contact the maintainers if you find a vulnerability.
