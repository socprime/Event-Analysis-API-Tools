# Event Analysis API Tools

Upload a log file to Event Analysis through the SOC Prime API, then download the events that matched detection rules.

## Requirements

- bash 3.2 or newer
- curl 7.71 or newer
- jq
- gzip
- A SOC Prime API key with access to Prime Hunt; otherwise the API answers 403.

## API key

Both scripts read the key from `SOCPRIME_API_KEY`. When it is unset, they ask for it without echoing it. Without a terminal (cron, CI) the variable is required.

```bash
read -rs SOCPRIME_API_KEY && export SOCPRIME_API_KEY
```

The scripts pass the key to curl through a temporary file only you can read, so it does not show up in `ps`.

`SOCPRIME_API_URL` changes the API address, `https://api.tdm.socprime.com` by default.

## Upload a file

```bash
./event_analysis_upload.sh events.jsonl
```

The script creates an analysis, uploads the file in gzip chunks and prints the analysis id. Progress goes to stderr, so `id=$(./event_analysis_upload.sh events.jsonl)` captures only the id. A chunk that hits a network error, 429 or 5xx is sent again.

- Formats: `.jsonl`, `.json` (read as JSON Lines), `.txt`, `.log`, `.evtx`. The extension decides how the file is read.
- Size: up to 3 GiB.
- One new analysis per minute.

An interrupted upload is not resumed: run the script again to start a new analysis.

## Download the tagged events

```bash
./event_analysis_download.sh <analysis_id> [output]
```

The script waits until the analysis has built the file of tagged events, downloads it and unpacks it to `output` (`<analysis_id>.ndjson` by default): NDJSON, one event that matched at least one rule per line.

A dropped connection is resumed. If the script gives up or you stop it, run the same command again: it continues from `<output>.gz.part`.

## Both in one go

```bash
id=$(./event_analysis_upload.sh events.jsonl) && ./event_analysis_download.sh "$id"
```

Both scripts exit with 0 on success and non-zero on an error, with the reason on stderr.

## License

Apache License 2.0, see [LICENSE](LICENSE).
