# Channels DVR Tools

A monitoring utility for [Channels DVR](https://getchannels.com/) servers that continuously tests TVE (TV Everywhere) channel stream connectivity.

## Features

- **Automated Stream Testing**: Continuously monitors all non-hidden TVE channels
- **Configurable Polling**: Set custom check intervals (minimum 60 minutes to avoid server overload)
- **Remote Server Support**: Connect to Channels DVR servers on your local network or remote locations
- **Lightweight**: Single-file Python script with minimal dependencies
- **Daemon-Friendly**: Designed to run as a long-running background process

## Requirements

- Python 3.x
- `requests` library

## Installation

1. Clone the repository:
```bash
git clone https://github.com/jtashiro/channels-dvr-tools.git
cd channels-dvr-tools
```

2. Install dependencies:
```bash
pip install requests
```

3. Make the script executable:
```bash
chmod +x tve_checker.py
```

## Usage

### Basic Usage

Monitor a local Channels DVR server (default: 127.0.0.1:8089):
```bash
./tve_checker.py
```

### Remote Server

Connect to a Channels DVR server on your network:
```bash
./tve_checker.py -i 192.168.1.100 -p 8089
```

### Custom Check Frequency

Run checks every 2 hours instead of the default 60 minutes:
```bash
./tve_checker.py -f 120
```

### Combined Options

Monitor a remote server with custom frequency:
```bash
./tve_checker.py -i 192.168.1.100 -p 8089 -f 90
```

### Check Version

Display the current version:
```bash
./tve_checker.py -v
```

## Command-Line Options

| Option | Description | Default |
|--------|-------------|---------|
| `-i`, `--ip_address` | IP address of the Channels DVR server | 127.0.0.1 |
| `-p`, `--port_number` | Port number of the Channels DVR server | 8089 |
| `-f`, `--frequency` | Check frequency in minutes (minimum: 60) | 60 |
| `-v`, `--version` | Display version and exit | - |

## How It Works

1. **Channel Discovery**: Queries the Channels DVR API (`/api/v1/channels`) to retrieve all channels
2. **Filtering**: Selects only non-hidden channels where `source_id` starts with 'TVE'
3. **Stream Testing**: For each channel, requests the stream endpoint and validates that video data is received
4. **Reporting**: Prints test results for each channel (OK or error details)
5. **Scheduling**: Waits for the specified interval before repeating

### Stream Validation

The tool efficiently validates streams by reading only the first chunk of data rather than downloading entire streams:

```python
# Validates stream is working without full download
for chunk in response.iter_content(chunk_size=1024):
    if chunk:
        test_ok = True
        break  # First chunk confirms stream works
```

## Example Output

```
Testing the connections of 45 TVE channels...
  #701 (HBO): OK
  #702 (Showtime): OK
  #703 (Cinemax): Link valid but no video received.
  #704 (Starz): OK
  ...
Next check in 60 minutes.
```

## Running as a Service

### systemd (Linux)

Create `/etc/systemd/system/tve-checker.service`:
```ini
[Unit]
Description=Channels DVR TVE Stream Monitor
After=network.target

[Service]
Type=simple
User=your-username
WorkingDirectory=/path/to/channels-dvr-tools
ExecStart=/usr/bin/python3 /path/to/channels-dvr-tools/tve_checker.py -i 192.168.1.100 -f 120
Restart=always
RestartSec=30

[Install]
WantedBy=multi-user.target
```

Enable and start:
```bash
sudo systemctl enable tve-checker
sudo systemctl start tve-checker
```

### Docker

Create a `Dockerfile`:
```dockerfile
FROM python:3-slim
WORKDIR /app
RUN pip install requests
COPY tve_checker.py .
ENTRYPOINT ["python3", "tve_checker.py"]
```

Build and run:
```bash
docker build -t tve-checker .
docker run -d --name tve-checker tve-checker -i 192.168.1.100 -f 120
```

## Troubleshooting

**No TVE channels found:**
- Verify your Channels DVR server is running and accessible
- Check that you have TVE sources configured in Channels DVR
- Ensure the IP address and port are correct

**Connection timeouts:**
- Check firewall settings on both client and server
- Verify network connectivity between machines
- Default timeout is 30 seconds per stream

**Minimum frequency error:**
- The tool enforces a 60-minute minimum to prevent server overload
- Increase the `-f` value to at least 60

## Contributing

Contributions are welcome! Please feel free to submit issues or pull requests.

## License

This project is open source. See repository for license details.

## Acknowledgments

Built for use with [Channels DVR](https://getchannels.com/) by Fancy Bits.
