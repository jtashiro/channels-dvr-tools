#!/usr/bin/env python3
"""
Alternative torrent search using direct web scraping.
Note: Only use this for legal, non-copyrighted content.
"""

import requests
from bs4 import BeautifulSoup
import re
import os
import json
from pathlib import Path


def load_config(config_file='.config'):
    """
    Load configuration from a JSON config file.
    
    Expected format:
    {
        "transmission": {
            "host": "localhost",
            "port": 9091,
            "username": "user",
            "password": "pass"
        }
    }
    
    Args:
        config_file: Path to config file (default: .config in current directory)
    
    Returns:
        dict: Configuration dictionary or empty dict if file doesn't exist
    """
    config_path = Path(config_file)
    
    if not config_path.exists():
        return {}
    
    try:
        with open(config_path, 'r') as f:
            return json.load(f)
    except json.JSONDecodeError as e:
        print(f"Warning: Invalid JSON in config file: {e}")
        return {}
    except Exception as e:
        print(f"Warning: Error reading config file: {e}")
        return {}


def search_torrents(query, api_url='https://apibay.org', debug=False):
    """
    Search for torrents using the API. Use only for legal content!
    """
    # The site uses an API endpoint for search
    search_url = f"{api_url}/q.php?q={query}"
    
    if debug:
        print(f"[DEBUG] API Search URL: {search_url}")
    
    try:
        headers = {
            'User-Agent': 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36'
        }
        
        if debug:
            print(f"[DEBUG] Sending request with headers: {headers}")
        
        response = requests.get(search_url, headers=headers, timeout=10)
        
        if debug:
            print(f"[DEBUG] Response status code: {response.status_code}")
            print(f"[DEBUG] Response content length: {len(response.text)} bytes")
        
        response.raise_for_status()
        
        # API returns JSON
        data = response.json()
        
        if debug:
            print(f"[DEBUG] API returned {len(data)} results")
            if data:
                print(f"[DEBUG] First result keys: {list(data[0].keys())}")
        
        torrents = []
        
        for idx, item in enumerate(data, 1):
            try:
                # Check if valid result (API returns error object for no results)
                if item.get('id') == '0' or item.get('name') == 'No results returned':
                    if debug:
                        print(f"[DEBUG] No results indicator found")
                    continue
                
                name = item.get('name', 'Unknown')
                info_hash = item.get('info_hash', '')
                size_bytes = int(item.get('size', 0))
                seeds = item.get('seeders', '0')
                leeches = item.get('leechers', '0')
                category = item.get('category', 'Unknown')
                
                # Convert size to human readable
                size = format_size(size_bytes)
                
                # Build magnet link
                magnet_link = None
                if info_hash:
                    magnet_link = f"magnet:?xt=urn:btih:{info_hash}&dn={requests.utils.quote(name)}"
                    # Add trackers
                    trackers = [
                        'udp://tracker.coppersurfer.tk:6969/announce',
                        'udp://tracker.openbittorrent.com:6969/announce',
                        'udp://9.rarbg.to:2710/announce',
                        'udp://9.rarbg.me:2780/announce',
                        'udp://tracker.opentrackr.org:1337/announce',
                    ]
                    for tracker in trackers:
                        magnet_link += f"&tr={requests.utils.quote(tracker)}"
                
                torrents.append({
                    'name': name,
                    'magnet': magnet_link,
                    'seeds': seeds,
                    'leeches': leeches,
                    'size': size,
                    'size_bytes': size_bytes,
                    'id': item.get('id', 'unknown'),
                    'category': category
                })
                
                if debug and idx <= 3:
                    print(f"[DEBUG] Added torrent: {name} ({size}, {seeds} seeds)")
                
            except Exception as e:
                if debug:
                    print(f"[DEBUG] Error parsing item {idx}: {e}")
                continue
        
        if debug:
            print(f"[DEBUG] Total torrents parsed: {len(torrents)}")
        
        return torrents
        
    except requests.RequestException as e:
        print(f"Error fetching search results: {e}")
        if debug:
            import traceback
            print(f"[DEBUG] Full traceback:")
            traceback.print_exc()
        return []
    except ValueError as e:
        print(f"Error parsing JSON response: {e}")
        if debug:
            print(f"[DEBUG] Response text: {response.text[:500]}")
        return []


