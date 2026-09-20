# Web UI

```{versionadded} 1.21.0
```

`icloudpd` includes a local dashboard for configuring and monitoring an iCloud download or Google Photos sync. Start it with:

```bash
icloudpd --web-ui
```

The browser opens at `http://127.0.0.1:8080`. Enter the Apple ID email address and download directory, optionally select albums and Google Photos settings, then choose **Start sync**. If Apple needs a password or verification code, the dashboard asks for it in the activity panel. Passwords are not placed in command-line arguments or configuration files.

The dashboard listens only on the local loopback interface and allows one active sync at a time. Stop it by pressing `Ctrl+C` in the terminal that launched it.

The original status and authentication UI remains available during command-line runs when `webui` is selected as the [MFA or password provider](authentication):

```bash
icloudpd --username you@example.com --directory ./icloud_photos \
  --password-provider keyring --password-provider webui --mfa-provider webui
```
