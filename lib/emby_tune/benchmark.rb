# frozen_string_literal: true

# `emby-tune benchmark`: how fast this machine reads and transcodes the library's own files.
module EmbyTune
  EMBY_FFMPEG_CANDIDATES = ["/opt/emby-server/bin/emby-ffmpeg", "/opt/emby-server/bin/ffmpeg"].freeze

  def self.monotonic
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  def self.find_ffmpeg
    EMBY_FFMPEG_CANDIDATES.find { |p| File.exist?(p) } || which("ffmpeg")
  end

  def self.pick_samples(emby)
    items = emby.get("/Items", "Recursive" => "true", "IncludeItemTypes" => "Movie,Episode",
                               "Fields" => "MediaStreams,Path", "Limit" => 3000)["Items"] || []
    best = {}
    items.each do |it|
      path = it["Path"].to_s
      next unless File.file?(path)

      v = (it["MediaStreams"] || []).find { |s| s["Type"] == "Video" }
      next unless v

      w = v["Width"].to_i
      codec = v["Codec"].to_s.downcase
      if w >= 3000 && codec == "hevc" then best["4k"] ||= path
      elsif w.between?(1700, 2000) && codec == "h264" then best["1080"] ||= path
      end
      break if best.size == 2
    end
    best
  end

  # Wall-clock seconds for a command, or nil on failure/timeout.
  def self.timed(cmd, timeout)
    t0 = monotonic
    pid = Process.spawn(*cmd, out: File::NULL, err: File::NULL)
    loop do
      if Process.waitpid(pid, Process::WNOHANG)
        return $?.success? ? monotonic - t0 : nil
      end
      if monotonic - t0 > timeout
        Process.kill("KILL", pid)
        Process.wait(pid)
        return nil
      end
      sleep 0.1
    end
  end

  def self.cmd_benchmark(opts)
    ffmpeg = find_ffmpeg || die("ffmpeg not found (looked for Emby's bundled one and ffmpeg in PATH)")
    samples = if opts[:file]
                { "file" => opts[:file] }
              else
                pick_samples(build_ctx(opts.merge(only: nil)).emby).tap do |s|
                  die("no local 4K HEVC or 1080p H.264 file found in the libraries; pass --file") if s.empty?
                end
              end
    puts "ffmpeg: #{ffmpeg}"
    base = [ffmpeg, "-hide_banner", "-nostdin", "-loglevel", "error", "-y"]
    secs = 10
    rows = []
    Dir.mktmpdir("emby-tune-") do |tmp|
      samples.each do |label, src|
        puts "\nSample #{label}: #{src}"
        read = timed(base + ["-ss", "900", "-t", "60", "-i", src, "-map", "0", "-c", "copy", "-f", "null", "-"], 300)
        rows << ["#{label}: read 60 s of the original from its disk", read && 60 / read]
        clip = File.join(tmp, "#{label}.mkv")
        unless timed(base + ["-ss", "600", "-t", (secs + 2).to_s, "-i", src, "-map", "0:v:0", "-c", "copy", clip], 300)
          puts "  could not cut a test clip; skipping CPU tests for this file"
          next
        end
        [["decode only", ["-f", "null", "-"]],
         ["to 1080p H.264 (x264 veryfast)", ["-vf", "scale=1920:-2,format=yuv420p", "-c:v", "libx264", "-preset", "veryfast", "-crf", "23", "-f", "null", "-"]],
         ["to 720p H.264 (x264 veryfast)", ["-vf", "scale=1280:-2,format=yuv420p", "-c:v", "libx264", "-preset", "veryfast", "-crf", "23", "-f", "null", "-"]]]
          .each do |name, out|
          puts "  #{name}..."
          t = timed(base + ["-t", secs.to_s, "-i", clip] + out, 300)
          rows << ["#{label}: #{name}", t && secs / t]
        end
      end
    end
    UI.head("Speed (1.0x = real time; below 1.0x stutters)")
    rows.each { |name, speed| puts "  #{name.ljust(55)} #{speed ? format('%.2fx', speed) : 'failed/timeout'}" }
    UI.head("What it means")
    rows.each do |name, speed|
      next unless speed

      sample = name.split(":").first
      if name.include?("read 60 s") && speed < 1.5
        UI.warn("#{sample}: the disk delivers only #{format('%.2f', speed)}x the bitrate; streams will buffer even " \
                "without transcoding. Something else is using the disk (torrents, scans).")
      end
      next unless name.end_with?("to 1080p H.264 (x264 veryfast)")

      if speed < 1 then UI.warn("#{sample}: cannot be transcoded in real time; it must direct play.")
      else UI.ok("#{sample}: about #{[(speed / 1.1).floor, 1].max} simultaneous 1080p transcode(s).")
      end
    end
    0
  end
end
