#!/usr/bin/env python
"""Run iCloud to Google Photos sync from saved configuration"""

import json
import logging
import os
import sys
from typing import Any, Dict

from icloudpd.config import GlobalConfig


def load_config(config_file: str) -> Dict[str, Any]:
    """
    Load configuration from JSON file

    Args:
        config_file: Path to configuration file

    Returns:
        Configuration dictionary

    Raises:
        FileNotFoundError: If config file doesn't exist
        json.JSONDecodeError: If config file is invalid JSON
    """
    if not os.path.exists(config_file):
        raise FileNotFoundError(
            f"Configuration file not found: {config_file}\n"
            f"Run 'icloudpd --preflight' to create configuration."
        )

    with open(config_file) as f:
        config = json.load(f)

    return config


def load_album_mapping(mapping_file: str) -> Dict[str, str]:
    """
    Load album mapping from JSON file

    Args:
        mapping_file: Path to album mapping file

    Returns:
        Album mapping dictionary
    """
    if not os.path.exists(mapping_file):
        return {}

    with open(mapping_file) as f:
        data = json.load(f)

    return data.get("album_mappings", {})


def run_from_config(config_file: str, global_config: GlobalConfig) -> int:
    """
    Run sync using saved configuration

    Args:
        config_file: Path to configuration file
        global_config: Global configuration from CLI

    Returns:
        Exit code (0 for success)
    """
    logger = logging.getLogger(__name__)

    try:
        # Load configuration
        print(f"\n{'=' * 70}")
        print("🚀 iCloud to Google Photos Sync")
        print(f"Loading configuration from: {config_file}")
        print("=" * 70)

        config = load_config(config_file)

        # Display loaded settings
        print("\n📋 Sync Configuration:")
        print(f"  • Username: {config.get('username', 'Not set')}")
        print(f"  • Directory: {config.get('directory', 'Not set')}")

        albums = config.get("albums", [])
        if albums:
            print(f"  • Albums: {len(albums)}")
            for album in albums:
                print(f"    - {album}")
        else:
            print("  • Albums: All photos (no specific albums)")

        print(f"  • Photo size: {config.get('size', 'original')}")
        print(f"  • Skip videos: {config.get('skip_videos', False)}")
        print(f"  • Skip live photos: {config.get('skip_live_photos', False)}")

        folder_structure = config.get("folder_structure")
        if folder_structure:
            print(f"  • Folder structure: {folder_structure}")

        # Google Photos sync
        google_sync = config.get("google_photos_sync", False)
        google_creds = config.get("google_credentials")
        google_mapping = config.get("google_album_mapping")

        if google_sync or google_creds:
            print("\n🌐 Google Photos Sync: ENABLED")
            if google_creds:
                print(f"  • Credentials: {google_creds}")
            if google_mapping:
                print(f"  • Album mapping: {google_mapping}")
                # Load and display mapping
                try:
                    mappings = load_album_mapping(google_mapping)
                    if mappings:
                        print("  • Album mappings:")
                        for icloud_album, google_album in mappings.items():
                            print(f"    - {icloud_album} → {google_album}")
                except Exception as e:
                    logger.warning(f"Could not load album mapping: {e}")
        else:
            print("\n🌐 Google Photos Sync: DISABLED")

        watch_interval = config.get("watch_interval")
        if watch_interval:
            print(f"\n⏱️  Watch mode: ENABLED (interval: {watch_interval}s)")

        print("\n" + "=" * 70)

        # Confirm
        proceed = input("\nStart sync with these settings? (y/n) [y]: ").strip().lower()
        if proceed not in ("", "y", "yes"):
            print("Sync cancelled.")
            return 0

        print("\n🚀 Starting sync...\n")
        print("=" * 70 + "\n")

        # Build command-line arguments from config
        args = []

        # Required arguments
        username = config.get("username")
        if not username:
            print("❌ Error: Username not found in configuration")
            return 1
        args.extend(["--username", username])

        directory = config.get("directory")
        if not directory:
            print("❌ Error: Directory not found in configuration")
            return 1

        # Expand and create directory if it doesn't exist
        directory = os.path.expanduser(directory)
        if not os.path.exists(directory):
            os.makedirs(directory, exist_ok=True)
            print(f"📁 Created download directory: {directory}")
        else:
            print(f"📁 Download directory: {directory}")

        args.extend(["--directory", directory])

        # Albums
        albums_list = config.get("albums", [])
        for album in albums_list:
            args.extend(["--album", album])

        # Google Photos sync
        if google_creds:
            args.append("--google-photos-sync")
            args.extend(["--google-photos-credentials", google_creds])
            if google_mapping:
                args.extend(["--google-photos-album-mapping", google_mapping])

        # Size
        size = config.get("size", "original")
        args.extend(["--size", size])

        # Skip options
        if config.get("skip_videos", False):
            args.append("--skip-videos")
        if config.get("skip_live_photos", False):
            args.append("--skip-live-photos")

        # Folder structure
        folder_structure = config.get("folder_structure")
        if folder_structure:
            args.extend(["--folder-structure", folder_structure])

        # Watch mode
        watch_interval = config.get("watch_interval")
        if watch_interval:
            args.extend(["--watch-with-interval", str(watch_interval)])

        # Log level
        log_level_str = config.get("log_level", "info")
        args.extend(["--log-level", log_level_str])

        # Print the command being run
        print("\n💻 Running equivalent command:")
        print("  icloudpd \\")
        i = 0
        while i < len(args):
            arg = args[i]
            if arg.startswith("--"):
                # This is a flag
                if i + 1 < len(args) and not args[i + 1].startswith("--"):
                    # Next arg is a value for this flag
                    value = args[i + 1]
                    if " " in value or "/" in value or ":" in value:
                        print(f'    {arg} "{value}" \\')
                    else:
                        print(f"    {arg} {value} \\")
                    i += 2
                else:
                    # Flag without value (boolean flag)
                    print(f"    {arg} \\")
                    i += 1
            else:
                # Standalone value (shouldn't happen)
                print(f"    {arg} \\")
                i += 1
        print("\n" + "=" * 70 + "\n")

        # Run the sync using the existing CLI
        # Import and call the main download function
        from icloudpd import cli

        # Save original sys.argv
        original_argv = sys.argv

        try:
            # Replace sys.argv with our constructed arguments
            sys.argv = ["icloudpd"] + args

            # Parse and run
            result = cli.cli()

            return result
        except Exception as e:
            logger.error(f"Error running sync: {e}", exc_info=True)
            return 1
        finally:
            # Restore original sys.argv
            sys.argv = original_argv

    except FileNotFoundError as e:
        print(f"\n❌ Error: {e}\n")
        return 1
    except json.JSONDecodeError as e:
        print(f"\n❌ Error: Invalid JSON in configuration file: {e}\n")
        return 1
    except Exception as e:
        logger.error(f"Error running sync: {e}", exc_info=True)
        return 1


if __name__ == "__main__":
    # For testing
    from icloudpd.config import GlobalConfig, LogLevel, MFAProvider, PasswordProvider

    test_config = GlobalConfig(
        help=False,
        version=False,
        preflight=False,
        sync_from_config=None,
        clear_credentials=None,
        use_os_locale=False,
        only_print_filenames=False,
        log_level=LogLevel.INFO,
        no_progress_bar=False,
        threads_num=1,
        domain="com",
        watch_with_interval=None,
        password_providers=[PasswordProvider.KEYRING, PasswordProvider.CONSOLE],
        mfa_provider=MFAProvider.CONSOLE,
    )

    sys.exit(run_from_config("icloud_photos_sync_config.json", test_config))
