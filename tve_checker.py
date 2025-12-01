#!/usr/bin/env python3

import argparse, requests, sys, time
from email.mime.text import MIMEText
from email.mime.multipart import MIMEMultipart
import smtplib
from concurrent.futures import ThreadPoolExecutor, as_completed
import json
import os
from datetime import datetime

API_CHANNELS        = 'api/v1/channels'
DEFAULT_PORT_NUMBER = '8089'
DEFAULT_IP_ADDRESS  = '127.0.0.1'
MINIMUM_FREQUENCY   = 60 # minutes
DEFAULT_MAX_WORKERS = 10 # parallel workers
DEFAULT_LOG_FILE    = 'tve_failures.json'
VERSION             = '2025.11.30.1600'


def test_video_stream(url):
    """Test a video stream and return (success, error_message) tuple."""
    try:
        with requests.get(url, stream=True, timeout=30) as response:
            # Make sure the link is valid
            if response.status_code == 200:
                # Read a chunk of the stream to verify it's working
                for chunk in response.iter_content(chunk_size=1024):
                    if chunk:
                        return (True, None)
                    else:
                        return (False, 'Link valid but no video received')
                return (False, 'No data received')
            else:
                return (False, f'HTTP {response.status_code}')
    except requests.exceptions.RequestException as e:
        return (False, str(e))

def test_channel(ch_number, ch_name, ip_address, port_number):
    """Test a single channel and return result."""
    stream_url = f'http://{ip_address}:{port_number}/devices/ANY/channels/{ch_number}/stream.mpg'
    success, error = test_video_stream(stream_url)
    return (ch_number, ch_name, success, error)

