# open-batoru-translation-ko

Korean translation database distribution repository for
`open-batoru-translater`.

## Launcher manifest URL

Use this URL in `patch/translate-source.json`:

```text
https://raw.githubusercontent.com/andrew0416/open-batoru-translation-ko/main/translate-manifest.json
```

Example:

```json
{
  "enabled": true,
  "mode": "manifest",
  "manifestUrl": "https://raw.githubusercontent.com/andrew0416/open-batoru-translation-ko/main/translate-manifest.json",
  "databasePath": "translate.db",
  "timeoutSeconds": 20,
  "keepBackup": true
}
```

## Release asset URL

The launcher downloads the latest released database from:

```text
https://github.com/andrew0416/open-batoru-translation-ko/releases/latest/download/translate.db
```

`translate.db` is uploaded as a GitHub Release asset. It is not committed
directly to this repository.

## Uploader files

Place these files in the same folder:

```text
UPLOAD_TRANSLATE_DB.bat
upload-translate-db.ps1
uploader-config.json
github-token.txt
translate.db
```

Do not commit `github-token.txt` or `translate.db`.

Create a GitHub personal access token for this repository with repository
contents and release write permission. Save only the token text in:

```text
github-token.txt
```

GitHub account passwords are not supported for this API flow.

## Run uploader

Double-click:

```text
UPLOAD_TRANSLATE_DB.bat
```

Or run with PowerShell:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\upload-translate-db.ps1
```

The uploader:

1. Reads local `translate.db`.
2. Checks that it looks like a SQLite database.
3. Downloads the latest release asset named `translate.db`.
4. Compares SHA256 hashes.
5. If both files are the same, prints a no-update message.
6. If different, creates a new release, uploads `translate.db`, and updates
   `translate-manifest.json`.

Uploader settings are stored in `uploader-config.json`.

## Version format

Release versions use this format:

```text
ko-YYYY-MM-DD-NN
```

Examples:

```text
ko-2026-08-05-01
ko-2026-08-05-02
ko-2026-08-06-01
```

The uploader checks existing Korean releases for today's date and automatically
uses the next number. On a new day, numbering starts again from `01`.
