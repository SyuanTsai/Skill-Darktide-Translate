<!--
SPDX-FileCopyrightText: 2026 SyuanTsai
SPDX-License-Identifier: Apache-2.0
-->

# Darktide translation adapter

The Python adapter validates Schema 15 localization worksets and processes pending
`AI_REQUIRED` units through Claude translation and review. Run it only from the
repository source tree or GitHub Actions. The installed Skill excludes this adapter.
It depends on `packages/claude-runner` and reads the configuration, rules manifest,
prompts, and schemas in `skills/auto-update-darktide-mod/assets/api-*`.

Run these commands from the repository root in a prepared Python 3.11+ environment.
`binding` prints the translation binding. `run --dry-run` previews the translation
and writes the summary. For live translation, omit `--dry-run` and set
`ANTHROPIC_API_KEY`. Match `--mode` to the workset's translation mode.

```text
python packages/darktide-translate/darktide_translate.py binding --mods-root <mods-root> --mod-relative-path <mod-path> --base-oid <base-oid> --mode update
python packages/darktide-translate/darktide_translate.py run --workset <workset.json> --mods-root <mods-root> --state <state.json> --cache-dir <cache-dir> --summary-out <summary.json> --mode update --dry-run
python -m pytest packages/claude-runner/tests tests/python/darktide_api -q
```

[Skill assets and workset binding](../../skills/auto-update-darktide-mod/references/api-translation.md)
