# frozen_string_literal: true

# Shared file access: one group, inherited permissions, and service units for Emby and Deluge.
module EmbyTune
  MEDIA_DROPIN_NAME = "20-media-access.conf"
  # Filesystems that cannot store Linux owners, mapped to the fstab type to mount them with.
  NON_POSIX_FS = { "ntfs" => "ntfs3", "ntfs3" => "ntfs3", "fuseblk" => "ntfs-3g", "exfat" => "exfat",
                   "vfat" => "vfat", "msdos" => "vfat" }.freeze

  Service = Struct.new(:pid, :user, :uid, :unit)

  def self.find_emby_process
    run(["ps", "-eo", "pid=,uid=,user=,args="]).out.each_line do |line|
      pid, uid, user, cmd = line.strip.split(/\s+/, 4)
      return Service.new(pid.to_i, user, uid.to_i, unit_of(pid)) if cmd =~ %r{(^|/)EmbyServer(\s|$)|EmbyServer\.dll}
    end
    nil
  end

  def self.running_gids(pid)
    read_text("/proc/#{pid}/status").to_s[/^Groups:\s*(.*)$/, 1].to_s.split.map(&:to_i)
  end

  def self.configured_gids(user)
    r = run(["id", "-G", user])
    r.ok ? r.out.split.map(&:to_i) : []
  end

  # need is a 3-bit rwx mask (4=r, 2=w, 1=x) checked against the class (owner/group/other) that applies.
  def self.allowed?(st, uid, gids, need)
    return true if uid.zero?

    bits = if st.uid == uid then (st.mode >> 6) & 7
           elsif gids.include?(st.gid) then (st.mode >> 3) & 7
           else st.mode & 7
           end
    bits & need == need
  end

  def self.audit_tree(root, uid, gids, group_gid)
    out = { dirs: 0, files: 0, dirs_blocked: [], files_blocked: [], wrong_group: 0, unreadable: 0 }
    stack = [root]
    until stack.empty?
      dir = stack.pop
      begin
        st = File.stat(dir)
        entries = Dir.children(dir)
      rescue SystemCallError
        out[:unreadable] += 1
        next
      end
      out[:dirs] += 1
      out[:dirs_blocked] << dir unless allowed?(st, uid, gids, 7)
      out[:wrong_group] += 1 if group_gid && st.gid != group_gid
      entries.each do |name|
        path = File.join(dir, name)
        s = File.lstat(path)
        next if s.symlink?
        next stack << path if s.directory?

        out[:files] += 1
        out[:files_blocked] << path unless allowed?(s, uid, gids, 6)
        out[:wrong_group] += 1 if group_gid && s.gid != group_gid
      rescue SystemCallError
        next
      end
    end
    out
  end

  def self.default_acl?(path, group)
    return false unless which("getfacl")

    run(["getfacl", "--omit-header", "--default", path]).out.lines.any? do |l|
      l.start_with?("default:group:#{group}:rw", "group:#{group}:rw")
    end
  end

  # Unique real paths, dropping any path nested inside another one in the list.
  def self.collapse_paths(paths)
    real = paths.compact.select { |p| File.directory?(p) }.map { |p| File.realpath(p).chomp("/") }.uniq.sort
    real.each_with_object([]) { |p, out| out << p unless out.any? { |q| p == q || p.start_with?("#{q}/") } }
  end

  def self.group_gid(group)
    Etc.getgrnam(group).gid
  rescue ArgumentError
    nil
  end

  # Emby and the torrent client must both read and write every library folder.
  def self.check_permissions(ctx, plan)
    return unless ctx.local

    group = ctx.opts[:media_group]
    emby = find_emby_process
    unless emby
      return plan.warn("perms", "Emby's process is not visible on this host (Docker?). Run the container with PUID/PGID set " \
                                "to a user and group that own the media folders; see docs/permissions.md.")
    end
    begin
      Etc.getpwnam(emby.user)
    rescue ArgumentError
      return plan.warn("perms", "Emby runs as uid #{emby.uid}, which has no local account (container?). See docs/permissions.md.")
    end
    deluge = find_deluged
    users = [emby.user]
    users << deluge.user if deluge && deluge.user != emby.user
    human = ENV["SUDO_USER"] || Etc.getlogin || ENV["USER"]
    users << human if human && human != "root" && !users.include?(human)

    # Library folders are fixed recursively. Deluge's own folders (unfinished downloads, the default
    # move target) are fixed only at the top: they often sit at a disk root next to unrelated data,
    # and new content created inside them inherits the settings anyway.
    roots = collapse_paths(ctx.library_paths)
    return if roots.empty?

    deluge_dirs = []
    if deluge
      cfg = deluge_state(deluge)["config"] || {}
      deluge_dirs = [cfg["download_location"], (cfg["move_completed_path"] if cfg["move_completed"])]
      deluge_dirs = collapse_paths(deluge_dirs).reject { |d| roots.any? { |r| d == r || d.start_with?("#{r}/") } }
    end

    gid = group_gid(group)
    posix_roots = roots.reject { |r| warn_non_posix(plan, r, group, gid, deluge || emby) }

    # 1. shared group with every service user in it
    need_restart = []
    missing = users.reject { |u| gid && configured_gids(u).include?(gid) }
    if missing.empty?
      [emby, deluge].compact.each { |s| need_restart << s.unit unless running_gids(s.pid).include?(gid) }
    else
      plan.fix("perms", "Shared '#{group}' group", gid ? "without #{missing.join(', ')}" : "missing",
               "#{users.join(', ')} in '#{group}'",
               "Emby, the torrent client and you all get access through one group instead of world-writable folders " \
               "or Emby joining a personal group.", needs_root: true) do
        root_run(["groupadd", group]) unless run(["getent", "group", group]).ok
        missing.each { |u| root_run(["usermod", "-aG", group, u]) }
      end
      need_restart.concat([emby, deluge].compact.select { |s| missing.include?(s.user) }.map(&:unit))
    end

    # 2. folders: group-owned, setgid, default ACL so new files stay group-writable
    acl = !which("setfacl").nil?
    emby_gids = configured_gids(emby.user) | [gid].compact
    problems = []
    top_only = []
    deluge_dirs.each do |d|
      next if mount_for(d) && NON_POSIX_FS.key?(mount_for(d).fstype)

      st = File.stat(d)
      why = []
      why << "not in group '#{group}'" if st.gid != gid
      why << "no setgid bit" if (st.mode & 0o2000).zero?
      why << "no default ACL" if acl && !default_acl?(d, group)
      top_only << [d, why + ["Deluge folder: new downloads and moved folders inherit from it"]] unless why.empty?
    end
    blocked_parents = []
    posix_roots.each do |r|
      a = audit_tree(r, emby.uid, emby_gids, gid)
      st = File.stat(r)
      why = []
      why << "#{a[:dirs_blocked].size} folder(s) Emby cannot write (e.g. #{a[:dirs_blocked].first})" unless a[:dirs_blocked].empty?
      why << "#{a[:files_blocked].size} file(s) Emby cannot read/write (e.g. #{a[:files_blocked].first})" unless a[:files_blocked].empty?
      why << "#{a[:wrong_group]} item(s) not in group '#{group}'" if a[:wrong_group].positive?
      why << "no setgid bit" if (st.mode & 0o2000).zero?
      why << "no default ACL" if acl && !default_acl?(r, group)
      why << "world-writable" unless (st.mode & 0o002).zero?
      why << "#{a[:unreadable]} folder(s) this tool could not list" if a[:unreadable].positive?
      problems << [r, why] unless why.empty?

      anc = File.dirname(r)
      until anc == "/" || anc.empty?
        if !blocked_parents.include?(anc) && !allowed?(File.stat(anc), emby.uid, emby_gids, 1)
          blocked_parents << anc
          plan.warn("perms", "Emby cannot enter #{anc} (no execute permission), so nothing below it is visible. " \
                             "Fix: sudo chmod o+x #{anc}")
        end
        anc = File.dirname(anc)
      end
    end
    if !problems.empty? || !top_only.empty?
      before = (problems + top_only).map { |r, why| "#{r}: #{why.join(', ')}" }.join("; ")
      plan.fix("perms", "Library and download folder access", before,
               "group '#{group}' rw, setgid folders#{acl ? ', default ACL' : ''}, not world-writable",
               "Every new file and folder inherits the group and stays group-writable, whoever creates it " \
               "(Deluge, Emby, a file manager). Only ownership/permission bits change; file contents and torrent " \
               "hashes are untouched.", needs_root: true) do
        problems.each do |r, _|
          root_run(["chgrp", "-R", group, r])
          root_run(["chmod", "-R", "u+rwX,g+rwX,o-w", r])
          root_run(["find", r, "-type", "d", "-exec", "chmod", "g+s", "{}", "+"])
          root_run(["setfacl", "-R", "-m", "g:#{group}:rwX,d:g:#{group}:rwX", r]) if acl
        end
        top_only.each do |d, _|
          root_run(["chgrp", group, d])
          root_run(["chmod", "u+rwx,g+rwxs,o-w", d])
          root_run(["setfacl", "-m", "g:#{group}:rwx,d:g:#{group}:rwx", d]) if acl
        end
      end
    elsif !posix_roots.empty?
      plan.ok("perms", "Emby can read and write all #{posix_roots.size} media folder tree(s)")
    end

    # 3. services: group-writable umask, and never start before the media disks are mounted
    [[emby, ctx.library_paths], [deluge, roots + deluge_dirs]].each do |svc, svc_paths|
      next unless svc&.unit

      need_restart << svc.unit if ensure_service_dropin(plan, svc, svc_paths)
    end

    units = [emby, deluge].compact.map(&:unit).compact.select { |u| need_restart.include?(u) }
    return if units.empty?

    playing = begin
      (ctx.emby.get("/Sessions") || []).count { |s| s["NowPlayingItem"] }
    rescue StandardError
      0
    end
    plan.fix("perms", "Restart services", "running with old groups/umask", "restart #{units.join(' ')}",
             "Group membership and umask only apply to a freshly started process." \
             "#{playing.positive? ? " #{playing} active playback session(s) will be interrupted." : ''}", needs_root: true) do
      root_run(["systemctl", "restart"] + units)
    end
  end

  # Disks whose filesystem cannot store Unix owners: only mount options decide access.
  def self.warn_non_posix(plan, root, group, gid, owner)
    m = mount_for(root)
    return false unless m && NON_POSIX_FS.key?(m.fstype)

    uuid = uuid_for_device(m.source) || "<uuid from: lsblk -f>"
    plan.warn("perms", "#{m.point} is #{m.fstype}, which cannot store Linux owners or permissions, so chmod/chown " \
                       "have no effect. Mount it with fixed ownership in /etc/fstab, then `sudo mount -o remount #{m.point}`:\n" \
                       "        UUID=#{uuid}  #{m.point}  #{NON_POSIX_FS[m.fstype]}  defaults,nofail,noatime," \
                       "uid=#{owner.uid},gid=#{gid || "<gid of '#{group}' after: sudo groupadd #{group}>"},umask=0002  0  0\n" \
                       "        Better: reformat the disk as ext4 (erases it).")
    true
  end

  # Returns true when a drop-in was planned (the service then needs a restart).
  def self.ensure_service_dropin(plan, svc, svc_paths)
    mounts = svc_paths.compact.select { |p| File.directory?(p) }.filter_map { |p| mount_for(p)&.point }
                      .reject { |pt| pt == "/" }.uniq.sort
    props = unit_props(svc.unit, "UMask", "RequiresMountsFor")
    umask = (props["UMask"].to_s.empty? ? "0022" : props["UMask"]).to_i(8)
    have = props["RequiresMountsFor"].to_s.split
    return false if (umask & 0o020).zero? && (mounts - have).empty?

    body = +""
    unless mounts.empty?
      body << "[Unit]\n# Do not start before the media disks are mounted (otherwise it sees empty folders\n" \
              "# or writes onto the system disk)\nRequiresMountsFor=#{mounts.join(' ')}\n\n"
    end
    body << "[Service]\n# Files this service creates in the media folders stay group-writable\nUMask=0002\n"
    dropin = "/etc/systemd/system/#{svc.unit}.d/#{MEDIA_DROPIN_NAME}"
    plan.fix("perms", "#{svc.unit} umask and disk dependency",
             "umask #{format('%04o', umask)}, waits for #{have.empty? ? 'nothing' : have.sort.join(' ')}",
             "umask 0002, waits for #{mounts.empty? ? 'nothing' : mounts.join(' ')}",
             "New files stay group-writable, and the service waits for the USB disks at boot.", needs_root: true) do
      root_write(dropin, body)
      root_run(%w[systemctl daemon-reload])
    end
    true
  end
end
