#!/usr/bin/env python3
"""
Post-processing script for Transmission downloads.
Automatically cleans up and moves completed torrents to Channels DVR directory structure.
"""

import os
import shutil
import re
import argparse
from pathlib import Path
import time


def is_video_file(filename):
    """Check if file is a video file."""
    video_extensions = {'.mkv', '.mp4', '.avi', '.m4v', '.ts', '.mpg', '.mpeg', '.mov'}
    return Path(filename).suffix.lower() in video_extensions


def extract_episode_info(filename):
    """Extract season and episode from filename."""
    patterns = [
        r'[Ss](\d+)[Ee](\d+)',
        r'(\d+)[xX](\d+)',
    ]
    
    for pattern in patterns:
        match = re.search(pattern, filename)
        if match:
            season = int(match.group(1))
            episode = int(match.group(2))
            return (season, episode)
    return None


def extract_show_name(filename):
    """Extract show name from torrent filename."""
    name = filename
    
    # Remove season/episode and everything after
    name = re.sub(r'[Ss]\d+[Ee]\d+.*$', '', name)
    name = re.sub(r'\d+[xX]\d+.*$', '', name)
    name = re.sub(r'[Ss]eason\s*\d+.*$', '', name, flags=re.IGNORECASE)
    
    # Remove year
    name = re.sub(r'\(\d{4}\).*$', '', name)
    name = re.sub(r'\.\d{4}\..*$', '', name)
    
    # Remove quality markers and everything after
    name = re.sub(r'\b(720[Pp]|1080[Pp]|2160[Pp]|4[Kk]|[Xx]26[45]|HEVC|WEB-?DL|WEB-?RIP|BluRay|HDTV|DVDRip)\b.*$', '', name, flags=re.IGNORECASE)
    
    # Clean up separators
    name = re.sub(r'[._\-]+', ' ', name)
    name = ' '.join(name.split()).strip()
    
    return name


def build_episode_filename(show_name, season, episode, original_filename):
    """Build proper episode filename: Show Name - S01E02 - Original Quality.ext"""
    # Extract quality/source info from original
    quality_match = re.search(r'(720[Pp]|1080[Pp]|2160[Pp]|4[Kk])', original_filename, re.IGNORECASE)
    quality = quality_match.group(1).upper() if quality_match else ''
    
    source_match = re.search(r'(WEB-?DL|WEB-?RIP|BluRay|HDTV|DVDRip)', original_filename, re.IGNORECASE)
    source = source_match.group(1).upper().replace('-', '') if source_match else ''
    
    codec_match = re.search(r'([Xx]26[45]|HEVC|[Hh]26[45])', original_filename, re.IGNORECASE)
    codec = codec_match.group(1).upper().replace('X', 'x') if codec_match else ''
    
    # Get extension
    ext = Path(original_filename).suffix
    
    # Build filename parts
    parts = [show_name, f"S{season:02d}E{episode:02d}"]
    if quality:
        parts.append(quality)
    if source:
        parts.append(source)
    if codec:
        parts.append(codec)
    
    return ' '.join(parts) + ext


def process_torrent_directory(torrent_dir, channels_tv_base, show_name_override=None, dry_run=False):
    """
    Process a completed torrent directory.
    
    Args:
        torrent_dir: Path to downloaded torrent directory
        channels_tv_base: Base Channels DVR TV directory
        show_name_override: Optional show name override
        dry_run: If True, only print actions without executing
    
    Returns:
        (success_count, error_count, show_name)
    """
    torrent_path = Path(torrent_dir)
    channels_base = Path(channels_tv_base)
    
    if not torrent_path.exists():
        print(f"Error: Torrent directory not found: {torrent_dir}")
        return (0, 1, None)
    
    print(f"\n{'='*60}")
    print(f"Processing: {torrent_path.name}")
    print(f"Mode: {'DRY RUN' if dry_run else 'LIVE'}")
    print(f"{'='*60}\n")
    
    # Find all video files
    video_files = []
    for item in torrent_path.rglob('*'):
        if item.is_file() and is_video_file(item.name):
            video_files.append(item)
    
    if not video_files:
        print("No video files found!")
        return (0, 1, None)
    
    print(f"Found {len(video_files)} video file(s)")
    
    # Determine show name from first video
    first_video = video_files[0]
    show_name = show_name_override or extract_show_name(first_video.name)
    
    if not show_name:
        print("Error: Could not determine show name!")
        return (0, len(video_files), None)
    
    print(f"Show name: {show_name}\n")
    
    # Create show directory
    show_dir = channels_base / show_name
    
    success_count = 0
    error_count = 0
    
    for video_file in video_files:
        print(f"Processing: {video_file.name}")
        
        # Extract episode info
        ep_info = extract_episode_info(video_file.name)
        
        if not ep_info:
            print(f"  ⚠ Could not extract episode info, keeping original name")
            target_filename = video_file.name
        else:
            season, episode = ep_info
            target_filename = build_episode_filename(show_name, season, episode, video_file.name)
            print(f"  → S{season:02d}E{episode:02d}")
        
        target_path = show_dir / target_filename
        
        print(f"  Target: {target_path}")
        
        if not dry_run:
            try:
                # Create show directory if needed
                show_dir.mkdir(parents=True, exist_ok=True)
                
                # Move file
                shutil.move(str(video_file), str(target_path))
                print(f"  ✓ Moved successfully")
                success_count += 1
            except Exception as e:
                print(f"  ✗ Error: {e}")
                error_count += 1
        else:
            print(f"  [DRY RUN] Would move here")
            success_count += 1
        
        print()
    
    # Clean up empty torrent directory
    if not dry_run and success_count > 0:
        try:
            # Remove any remaining non-video files
            for item in torrent_path.rglob('*'):
                if item.is_file():
                    item.unlink()
            
            # Remove empty directories
            for item in sorted(torrent_path.rglob('*'), key=lambda p: len(p.parts), reverse=True):
                if item.is_dir() and not any(item.iterdir()):
                    item.rmdir()
            
            # Remove main directory if empty
            if not any(torrent_path.iterdir()):
                torrent_path.rmdir()
                print(f"✓ Cleaned up torrent directory")
        except Exception as e:
            print(f"⚠ Warning: Could not fully clean up torrent directory: {e}")
    
    print(f"{'='*60}")
    print(f"Summary: {success_count} succeeded, {error_count} failed")
    print(f"{'='*60}\n")
    
    return (success_count, error_count, show_name)


