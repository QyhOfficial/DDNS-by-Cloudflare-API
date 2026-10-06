# DDNS by Cloudflare API

Automatically update Cloudflare DNS records to implement Dynamic DNS (DDNS). Includes two scripts for different platforms and scenarios, both designed to run as **startup scripts**.

## Scripts

| Script | Platform | Record Type | IP Source |
|--------|----------|-------------|-----------|
| `Windows-update-AAAA-record.ps1` | Windows | AAAA (IPv6) | Parses `ipconfig` output for public IPv6 address |
| `gcp-vm-update-A-record.sh` | Google Cloud Linux VM | A (IPv4) | [GCP VM Metadata endpoint](https://docs.cloud.google.com/compute/docs/metadata/overview) |
| `oci-vm-update-A-record.sh` | Oracle Cloud Linux VM | A (IPv4) | [icanhazip.com](https://icanhazip.com) |

Both scripts follow the same workflow: get current IP -> query existing Cloudflare record -> update if changed.

## Prerequisites

- A domain managed by Cloudflare
- A [Cloudflare API Token](https://dash.cloudflare.com/profile/api-tokens) with DNS edit permission

## Configuration

Each script requires the following settings:

| Variable | Description |
|----------|-------------|
| `CLOUDFLARE_API_TOKEN` | Cloudflare API Token |
| `CLOUDFLARE_ZONE_NAME` | Root domain, e.g. `example.com` |
| `CLOUDFLARE_RECORD_NAME` | Subdomain prefix (default: `omen` / `gcp` / `oci`) |

- **Google Cloud script**: Edit the variables directly in the script before deploying.
- **Windows / Oracle Cloud script**: Read from environment variables. See the setup sections below for how to configure them.

## Setup as Startup Script

### Windows (Task Scheduler)

1. Set system environment variables:

   ```
   setx CLOUDFLARE_API_TOKEN "your-api-token" /M
   setx CLOUDFLARE_ZONE_NAME "example.com" /M
   ```

2. Open Task Scheduler (`taskschd.msc`) and create a task:
   - **General**: Check "Run whether user is logged on or not" and "Run with highest privileges"
   - **Trigger**: New -> Select "At startup". Optionally add a repeating schedule (e.g. every 10 minutes)
   - **Action**:
     - Program: `powershell.exe`
     - Arguments: `-ExecutionPolicy Bypass -File "C:\path\to\Windows-update-AAAA-record.ps1"`

### Google Cloud VM (Instance Startup Script)

Configure the script as a Compute Engine instance startup script. Edit the configuration variables at the top of the script before deploying. It will run automatically every time the VM boots.

1. Go to **Compute Engine** -> **VM instances**
2. Click on the instance -> **Edit**
3. Under **Metadata**, add a key `startup-script` with the script content as the value
4. Save

Google Cloud ephemeral external IPs only change on VM reboot, so running the script at startup keep the DNS record updated on time.

### Oracle Cloud VM (systemd)

Configure the script to run on instance boot via systemd.

1. Upload the script to the instance (e.g. `/usr/local/sbin/oci-vm-update-A-record.sh`) and make it executable. If SELinux is enabled (default on Oracle Linux), restore the correct security context so systemd can execute it:

   ```bash
   chmod +x /usr/local/sbin/oci-vm-update-A-record.sh
   restorecon -v /usr/local/sbin/oci-vm-update-A-record.sh
   ```

2. Set the environment variables in `/etc/environment` or in a wrapper script:

   ```bash
   echo 'CLOUDFLARE_API_TOKEN=your-api-token' >> /etc/environment
   echo 'CLOUDFLARE_ZONE_NAME=example.com' >> /etc/environment
   ```

3. Create a systemd service to run the script at boot:

   ```bash
   cat > /etc/systemd/system/cloudflare-ddns.service << 'EOF'
   [Unit]
   Description=Update Cloudflare DNS record with current public IP
   After=network-online.target
   Wants=network-online.target

   [Service]
   Type=oneshot
   EnvironmentFile=/etc/environment
   ExecStart=/usr/local/sbin/oci-vm-update-A-record.sh

   [Install]
   WantedBy=multi-user.target
   EOF

   systemctl enable cloudflare-ddns.service
   ```

Oracle Cloud reserved public IPs persist across reboots, but ephemeral public IPs may change — running the script at startup keeps the DNS record in sync.

## Logs

- **Windows script**: Outputs to console (viewable in Task Scheduler history)
- **Google Cloud / Oracle Cloud script**: Writes to `/var/log/cloudflare-dns-update.log` (overwritten on each run)
