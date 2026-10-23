# Raspberry Pi 5 as an Emby server

A Pi 5 (8 GB) is a good Emby server for direct play and a weak one for transcoding. It has no hardware video encoder, and Emby doesn't use its HEVC decoder, so every transcode runs on four Cortex-A76 cores.

## What it can transcode

Emby 4.10's bundled ffmpeg, 10-second clips copied to NVMe first so the disk isn't a factor:

| Job | Speed (1.0x = real time) |
|---|---|
| 4K HEVC 10-bit, decode only | 0.67x |
| 4K HEVC 10-bit → 1080p H.264 (x264 veryfast) | 0.44x |
| 4K HEVC 10-bit → 4K H.264 (what Emby does with no width cap) | 0.30x |
| 1080p H.264 → 1080p H.264 | 2.23x |
| 1080p H.264 → 720p H.264 | 3.55x |
| 1080p H.264 → 1080p HEVC (x265 veryfast) | 0.89x |

What that means:

- **4K HEVC can't be transcoded**, whatever the settings: decoding alone is below real time. Use clients that direct play it (Android TV / Google TV, Shield, LG/Samsung apps, Apple TV, Emby for Windows). The Chrome web player can't.
- **1080p H.264 transcodes fine**, about two at once.
- **Never let it encode HEVC.** Turn off "Enable HEVC encoding".
- If remote users need 4K titles, keep a 1080p H.264 version next to the 4K file (Emby shows both as versions), or have Emby's "Convert media" make one overnight. On a Pi that takes about 2x the movie's length.

`emby-tune benchmark` runs the same tests on your own files.

## Hardware checklist

- **Official 27 W power supply**, especially with USB hard drives. `vcgencmd get_throttled` should print `throttled=0x0`.
- **Active cooler.** Under load it should stay well under 80 °C (`vcgencmd measure_temp`).
- **Boot from NVMe** (M.2 HAT) and keep the OS, Emby's data folder (`/var/lib/emby`), the transcoding temp folder and torrent downloads on it. Leave hard drives for finished media.
- `dtparam=pciex1_gen=3` in `/boot/firmware/config.txt` for full NVMe speed, and `usb_max_current_enable=1` if you power drives from the Pi's USB ports.
- **Wired Ethernet.** 4K remuxes run 50-80 Mbps.

## Linux disk tuning

USB hard drives are where a Pi media server stalls. The files are in [`config/`](../config); `emby-tune` installs the first two and only warns about the third.

**[`60-media-hdd-iosched.rules`](../config/udev/60-media-hdd-iosched.rules)** goes in `/etc/udev/rules.d/`. BFQ is the only Linux scheduler that respects `ionice` classes, so a torrent client at idle priority waits while Emby reads. Writes the kernel flushes later on Deluge's behalf don't carry that priority, which is why downloads still belong on another disk. A 4 MB readahead suits large sequential video reads.

**[`60-media-writeback.conf`](../config/sysctl/60-media-writeback.conf)** goes in `/etc/sysctl.d/`. By default Linux lets 20% of RAM (1.6 GB on an 8 GB Pi) build up as unwritten data and then flushes it all at once. While that happens, reads from the same disk wait. Capping it at 256 MB keeps the flushes short.

**[`noatime` in `/etc/fstab`](../config/fstab/media-drives.fstab.example).** Without it, every read also writes an access time. Apply it live with `sudo mount -o remount,noatime /mnt/media1`.

Apply the first two without a reboot:

```bash
sudo udevadm control --reload && sudo udevadm trigger --subsystem-match=block --action=change
sudo sysctl -p /etc/sysctl.d/60-media-writeback.conf
```

Check: `cat /sys/block/sda/queue/scheduler` should show `[bfq]`.

## Running Emby's ffmpeg by hand

Emby 4.10 ships `bin/ffmpeg` with a relative loader path, so it fails when run outside `/opt/emby-server`. Use the wrapper instead:

```bash
/opt/emby-server/bin/emby-ffmpeg -hide_banner -i input.mkv -f null -
```
