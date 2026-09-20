#!/usr/bin/env python
"""Pre-flight mode for simplified authentication and configuration setup"""

import json
import logging
import os
import sys
from typing import Any, Dict

from icloudpd.google_oauth_server import SimplifiedGoogleAuth
from pyicloud_ipd.base import PyiCloudService


class PreFlightMode:
    """
    Pre-flight mode to simplify authentication and configuration setup

    This mode:
    1. Handles Apple iCloud authentication with 2FA support
    2. Handles Google Photos authentication with local OAuth server
    3. Interactively selects albums to sync
    4. Configures media parameters
    5. Saves configuration for future runs
    """

    def __init__(
        self,
        logger: logging.Logger | None = None,
        skip_icloud: bool = False,
        skip_google: bool = False,
    ):
        self.logger = logger or logging.getLogger(__name__)
        self.config: Dict[str, Any] = {}
        self.icloud_service: PyiCloudService | None = None
        self.skip_icloud = skip_icloud
        self.skip_google = skip_google

    def run(self, config_file: str = "icloud_photos_sync_config.json") -> bool:
        """
        Run pre-flight setup

        Args:
            config_file: Path to save configuration

        Returns:
            True if setup successful
        """
        # Load existing config if available
        if os.path.exists(config_file):
            try:
                with open(config_file) as f:
                    self.config = json.load(f)
                    self.logger.info(f"Loaded existing configuration from {config_file}")
            except (OSError, json.JSONDecodeError):
                pass

        self._print_welcome()

        # Step 1: Apple iCloud Authentication
        if not self.skip_icloud:
            if not self._setup_icloud_auth():
                self.logger.error("✗ iCloud authentication failed")
                return False
        else:
            print("\n" + "─" * 70)
            print("Step 1/4: iCloud Authentication")
            print("─" * 70 + "\n")
            print("✓ Using existing iCloud authentication\n")

        # Step 2: Google Photos Authentication
        if not self.skip_google:
            if not self._setup_google_auth():
                self.logger.error("✗ Google Photos authentication failed")
                return False
        else:
            print("\n" + "─" * 70)
            print("Step 2/4: Google Photos Authentication")
            print("─" * 70 + "\n")
            print("✓ Using existing Google Photos authentication\n")

        # Step 3: Album Selection
        if not self._select_albums():
            self.logger.error("✗ Album selection failed")
            return False

        # Step 4: Media Parameters
        if not self._configure_media_parameters():
            self.logger.error("✗ Media parameter configuration failed")
            return False

        # Step 5: Save Configuration
        if not self._save_configuration(config_file):
            self.logger.error("✗ Configuration save failed")
            return False

        self._print_success(config_file)
        return True

    def _print_welcome(self):
        """Print welcome message"""
        print("\n" + "=" * 70)
        print("🚀 iCloud Photos to Google Photos Sync - Pre-Flight Setup")
        print("=" * 70)
        print("\nThis wizard will help you:")
        print("  1. Authenticate with iCloud (including 2FA)")
        print("  2. Authenticate with Google Photos")
        print("  3. Select albums to sync")
        print("  4. Configure media parameters")
        print("  5. Save configuration for future runs")
        print("\n" + "=" * 70 + "\n")

    def _setup_icloud_auth(self) -> bool:
        """Setup iCloud authentication with 2FA support"""
        print("\n" + "─" * 70)
        print("Step 1/4: iCloud Authentication")
        print("─" * 70 + "\n")

        saved_username = self.config.get("username", "")
        if saved_username:
            username_prompt = f"Enter your iCloud email address [{saved_username}]: "
            username = input(username_prompt).strip() or saved_username
        else:
            username = input("Enter your iCloud email address: ").strip()

        if not username:
            self.logger.error("Username is required")
            return False

        self.config["username"] = username
        print("Checking your saved iCloud session and keyring credentials...")
        try:
            import getpass

            from icloudpd.authentication import authenticator
            from icloudpd.mfa_provider import MFAProvider
            from icloudpd.status import StatusExchange
            from pyicloud_ipd.response_types import AuthenticatorSuccess
            from pyicloud_ipd.utils import get_password_from_keyring, store_password_in_keyring

            def prompt_for_password(_username: str) -> str | None:
                print("Your iCloud password is needed. It is sent only to Apple.")
                return getpass.getpass("iCloud password: ") or None

            def save_password(account: str, password: str) -> None:
                try:
                    store_password_in_keyring(account, password)
                except Exception as error:
                    self.logger.warning("Could not save the password to your keyring: %s", error)

            password_providers = {
                "keyring": (get_password_from_keyring, save_password),
                "console": (prompt_for_password, save_password),
            }
            auth_result = authenticator(
                logger=self.logger,
                domain="com",
                password_providers=password_providers,
                mfa_provider=MFAProvider.CONSOLE,
                status_exchange=StatusExchange(),
                username=username,
                notificator=lambda: None,
                response_observer=None,
                cookie_directory=os.path.expanduser("~/.pyicloud"),
                client_id=None,
            )
            match auth_result:
                case AuthenticatorSuccess(service):
                    self.icloud_service = service
                    print("iCloud connected successfully.\n")
                    return True
                case _:
                    self.logger.error(
                        "iCloud authentication was not completed (%s).",
                        type(auth_result).__name__,
                    )
                    return False
        except Exception as error:
            self.logger.error("iCloud authentication failed: %s", error)
            return False

    def _setup_google_auth(self) -> bool:
        """Setup Google Photos authentication"""
        print("\n" + "─" * 70)
        print("Step 2/4: Google Photos Authentication")
        print("─" * 70 + "\n")

        credentials_file = "google_credentials.json"
        token_file = "google_credentials_token.json"

        # Check if credentials file exists
        if not os.path.exists(credentials_file):
            print("\n⚠ Google OAuth credentials not found!")
            print("\nYou need to create OAuth credentials first.")
            print("This is a one-time setup that takes ~5 minutes.")
            print("\nDetailed instructions: https://console.cloud.google.com/")

            cont = (
                input("\nDo you want to see step-by-step instructions? (y/n) [y]: ").strip().lower()
            )
            if cont in ("", "y", "yes"):
                self._show_google_oauth_instructions()

            print("\nAfter creating credentials, save them as 'google_credentials.json'")
            print("in the current directory, then run this wizard again.")
            return False

        print("\nConnecting Google Photos...")
        print("Saved authorization will be reused automatically when it is still valid.")

        try:
            auth = SimplifiedGoogleAuth(credentials_file, self.logger)
            if auth.authenticate():
                self.config["google_credentials"] = credentials_file
                self.config["google_token"] = token_file
                return True
            return False
        except Exception as error:
            self.logger.error("Google authentication failed: %s", error)
            return False

    def _show_google_oauth_instructions(self):
        """Show detailed Google OAuth setup instructions"""
        print("\n" + "=" * 70)
        print("📝 Google OAuth Credentials Setup Guide")
        print("=" * 70)
        print("\n🌐 Step 1: Go to Google Cloud Console")
        print("   → Open: https://console.cloud.google.com/")
        print("")
        print("📁 Step 2: Create or Select a Project")
        print("   → Click 'Select a project' at the top")
        print("   → Click 'NEW PROJECT'")
        print("   → Name: 'iCloud Photos Sync' (or any name)")
        print("   → Click 'CREATE'")
        print("")
        print("🔌 Step 3: Enable Photos Library API")
        print("   → Go to: APIs & Services → Library")
        print("   → Search for 'Photos Library API'")
        print("   → Click on it and click 'ENABLE'")
        print("")
        print("🔑 Step 4: Create OAuth Credentials")
        print("   → Go to: APIs & Services → Credentials")
        print("   → Click '+ CREATE CREDENTIALS' → 'OAuth client ID'")
        print("   → If prompted, configure consent screen:")
        print("     • User Type: External")
        print("     • App name: iCloud Photos Sync")
        print("     • User support email: your email")
        print("     • Developer contact: your email")
        print("     • Click SAVE AND CONTINUE (skip optional fields)")
        print("     • Scopes: Skip, click SAVE AND CONTINUE")
        print("     • Test users: Add your email, click SAVE AND CONTINUE")
        print("")
        print("   → Back to Create OAuth client ID:")
        print("     • Application type: Desktop app")
        print("     • Name: iCloud Photos Sync")
        print("     • Click CREATE")
        print("")
        print("💾 Step 5: Download Credentials")
        print("   → Click DOWNLOAD JSON button")
        print("   → Save the file as 'google_credentials.json'")
        print("   → Place it in this directory:")
        print(f"     {os.getcwd()}/google_credentials.json")
        print("")
        print("=" * 70)
        print("\n✅ After completing these steps, run: ./dist/icloudpd --preflight")
        print("=" * 70 + "\n")

    def _select_albums(self) -> bool:
        """Interactive album selection"""
        print("\n" + "─" * 70)
        print("Step 3/4: Album Selection")
        print("─" * 70 + "\n")

        if not self.icloud_service:
            self.logger.error("iCloud service not initialized")
            return False

        try:
            # Get photos service
            from pyicloud_ipd.response_types import PhotosServiceAccessSuccess

            photos_result = self.icloud_service.get_photos_service()
            match photos_result:
                case PhotosServiceAccessSuccess(photos_service):
                    pass
                case _:
                    self.logger.error("Could not access Photos service")
                    return False

            # Get albums
            print("Fetching your iCloud albums...")
            from pyicloud_ipd.response_types import AlbumsFetchSuccess

            albums_result = photos_service.get_albums()
            match albums_result:
                case AlbumsFetchSuccess(albums_dict):
                    albums = albums_dict
                case _:
                    self.logger.error("Could not fetch albums")
                    return False

            if not albums:
                print("\n⚠ No albums found in your iCloud Photos")
                sync_all = input("Sync all photos from main library? (y/n): ").strip().lower()
                if sync_all == "y":
                    self.config["albums"] = []
                    self.config["album_mappings"] = {}
                    return True
                else:
                    return False

            # Display albums
            print(f"\nFound {len(albums)} albums in your iCloud Photos:")
            print("")

            album_list = list(albums.items())
            for idx, (name, _album) in enumerate(album_list, 1):
                print(f"  {idx:2d}. {name}")

            print("")
            print("Select albums to sync:")
            print("  - Enter album numbers separated by commas (e.g., 1,3,5)")
            print("  - Enter 'all' to sync all albums")
            print("  - Enter 'none' to sync only main library")
            print("")

            selection = input("Your selection: ").strip().lower()

            if selection == "none":
                self.config["albums"] = []
                self.config["album_mappings"] = {}
                return True
            elif selection == "all":
                selected_albums = [name for name, _ in album_list]
            else:
                # Parse selection
                try:
                    indices = [int(i.strip()) for i in selection.split(",")]
                    selected_albums = [
                        album_list[i - 1][0] for i in indices if 1 <= i <= len(album_list)
                    ]
                except (ValueError, IndexError):
                    self.logger.error("Invalid selection")
                    return False

            if not selected_albums:
                self.logger.error("No albums selected")
                return False

            # Create album mappings
            print(f"\nSelected {len(selected_albums)} album(s)")
            print("\nAlbum Mapping Configuration:")
            print("For each iCloud album, specify the Google Photos album name")
            print("(Press Enter to use the same name)")
            print("")

            album_mappings = {}
            for album_name in selected_albums:
                google_name = input(f"  {album_name} → ").strip()
                if not google_name:
                    google_name = album_name
                album_mappings[album_name] = google_name
                print(f"    ✓ {album_name} → {google_name}")

            self.config["albums"] = selected_albums
            self.config["album_mappings"] = album_mappings

            print(f"\n✓ Configured {len(selected_albums)} album(s) for sync")
            return True

        except Exception as e:
            self.logger.error(f"Album selection error: {e}")
            return False

    def _configure_media_parameters(self) -> bool:
        """Configure media download parameters"""
        print("\n" + "─" * 70)
        print("Step 4/4: Media Parameters")
        print("─" * 70 + "\n")

        # Download directory
        default_dir = "./icloud_photos"
        directory = input(f"Download directory [{default_dir}]: ").strip()
        if not directory:
            directory = default_dir
        self.config["directory"] = directory

        # Photo size
        print("\nPhoto size options:")
        print("  1. Original (full resolution)")
        print("  2. Medium (medium resolution)")
        print("  3. Thumb (thumbnail)")
        size_choice = input("Select size [1]: ").strip()

        size_map = {"1": "original", "2": "medium", "3": "thumb", "": "original"}
        self.config["size"] = size_map.get(size_choice, "original")

        # Skip videos
        skip_videos = input("Skip videos? (y/n) [n]: ").strip().lower()
        self.config["skip_videos"] = skip_videos == "y"

        # Skip live photos
        skip_live = input("Skip live photos? (y/n) [n]: ").strip().lower()
        self.config["skip_live_photos"] = skip_live == "y"

        # Folder structure
        print("\nFolder structure options:")
        print("  1. {:%Y/%m/%d} - Year/Month/Day")
        print("  2. {:%Y/%m} - Year/Month")
        print("  3. {:%Y} - Year only")
        print("  4. none - All in download directory")
        structure_choice = input("Select structure [1]: ").strip()

        structure_map = {
            "1": "{:%Y/%m/%d}",
            "2": "{:%Y/%m}",
            "3": "{:%Y}",
            "4": "none",
            "": "{:%Y/%m/%d}",
        }
        self.config["folder_structure"] = structure_map.get(structure_choice, "{:%Y/%m/%d}")

        # Watch mode
        watch = input("\nEnable continuous sync (watch mode)? (y/n) [n]: ").strip().lower()
        if watch == "y":
            interval = input("Sync interval in seconds [3600]: ").strip()
            try:
                self.config["watch_interval"] = int(interval) if interval else 3600
            except ValueError:
                self.config["watch_interval"] = 3600
        else:
            self.config["watch_interval"] = None

        print("\n✓ Media parameters configured")
        return True

    def _save_configuration(self, config_file: str) -> bool:
        """Save configuration to file"""
        try:
            # Create album mapping file
            mapping_file = "album_mapping.json"
            google_album_ids = {}
            if os.path.exists(mapping_file):
                try:
                    with open(mapping_file, encoding="utf-8") as file_obj:
                        google_album_ids = json.load(file_obj).get("google_album_ids", {})
                except (OSError, json.JSONDecodeError):
                    self.logger.warning("Could not preserve existing Google album IDs")
            mapping_config = {
                "album_mappings": self.config.get("album_mappings", {}),
                "google_album_ids": google_album_ids,
            }

            with open(mapping_file, "w") as f:
                json.dump(mapping_config, f, indent=2)

            # Save main config
            config_to_save = {
                "username": self.config.get("username"),
                "directory": self.config.get("directory"),
                "albums": self.config.get("albums", []),
                "size": self.config.get("size", "original"),
                "skip_videos": self.config.get("skip_videos", False),
                "skip_live_photos": self.config.get("skip_live_photos", False),
                "folder_structure": self.config.get("folder_structure", "{:%Y/%m/%d}"),
                "watch_interval": self.config.get("watch_interval"),
                "google_credentials": self.config.get("google_credentials"),
                "google_album_mapping": mapping_file,
            }

            with open(config_file, "w") as f:
                json.dump(config_to_save, f, indent=2)

            self.logger.info(f"✓ Configuration saved to {config_file}")
            self.logger.info(f"✓ Album mapping saved to {mapping_file}")
            return True

        except Exception as e:
            self.logger.error(f"Failed to save configuration: {e}")
            return False

    def _print_success(self, config_file: str):
        """Print success message with next steps"""
        print("\n" + "=" * 70)
        print("✓ Setup Complete!")
        print("=" * 70)
        print("\nYour configuration has been saved.")
        print("\nTo start syncing, run:")
        print("")
        print("  icloudpd \\")

        if self.config.get("username"):
            print(f"    --username {self.config['username']} \\")
        if self.config.get("directory"):
            print(f"    --directory {self.config['directory']} \\")

        albums = self.config.get("albums", [])
        if albums:
            for album in albums:
                print(f'    --album "{album}" \\')

        if self.config.get("google_credentials"):
            print("    --google-photos-sync \\")
            print(f"    --google-photos-credentials {self.config['google_credentials']} \\")
            print(
                f"    --google-photos-album-mapping {self.config.get('google_album_mapping', 'album_mapping.json')} \\"
            )

        if self.config.get("size"):
            print(f"    --size {self.config['size']} \\")

        if self.config.get("skip_videos"):
            print("    --skip-videos \\")

        if self.config.get("skip_live_photos"):
            print("    --skip-live-photos \\")

        if self.config.get("folder_structure"):
            print(f'    --folder-structure "{self.config["folder_structure"]}" \\')

        if self.config.get("watch_interval"):
            print(f"    --watch-with-interval {self.config['watch_interval']}")
        else:
            print("    # Add --watch-with-interval 3600 for continuous sync")

        print("")
        print("=" * 70)
        print("\nConfiguration files created:")
        print(f"  - {config_file}")
        print(f"  - {self.config.get('google_album_mapping', 'album_mapping.json')}")
        print(f"  - {self.config.get('google_credentials', 'google_credentials.json')}")
        print(f"  - {self.config.get('google_token', 'google_credentials_token.json')}")
        print("\n" + "=" * 70 + "\n")