def format_size(size_bytes):
    """Convert bytes to human-readable format."""
    for unit in ['B', 'KiB', 'MiB', 'GiB', 'TiB']:
        if size_bytes < 1024.0:
            return f"{size_bytes:.2f} {unit}"
        size_bytes /= 1024.0
    return f"{size_bytes:.2f} PiB"


def parse_episode_info(name):
    """Extract season and episode information from torrent name."""
    # Common patterns: S01E02, 1x02, s01e02, etc.
    patterns = [
        r'[Ss](\d+)[Ee](\d+)',  # S01E02, s01e02
        r'(\d+)[xX](\d+)',       # 1x02, 1X02
        r'[Ss]eason\s*(\d+).*[Ee]pisode\s*(\d+)',  # Season 1 Episode 2
    ]
    
    for pattern in patterns:
        match = re.search(pattern, name)
        if match:
            season = int(match.group(1))
            episode = int(match.group(2))
            return (season, episode)
    
    return None


def parse_quality(name):
    """Extract quality information from torrent name."""
    name_upper = name.upper()
    
    # Quality scores (higher is better)
    quality_scores = {
        '2160P': 400, '4K': 400,
        '1080P': 300,
        '720P': 200,
        '480P': 100,
        '360P': 50,
    }
    
    # Encoding scores
    encoding_scores = {
        'X265': 50, 'HEVC': 50, 'H265': 50,
        'X264': 30, 'H264': 30,
        'XVID': 10,
    }
    
    # Source scores
    source_scores = {
        'BLURAY': 40, 'BLU-RAY': 40,
        'WEBRIP': 30, 'WEB-RIP': 30,
        'WEBDL': 30, 'WEB-DL': 30,
        'HDTV': 20,
        'DVDRIP': 10,
    }
    
    score = 0
    
    for quality, pts in quality_scores.items():
        if quality in name_upper:
            score += pts
            break
    
    for encoding, pts in encoding_scores.items():
        if encoding in name_upper:
            score += pts
            break
    
    for source, pts in source_scores.items():
        if source in name_upper:
            score += pts
            break
    
    return score


def deduplicate_episodes(torrents, debug=False):
    """
    Group torrents by episode, keep only the best quality with most seeds.
    Returns sorted list of unique episodes.
    """
    episodes = {}
    
    for torrent in torrents:
        ep_info = parse_episode_info(torrent['name'])
        
        if not ep_info:
            # Not an episode, keep it with a unique key
            unique_key = f"non_episode_{torrent['id']}"
            episodes[unique_key] = torrent
            continue
        
        season, episode = ep_info
        ep_key = (season, episode)
        
        # Calculate quality score
        quality_score = parse_quality(torrent['name'])
        seeds = int(torrent.get('seeds', 0))
        
        # Combined score: quality is more important than seeds
        torrent['quality_score'] = quality_score
        torrent['combined_score'] = quality_score * 100 + seeds
        torrent['episode_info'] = ep_info
        
        if debug:
            print(f"[DEBUG] {torrent['name'][:50]}... - S{season:02d}E{episode:02d} - Quality: {quality_score}, Seeds: {seeds}")
        
        # Keep the best one for this episode
        if ep_key not in episodes or torrent['combined_score'] > episodes[ep_key]['combined_score']:
            episodes[ep_key] = torrent
    
    # Sort by episode info
    sorted_episodes = []
    
    # First add episodes (sorted by season/episode)
    episode_items = [(k, v) for k, v in episodes.items() if isinstance(k, tuple)]
    episode_items.sort(key=lambda x: x[0])  # Sort by (season, episode) tuple
    sorted_episodes.extend([v for k, v in episode_items])
    
    # Then add non-episodes
    non_episodes = [v for k, v in episodes.items() if not isinstance(k, tuple)]
    sorted_episodes.extend(non_episodes)
    
    return sorted_episodes


