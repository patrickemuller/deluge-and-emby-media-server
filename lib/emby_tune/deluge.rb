# frozen_string_literal: true

# Deluge: a pure-Ruby client for the daemon RPC (TLS + zlib + rencode) and the Deluge checks.
module EmbyTune

  # rencode, the serialization Deluge's RPC uses (same constants as the reference rencode.py).
  module Rencode
    CHR_LIST = 59
    CHR_DICT = 60
    CHR_INT = 61
    CHR_INT1 = 62
    CHR_INT2 = 63
    CHR_INT4 = 64
    CHR_INT8 = 65
    CHR_FLOAT32 = 66
    CHR_FLOAT64 = 44
    CHR_TRUE = 67
    CHR_FALSE = 68
    CHR_NONE = 69
    CHR_TERM = 127
    INT_POS_FIXED_COUNT = 44
    INT_NEG_FIXED_START = 70
    INT_NEG_FIXED_COUNT = 32
    DICT_FIXED_START = 102
    DICT_FIXED_COUNT = 25
    STR_FIXED_START = 128
    STR_FIXED_COUNT = 64
    LIST_FIXED_START = 192
    LIST_FIXED_COUNT = 64

    module_function

    def dump(obj)
      out = String.new(encoding: Encoding::BINARY)
      enc(obj, out)
      out
    end

    def enc(x, out)
      case x
      when true then out << CHR_TRUE.chr
      when false then out << CHR_FALSE.chr
      when nil then out << CHR_NONE.chr
      when Integer then enc_int(x, out)
      when Float then out << CHR_FLOAT64.chr << [x].pack("G")
      when String, Symbol
        s = x.to_s.b
        s.bytesize < STR_FIXED_COUNT ? out << (STR_FIXED_START + s.bytesize).chr << s : out << "#{s.bytesize}:".b << s
      when Array then enc_seq(x, out, LIST_FIXED_START, LIST_FIXED_COUNT, CHR_LIST) { |e| enc(e, out) }
      when Hash then enc_seq(x, out, DICT_FIXED_START, DICT_FIXED_COUNT, CHR_DICT) { |(k, v)| enc(k, out); enc(v, out) }
      else raise ArgumentError, "rencode cannot encode #{x.class}"
      end
    end

    def enc_int(x, out)
      if x >= 0 && x < INT_POS_FIXED_COUNT then out << x.chr
      elsif x.negative? && x >= -INT_NEG_FIXED_COUNT then out << (INT_NEG_FIXED_START - 1 - x).chr
      elsif x.between?(-128, 127) then out << CHR_INT1.chr << [x].pack("c")
      elsif x.between?(-32_768, 32_767) then out << CHR_INT2.chr << [x].pack("s>")
      elsif x.between?(-2**31, 2**31 - 1) then out << CHR_INT4.chr << [x].pack("l>")
      elsif x.between?(-2**63, 2**63 - 1) then out << CHR_INT8.chr << [x].pack("q>")
      else out << CHR_INT.chr << x.to_s.b << CHR_TERM.chr
      end
    end

    def enc_seq(items, out, fixed_start, fixed_count, open_chr, &each)
      if items.size < fixed_count
        out << (fixed_start + items.size).chr
        items.each(&each)
      else
        out << open_chr.chr
        items.each(&each)
        out << CHR_TERM.chr
      end
    end

    def load(data)
      dec(data.b, 0).first
    end

    def str(raw)
      s = raw.dup.force_encoding(Encoding::UTF_8)
      s.valid_encoding? ? s : raw
    end

    def dec(s, i)
      t = s.getbyte(i)
      case t
      when CHR_LIST then dec_until_term(s, i + 1) { |j| dec(s, j) }
      when CHR_DICT
        pairs, j = dec_until_term(s, i + 1) { |k| key, k2 = dec(s, k); val, k3 = dec(s, k2); [[key, val], k3] }
        [pairs.to_h, j]
      when CHR_INT
        j = s.index(CHR_TERM.chr, i + 1)
        [s[(i + 1)...j].to_i, j + 1]
      when CHR_INT1 then [s[i + 1, 1].unpack1("c"), i + 2]
      when CHR_INT2 then [s[i + 1, 2].unpack1("s>"), i + 3]
      when CHR_INT4 then [s[i + 1, 4].unpack1("l>"), i + 5]
      when CHR_INT8 then [s[i + 1, 8].unpack1("q>"), i + 9]
      when CHR_FLOAT32 then [s[i + 1, 4].unpack1("g"), i + 5]
      when CHR_FLOAT64 then [s[i + 1, 8].unpack1("G"), i + 9]
      when CHR_TRUE then [true, i + 1]
      when CHR_FALSE then [false, i + 1]
      when CHR_NONE then [nil, i + 1]
      when 48..57
        colon = s.index(":", i)
        n = s[i...colon].to_i
        [str(s[colon + 1, n]), colon + 1 + n]
      else dec_fixed(s, i, t)
      end
    end

    def dec_fixed(s, i, t)
      if t < INT_POS_FIXED_COUNT then [t, i + 1]
      elsif t >= INT_NEG_FIXED_START && t < INT_NEG_FIXED_START + INT_NEG_FIXED_COUNT then [INT_NEG_FIXED_START - 1 - t, i + 1]
      elsif t >= DICT_FIXED_START && t < DICT_FIXED_START + DICT_FIXED_COUNT
        h = {}
        j = i + 1
        (t - DICT_FIXED_START).times do
          key, j = dec(s, j)
          h[key], j = dec(s, j)
        end
        [h, j]
      elsif t >= STR_FIXED_START && t < STR_FIXED_START + STR_FIXED_COUNT
        n = t - STR_FIXED_START
        [str(s[i + 1, n]), i + 1 + n]
      elsif t >= LIST_FIXED_START
        arr = []
        j = i + 1
        (t - LIST_FIXED_START).times do
          v, j = dec(s, j)
          arr << v
        end
        [arr, j]
      else raise ArgumentError, "rencode: unknown type byte #{t}"
      end
    end

    def dec_until_term(s, i)
      items = []
      until s.getbyte(i) == CHR_TERM
        v, i = yield(i)
        items << v
      end
      [items, i + 1]
    end
  end

  # Deluge 2 daemon RPC: TLS socket, each message = version byte + 4-byte length + zlib(rencode(data)).
  class DelugeRPC
    RPC_RESPONSE = 1
    RPC_ERROR = 2

    def initialize(port, user, password)
      ctx = OpenSSL::SSL::SSLContext.new
      ctx.verify_mode = OpenSSL::SSL::VERIFY_NONE # deluged uses a self-signed certificate on localhost
      @ssl = OpenSSL::SSL::SSLSocket.new(TCPSocket.new("127.0.0.1", port), ctx)
      @ssl.sync_close = true
      @ssl.connect
      @id = 0
      call("daemon.login", [user, password], "client_version" => "2.0.3")
    end

    def call(method, args = [], kwargs = {})
      @id += 1
      body = Zlib::Deflate.deflate(Rencode.dump([[@id, method, args, kwargs]]))
      @ssl.write([1, body.bytesize].pack("CN") + body)
      loop do
        msg = read_message
        next unless [RPC_RESPONSE, RPC_ERROR].include?(msg[0]) && msg[1] == @id
        raise "Deluge #{method} failed: #{msg[2..3].inspect}" if msg[0] == RPC_ERROR

        return msg[2]
      end
    end

    def close
      @ssl.close
    rescue StandardError
      nil
    end

    private

    def read_message
      _version, length = read_exact(5).unpack("CN")
      Rencode.load(Zlib::Inflate.inflate(read_exact(length)))
    end

    def read_exact(n)
      buf = String.new(encoding: Encoding::BINARY)
      buf << @ssl.readpartial(n - buf.bytesize) while buf.bytesize < n
      buf
    end
  end

  DelugeProc = Struct.new(:pid, :user, :uid, :config_dir, :unit)
  DELUGE_DROPIN_NAME = "10-low-io-priority.conf"
  DELUGE_PRIORITY_DROPIN = "[Service]\n# Torrent disk I/O must never starve Emby streaming reads " \
                           "(effective with the BFQ scheduler)\nIOSchedulingClass=idle\nNice=10\n"

  def self.find_deluged
    run(["ps", "-eo", "pid=,uid=,user=,args="]).out.each_line do |line|
      pid, uid, user, cmd = line.strip.split(/\s+/, 4)
      next unless cmd =~ %r{(^|/)deluged(\s|$)}

      config_dir = cmd[/(?:-c|--config)[= ](\S+)/, 1] || File.join(Etc.getpwnam(user).dir, ".config", "deluge")
      return DelugeProc.new(pid.to_i, user, uid.to_i, config_dir, unit_of(pid))
    end
    nil
  rescue ArgumentError
    nil
  end

  # Read a file belonging to the Deluge user (its auth file is private).
  def self.read_as_owner(path)
    read_text(path) || run(sudo + ["cat", path]).then { |r| r.ok ? r.out : nil }
  end

  def self.deluge_session(daemon)
    auth = read_as_owner(File.join(daemon.config_dir, "auth")).to_s
    user, password = auth.lines.map { |l| l.strip.split(":") }.find { |u, _| u == "localclient" }
    raise "no localclient entry in #{daemon.config_dir}/auth" unless password

    core = read_as_owner(File.join(daemon.config_dir, "core.conf")).to_s
    port = begin
      JSON.parse(core[(core.index("}") + 1)..])["daemon_port"] # file = header object + config object
    rescue StandardError
      nil
    end
    rpc = DelugeRPC.new(port || 58_846, user, password)
    yield rpc
  ensure
    rpc&.close
  end

  def self.deluge_state(daemon, set: nil)
    deluge_session(daemon) do |rpc|
      rpc.call("core.set_config", [set]) if set
      { "config" => rpc.call("core.get_config"),
        "torrents" => rpc.call("core.get_torrents_status", [{}, %w[name save_path state]]).values }
    end
  rescue StandardError => e
    { "error" => e.message }
  end

  def self.check_deluge(ctx, plan)
    return unless ctx.local

    daemon = find_deluged
    return plan.ok("deluge", "Deluge daemon not running on this host; skipped") unless daemon

    state = deluge_state(daemon)
    return plan.warn("deluge", "Could not talk to deluged (#{state['error']}).") if state["error"]

    cfg = state["config"]
    lib_paths = ctx.library_paths.select { |p| File.directory?(p) }.map { |p| File.realpath(p) }
    inside_library = lambda do |path|
      rp = File.realpath(existing_ancestor(path.to_s.empty? ? "/nonexistent" : path))
      lib_paths.any? { |lp| rp == lp || rp.start_with?("#{lp.chomp('/')}/") }
    end

    unfinished = state["torrents"].select { |t| %w[Downloading Queued Checking Allocating].include?(t["state"]) && inside_library.call(t["save_path"]) }
    unless unfinished.empty?
      plan.warn("deluge", "#{unfinished.size} unfinished torrent(s) download straight into an Emby library folder " \
                          "(e.g. #{unfinished.first['name'][0, 60]}). Emby scans the partial files and the random writes " \
                          "slow every stream on that disk. New torrents use the settings below.")
    end

    dl = cfg["download_location"].to_s
    incomplete = ctx.opts[:deluge_incomplete] || File.join(Etc.getpwnam(daemon.user).dir, "deluge-incomplete")
    on_library_hdd = rotational?(dl) &&
                     (inside_library.call(dl) || lib_paths.any? { |p| rotational?(p) && disk_for_path(p) == disk_for_path(dl) })
    if on_library_hdd
      free_gb = disk_free_gb(existing_ancestor(incomplete))
      if rotational?(incomplete)
        plan.warn("deluge", "Downloads write to a spinning disk that Emby streams from (#{dl}), and #{incomplete} " \
                            "is not on an SSD either. Pass --deluge-incomplete <dir on an SSD>.")
      elsif free_gb && free_gb < ctx.opts[:deluge_min_free_gb]
        plan.warn("deluge", "Downloads write to the spinning library disk (#{dl}); #{incomplete} is on an SSD but only " \
                            "has #{free_gb.round} GB free (need #{ctx.opts[:deluge_min_free_gb]} GB).")
      else
        move_path = cfg["move_completed"] ? cfg["move_completed_path"] : dl
        plan.fix("deluge", "Incomplete downloads", dl, "#{incomplete} (SSD), then move to #{move_path}",
                 "Torrents write in random order; keeping that off the HDD that Emby reads from stops stutter. " \
                 "Finished files are moved in one sequential copy.", needs_root: true) do
          root_run(["install", "-d", "-o", daemon.user, "-m", "0775", incomplete])
          res = deluge_state(daemon, set: { "download_location" => incomplete, "move_completed" => true,
                                          "move_completed_path" => move_path })
          raise res["error"] if res["error"]
        end
      end
    else
      plan.ok("deluge", "Downloads land on #{dl} (not the library HDD)")
    end

    max_dl = cfg["max_active_downloading"].to_i
    want = ctx.opts[:deluge_max_downloads]
    if max_dl > want || max_dl.negative?
      plan.fix("deluge", "Max active downloads", max_dl, want,
               "Each active torrent adds random writes; a few at full speed finish sooner than many at once.") do
        res = deluge_state(daemon, set: { "max_active_downloading" => want })
        raise res["error"] if res["error"]
      end
    end

    unless daemon.unit
      plan.warn("deluge", "deluged is not a systemd service; start it with `ionice -c3 nice -n10 deluged` for low disk priority.")
      return
    end
    cls = unit_props(daemon.unit, "IOSchedulingClass")["IOSchedulingClass"].to_s
    return if %w[3 idle].include?(cls)

    dropin = "/etc/systemd/system/#{daemon.unit}.d/#{DELUGE_DROPIN_NAME}"
    plan.fix("deluge", "#{daemon.unit} disk priority", cls.empty? ? "best-effort" : cls, "idle (+ nice 10)",
             "Emby's reads go ahead of Deluge's disk I/O. Applied live, persisted as a systemd drop-in.", needs_root: true) do
      root_write(dropin, DELUGE_PRIORITY_DROPIN)
      root_run(%w[systemctl daemon-reload])
      Dir.children("/proc/#{daemon.pid}/task").each do |tid|
        run(sudo + ["ionice", "-c3", "-p", tid])
        run(sudo + ["renice", "-n", "10", "-p", tid])
      end
    end
  end

  def self.disk_free_gb(path)
    r = run(["df", "-Pk", path])
    kb = r.out.lines.last.to_s.split[3]
    kb ? kb.to_i / 1e6 : nil
  end

  # ------------------------------------------------------------------------- deluge-apply command

  def self.cmd_deluge_apply(opts)
    file = opts[:args].first || die("usage: emby-tune deluge-apply SETTINGS.json")
    settings = JSON.parse(File.read(file))
    daemon = find_deluged || die("deluged is not running on this host")
    state = deluge_state(daemon, set: settings)
    die("could not talk to deluged: #{state['error']}") if state["error"]
    settings.each_key { |k| puts "#{k} = #{state['config'][k].inspect}" }
    0
  end
end
