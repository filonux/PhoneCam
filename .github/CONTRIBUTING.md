# Contributing

Thanks for your interest. This guide covers the basics so your contribution can be reviewed and accepted quickly.

## Before writing code

- For large changes, or changes that alter current behavior, open an issue first (using the feature request template) to discuss the approach before investing time in the implementation.
- For specific bugs or small improvements, you can go straight to a pull request.

## Submitting a pull request

- Keep the change focused: one fix or feature per PR.
- Run `shellcheck script/phonecam.sh` and make sure you introduce no new warnings.
- Run the test suite from the project root with `bash tests/run_all.sh` (about 2–3 minutes). It needs no physical phone and makes no real system audio/video changes; its requirements are [below](#test-requirements).
- Interface text lives in a bilingual message catalog in the script: any new user-facing message needs both an English and a Spanish entry.
- Update `README.md` and `README-es.md` if the change affects usage or requirements.
- Fill in the pull request template; it is applied automatically.

## Test requirements

Besides Bash 4.4 or newer, the suite needs:

- `python3` with Pillow (`python3-pil` on Debian, Ubuntu and Mint, or `pip install Pillow`), the only third-party Python module it uses.
- The util-linux and GNU coreutils tools of a normal desktop Linux, notably `script`, `flock` and `timeout`. If you run it as root it also needs `runuser`, because the install tests run as an unprivileged user.

`shellcheck` is not part of the suite; run it separately.

## Changing the application icon

`script/phonecam.sh` ends with a copy of `assets/phonecam-icon.png`: base64 lines starting with `#@` (comments, never executed), so a copy of the script without `assets/` beside it can still install its icon. The tests fail while the two differ in any pixel, so after changing the asset regenerate the block with [oxipng](https://github.com/shssoichiro/oxipng) (9.1.1 reproduces the current block byte for byte):

```bash
oxipng -o 4 --strip safe --out /tmp/phonecam-icon.png assets/phonecam-icon.png
sed -i '/^#@/d' script/phonecam.sh
base64 < /tmp/phonecam-icon.png | sed 's/^/#@/' >> script/phonecam.sh
```

Keep `--strip safe`: without it the metadata chunks of the asset stay in the script. Without the command-line tool, `pip install pyoxipng` and `oxipng.optimize_from_memory(data, level=4, strip=oxipng.StripChunks.safe())` give the same bytes. Any encoder that keeps the pixels passes the tests, but Pillow's `optimize=True`, for example, leaves the PNG about 22 KB larger.

## Reporting bugs or proposing ideas

Use the repository's issue templates; they open automatically when you create a new issue. The more context you give (distro, `zenity` version, exact steps), the faster it can be diagnosed.

For security matters, please report them privately instead of opening a public issue — see [`SECURITY.md`](SECURITY.md).