def monitor_directory(watch_dir, channels_tv_base, interval=60, show_name_override=None,
                     transmission_host='localhost', transmission_port=9091,
                     transmission_username=None, transmission_password=None):
    """
    Monitor a directory for completed torrents and process them.
    
    Args:
        watch_dir: Directory to monitor for completed downloads
        channels_tv_base: Base Channels DVR TV directory
        interval: Check interval in seconds
        show_name_override: Optional show name override
        transmission_host: Transmission host
        transmission_port: Transmission port
        transmission_username: Transmission username
        transmission_password: Transmission password
    """
    watch_path = Path(watch_dir)
    
    if not watch_path.exists():
        print(f"Error: Watch directory not found: {watch_dir}")
        return
    
    print(f"Monitoring: {watch_dir}")
    print(f"Target: {channels_tv_base}")
    print(f"Check interval: {interval} seconds")
    print("Press Ctrl+C to stop\n")
    
    processed = set()
    
    try:
        while True:
            # Look for torrent directories
            for item in watch_path.iterdir():
                if not item.is_dir() or item.name.startswith('.'):
                    continue
                
                if str(item) in processed:
                    continue
                
                # Check if directory looks complete (no .part files)
                part_files = list(item.rglob('*.part'))
                if part_files:
                    continue
                
                # Check if it has video files
                video_files = [f for f in item.rglob('*') if f.is_file() and is_video_file(f.name)]
                if not video_files:
                    continue
                
                print(f"Found completed download: {item.name}")
                torrent_name = item.name
                
                # Process it
                success, errors, show_name = process_torrent_directory(
                    item,
                    channels_tv_base,
                    show_name_override=show_name_override,
                    dry_run=False
                )
                
                if success > 0:
                    processed.add(str(item))
                    
                    # Remove from Transmission after successful processing
                    remove_torrent_from_transmission(
                        torrent_name,
                        host=transmission_host,
                        port=transmission_port,
                        username=transmission_username,
                        password=transmission_password
                    )
            
            time.sleep(interval)
    
    except KeyboardInterrupt:
        print("\n\nStopping monitor...")


def remove_torrent_from_transmission(torrent_name, host='localhost', port=9091, username=None, password=None):
    """
    Remove torrent from Transmission and delete data.
    
    Args:
        torrent_name: Name of torrent to remove
        host: Transmission host
        port: Transmission port
        username: Transmission username
        password: Transmission password
    
    Returns:
        True if removed successfully, False otherwise
    """
    try:
        import transmission_rpc
        
        # Connect to Transmission
        client = transmission_rpc.Client(
            host=host,
            port=port,
            username=username,
            password=password
        )
        
        # Find torrent by name
        torrents = client.get_torrents()
        for torrent in torrents:
            if torrent.name == torrent_name:
                # Remove torrent and delete data
                client.remove_torrent(torrent.id, delete_data=True)
                print(f"  ✓ Removed from Transmission and deleted data")
                return True
        
        print(f"  ⚠ Torrent not found in Transmission: {torrent_name}")
        return False
        
    except ImportError:
        print(f"  ⚠ transmission-rpc not installed, cannot remove from Transmission")
        return False
    except Exception as e:
        print(f"  ⚠ Error removing from Transmission: {e}")
        return False


