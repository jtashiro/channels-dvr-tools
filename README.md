# Channels DVR Tools

A collection of utilities for [Channels DVR](https://getchannels.com/) server management, including TVE stream monitoring, torrent management, and automated content organization.

## Tools Overview

### 📺 TVE Stream Checker (`tve_checker.py`)
Monitor and validate TVE (TV Everywhere) channel stream connectivity with email notifications for failures.

### 🔍 Torrent Search (`torrent_search.py`)
Search, deduplicate, and download content via torrents with automatic quality selection and Transmission integration.

### 📦 Transmission Manager (`torrent_manager.py`)
Command-line interface for managing torrents in Transmission (add, list, remove, stats).

### 🔄 Post-Processor (`transmission_postprocess.py`)
Automatically clean up and organize downloaded content into proper Channels DVR directory structure.

## Requirements

- Python 3.x
- `requests` library
- `beautifulsoup4` library (for torrent search)
- `transmission-rpc` library (for torrent management)

## Installation

1. Clone the repository:
```bash
git clone https://github.com/jtashiro/channels-dvr-tools.git
cd channels-dvr-tools
```

2. Install dependencies:
```bash
pip install requests beautifulsoup4 transmission-rpc
```

3. Make scripts executable:
```bash
chmod +x tve_checker.py torrent_search.py torrent_manager.py transmission_postprocess.py
```

---

## 📺 TVE Stream Checker

Monitor TVE channel connectivity with email notifications for failures.

### Features
- Tests all non-hidden TVE channels
- Tracks failure duration (how long each channel has been failing)
- Email notifications with pretty HTML reports
- Parallel testing for faster execution
- Persistent failure log

### Usage

```bash
# Basic usage (one-time check)
./tve_checker.py -i nas.local

# With email notifications
./tve_checker.py -i nas.local \
  --smtp-server smtp.gmail.com \
  --sender-email you@gmail.com \
  --sender-password "your-app-password" \
  --recipient-email notify@example.com

# Adjust parallel workers
./tve_checker.py -i nas.local --max-workers 20
```

### Command-Line Options

| Option | Description | Default |
|--------|-------------|---------|
| `-i`, `--ip_address` | IP address of Channels DVR server | 127.0.0.1 |
| `-p`, `--port_number` | Port number of Channels DVR server | 8089 |
| `--max-workers` | Parallel test workers | 10 |
| `--smtp-server` | SMTP server for email | - |
| `--smtp-port` | SMTP port | 587 |
| `--sender-email` | Email address to send from | - |
| `--sender-password` | Email password | - |
| `--recipient-email` | Email address to send to | - |
| `--log-file` | Failure log file path | tve_failures.json |

### Run via Cron

Add to crontab for automatic monitoring:
```bash
# Check every hour
0 * * * * /opt/local/bin/python3.13 /path/to/tve_checker.py -i nas.local --smtp-server smtp.gmail.com --sender-email you@gmail.com --sender-password "password" --recipient-email notify@example.com >> /tmp/tve-checker.log 2>&1
```

---

## 🔍 Torrent Search & Download

Search for content, automatically deduplicate episodes, select best quality, and download via Transmission.

### Features
- Quality-based ranking (4K > 1080p > 720p, etc.)
- Episode deduplication (keeps best quality with most seeds)
- Automatic sorting by season/episode
- Transmission integration
- Temporary download location support

### Usage

```bash
# Search and display results
./torrent_search.py --query "Breaking Bad"

# Auto-download to Transmission
./torrent_search.py --query "Breaking Bad" --auto-download

# Remote Transmission server
./torrent_search.py --query "The Office" --auto-download \
  --host 192.168.1.100 \
  --username admin \
  --password secret

# Override show name for directory structure
./torrent_search.py --query "show" --auto-download --show-name "The Show"

# Debug mode
./torrent_search.py --query "ubuntu" --debug
```

**Note:** Only use for legal, non-copyrighted content (Linux ISOs, open-source software, Creative Commons media, etc.)

---

## 📦 Transmission Manager

Command-line tool for managing torrents in Transmission.

### Usage

```bash
# Add a magnet link
./torrent_manager.py add "magnet:?xt=urn:btih:..."

# Add with custom download directory
./torrent_manager.py add "magnet:?xt=urn:btih:..." --dir /downloads/shows

# List active torrents
./torrent_manager.py list

# Show statistics
./torrent_manager.py stats

# Remove a torrent (keeps files)
./torrent_manager.py remove 1

# Remove torrent and delete files
./torrent_manager.py remove 1 --delete-data

# Remote Transmission
./torrent_manager.py --host 192.168.1.100 --username admin --password pass list
```

---

## 🔄 Post-Processor

Automatically organize completed downloads into Channels DVR directory structure.

### Features
- Moves files from temp download location
- Extracts show name and episode info
- Renames to Channels DVR format: `Show Name S01E02 1080p WEBDL.mkv`
- Removes torrent artifacts (.nfo, .txt, etc.)
- Cleans up empty directories

### Usage

#### Process Single Download (Dry Run)
```bash
./transmission_postprocess.py process \
  "/Volumes/cloud2-nas/temp-downloads/Show.S01E01.1080p" \
  "/Volumes/cloud2-nas/channels-dvr/TV"
```

#### Process Single Download (Apply Changes)
```bash
./transmission_postprocess.py process \
  "/Volumes/cloud2-nas/temp-downloads/Show.S01E01.1080p" \
  "/Volumes/cloud2-nas/channels-dvr/TV" \
  --apply
```

#### Process All Completed Downloads (For Cron)
```bash
./transmission_postprocess.py process-all \
  "/Volumes/cloud2-nas/temp-downloads" \
  "/Volumes/cloud2-nas/channels-dvr/TV"
```

#### Monitor Directory Continuously
```bash
./transmission_postprocess.py monitor \
  "/Volumes/cloud2-nas/temp-downloads" \
  "/Volumes/cloud2-nas/channels-dvr/TV"
```

### Run via Cron

Add to crontab to process completed downloads every 5 minutes:
```bash
*/5 * * * * /opt/local/bin/python3.13 /path/to/transmission_postprocess.py process-all /Volumes/cloud2-nas/temp-downloads /Volumes/cloud2-nas/channels-dvr/TV >> /tmp/transmission-postprocess.log 2>&1
```

---

## ⚙️ Automated Sonarr/Radarr Configuration

### `post_install_links.sh`

Automates the initial and ongoing setup of Sonarr and Radarr after installation or container recreation. This script is designed for Docker-based deployments and ensures all download client and indexer settings are correct and up to date.

**Key Features:**
- Reads API keys directly from running Docker containers (Jackett, Sonarr, Radarr)
- Configures Transmission as the download client for both Sonarr and Radarr
- Adds or updates Remote Path Mappings for each app, always removing any existing mapping for the same host/remote/local path before adding the new one (idempotent)
- Ensures correct host and path matching, including trailing slashes, for reliable mapping
- Links all active Jackett indexers to Sonarr and Radarr
- Removes old clients, indexers, and stale remote path mappings before adding new ones
- Suppresses verbose JSON output for cleaner logs

#### Usage

```bash
./post_install_links.sh [hostname]
```
- If no hostname is provided, the script uses the current machine's hostname with `.local` appended.
- Ensure Docker containers for Jackett, Sonarr, Radarr, and Transmission are running and accessible.
- The script prints debug output and errors for any failed API calls.

#### Idempotency & Troubleshooting
- The script is safe to run multiple times; it will always remove and re-add remote path mappings as needed.
- If you see errors about "RemotePath already configured," the script now forcibly removes all matching mappings before adding the new one.
- If remote path mappings are not used, verify the host and path match exactly what Sonarr/Radarr see from Transmission (including trailing slashes).
- Check for API errors in the output (HTTP 400/401/500, validation errors, etc.).
- The script prints the POST payload and API response for debugging, but suppresses large JSON dumps for clarity.

---

## Complete Workflow Example

### 1. Configure Transmission
Set download directory to: `/Volumes/cloud2-nas/temp-downloads`

### 2. Search and Download
```bash
./torrent_search.py --query "Breaking Bad" --auto-download
```

### 3. Automatic Post-Processing (Cron)
Files are automatically cleaned up and moved to:
```
/Volumes/cloud2-nas/channels-dvr/TV/Breaking Bad/Breaking Bad S01E01 1080p WEBDL x264.mkv
```

### 4. Channels DVR Auto-Indexes
Channels DVR automatically detects and indexes the new files!

---

## Channels DVR Directory Structure

For proper indexing, organize files as follows:

### TV Shows
```
/Volumes/cloud2-nas/channels-dvr/TV/
  └── Show Name/
      ├── Show Name S01E01 1080p WEBDL.mkv
      ├── Show Name S01E02 720p HDTV.mkv
      └── Show Name S02E01 1080p BluRay.mkv
```

### Movies
```
/Volumes/cloud2-nas/channels-dvr/Movies/
  ├── Movie Title (2023).mkv
  └── Another Movie (2022).mp4
```

The post-processor automatically creates this structure for you.

## Troubleshooting

### TVE Checker

**No TVE channels found:**
- Verify Channels DVR server is running and accessible
- Check that you have TVE sources configured
- Ensure the IP address and port are correct

**Connection timeouts:**
- Check firewall settings
- Verify network connectivity
- Default timeout is 30 seconds per stream

### Torrent Search

**No results found:**
- API may be temporarily down
- Try different search terms
- Check debug output with `--debug` flag

**Transmission connection failed:**
- Ensure Transmission is running
- Verify host/port/credentials
- Check Transmission allows remote access

### Post-Processor

**Files not moving:**
- Check source and destination paths exist
- Verify write permissions
- Use `--apply` flag (dry-run is default for `process` command)

**Episode detection failing:**
- Override show name with `--show-name "Show Name"`
- Check filename contains S##E## or #x## pattern

## Contributing

Contributions are welcome! Please feel free to submit issues or pull requests.

## License

This project is open source. See repository for license details.

## Acknowledgments

Built for use with [Channels DVR](https://getchannels.com/) by Fancy Bits.
