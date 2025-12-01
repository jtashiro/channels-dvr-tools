#!/usr/bin/env python3
"""
Torrent Manager - Download legal content via Transmission
Useful for: Linux ISOs, open-source software, Creative Commons content, etc.
"""

import argparse
import sys

try:
    import transmission_rpc
except ImportError:
    print("Error: transmission-rpc library not installed")
    print("Install with: pip install transmission-rpc")
    sys.exit(1)


class TorrentManager:
    """Manage torrents via Transmission RPC."""
    
    def __init__(self, host='localhost', port=9091, username=None, password=None):
        """Initialize connection to Transmission daemon."""
        try:
            self.client = transmission_rpc.Client(
                host=host,
                port=port,
                username=username,
                password=password
            )
            print(f"Connected to Transmission at {host}:{port}")
        except Exception as e:
            print(f"Error connecting to Transmission: {e}")
            sys.exit(1)
    
    def add_magnet(self, magnet_link, download_dir=None):
        """Add a magnet link to Transmission."""
        try:
            torrent = self.client.add_torrent(
                magnet_link,
                download_dir=download_dir
            )
            print(f"Added torrent: {torrent.name}")
            print(f"  ID: {torrent.id}")
            print(f"  Status: {torrent.status}")
            return torrent
        except Exception as e:
            print(f"Error adding magnet link: {e}")
            return None
    
    def add_torrent_file(self, torrent_file, download_dir=None):
        """Add a .torrent file to Transmission."""
        try:
            with open(torrent_file, 'rb') as f:
                torrent_data = f.read()
            
            torrent = self.client.add_torrent(
                torrent_data,
                download_dir=download_dir
            )
            print(f"Added torrent: {torrent.name}")
            print(f"  ID: {torrent.id}")
            print(f"  Status: {torrent.status}")
            return torrent
        except Exception as e:
            print(f"Error adding torrent file: {e}")
            return None
    
    def list_torrents(self):
        """List all torrents."""
        try:
            torrents = self.client.get_torrents()
            if not torrents:
                print("No active torrents")
                return
            
            print(f"\nActive torrents ({len(torrents)}):")
            print("-" * 80)
            for torrent in torrents:
                progress = torrent.progress
                status = torrent.status
                print(f"[{torrent.id}] {torrent.name}")
                print(f"    Status: {status} | Progress: {progress:.1f}%")
                print(f"    Size: {torrent.total_size / (1024**3):.2f} GB")
                if torrent.eta:
                    print(f"    ETA: {torrent.eta}")
                print()
        except Exception as e:
            print(f"Error listing torrents: {e}")
    
    def remove_torrent(self, torrent_id, delete_data=False):
        """Remove a torrent by ID."""
        try:
            self.client.remove_torrent(torrent_id, delete_data=delete_data)
            action = "Removed and deleted" if delete_data else "Removed"
            print(f"{action} torrent ID: {torrent_id}")
        except Exception as e:
            print(f"Error removing torrent: {e}")
    
    def get_session_stats(self):
        """Get Transmission session statistics."""
        try:
            stats = self.client.session_stats()
            print("\nSession Statistics:")
            print(f"  Active torrents: {stats.activeTorrentCount}")
            print(f"  Download speed: {stats.downloadSpeed / 1024:.2f} KB/s")
            print(f"  Upload speed: {stats.uploadSpeed / 1024:.2f} KB/s")
            print(f"  Total downloaded: {stats.current_stats['downloadedBytes'] / (1024**3):.2f} GB")
            print(f"  Total uploaded: {stats.current_stats['uploadedBytes'] / (1024**3):.2f} GB")
        except Exception as e:
            print(f"Error getting stats: {e}")


def main():
    parser = argparse.ArgumentParser(
        description="Manage legal torrents via Transmission",
        epilog="Examples of legal content: Linux ISOs, open-source software, Creative Commons media"
    )
    
    parser.add_argument('--host', default='localhost', help='Transmission host (default: localhost)')
    parser.add_argument('--port', type=int, default=9091, help='Transmission port (default: 9091)')
    parser.add_argument('--username', help='Transmission username')
    parser.add_argument('--password', help='Transmission password')
    
    subparsers = parser.add_subparsers(dest='command', help='Commands')
    
    # Add magnet link
    add_parser = subparsers.add_parser('add', help='Add a magnet link')
    add_parser.add_argument('magnet', help='Magnet link to add')
    add_parser.add_argument('--dir', help='Download directory')
    
    # Add torrent file
    file_parser = subparsers.add_parser('add-file', help='Add a .torrent file')
    file_parser.add_argument('file', help='Path to .torrent file')
    file_parser.add_argument('--dir', help='Download directory')
    
    # List torrents
    subparsers.add_parser('list', help='List all torrents')
    
    # Remove torrent
    remove_parser = subparsers.add_parser('remove', help='Remove a torrent')
    remove_parser.add_argument('id', type=int, help='Torrent ID to remove')
    remove_parser.add_argument('--delete-data', action='store_true', help='Also delete downloaded files')
    
    # Stats
    subparsers.add_parser('stats', help='Show session statistics')
    
    args = parser.parse_args()
    
    if not args.command:
        parser.print_help()
        sys.exit(1)
    
    # Initialize manager
    manager = TorrentManager(
        host=args.host,
        port=args.port,
        username=args.username,
        password=args.password
    )
    
    # Execute command
    if args.command == 'add':
        manager.add_magnet(args.magnet, download_dir=args.dir)
    elif args.command == 'add-file':
        manager.add_torrent_file(args.file, download_dir=args.dir)
    elif args.command == 'list':
        manager.list_torrents()
    elif args.command == 'remove':
        manager.remove_torrent(args.id, delete_data=args.delete_data)
    elif args.command == 'stats':
        manager.get_session_stats()


if __name__ == '__main__':
    main()