def extract_show_name(torrent_name):
    """Extract clean show name from torrent filename."""
    # Remove common patterns to isolate show name
    name = torrent_name
    
    # Remove season/episode patterns
    name = re.sub(r'[Ss]\d+[Ee]\d+.*$', '', name)
    name = re.sub(r'\d+[xX]\d+.*$', '', name)
    name = re.sub(r'[Ss]eason\s*\d+.*$', '', name, flags=re.IGNORECASE)
    
    # Remove year in parentheses
    name = re.sub(r'\(\d{4}\)', '', name)
    
    # Remove quality/encoding info
    name = re.sub(r'\b(720[Pp]|1080[Pp]|2160[Pp]|4[Kk]|[Xx]26[45]|[Hh]26[45]|HEVC|WEB-?DL|WEB-?RIP|BluRay|HDTV|DVDRip)\b.*$', '', name, flags=re.IGNORECASE)
    
    # Remove special characters and extra spaces
    name = re.sub(r'[._\-]+', ' ', name)
    name = ' '.join(name.split()).strip()
    
    return name


def add_to_transmission(torrents, host='localhost', port=9091, username=None, password=None, download_dir=None, show_name=None, debug=False):
    """Add torrents to Transmission using torrent_manager."""
    import subprocess
    
    added_count = 0
    failed_count = 0
    
    for torrent in torrents:
        if not torrent.get('magnet'):
            print(f"[SKIP] No magnet link for: {torrent['name']}")
            continue
        
        ep_info = torrent.get('episode_info')
        if ep_info:
            season, episode = ep_info
            print(f"\n[ADD] S{season:02d}E{episode:02d}: {torrent['name']}")
        else:
            print(f"\n[ADD] {torrent['name']}")
        
        print(f"      Seeds: {torrent['seeds']} | Size: {torrent['size']} | Quality Score: {torrent.get('quality_score', 0)}")
        
        # Determine download directory - only set if explicitly provided
        # Otherwise, let transmission-daemon use its default download directory
        target_dir = download_dir
        
        if target_dir and debug:
            print(f"[DEBUG] Using custom download directory: {target_dir}")
        elif debug:
            print(f"[DEBUG] Using transmission-daemon default download directory")
        
        # Build command
        cmd = ['python3', 'torrent_manager.py']
        
        if host != 'localhost':
            cmd.extend(['--host', host])
        if port != 9091:
            cmd.extend(['--port', str(port)])
        if username:
            cmd.extend(['--username', username])
        if password:
            cmd.extend(['--password', password])
        
        cmd.append('add')
        cmd.append(torrent['magnet'])
        
        if target_dir:
            cmd.extend(['--dir', target_dir])
        
        if debug:
            print(f"[DEBUG] Running: {' '.join(cmd[:5])}... add [magnet] {'--dir ' + target_dir if target_dir else ''}")
        
        try:
            result = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
            if result.returncode == 0:
                print(f"      ✓ Added successfully")
                if target_dir:
                    print(f"      → {target_dir}")
                added_count += 1
            else:
                # Collect all error information
                error_msg = result.stderr.strip() or result.stdout.strip() or f"Exit code {result.returncode}"
                print(f"      ✗ Failed: {error_msg}")
                if debug:
                    print(f"[DEBUG] Command: {' '.join(cmd)}")
                    print(f"[DEBUG] Return code: {result.returncode}")
                    print(f"[DEBUG] Stdout: {result.stdout}")
                    print(f"[DEBUG] Stderr: {result.stderr}")
                failed_count += 1
        except subprocess.TimeoutExpired:
            print(f"      ✗ Error: Command timed out after 30 seconds")
            failed_count += 1
        except FileNotFoundError:
            print(f"      ✗ Error: torrent_manager.py not found or python3 not available")
            failed_count += 1
        except Exception as e:
            print(f"      ✗ Error: {type(e).__name__}: {e}")
            failed_count += 1
    
    print(f"\n{'='*60}")
    print(f"Summary: {added_count} added, {failed_count} failed")
    return added_count, failed_count