def process_all_completed(watch_dir, channels_tv_base, show_name_override=None, 
                         transmission_host='localhost', transmission_port=9091, 
                         transmission_username=None, transmission_password=None):
    """
    Process all completed torrents in a directory (one-shot, for cron).
    
    Args:
        watch_dir: Directory containing completed downloads
        channels_tv_base: Base Channels DVR TV directory
        show_name_override: Optional show name override
        transmission_host: Transmission host
        transmission_port: Transmission port
        transmission_username: Transmission username
        transmission_password: Transmission password
    """
    watch_path = Path(watch_dir)
    
    if not watch_path.exists():
        print(f"Error: Watch directory not found: {watch_dir}")
        return
    
    print(f"Scanning: {watch_dir}")
    print(f"Target: {channels_tv_base}\n")
    
    total_success = 0
    total_errors = 0
    processed_count = 0
    
    # Look for torrent directories
    for item in watch_path.iterdir():
        if not item.is_dir() or item.name.startswith('.'):
            continue
        
        # Check if directory looks complete (no .part files)
        part_files = list(item.rglob('*.part'))
        if part_files:
            print(f"Skipping incomplete: {item.name} ({len(part_files)} .part files)")
            continue
        
        # Check if it has video files
        video_files = [f for f in item.rglob('*') if f.is_file() and is_video_file(f.name)]
        if not video_files:
            continue
        
        print(f"Processing: {item.name}")
        torrent_name = item.name
        
        # Process it
        success, errors, show_name = process_torrent_directory(
            item,
            channels_tv_base,
            show_name_override=show_name_override,
            dry_run=False
        )
        
        total_success += success
        total_errors += errors
        if success > 0:
            processed_count += 1
            
            # Remove from Transmission after successful processing
            remove_torrent_from_transmission(
                torrent_name,
                host=transmission_host,
                port=transmission_port,
                username=transmission_username,
                password=transmission_password
            )
    
    if processed_count == 0:
        print("No completed downloads to process.")
    else:
        print(f"\n{'='*60}")
        print(f"TOTAL: Processed {processed_count} torrent(s)")
        print(f"       {total_success} file(s) succeeded, {total_errors} failed")
        print(f"{'='*60}")


def main():
    parser = argparse.ArgumentParser(
        description='Post-process Transmission downloads for Channels DVR',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Process single torrent directory (dry run)
  %(prog)s process /downloads/complete/Show.S01E01 /mnt/cloud2-nas/Imported-TV
  
  # Process and apply changes
  %(prog)s process /downloads/complete/Show.S01E01 /mnt/cloud2-nas/Imported-TV --apply
  
  # Process all completed downloads (for cron)
  %(prog)s process-all /Volumes/cloud2-nas/temp-downloads /mnt/cloud2-nas/Imported-TV
  
  # Monitor directory continuously
  %(prog)s monitor /Volumes/cloud2-nas/temp-downloads /mnt/cloud2-nas/Imported-TV
        """
    )
    
    subparsers = parser.add_subparsers(dest='command', help='Command')
    
    # Process command
    process_parser = subparsers.add_parser('process', help='Process a single torrent directory')
    process_parser.add_argument('torrent_dir', help='Torrent directory to process')
    process_parser.add_argument('channels_tv_base', help='Channels DVR TV base directory')
    process_parser.add_argument('--apply', action='store_true', help='Apply changes (default is dry-run)')
    process_parser.add_argument('--show-name', help='Override auto-detected show name')
    
    # Process-all command (for cron)
    processall_parser = subparsers.add_parser('process-all', help='Process all completed downloads (for cron)')
    processall_parser.add_argument('watch_dir', help='Directory to scan for completed downloads')
    processall_parser.add_argument('channels_tv_base', help='Channels DVR TV base directory')
    processall_parser.add_argument('--show-name', help='Override auto-detected show name')
    
    # Monitor command
    monitor_parser = subparsers.add_parser('monitor', help='Monitor directory for completed downloads')
    monitor_parser.add_argument('watch_dir', help='Directory to monitor')
    monitor_parser.add_argument('channels_tv_base', help='Channels DVR TV base directory')
    monitor_parser.add_argument('--interval', type=int, default=60, help='Check interval in seconds (default: 60)')
    monitor_parser.add_argument('--show-name', help='Override auto-detected show name')
    
    args = parser.parse_args()
    
    if not args.command:
        parser.print_help()
        return
    
    if args.command == 'process':
        process_torrent_directory(
            args.torrent_dir,
            args.channels_tv_base,
            show_name_override=args.show_name,
            dry_run=not args.apply
        )
    elif args.command == 'process-all':
        process_all_completed(
            args.watch_dir,
            args.channels_tv_base,
            show_name_override=args.show_name
        )
    elif args.command == 'monitor':
        monitor_directory(
            args.watch_dir,
            args.channels_tv_base,
            interval=args.interval,
            show_name_override=args.show_name
        )


if __name__ == '__main__':
    main()