def clear_icloud_credentials():
    """Clear iCloud authentication credentials"""
    import shutil

    cookie_dir = os.path.expanduser("~/.pyicloud")

    if os.path.exists(cookie_dir):
        try:
            shutil.rmtree(cookie_dir)
            print("✓ iCloud credentials cleared")
            print(f"  Removed: {cookie_dir}")
            return True
        except Exception as e:
            print(f"✗ Failed to clear iCloud credentials: {e}")
            return False
    else:
        print("⚠ No iCloud credentials found")
        return True


def clear_google_credentials():
    """Clear Google Photos authentication credentials"""
    files_to_remove = ["google_credentials.json", "google_credentials_token.json"]

    removed = False
    for filename in files_to_remove:
        if os.path.exists(filename):
            try:
                os.remove(filename)
                print(f"✓ Removed: {filename}")
                removed = True
            except Exception as e:
                print(f"✗ Failed to remove {filename}: {e}")
        else:
            print(f"⚠ Not found: {filename}")

    if removed:
        print("✓ Google credentials cleared")
        return True
    else:
        print("⚠ No Google credentials found")
        return True


def clear_all_credentials():
    """Clear both iCloud and Google credentials"""
    print("\n" + "=" * 70)
    print("Clearing all credentials...")
    print("=" * 70 + "\n")

    icloud_ok = clear_icloud_credentials()
    print()
    google_ok = clear_google_credentials()

    print("\n" + "=" * 70)
    if icloud_ok and google_ok:
        print("✓ All credentials cleared successfully")
    else:
        print("⚠ Some credentials could not be cleared")
    print("=" * 70 + "\n")

    return icloud_ok and google_ok


def run_preflight_setup(
    clear_apple: bool = False, clear_google: bool = False, clear_all: bool = False
):
    """Main entry point for pre-flight setup"""
    # Handle credential clearing
    if clear_all:
        clear_all_credentials()
        sys.exit(0)

    if clear_apple:
        clear_icloud_credentials()
        if not clear_google:
            sys.exit(0)

    if clear_google:
        clear_google_credentials()
        sys.exit(0)

    # Setup logging
    logging.basicConfig(format="%(message)s", level=logging.INFO)
    logger = logging.getLogger("preflight")

    # Run setup
    preflight = PreFlightMode(logger)
    success = preflight.run()

    if success:
        sys.exit(0)
    else:
        print("\n✗ Setup failed. Please try again.")
        sys.exit(1)


if __name__ == "__main__":
    run_preflight_setup()