def parse_number_range(numbers_str):
    """
    Parse number string like "1,3,5" or "1-3,5" into list of integers.
    
    Args:
        numbers_str: String like "1,3,5" or "1-3,5,7-9"
    
    Returns:
        List of integers
    """
    result = set()
    
    for part in numbers_str.split(','):
        part = part.strip()
        if '-' in part:
            # Handle range like "1-3"
            try:
                start, end = part.split('-')
                result.update(range(int(start), int(end) + 1))
            except ValueError:
                print(f"Warning: Invalid range '{part}', skipping")
        else:
            # Handle single number
            try:
                result.add(int(part))
            except ValueError:
                print(f"Warning: Invalid number '{part}', skipping")
    
    return sorted(result)


def get_category_name(category_id):
    """
    Get friendly category name from ID.
    
    Args:
        category_id: Category ID string
    
    Returns:
        Friendly category name
    """
    CATEGORY_NAMES = {
        # Audio
        '100': 'Audio',
        '101': 'Music',
        '102': 'Audio Books',
        '103': 'Sound Clips',
        '104': 'FLAC',
        '199': 'Audio Other',
        
        # Video
        '200': 'Video',
        '201': 'Movies',
        '202': 'Movies DVDR',
        '203': 'Music Videos',
        '204': 'Movie Clips',
        '205': 'TV Shows',
        '206': 'Handheld',
        '207': 'HD Movies',
        '208': 'HD TV Shows',
        '209': ' 3D Movies',
        '299': 'Video Other',
        
        # Applications
        '300': 'Applications',
        '301': 'Windows',
        '302': 'Mac',
        '303': 'UNIX',
        '304': 'Handheld',
        '305': 'IOS (iPad/iPhone)',
        '306': 'Android',
        '399': 'Applications Other',
        
        # Games
        '400': 'Games',
        '401': 'PC Games',
        '402': 'Mac Games',
        '403': 'PSx',
        '404': 'XBOX360',
        '405': 'Wii',
        '406': 'Handheld',
        '407': 'IOS (iPad/iPhone)',
        '408': 'Android',
        '499': 'Games Other',
        
        # Porn
        '500': 'Porn',
        '501': 'Movies',
        '502': 'Movies DVDR',
        '503': 'Pictures',
        '504': 'Games',
        '505': 'HD Movies',
        '506': 'Movie Clips',
        '599': 'Porn Other',
        
        # Other
        '600': 'Other',
        '601': 'E-books',
        '602': 'Comics',
        '603': 'Pictures',
        '604': 'Covers',
        '605': 'Physibles',
        '699': 'Other Other',
    }
    return CATEGORY_NAMES.get(category_id, f'Category {category_id}')


def parse_category(category_input):
    """
    Parse category input - accepts friendly names or numeric IDs.
    
    Args:
        category_input: Category name (case-insensitive) or numeric ID
    
    Returns:
        Category ID string or None if invalid
    """
    # Category mapping: friendly name -> ID
    CATEGORIES = {
        'audio': '100',
        'music': '100',
        'video': '200',
        'movies': '200',
        'tv': '205',
        'tvshows': '205',
        'tv-shows': '205',
        'hdmovies': '207',
        'hd-movies': '207',
        'hdtv': '208',
        'hd-tv': '208',
        'apps': '300',
        'applications': '300',
        'games': '400',
        'porn': '500',
        'xxx': '500',
        'other': '600',
    }
    
    # If it's already a number, return it
    if category_input.isdigit():
        return category_input
    
    # Try to match friendly name (case-insensitive)
    category_lower = category_input.lower()
    if category_lower in CATEGORIES:
        return CATEGORIES[category_lower]
    
    # Invalid category
    print(f"Warning: Unknown category '{category_input}'")
    print(f"Valid categories: {', '.join(sorted(set(CATEGORIES.keys())))}")
    print(f"Or use numeric ID (100, 200, 205, 207, 208, 300, 400, 500, 600)")
    return None