class ChannelsDVRServer:
    '''Attributes and methods to interact with a Channels DVR server.'''
    def __init__(self, ip_address=DEFAULT_IP_ADDRESS, port_number=DEFAULT_PORT_NUMBER, log_file=DEFAULT_LOG_FILE):
        '''Initialize the server attributes.'''
        self.ip_address  = ip_address
        self.port_number = port_number
        self.email_config = None
        self.log_file = log_file
        self.failure_log = self._load_failure_log()

    def _load_failure_log(self):
        '''Load the failure log from disk.'''
        if os.path.exists(self.log_file):
            try:
                with open(self.log_file, 'r') as f:
                    return json.load(f)
            except (json.JSONDecodeError, IOError):
                return {}
        return {}

    def _save_failure_log(self):
        '''Save the failure log to disk.'''
        try:
            with open(self.log_file, 'w') as f:
                json.dump(self.failure_log, f, indent=2)
        except IOError as e:
            print(f'Warning: Could not save failure log: {e}')

    def update_failure_log(self, failed_channels, passed_channels):
        '''Update the failure log with current test results.'''
        current_time = datetime.now().isoformat()
        
        # Add or update failed channels
        for ch_number, ch_data in failed_channels.items():
            ch_key = str(ch_number)
            if ch_key not in self.failure_log:
                # New failure
                self.failure_log[ch_key] = {
                    'name': ch_data['name'],
                    'first_failed': current_time,
                    'last_checked': current_time,
                    'error': ch_data['error']
                }
            else:
                # Continuing failure
                self.failure_log[ch_key]['last_checked'] = current_time
                self.failure_log[ch_key]['error'] = ch_data['error']
        
        # Remove channels that are now passing
        for ch_number in passed_channels.keys():
            ch_key = str(ch_number)
            if ch_key in self.failure_log:
                del self.failure_log[ch_key]
        
        self._save_failure_log()

    def get_failure_duration(self, ch_number):
        '''Get the duration a channel has been failing.'''
        ch_key = str(ch_number)
        if ch_key in self.failure_log:
            first_failed = datetime.fromisoformat(self.failure_log[ch_key]['first_failed'])
            duration = datetime.now() - first_failed
            
            # Format duration nicely
            days = duration.days
            hours = duration.seconds // 3600
            minutes = (duration.seconds % 3600) // 60
            
            if days > 0:
                if days == 1:
                    return f'{days} day'
                return f'{days} days'
            elif hours > 0:
                if hours == 1:
                    return f'{hours} hour'
                return f'{hours} hours'
            elif minutes > 0:
                if minutes == 1:
                    return f'{minutes} minute'
                return f'{minutes} minutes'
            else:
                return 'just now'
        return None

    def get_tve_channels(self):
        '''
        Return the list of non-hidden channels from all TVE sources.

        The output will be a JSON dictionary:
            keys   = channel numbers
            values = channel names
        '''
        api_channels = f'http://{self.ip_address}:{self.port_number}/{API_CHANNELS}'
        tve_channels = {}

        channels = requests.get(api_channels).json()

        for channel in channels:
            hidden = channel.get('hidden', False)

            if not hidden and channel['source_id'].startswith('TVE'):
                tve_channels[channel['number']] = channel['name']

        return tve_channels

    def set_email_config(self, smtp_server, smtp_port, sender_email, sender_password, recipient_email):
        '''Configure email settings for result notifications.'''
        self.email_config = {
            'smtp_server': smtp_server,
            'smtp_port': smtp_port,
            'sender_email': sender_email,
            'sender_password': sender_password,
            'recipient_email': recipient_email
        }

    def send_results_email(self, passed_channels, failed_channels):
        '''Send a pretty HTML formatted email with test results.'''
        if not self.email_config:
            print('Email not configured. Skipping email notification.')
            return

        # Create message
        msg = MIMEMultipart('alternative')
        msg['Subject'] = f'Channels DVR TVE Test Results - {len(failed_channels)} Failed, {len(passed_channels)} Passed'
        msg['From'] = self.email_config['sender_email']
        msg['To'] = self.email_config['recipient_email']

        # Create HTML content
        html = f'''
        <html>
        <head>
            <style>
                body {{ font-family: Arial, sans-serif; margin: 20px; background-color: #f5f5f5; }}
                .container {{ max-width: 800px; margin: 0 auto; background-color: white; padding: 20px; border-radius: 8px; box-shadow: 0 2px 4px rgba(0,0,0,0.1); }}
                h1 {{ color: #333; border-bottom: 3px solid #4CAF50; padding-bottom: 10px; }}
                h2 {{ color: #555; margin-top: 30px; }}
                .summary {{ background-color: #f9f9f9; padding: 15px; border-radius: 5px; margin: 20px 0; }}
                .stats {{ display: flex; justify-content: space-around; text-align: center; }}
                .stat-box {{ flex: 1; padding: 10px; }}
                .stat-number {{ font-size: 36px; font-weight: bold; }}
                .passed {{ color: #4CAF50; }}
                .failed {{ color: #f44336; }}
                .channel-list {{ list-style: none; padding: 0; }}
                .channel-item {{ padding: 12px; margin: 8px 0; border-radius: 5px; display: flex; justify-content: space-between; align-items: center; }}
                .channel-passed {{ background-color: #e8f5e9; border-left: 4px solid #4CAF50; }}
                .channel-failed {{ background-color: #ffebee; border-left: 4px solid #f44336; }}
                .channel-number {{ color: #888; font-size: 14px; margin-left: 8px; }}
                .channel-name {{ font-weight: bold; font-size: 18px; color: #333; }}
                .status {{ font-weight: bold; padding: 4px 12px; border-radius: 3px; font-size: 14px; }}
                .status-ok {{ background-color: #4CAF50; color: white; }}
                .status-fail {{ background-color: #f44336; color: white; }}
                .footer {{ margin-top: 30px; padding-top: 20px; border-top: 1px solid #ddd; color: #888; font-size: 12px; text-align: center; }}
                .error-message {{ color: #d32f2f; font-size: 12px; margin-top: 4px; }}
            </style>
        </head>
        <body>
            <div class="container">
                <h1>📺 Channels DVR TVE Test Results</h1>
                
                <div class="summary">
                    <div class="stats">
                        <div class="stat-box">
                            <div class="stat-number passed">{len(passed_channels)}</div>
                            <div>Passed</div>
                        </div>
                        <div class="stat-box">
                            <div class="stat-number failed">{len(failed_channels)}</div>
                            <div>Failed</div>
                        </div>
                        <div class="stat-box">
                            <div class="stat-number">{len(passed_channels) + len(failed_channels)}</div>
                            <div>Total</div>
                        </div>
                    </div>
                </div>
        '''

        # Add failed channels section (sorted by channel name)
        if failed_channels:
            html += '<h2 class="failed">❌ Failed Channels</h2><ul class="channel-list">'
            # Sort by channel name instead of number
            sorted_failed = sorted(failed_channels.items(), key=lambda x: x[1]['name'].lower())
            for ch_number, ch_data in sorted_failed:
                # Create friendly error message
                error = ch_data.get('error', 'Unknown error')
                if 'HTTP' in error:
                    friendly_error = f'Connection Error ({error})'
                elif 'timeout' in error.lower():
                    friendly_error = f'Timeout ({error})'
                elif 'no video' in error.lower():
                    friendly_error = f'No Video Data ({error})'
                else:
                    friendly_error = f'Stream Error ({error})'
                
                # Get failure duration
                duration = self.get_failure_duration(ch_number)
                duration_text = f' • Failing for: {duration}' if duration else ''
                
                html += f'''
                <li class="channel-item channel-failed">
                    <div>
                        <span class="channel-name">{ch_data["name"]}</span>
                        <span class="channel-number">#{ch_number}</span>
                        <div class="error-message">{friendly_error}{duration_text}</div>
                    </div>
                    <span class="status status-fail">FAILED</span>
                </li>
                '''
            html += '</ul>'
        else:
            html += '<h2 class="passed">✅ All channels passed!</h2>'

        # Add passed channels section (sorted by channel name)
        if passed_channels:
            html += '<h2 class="passed">✅ Passed Channels</h2><ul class="channel-list">'
            # Sort by channel name instead of number
            sorted_passed = sorted(passed_channels.items(), key=lambda x: x[1].lower())
            for ch_number, ch_name in sorted_passed:
                html += f'''
                <li class="channel-item channel-passed">
                    <div>
                        <span class="channel-name">{ch_name}</span>
                        <span class="channel-number">#{ch_number}</span>
                    </div>
                    <span class="status status-ok">OK</span>
                </li>
                '''
            html += '</ul>'

        html += f'''
                <div class="footer">
                    <p>Server: {self.ip_address}:{self.port_number}</p>
                    <p>Generated by Channels DVR Tools v{VERSION}</p>
                </div>
            </div>
        </body>
        </html>
        '''

        # Attach HTML content
        msg.attach(MIMEText(html, 'html'))

        # Send email
        try:
            with smtplib.SMTP(self.email_config['smtp_server'], self.email_config['smtp_port']) as server:
                server.starttls()
                server.login(self.email_config['sender_email'], self.email_config['sender_password'])
                server.send_message(msg)
            print('Email notification sent successfully.')
        except Exception as e:
            print(f'Failed to send email: {e}')

    
