# DDNS by Cloudflare API

Automatically update Cloudflare DNS records to implement Dynamic DNS (DDNS). Includes two scripts for different platforms and scenarios, both designed to run as **startup scripts**.

## Scripts

| Script | Platform | Record Type | IP Source |
|--------|----------|-------------|-----------|
| `Windows-update-AAAA-record.ps1` | Windows | AAAA (IPv6) | Parses `ipconfig` output for public IPv6 address |
| `gcp-vm-update-A-record.sh` | GCP Linux VM | A (IPv4) | GCP Metadata API (`metadata.google.internal`) |

Both scripts follow the same workflow: get current IP -> query existing Cloudflare record -> update if changed, skip if unchanged.

## Prerequisites

- A domain managed by Cloudflare
- A [Cloudflare API Token](https://dash.cloudflare.com/profile/api-tokens) with DNS edit permission
- The target DNS record must **already exist** in Cloudflare (the scripts only update, they do not create records)
- GCP script requires `curl` and `jq`

## Environment Variables

Both scripts read configuration from environment variables:

| Variable | Description | Required |
|----------|-------------|----------|
| `CLOUDFLARE_API_TOKEN` | Cloudflare API Token | Yes |
| `CLOUDFLARE_ZONE_NAME` | Root domain, e.g. `example.com` | Yes |

The subdomain prefix is hardcoded in each script (`omen` for Windows, `gcp` for GCP). Edit the `$RecordName` or `CLOUDFLARE_RECORD_NAME` variable in the script to change it.

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

### GCP VM (Instance Startup Script)

Configure the script as a GCP instance startup script via the cloud platform. It will run automatically every time the VM boots.

**Option A: Set via gcloud CLI**

```bash
gcloud compute instances add-metadata INSTANCE_NAME \
  --metadata-from-file startup-script=gcp-vm-update-A-record.sh
```

**Option B: Set via GCP Console**

1. Go to **Compute Engine** -> **VM instances**
2. Click on the instance -> **Edit**
3. Under **Metadata**, add a key `startup-script` with the script content as the value
4. Save

**Environment variables** must be set inside the script directly or passed via additional instance metadata and read with `curl -s -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/attributes/KEY`.

GCP ephemeral external IPs only change on VM reboot, so running the script at startup is sufficient — no periodic scheduling is needed.

## Logs

- **Windows script**: Outputs to console (viewable in Task Scheduler history)
- **GCP script**: Writes to `/var/log/cloudflare-dns-update.log` (overwritten on each run)
