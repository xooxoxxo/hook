Each `<id>/before/` is a realistic HOME for one harness; `after/` (no harness CLI) and `after-cli/` (fake CLIs) hold the files a sync adds or changes, with the temp HOME written as `/HOME`.
Regenerate the goldens with `HOOK_UPDATE_GOLDEN=1 python3 -m unittest discover -s clients -p test_integrations_fixtures.py`, then read every diff before you commit it.