if __name__ == "__main__":
    # Create an ArgumentParser object
    parser = argparse.ArgumentParser(
                description = "Test the connections of all non-hidden TVE channels.")

    # Add the input arguments
    parser.add_argument('-f', '--frequency', type=int, default=MINIMUM_FREQUENCY, \
            help='Frequency of queries sent to the Channels DVR server, in minutes. Default = minimum: 60 minutes.')
    parser.add_argument('-i', '--ip_address', type=str, default=DEFAULT_IP_ADDRESS, \
                        help='IP address of the Channels DVR server. Default: 127.0.0.1')
    parser.add_argument('-p', '--port_number', type=str, default=DEFAULT_PORT_NUMBER, \
                        help='Port number of the Channels DVR server. Default: 8089')
    parser.add_argument('-v', '--version', action='store_true', help='Print the version number and exit the program.')
    parser.add_argument('--smtp-server', type=str, help='SMTP server for sending email notifications')
    parser.add_argument('--smtp-port', type=int, default=587, help='SMTP server port. Default: 587')
    parser.add_argument('--sender-email', type=str, help='Email address to send from')
    parser.add_argument('--sender-password', type=str, help='Password for sender email account')
    parser.add_argument('--recipient-email', type=str, help='Email address to send results to')
    parser.add_argument('--max-workers', type=int, default=DEFAULT_MAX_WORKERS, \
                        help=f'Maximum number of parallel workers for testing channels. Default: {DEFAULT_MAX_WORKERS}')
    parser.add_argument('--log-file', type=str, default=DEFAULT_LOG_FILE, \
                        help=f'Path to failure log file. Default: {DEFAULT_LOG_FILE}')

    # Parse the arguments
    args = parser.parse_args()

    # Access the values of the arguments
    frequency         = args.frequency
    ip_address        = args.ip_address
    port_number       = args.port_number
    version           = args.version

    # If the version flag is set, print the version number and exit
    if version:
        print(VERSION)
        sys.exit()

    # Sanity check of the provided arguments.
    if frequency < MINIMUM_FREQUENCY:
        print(f'Minimum frequency of {MINIMUM_FREQUENCY} minutes! Try again.')
        sys.exit()
        
    # All good. Let's go!

    DVR = ChannelsDVRServer(ip_address, port_number, args.log_file)

    # Configure email if all email arguments are provided
    if all([args.smtp_server, args.sender_email, args.sender_password, args.recipient_email]):
        DVR.set_email_config(
            args.smtp_server,
            args.smtp_port,
            args.sender_email,
            args.sender_password,
            args.recipient_email
        )
        print('Email notifications enabled.')
    elif any([args.smtp_server, args.sender_email, args.sender_password, args.recipient_email]):
        print('Warning: Incomplete email configuration. All email parameters required. Email notifications disabled.')

    tve_channels = DVR.get_tve_channels()

    if not tve_channels:
        print(f'No TVE channels received from the Channels DVR server at http://{ip_address}:{port_number}!')
        sys.exit()

    sorted_channels = list(tve_channels.keys())
    sorted_channels.sort()

    passed_channels = {}
    failed_channels = {}

    print(f'Testing the connections of {len(sorted_channels)} TVE channels using {args.max_workers} workers...')
    
    # Test channels in parallel
    with ThreadPoolExecutor(max_workers=args.max_workers) as executor:
        # Submit all test jobs
        future_to_channel = {
            executor.submit(test_channel, ch_num, tve_channels[ch_num], ip_address, port_number): ch_num
            for ch_num in sorted_channels
        }
        
        # Process results as they complete
        for future in as_completed(future_to_channel):
            ch_number, ch_name, success, error = future.result()
            
            if success:
                print(f'  #{ch_number} ({ch_name}): OK')
                passed_channels[ch_number] = ch_name
            else:
                print(f'  #{ch_number} ({ch_name}): FAILED - {error}')
                failed_channels[ch_number] = {'name': ch_name, 'error': error}

    # Update failure log
    DVR.update_failure_log(failed_channels, passed_channels)
    
    # Send email if configured and there are failures
    if DVR.email_config and failed_channels:
        DVR.send_results_email(passed_channels, failed_channels)
        