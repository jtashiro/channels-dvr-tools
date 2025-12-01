# Channels DVR Tools

## Project Purpose
This is a monitoring utility for Channels DVR servers. The tool tests TVE (TV Everywhere) channel stream connectivity on a scheduled basis.

## Architecture

### Single-File Design
- `tve_checker.py`: Standalone monitoring script with no external dependencies beyond `requests`
- Run as a long-running daemon with configurable polling frequency (minimum 60 minutes)

### Channels DVR Integration
The script interacts with the Channels DVR server REST API:
- **Channel Discovery**: `GET http://{ip}:{port}/api/v1/channels` - returns all channels
- **Stream Testing**: `GET http://{ip}:{port}/devices/ANY/channels/{number}/stream.mpg` - validates video streams
- **Filtering Logic**: Only tests non-hidden channels where `source_id` starts with 'TVE'

## Key Patterns

### Stream Validation Approach
```python
# Streams are validated by reading first chunk, not full playback
for chunk in response.iter_content(chunk_size=1024):
    if chunk:
        test_ok = True
        break  # Single chunk confirms stream is working
```

### API Response Structure
Channels API returns channel objects with:
- `number`: Channel number (key for sorting/identification)
- `name`: Display name
- `source_id`: Source type (filter for 'TVE-*' prefix)
- `hidden`: Boolean flag (exclude hidden channels)

## Running the Tool

```bash
# Basic usage (local server, 60-minute intervals)
./tve_checker.py

# Remote server with custom frequency
./tve_checker.py -i 192.168.1.100 -p 8089 -f 120

# Check version
./tve_checker.py -v
```

## Development Conventions

- **Versioning**: Manual date-based versioning in `VERSION` constant (format: `YYYY.MM.DD.HHMM`)
- **Defaults**: IP `127.0.0.1`, port `8089`, frequency `60` minutes (minimum enforced)
- **Error Handling**: Exits on critical failures (no TVE channels, invalid frequency), prints errors for stream issues
- **Dependencies**: Only `requests` library required; uses Python 3 stdlib otherwise

## When Modifying

- Update `VERSION` constant with current timestamp when making changes
- Maintain minimum frequency check (`MINIMUM_FREQUENCY = 60` minutes) to avoid server overload
- Preserve infinite loop structure - tool is designed as a daemon, not one-shot script
- Keep single-file architecture - no modules or additional files
