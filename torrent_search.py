#!/usr/bin/env python3
"""
Alternative torrent search using direct web scraping.
Note: Only use this for legal, non-copyrighted content.
"""

import requests
from bs4 import BeautifulSoup
import re

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
                    'id': item.get('id', 'unknown')
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
        
        # Determine download directory
        target_dir = download_dir
        if not target_dir:
            # Use temporary download location
            # Default: /Volumes/cloud2-nas/temp-downloads/
            target_dir = '/Volumes/cloud2-nas/temp-downloads'
            
            if debug:
                print(f"[DEBUG] Using temp download directory: {target_dir}")
        
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
                print(f"      ✗ Failed: {result.stderr.strip()}")
                failed_count += 1
        except Exception as e:
            print(f"      ✗ Error: {e}")
            failed_count += 1
    
    print(f"\n{'='*60}")
    print(f"Summary: {added_count} added, {failed_count} failed")
    return added_count, failed_count


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
  
  # Search and auto-download to Transmission
  %(prog)s --auto-download
  
  # Download to specific directory on remote Transmission
  %(prog)s --auto-download --host 192.168.1.100 --dir /downloads/shows
        """
    )
    
    parser.add_argument('-d', '--debug', action='store_true', help='Enable debug output')
    parser.add_argument('--auto-download', action='store_true', help='Automatically add torrents to Transmission')
    parser.add_argument('--host', default='localhost', help='Transmission host (default: localhost)')
    parser.add_argument('--port', type=int, default=9091, help='Transmission port (default: 9091)')
    parser.add_argument('--username', help='Transmission username')
    parser.add_argument('--password', help='Transmission password')
    parser.add_argument('--dir', help='Download directory in Transmission (auto-detects for TV shows if not specified)')
    parser.add_argument('--show-name', help='Override auto-detected show name for directory structure')
    parser.add_argument('--query', help='Search query (skip interactive prompt)')
    
    args = parser.parse_args()
    
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
    
    print(f"\n{'='*60}")
    print(f"After deduplication: {len(unique_results)} unique episodes/files")
    print(f"{'='*60}\n")
    
    if not args.auto_download:
        # Just display results
        for i, torrent in enumerate(unique_results, 1):
            ep_info = torrent.get('episode_info')
            if ep_info:
                season, episode = ep_info
                print(f"{i}. S{season:02d}E{episode:02d}: {torrent['name']}")
            else:
                print(f"{i}. {torrent['name']}")
            
            print(f"   Size: {torrent['size']} | Seeds: {torrent['seeds']} | Quality: {torrent.get('quality_score', 0)}")
            if torrent['magnet']:
                print(f"   Magnet: {torrent['magnet'][:80]}...")
            print()
        
        print("\nTo automatically download these, run with --auto-download flag")
    else:
        # Add to Transmission
        print("Adding torrents to Transmission...\n")
        add_to_transmission(
            unique_results,
            host=args.host,
            port=args.port,
            username=args.username,
            password=args.password,
            download_dir=args.dir,
            show_name=args.show_name,
            debug=args.debug
        )


if __name__ == '__main__':
    main()
