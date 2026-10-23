# Letting Emby and Deluge share the media folders

Emby and Deluge run as different Linux users, so one of them usually ends up unable to write the other's folders. Emby then can't save subtitles, images or NFO files next to the media, or delete items from the apps. Typical signs are "Access to the path ... is denied" in the Emby log, subtitles that never appear, and missing artwork. The fix is one shared group that both services (and you) belong to, and folders set up so every new file stays in that group and group-writable, whoever creates it.

Don't fix it with `chmod 777` or by adding the `emby` user to your personal group. Both work until the next folder is created with different permissions, and both open more than the media.

## Who needs what

| Who | Needs to |
|---|---|
| Deluge's user | write unfinished downloads, move finished ones into the library, delete torrents |
| `emby` | read media; write subtitles, images and NFO files next to it; delete when you delete in the app |
| you | rename, move and clean up from a shell, file manager or Samba share |

## 1. Check the disk's filesystem

```bash
lsblk -f
```

Note the `FSTYPE` and `UUID` of each media disk.

- **ext4, xfs or btrfs**: permissions live on the disk. Mount it by UUID ([example](../config/fstab/media-drives.fstab.example)) and continue with step 2.
- **NTFS or exFAT** (USB drives often ship this way): the disk can't store Linux owners, and `chmod`/`chown` silently do nothing. Either mount it with fixed ownership (`uid=`, `gid=`, `umask=0002`; see the commented lines in the [fstab example](../config/fstab/media-drives.fstab.example)), or reformat it as ext4, which erases it. `emby-tune` detects this and prints the exact fstab line with your disk's UUID.

## 2. One shared group

Replace `debian-deluged` with the user your Deluge runs as (`ps -o user= -C deluged`):

```bash
sudo groupadd media
sudo usermod -aG media emby
sudo usermod -aG media debian-deluged
sudo usermod -aG media "$USER"
```

## 3. Folders that pass the group on

Run this for every library folder and for Deluge's unfinished-download folder:

```bash
D=/mnt/media1/Movies
sudo chgrp -R media "$D"
sudo chmod -R u+rwX,g+rwX,o-w "$D"
sudo find "$D" -type d -exec chmod g+s {} +
sudo setfacl -R -m g:media:rwX,d:g:media:rwX "$D"   # apt install acl
```

| Piece | Why |
|---|---|
| group `media`, `g+rwX` | both services reach everything through the group |
| setgid on folders (`g+s`) | new files and folders inherit group `media` instead of the creator's own group |
| default ACL (`d:g:media:rwX`) | new files stay group-writable even when the creating program uses umask 022 (file managers, `mv`, some tools) |
| the same on the unfinished-download folder | finished downloads moved from another disk are copied with their old modes; without setgid there, moved folders lose it |
| `o-w` | nobody else can write |

Only ownership and permission bits change. File contents, and therefore torrent hashes and seeding, stay as they are.

## 4. Services: umask, and wait for the disks

Copy [`emby-server.service.d/20-media-access.conf`](../config/systemd/emby-server.service.d/20-media-access.conf) and [`deluged.service.d/20-media-access.conf`](../config/systemd/deluged.service.d/20-media-access.conf) into `/etc/systemd/system/`, put your own mount points in `RequiresMountsFor`, then:

```bash
sudo systemctl daemon-reload
sudo systemctl restart emby-server deluged
```

`UMask=0002` makes the files each service creates group-writable. `RequiresMountsFor` stops Emby or Deluge from starting before a USB disk is mounted. Without it, Emby sees empty folders and Deluge can download onto the system disk under the empty mount point. Group membership only takes effect after a restart.

## 5. Check

```bash
sudo -u emby touch /mnt/media1/Movies/.write-test && sudo -u emby rm /mnt/media1/Movies/.write-test && echo ok
```

Or run `emby-tune --host <server IP> --only perms --dry-run`. It goes through every library folder, counts what Emby can't read or write, and proposes the steps above.

## Docker

Inside containers, the user and group are numbers. Run both containers with the same group: for linuxserver.io images that means `PUID=<deluge user's uid>` and `PGID=<media gid>`, and for the official Emby image `UID`/`GID`/`GIDLIST`. Mount the same host paths into both. Steps 1 and 3 still apply on the host.