def main():
    import sys
    import argparse
    
    parser = argparse.ArgumentParser(
        description='Search and download torrents (legal content only)',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Just search and display
  %(prog)s
  
  # Search with debug info
  %(prog)s --debug
  
  # Search and auto-download ALL to Transmission
  %(prog)s --auto-download
  
  # Search and select which ones to download interactively
  %(prog)s --select
  
  # Download specific numbers
  %(prog)s --numbers "1,3,5"
  %(prog)s --numbers "1-3,5,7-9"
  
  # Filter results with minimum seeds
  %(prog)s --min-seeds 5
  %(prog)s --query "Show Name" --min-seeds 10 --select
  
  # Filter by category
  %(prog)s --query "Show Name" --category tv
  %(prog)s --category hdtv --min-seeds 5 --select
  %(prog)s --category "205" --select  # Can also use numeric ID
  
  # Sort by size instead of seeds
  %(prog)s --query "Show Name" --sort-desc size
  %(prog)s --sort-desc seeds  # Default
  
  # Download to specific directory on remote Transmission
  %(prog)s --numbers "1,3" --host 192.168.1.100 --dir /downloads/shows

Config File:
  Create a .config file in the script directory with:
  {
    "transmission": {
      "host": "localhost",
      "port": 9091,
      "username": "your_username",
      "password": "your_password"
    }
  }
  Command line arguments override config file settings.
        """
    )
    
    parser.add_argument('-d', '--debug', action='store_true', help='Enable debug output')
    parser.add_argument('--auto-download', action='store_true', help='Automatically add ALL torrents to Transmission')
    parser.add_argument('--select', action='store_true', help='Interactively select which torrents to download')
    parser.add_argument('--numbers', help='Download specific torrent numbers (e.g., "1,3,5" or "1-3,5")')
    parser.add_argument('--min-seeds', type=int, default=1, help='Minimum number of seeds required (default: 1)')
    parser.add_argument('--category', help='Filter by category (e.g., "tv", "hdtv", "movies", "205")')
    parser.add_argument('--sort-desc', choices=['size', 'seeds'], default='seeds', help='Sort results in descending order by size or seeds (default: seeds)')
    parser.add_argument('--config', default='.config', help='Config file path (default: .config)')
    parser.add_argument('--host', help='Transmission host (overrides config)')
    parser.add_argument('--port', type=int, help='Transmission port (overrides config)')
    parser.add_argument('--username', help='Transmission username (overrides config)')
    parser.add_argument('--password', help='Transmission password (overrides config)')
    parser.add_argument('--dir', help='Download directory in Transmission (auto-detects for TV shows if not specified)')
    parser.add_argument('--show-name', help='Override auto-detected show name for directory structure')
    parser.add_argument('--query', help='Search query (skip interactive prompt)')
    
    args = parser.parse_args()
    
    # Load config file
    config = load_config(args.config)
    transmission_config = config.get('transmission', {})
    
    if args.debug and config:
        print(f"[DEBUG] Loaded config from {args.config}")
        if transmission_config:
            print(f"[DEBUG] Transmission config: host={transmission_config.get('host')}, port={transmission_config.get('port')}, username={'***' if transmission_config.get('username') else 'None'}")
    
    # Merge config file and command line args (CLI args take precedence)
    host = args.host or transmission_config.get('host', 'localhost')
    port = args.port or transmission_config.get('port', 9091)
    username = args.username or transmission_config.get('username')
    password = args.password or transmission_config.get('password')
    
    # Example search
    query = args.query if args.query else input("Enter search term: ")
    
    print(f"\nSearching for: {query}")
    print("Note: Only use for legal, non-copyrighted content!\n")
    
    if args.debug:
        print("[DEBUG] Debug mode enabled\n")
    
    results = search_torrents(query, debug=args.debug)
    
    if not results:
        print("No results found or error occurred.")
        return
    
    print(f"Found {len(results)} results before deduplication")
    
    # Deduplicate and sort by episode
    unique_results = deduplicate_episodes(results, debug=args.debug)
    
    # Filter by category
    if args.category:
        category_id = parse_category(args.category)
        if category_id:
            before_filter = len(unique_results)
            unique_results = [t for t in unique_results if t.get('category') == category_id]
            filtered = before_filter - len(unique_results)
            if filtered > 0:
                print(f"Filtered out {filtered} torrent(s) not in category {category_id}")
        else:
            print("Category filter ignored due to invalid input")
            args.category = None  # Clear invalid category for display
    
    # Filter by minimum seeds
    if args.min_seeds > 0:
        before_filter = len(unique_results)
        unique_results = [t for t in unique_results if int(t.get('seeds', 0)) >= args.min_seeds]
        filtered = before_filter - len(unique_results)
        if filtered > 0:
            print(f"Filtered out {filtered} torrent(s) with less than {args.min_seeds} seeds")
    
    # Sort results
    if args.sort_desc == 'seeds':
        unique_results.sort(key=lambda t: int(t.get('seeds', 0)), reverse=True)
    elif args.sort_desc == 'size':
        unique_results.sort(key=lambda t: int(t.get('size_bytes', 0)), reverse=True)
    
    print(f"\n{'='*60}")
    print(f"After deduplication: {len(unique_results)} unique episodes/files")
    if args.category:
        print(f"Category filter: {args.category}")
    if args.min_seeds > 0:
        print(f"Minimum seeds: {args.min_seeds}")
    print(f"Sort: {args.sort_desc} (descending)")
    print(f"{'='*60}\n")
    
    # Display results
    for i, torrent in enumerate(unique_results, 1):
        ep_info = torrent.get('episode_info')
        if ep_info:
            season, episode = ep_info
            print(f"{i}. S{season:02d}E{episode:02d}: {torrent['name']}")
        else:
            print(f"{i}. {torrent['name']}")
        
        category_id = torrent.get('category', 'Unknown')
        category_name = get_category_name(category_id) if category_id != 'Unknown' else 'Unknown'
        print(f"   Size: {torrent['size']} | Seeds: {torrent['seeds']} | Quality: {torrent.get('quality_score', 0)} | Category: {category_name}")
        if torrent['magnet']:
            print(f"   Magnet: {torrent['magnet'][:80]}...")
        print()
    
    # Determine which torrents to download
    torrents_to_download = []
    
    if args.auto_download:
        # Download all
        torrents_to_download = unique_results
    elif args.numbers:
        # Download specific numbers
        numbers = parse_number_range(args.numbers)
        for num in numbers:
            if 1 <= num <= len(unique_results):
                torrents_to_download.append(unique_results[num - 1])
            else:
                print(f"Warning: Number {num} is out of range (1-{len(unique_results)})")
    elif args.select:
        # Interactive selection
        print("\nEnter torrent numbers to download (e.g., '1,3,5' or '1-3,5' or 'all'):")
        selection = input("> ").strip()
        
        if selection.lower() == 'all':
            torrents_to_download = unique_results
        else:
            numbers = parse_number_range(selection)
            for num in numbers:
                if 1 <= num <= len(unique_results):
                    torrents_to_download.append(unique_results[num - 1])
                else:
                    print(f"Warning: Number {num} is out of range (1-{len(unique_results)})")
    
    # Download selected torrents
    if torrents_to_download:
        print(f"\nAdding {len(torrents_to_download)} torrent(s) to Transmission...\n")
        add_to_transmission(
            torrents_to_download,
            host=host,
            port=port,
            username=username,
            password=password,
            download_dir=args.dir,
            show_name=args.show_name,
            debug=args.debug
        )
    else:
        print("\nNo torrents selected for download.")
        print("Use --auto-download, --select, or --numbers to download torrents.")


if __name__ == '__main__':
    main()
