#!/usr/bin/env python
"""Google Photos synchronization module for iCloud Photos"""

import json
import logging
import os
import tempfile
from pathlib import Path
from typing import Any, Callable, Dict

from icloudpd.google_photos_client import GooglePhotosClient


class AlbumMapping:
    """Manages album mappings between iCloud Photos and Google Photos"""

    def __init__(self, mapping_file: str, logger: logging.Logger | None = None):
        """
        Initialize album mapping.

        Args:
            mapping_file: Path to JSON file containing album mappings
            logger: Optional logger instance
        """
        self.logger = logger or logging.getLogger(__name__)
        self.mapping_file = mapping_file
        self.mappings: Dict[str, str] = {}
        self.google_album_ids: Dict[str, str] = {}
        self._mapping_data: Dict[str, Any] = {}

        self._load_mappings()

    def _load_mappings(self) -> None:
        """Load album mappings from JSON file"""
        if os.path.exists(self.mapping_file):
            try:
                with open(self.mapping_file, encoding="utf-8") as file_obj:
                    data = json.load(file_obj)
                    self._mapping_data = data
                    self.mappings = data.get("album_mappings", {})
                    self.google_album_ids = data.get("google_album_ids", {})
                    self.logger.info(f"Loaded {len(self.mappings)} album mappings")
            except Exception as e:
                self.logger.error(f"Failed to load album mappings: {e}")
                self.mappings = {}
        else:
            self.logger.warning(f"Album mapping file not found: {self.mapping_file}")
            self.mappings = {}

    def _save_album_ids(self) -> None:
        """Persist stable Google album IDs without losing user-defined fields."""
        mapping_path = Path(self.mapping_file)
        mapping_path.parent.mkdir(parents=True, exist_ok=True)
        self._mapping_data["album_mappings"] = self.mappings
        self._mapping_data["google_album_ids"] = self.google_album_ids

        temporary_path: str | None = None
        try:
            with tempfile.NamedTemporaryFile(
                "w",
                encoding="utf-8",
                dir=mapping_path.parent,
                prefix=f".{mapping_path.name}.",
                suffix=".tmp",
                delete=False,
            ) as file_obj:
                json.dump(self._mapping_data, file_obj, indent=2, sort_keys=True)
                file_obj.write("\n")
                temporary_path = file_obj.name
            os.replace(temporary_path, mapping_path)
        finally:
            if temporary_path and os.path.exists(temporary_path):
                os.unlink(temporary_path)

    def get_google_album_name(self, icloud_album_name: str) -> str | None:
        """
        Get Google Photos album name for an iCloud album.

        Args:
            icloud_album_name: Name of the iCloud album

        Returns:
            Google Photos album name or None if no mapping exists
        """
        return self.mappings.get(icloud_album_name)

    def should_sync_album(self, icloud_album_name: str) -> bool:
        """
        Check if an iCloud album should be synced to Google Photos.

        Args:
            icloud_album_name: Name of the iCloud album

        Returns:
            True if the album should be synced, False otherwise
        """
        return icloud_album_name in self.mappings

    def get_or_cache_album_id(
        self, google_album_name: str, google_client: GooglePhotosClient
    ) -> str | None:
        """
        Get or cache Google Photos album ID.

        Args:
            google_album_name: Name of the Google Photos album
            google_client: Google Photos client instance

        Returns:
            Album ID if found/created, None otherwise
        """
        if google_album_name in self.google_album_ids:
            return self.google_album_ids[google_album_name]

        # Get or create album
        album_id = google_client.get_or_create_album(google_album_name)
        if album_id:
            self.google_album_ids[google_album_name] = album_id
            self._save_album_ids()

        return album_id


