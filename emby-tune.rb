#!/usr/bin/env ruby
# frozen_string_literal: true

# emby-tune: audit an Emby server (plus Deluge and the Linux disks it reads from) and apply
# settings that are known to help low-power hosts such as a Raspberry Pi.
# Nothing is changed without showing the plan first. Run with --help for options.
#
# Layout: this file is the command line; the checks live in lib/emby_tune/
#   emby_settings.rb  Emby's own settings, as a table of rules
#   deluge.rb         Deluge daemon client (pure Ruby) and Deluge checks
#   disks.rb          I/O scheduler, writeback and mount checks for media disks
#   permissions.rb    shared read/write access for Emby and Deluge
#   benchmark.rb      the `benchmark` command

require_relative "lib/emby_tune"

module EmbyTune
  CHECKS = {
    "emby" => %i[check_server check_encoding check_libraries check_users check_plugins check_tasks],
    "deluge" => %i[check_deluge],
    "os" => %i[check_os],
    "perms" => %i[check_permissions]
  }.freeze

  def self.cmd_tune(opts)
    ctx = build_ctx(opts)
    ctx.prefs = parse_prefs(opts, ctx.emby.get("/Localization/Cultures") || [])
    puts "Emby #{ctx.info['Version']} '#{ctx.info['ServerName']}' at #{opts[:url]}" \
         "#{ctx.local ? '' : ' (remote: OS and Deluge checks skipped)'}"
    plan = Plan.new
    CHECKS.values_at(*(opts[:only] || AREAS)).flatten.each do |check|
      send(check, ctx, plan)
    rescue HTTPError => e
      plan.warn("emby", "#{check} skipped: #{e.message}")
    end
    report(plan)
    return 0 if plan.changes.empty?

    if opts[:dry_run]
      puts "\nDry run: nothing changed."
      return 0
    end
    unless opts[:yes] || confirm("\nApply these changes?")
      puts "Nothing changed."
      return 0
    end
    apply(plan)
  end

  def self.report(plan)
    plan.oks.each { |area, msg| UI.ok("#{UI.dim("#{area}:")} #{msg}") }
    plan.warnings.each { |area, msg| UI.warn("#{UI.dim("#{area}:")} #{msg}") }
    return UI.head("Nothing to change.") if plan.changes.empty?

    UI.head("#{plan.changes.size} change(s) proposed:")
    plan.changes.each do |c|
      UI.change("#{UI.dim("#{c.area}:")} #{c.title}: #{show(c.before)} -> #{show(c.after)}#{c.needs_root ? ' (sudo)' : ''}")
      puts "        #{UI.dim(c.why)}"
    end
  end

  def self.apply(plan)
    failed = plan.changes.count do |c|
      c.apply.call
      UI.ok(c.title)
      false
    rescue StandardError => e
      UI.warn("#{c.title}: failed (#{e.message})")
      true
    end
    puts "\nApplied #{plan.changes.size - failed}/#{plan.changes.size} change(s)."
    failed.zero? ? 0 : 1
  end

  def self.parse_args(argv)
    opts = { port: Integer(ENV.fetch("EMBY_PORT", "8096")), host: ENV["EMBY_HOST"], user_subs: [], quiet_hour: 3,
             deluge_max_downloads: 2, deluge_min_free_gb: 100, media_group: "media" }
    parser = OptionParser.new do |p|
      p.banner = "Usage: emby-tune [tune|benchmark|deluge-apply FILE] [options]\n\n" \
                 "Audit Emby (+ Deluge and Linux disk settings) and apply sane defaults.\n" \
                 "Shows a plan and asks before changing anything."
      p.separator "\nConnection:"
      p.on("--host HOST", "internal (LAN) IP or hostname of the Emby server, e.g. 192.168.1.50 (or EMBY_HOST; prompted if missing)") { |v| opts[:host] = v }
      p.on("--port PORT", Integer, "Emby HTTP port (default: 8096, or EMBY_PORT)") { |v| opts[:port] = v }
      p.on("--api-key KEY", "admin API key (or EMBY_API_KEY)") { |v| opts[:api_key] = v }
      p.on("--username NAME", "admin username instead of an API key (password from EMBY_PASSWORD or prompt)") { |v| opts[:username] = v }
      p.separator "\nWhat to do:"
      p.on("--dry-run", "show the plan, change nothing") { opts[:dry_run] = true }
      p.on("-y", "--yes", "apply without asking") { opts[:yes] = true }
      p.on("--only AREAS", Array, "comma list of areas: #{AREAS.join(',')} (default: all)") { |v| opts[:only] = v }
      p.separator "\nServer name, subtitles and audio (opt-in):"
      p.on("--server-name NAME", "name the Emby apps show for this server") { |v| opts[:server_name] = v }
      p.on("--subtitle-langs LIST", "libraries download subtitles in these languages, e.g. en,pt-br") { |v| opts[:subtitle_langs] = v }
      p.on("--opensubtitles-user NAME", "opensubtitles.com username (not the email)") { |v| opts[:opensubtitles_user] = v }
      p.on("--opensubtitles-password PW", "password (or OPENSUBTITLES_PASSWORD, or prompt)") { |v| opts[:opensubtitles_password] = v }
      p.on("--original-audio", "prefer original-language audio for all users (#{DEFAULT_ORIGINAL_AUDIO})") { opts[:original_audio] = true }
      p.on("--audio-pref LIST", "custom audio language list for all users, e.g. jpn,eng (ISO 639-2)") { |v| opts[:audio_pref] = v }
      p.on("--subs-pref LANGS[:MODE]", "subtitle preference for all users, e.g. eng:Always") { |v| opts[:subs_pref] = v }
      p.on("--user-subs NAME=LANGS[:MODE]", "per-user subtitle preference, e.g. 'Ana=pob,por:Smart' (repeatable)") { |v| opts[:user_subs] << v }
      p.on("--allow-downloads", "let every user download media for offline use") { opts[:allow_downloads] = true }
      p.separator "\nScheduling, Deluge and file access:"
      p.on("--quiet-hour HOUR", Integer, "hour for heavy nightly tasks (default: 3)") { |v| opts[:quiet_hour] = v }
      p.on("--deluge-incomplete DIR", "SSD folder for unfinished torrents (default: ~deluge-user/deluge-incomplete)") { |v| opts[:deluge_incomplete] = v }
      p.on("--deluge-max-downloads N", Integer, "max active torrent downloads (default: 2)") { |v| opts[:deluge_max_downloads] = v }
      p.on("--deluge-min-free-gb N", Integer, "free space needed on the SSD (default: 100)") { |v| opts[:deluge_min_free_gb] = v }
      p.on("--media-group NAME", "group shared by Emby, Deluge and you for the media folders (default: media)") { |v| opts[:media_group] = v }
      p.separator "\nBenchmark:"
      p.on("--file PATH", "benchmark this video file instead of picking samples from the library") { |v| opts[:file] = v }
      p.separator "\nExamples (192.168.1.50 = your server's internal IP):"
      p.separator "  emby-tune --host 192.168.1.50 --dry-run"
      p.separator "  emby-tune --host 192.168.1.50 --server-name 'Home Cinema' --subtitle-langs en,pt-br --original-audio"
      p.separator "  emby-tune --host 192.168.1.50 --user-subs 'Ana=pob,por:Smart'"
      p.separator "  emby-tune --host 192.168.1.50 benchmark"
      p.separator "  emby-tune deluge-apply config/deluge/recommended-settings.json"
      p.on("--version", "print the version") do
        puts "emby-tune #{VERSION}"
        exit
      end
    end
    rest = parser.parse(argv)
    opts[:command] = %w[tune benchmark deluge-apply].include?(rest.first) ? rest.shift : "tune"
    opts[:args] = rest
    die("--quiet-hour must be 0-23") unless opts[:quiet_hour].between?(0, 23)
    die("--only accepts #{AREAS.join(', ')}") if opts[:only] && !(opts[:only] - AREAS).empty?
    die("--media-group must be a valid Linux group name") unless opts[:media_group].match?(/\A[a-z_][a-z0-9_-]{0,31}\z/)
    opts
  rescue OptionParser::ParseError => e
    die(e.message)
  end

  def self.main(argv)
    opts = parse_args(argv)
    case opts[:command]
    when "benchmark" then cmd_benchmark(opts)
    when "deluge-apply" then cmd_deluge_apply(opts)
    else cmd_tune(opts)
    end
  rescue Interrupt
    puts "\ninterrupted; nothing further changed"
    130
  rescue Errno::EPIPE # output piped into head/less that exited early
    0
  ensure
    opts&.dig(:logout)&.call
  end
end

exit(EmbyTune.main(ARGV)) if $PROGRAM_NAME == __FILE__
