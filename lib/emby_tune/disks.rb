# frozen_string_literal: true

# Block devices, mounts, and the Linux I/O settings for media hard drives.
module EmbyTune
  UDEV_RULE_PATH = "/etc/udev/rules.d/60-media-hdd-iosched.rules"
  SYSCTL_PATH = "/etc/sysctl.d/60-media-writeback.conf"
  # Exact contents of the files installed here; config/ in the repo holds identical copies.
  UDEV_RULE = "# Media HDDs: BFQ honours ionice so streaming reads beat bulk writes; big readahead for sequential reads\n" \
              'ACTION=="add|change", KERNEL=="sd[a-z]|sd[a-z][a-z]", ATTR{queue/rotational}=="1", ' \
              "ATTR{queue/scheduler}=\"bfq\", ATTR{queue/read_ahead_kb}=\"4096\"\n"
  SYSCTL_CONF = "# Smaller writeback bursts so bulk writes do not stall media reads on USB/SATA HDDs\n" \
                "vm.dirty_background_bytes = 67108864\nvm.dirty_bytes = 268435456\n"

  Mount = Struct.new(:source, :point, :fstype, :options)

  def self.disk_for_path(path)
    st = File.stat(existing_ancestor(path))
    sys = File.realpath("/sys/dev/block/#{st.dev_major}:#{st.dev_minor}")
    disk = File.exist?(File.join(sys, "partition")) ? File.dirname(sys) : sys
    File.directory?(File.join(disk, "queue")) ? disk : nil
  rescue SystemCallError
    nil
  end

  def self.queue_attr(disk, name)
    read_text(File.join(disk, "queue", name))&.strip
  end

  def self.rotational?(path)
    disk = disk_for_path(path)
    disk ? queue_attr(disk, "rotational") == "1" : nil
  end

  def self.mount_for(path)
    real = File.realpath(existing_ancestor(path))
    best = nil
    (read_text("/proc/self/mounts") || "").each_line do |line|
      parts = line.split
      next if parts.size < 4

      mnt = parts[1].gsub("\\040", " ")
      inside = real == mnt || real.start_with?("#{mnt.chomp('/')}/")
      best = Mount.new(parts[0], mnt, parts[2], parts[3]) if inside && (best.nil? || mnt.size > best.point.size)
    end
    best
  rescue SystemCallError
    nil
  end

  def self.uuid_for_device(dev)
    dir = "/dev/disk/by-uuid"
    return nil unless File.directory?(dir)

    real = File.realpath(dev)
    Dir.children(dir).find { |name| File.realpath(File.join(dir, name)) == real }
  rescue SystemCallError
    nil
  end

  def self.iowait_percent(seconds = 2.0)
    sample = lambda do
      first = (read_text("/proc/stat") || "").lines.first
      first&.start_with?("cpu ") ? first.split[1..].map(&:to_i) : nil
    end
    a = sample.call
    return nil unless a

    sleep seconds
    d = sample.call.zip(a).map { |y, x| y - x }
    total = d.sum
    total.positive? ? 100.0 * d[4] / total : nil
  end


  # ------------------------------------------------------------------------- Linux disk checks

  def self.check_os(ctx, plan)
    unless ctx.local
      return plan.ok("os", "Emby runs on another machine (or in a container with different paths); OS checks skipped. " \
                           "Run this tool on the Emby host to include them.")
    end
    model = read_text("/proc/device-tree/model").to_s.delete("\0").strip
    plan.ok("os", "Hardware: #{model}") unless model.empty?
    if which("vcgencmd")
      val = run(%w[vcgencmd get_throttled]).out.strip.split("=", 2)[1]
      plan.warn("os", "Raspberry Pi reports throttling/under-voltage (#{val}). Use the official PSU and a cooler.") if val && val != "0x0"
    end

    disks = Hash.new { |h, k| h[k] = [] }
    ctx.library_paths.each do |p|
      next unless File.directory?(p)

      d = disk_for_path(p)
      disks[d] << p if d && queue_attr(d, "rotational") == "1"
    end
    data = emby_data_dir(ctx)
    custom_tmp = begin
      ctx.emby.get("/System/Configuration/encoding")["TranscodingTempPath"]
    rescue StandardError
      nil
    end
    tmp_path = [custom_tmp, ctx.info["TranscodingTempPath"], data && File.join(data, "transcoding-temp")]
               .find { |p| p && !p.empty? }
    if tmp_path && rotational?(tmp_path)
      plan.warn("os", "Transcoding temp folder #{tmp_path} is on a spinning disk; point it at an SSD " \
                      "(Dashboard > Transcoding > Transcoding temporary path).")
    end

    no_atime = ctx.library_paths.find { |p| File.directory?(p) && (m = mount_for(p)) && !m.options.split(",").include?("noatime") }
    if no_atime
      plan.warn("os", "#{no_atime} is mounted without noatime: every read also writes an access time. Add 'noatime' to " \
                      "its /etc/fstab options and run `sudo mount -o remount,noatime <mountpoint>`.")
    end

    check_disk_tuning(plan, disks) unless disks.empty?

    iow = iowait_percent
    return unless iow && iow > 20

    plan.warn("os", "CPU is waiting on disk #{iow.round}% of the time right now: a disk is the bottleneck " \
                    "(often torrents or a library scan writing to the drive Emby streams from).")
  end

  def self.check_disk_tuning(plan, disks)
    needs = disks.keys.filter_map do |d|
      sched = queue_attr(d, "scheduler").to_s
      ra = queue_attr(d, "read_ahead_kb").to_i
      [File.basename(d), sched[/\[([^\]]+)\]/, 1] || sched, ra] if !sched.include?("[bfq]") || ra < 4096
    end
    if needs.empty?
      plan.ok("os", "Library HDDs already use BFQ with large readahead")
    else
      before = needs.map { |n, s, r| "#{n}: #{s}, readahead #{r} KB" }.join(", ")
      plan.fix("os", "Library HDD I/O scheduler", before, "bfq, readahead 4096 KB",
               "BFQ lets streaming reads cut ahead of torrent/scan writes; large readahead suits big video files.",
               needs_root: true) do
        root_run(%w[modprobe bfq]) unless queue_attr(disks.keys.first, "scheduler").to_s.include?("bfq")
        root_write(UDEV_RULE_PATH, UDEV_RULE)
        root_run(%w[udevadm control --reload])
        disks.each_key do |d|
          run(sudo + ["tee", File.join(d, "queue", "scheduler")], stdin_data: "bfq")
          run(sudo + ["tee", File.join(d, "queue", "read_ahead_kb")], stdin_data: "4096")
        end
      end
    end

    dirty_bytes = read_text("/proc/sys/vm/dirty_bytes").to_i
    dirty_ratio = (read_text("/proc/sys/vm/dirty_ratio") || "20").to_i
    mem_kb = read_text("/proc/meminfo").to_s[/MemTotal:\s+(\d+)/, 1].to_i
    limit_mb = dirty_bytes.positive? ? dirty_bytes / 2.0**20 : mem_kb / 1024.0 * dirty_ratio / 100
    return unless limit_mb > 512

    plan.fix("os", "Dirty-page writeback limit", "#{limit_mb.round} MB", "256 MB (background 64 MB)",
             "Gigabytes of pending writes flushed at once block reads from the same disk for seconds.", needs_root: true) do
      root_write(SYSCTL_PATH, SYSCTL_CONF)
      root_run([which("sysctl") || "/sbin/sysctl", "-p", SYSCTL_PATH])
    end
  end
end