class GooglePhotosSync:
    """Handles synchronization of photos to Google Photos"""

    def __init__(
        self,
        google_client: GooglePhotosClient,
        album_mapping: AlbumMapping,
        logger: logging.Logger | None = None,
    ):
        """
        Initialize Google Photos sync.

        Args:
            google_client: Google Photos client instance
            album_mapping: Album mapping instance
            logger: Optional logger instance
        """
        self.google_client = google_client
        self.album_mapping = album_mapping
        self.logger = logger or logging.getLogger(__name__)
        self.uploaded_files: Dict[str, bool] = {}  # Track uploaded files

    def sync_photo(
        self, file_path: str, icloud_album_name: str | None = None, description: str | None = None
    ) -> bool:
        """
        Sync a photo to Google Photos.

        Args:
            file_path: Path to the photo file
            icloud_album_name: Name of the source iCloud album
            description: Optional description for the photo

        Returns:
            True if successfully synced, False otherwise
        """
        # Check if file was already uploaded in this session
        if file_path in self.uploaded_files:
            self.logger.debug(f"Already synced in this session: {os.path.basename(file_path)}")
            return self.uploaded_files[file_path]

        # Check if we should sync this album
        if icloud_album_name and not self.album_mapping.should_sync_album(icloud_album_name):
            self.logger.debug(
                f"Album '{icloud_album_name}' not configured for sync, skipping {os.path.basename(file_path)}"
            )
            return False

        # Get Google Photos album name
        google_album_name = None
        album_id = None

        if icloud_album_name:
            google_album_name = self.album_mapping.get_google_album_name(icloud_album_name)
            if google_album_name:
                album_id = self.album_mapping.get_or_cache_album_id(
                    google_album_name, self.google_client
                )
                if not album_id:
                    self.logger.error(
                        f"Failed to get/create Google Photos album: {google_album_name}"
                    )
                    self.uploaded_files[file_path] = False
                    return False

        # Upload and create media item
        success = self.google_client.upload_and_create(file_path, album_id, description)

        if success:
            album_info = f" to album '{google_album_name}'" if google_album_name else ""
            self.logger.info(f"Synced to Google Photos{album_info}: {os.path.basename(file_path)}")
        else:
            self.logger.error(f"Failed to sync to Google Photos: {os.path.basename(file_path)}")

        # Cache result
        self.uploaded_files[file_path] = success
        return success


def create_sample_mapping_file(output_path: str) -> None:
    """
    Create a sample album mapping configuration file.

    Args:
        output_path: Path where the sample file should be created
    """
    sample_config = {
        "_comment": "Map iCloud Photos albums to Google Photos albums",
        "_usage": "Add mappings in the format: 'iCloud Album Name': 'Google Photos Album Name'",
        "album_mappings": {
            "Vacation 2024": "Vacation 2024",
            "Family Photos": "Family",
            "Screenshots": "Screenshots",
        },
    }

    with open(output_path, "w", encoding="utf-8") as file_obj:
        json.dump(sample_config, file_obj, indent=2)

    print(f"Sample album mapping file created: {output_path}")
    print("Edit this file to configure your album mappings.")


def build_google_photos_uploader(
    credentials_path: str | None,
    mapping_file: str | None,
    logger: logging.Logger,
    enabled: bool = False,
) -> Callable[[str, str | None], bool] | None:
    """
    Build a Google Photos uploader function if enabled.

    Args:
        credentials_path: Path to Google OAuth2 credentials
        mapping_file: Path to album mapping configuration
        logger: Logger instance
        enabled: Whether Google Photos sync is enabled

    Returns:
        Upload function or None if disabled
    """
    if not enabled:
        return None

    if not credentials_path:
        logger.warning("Google Photos sync enabled but no credentials path provided")
        return None

    if not mapping_file:
        logger.warning("Google Photos sync enabled but no mapping file provided")
        return None

    try:
        # Initialize Google Photos client
        google_client = GooglePhotosClient(credentials_path, logger)

        # Initialize album mapping
        album_mapping = AlbumMapping(mapping_file, logger)

        # Create sync instance
        sync = GooglePhotosSync(google_client, album_mapping, logger)

        # Return a simple upload function
        def upload_photo(file_path: str, album_name: str | None = None) -> bool:
            return sync.sync_photo(file_path, album_name)

        logger.info("Google Photos sync initialized successfully")
        return upload_photo
    except Exception as e:
        logger.error(f"Failed to initialize Google Photos sync: {e}")
        return None
