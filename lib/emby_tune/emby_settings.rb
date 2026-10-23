# frozen_string_literal: true

# Emby's own settings. Each setting is one row in a table (Rule); `check_rules` compares a settings
# object against the rows and plans one change per row that is wrong.
module EmbyTune
  # set:     key => wanted value (several keys change together, e.g. audio language + "play default track").
  # only_if: facts that must all be true for the row to apply (:cpu_only, :subtitles, ...).
  # ok_if:   optional test of the current settings that counts as already fine (e.g. any width up to 1920).
  # show:    keys to display in the plan (defaults to all of `set`; used to hide passwords).
  Rule = Struct.new(:area, :title, :set, :why, :only_if, :ok_if, :show, keyword_init: true)

  ENCODING_RULES = [
    Rule.new(area: "transcode", title: "Transcode throttling", set: { "EnableThrottling" => true },
             why: "Pauses ffmpeg once it is far enough ahead of playback, freeing CPU for other streams."),
    Rule.new(area: "transcode", title: "HEVC (H.265) encoding", set: { "EnableHevcEncoding" => false }, only_if: [:cpu_only],
             why: "Software x265 is slower than real time on low-power CPUs (Pi 5: 0.89x at 1080p); H.264 is ~2.5x faster."),
    Rule.new(area: "transcode", title: "Max transcode width", set: { "TranscodingMaxWidth" => 1920 }, only_if: [:cpu_only],
             ok_if: ->(s) { (1..1920).cover?(s["TranscodingMaxWidth"].to_i) },
             why: "Stops the CPU from re-encoding 4K into 4K H.264 (Pi 5: 0.30x); 1080p output is the most a CPU can manage."),
    Rule.new(area: "transcode", title: "Hardware encoding", set: { "EnableHardwareEncoding" => false }, only_if: [:cpu_only],
             why: "No hardware encoder exists on this machine."),
    Rule.new(area: "transcode", title: "Software tone mapping", set: { "EnableSoftwareToneMapping" => false }, only_if: [:cpu_only],
             why: "HDR to SDR tone mapping in software is far too heavy for a CPU-only box.")
  ].freeze

  LIBRARY_RULES = [
    Rule.new(area: "subtitles", title: "only download forced subtitles", set: { "ForcedSubtitlesOnly" => false }, only_if: [:subtitles],
             why: "With this on, only 'forced' (foreign-dialogue) subtitles are fetched, so almost nothing downloads."),
    Rule.new(area: "subtitles", title: "require hash match", set: { "RequirePerfectSubtitleMatch" => false }, only_if: [:subtitles],
             why: "Hash matches only exist for byte-identical release files; most files then get no subtitles."),
    Rule.new(area: "subtitles", title: "skip if embedded subtitles exist", set: { "SkipSubtitlesIfEmbeddedSubtitlesPresent" => true },
             only_if: [:subtitles], why: "Saves the provider's daily download quota for files that really lack the language."),
    Rule.new(area: "library", title: "intro detection during scan", set: { "EnableMarkerDetectionDuringLibraryScan" => false },
             only_if: [:cpu_only], why: "Fingerprinting audio during scans competes with playback; the nightly task does it instead.")
  ].freeze

  ANIME_RULE = Rule.new(area: "metadata", title: "AniDB request delay (ms)", set: { "AniDB_wait_time" => 2500 },
                        ok_if: ->(s) { s["AniDB_wait_time"].to_i >= 2000 },
                        why: "AniDB bans clients that send more than one request every 2 seconds.")

  DEFAULT_ORIGINAL_AUDIO = "jpn,kor,chi,eng"
  VIDEO_LIBRARY_TYPES = [nil, "", "movies", "tvshows", "mixed", "homevideos", "musicvideos"].freeze
  SUBTITLE_MODES = %w[Default Always OnlyForced None Smart HearingImpaired].freeze
  HEAVY_TASKS = ["Detect Episode Intros", "Video preview thumbnail extraction", "Thumbnail image extraction",
                 "Chapter image extraction"].freeze

  def self.same?(current, wanted)
    [true, false].include?(wanted) ? (current ? true : false) == wanted : current == wanted
  end

  def self.show(value)
    case value
    when nil, "", [] then "none"
    when Array then "[#{value.join(', ')}]"
    else value.to_s
    end
  end

  # Plans a change for every rule whose settings are wrong; `save` persists the (mutated) settings object.
  def self.check_rules(plan, rules, settings, facts, label: nil, &save)
    rules.each do |r|
      next unless Array(r.only_if).all? { |f| facts[f] }
      next if r.ok_if ? r.ok_if.call(settings) : r.set.all? { |k, v| same?(settings[k], v) }

      keys = r.show || r.set.keys
      plan.fix(r.area, [label, r.title].compact.join(" "), keys.map { |k| show(settings[k]) }.join(" / "),
               keys.map { |k| show(r.set[k]) }.join(" / "), r.why) do
        settings.merge!(r.set)
        save.call
      end
    end
  end

  # ------------------------------------------------------------------------- command-line preferences

  def self.parse_lang_mode(spec, cultures)
    langs, mode = spec.split(":", 2)
    langs = langs.to_s.split(",").map(&:strip).map(&:downcase).reject(&:empty?)
    valid = cultures.flat_map { |c| [c["ThreeLetterISOLanguageName"], *Array(c["ThreeLetterISOLanguageNames"])] }.compact.map(&:downcase)
    bad = valid.empty? ? [] : langs - valid
    unless bad.empty?
      die("unknown language code(s) #{bad.join(', ')}: use ISO 639-2 three-letter codes " \
          "(eng, por, spa, jpn...; Brazilian Portuguese subtitles are 'pob')")
    end
    mode = mode.to_s.strip
    die("unknown subtitle mode '#{mode}'; use one of #{SUBTITLE_MODES.sort.join(', ')}") unless mode.empty? || SUBTITLE_MODES.include?(mode)
    [langs.join(","), mode]
  end

  # Validates the opt-in flags once, against Emby's own language list.
  def self.parse_prefs(opts, cultures)
    prefs = { user_subs: {} }
    if opts[:subtitle_langs]
      valid = cultures.map { |c| c["TwoLetterISOLanguageName"].to_s.downcase }
      prefs[:subtitle_langs] = opts[:subtitle_langs].split(",").map(&:strip).map(&:downcase).reject(&:empty?)
      bad = valid.empty? ? [] : prefs[:subtitle_langs] - valid
      die("unknown --subtitle-langs code(s): #{bad.join(', ')}. Use Emby's two-letter codes, e.g. en, pt-br, es, fr, ja") unless bad.empty?
    end
    audio = opts[:audio_pref] || (opts[:original_audio] ? DEFAULT_ORIGINAL_AUDIO : nil)
    prefs[:audio] = parse_lang_mode(audio, cultures).first if audio
    prefs[:all_subs] = parse_lang_mode(opts[:subs_pref], cultures) if opts[:subs_pref]
    opts[:user_subs].each do |spec|
      name, rest = spec.split("=", 2)
      die("--user-subs expects NAME=LANGS[:MODE], got '#{spec}'") if rest.nil?
      prefs[:user_subs][name.strip.downcase] = parse_lang_mode(rest, cultures)
    end
    prefs
  end

  # ------------------------------------------------------------------------- checks

  def self.check_server(ctx, plan)
    v = ctx.info["Version"] || "?"
    plan.warn("emby", "Emby #{v} is old; this tool targets 4.8+. Some checks may not apply.") if (v.scan(/\d+/).map(&:to_i) <=> [4, 8]) == -1
    if ctx.info["HasUpdateAvailable"]
      plan.warn("emby", "Emby #{v} has an update available. Debian/Ubuntu/Pi: install the newest " \
                        "emby-server-deb_*_<arch>.deb from github.com/MediaBrowser/Emby.Releases/releases; Docker: pull the image.")
    else
      plan.ok("emby", "Emby #{v} is current")
    end
    sc = ctx.emby.get("/System/Configuration")
    name = ctx.opts[:server_name].to_s.strip
    unless name.empty?
      rule = Rule.new(area: "emby", title: "Server name", set: { "ServerName" => name },
                      why: "The name the apps show when they find or list this server.")
      check_rules(plan, [rule], sc, {}) { ctx.emby.post("/System/Configuration", sc) }
    end
    if sc["EnableRemoteAccess"] && !sc["EnableHttps"] && !sc["IsBehindProxy"]
      plan.warn("emby", "Remote access is enabled over plain HTTP (logins and tokens travel unencrypted). " \
                        "Put Emby behind a reverse proxy with HTTPS, or use a VPN such as WireGuard/Tailscale.")
    end
    case ctx.cpu_only
    when nil then plan.warn("transcode", "Could not read hardware codec info; transcoding settings left alone.")
    when true
      plan.warn("transcode", "No hardware video codecs detected: every transcode runs on the CPU. On ARM boards " \
                             "(Raspberry Pi 4/5) 4K HEVC cannot be transcoded in real time; such files need clients " \
                             "that direct play them. Run `emby-tune benchmark` to measure this machine.")
    else plan.ok("transcode", "Hardware video codecs detected")
    end
  end

  def self.check_encoding(ctx, plan)
    enc = ctx.emby.get("/System/Configuration/encoding")
    rules = ctx.cpu_only.nil? ? ENCODING_RULES.first(1) : ENCODING_RULES
    check_rules(plan, rules, enc, { cpu_only: ctx.cpu_only }) { ctx.emby.post("/System/Configuration/encoding", enc) }
  end

  def self.check_libraries(ctx, plan)
    fetchers = (ctx.emby.get("/Libraries/AvailableOptions", "LibraryContentType" => "movies")["SubtitleFetchers"] || []).map { |f| f["Name"] }
    plan.warn("subtitles", "No subtitle download plugin installed. Install 'Open Subtitles' from Dashboard > Plugins > Catalog.") if fetchers.empty?
    wanted = ctx.prefs[:subtitle_langs]

    ctx.libraries.each do |lib|
      next unless VIDEO_LIBRARY_TYPES.include?(lib["CollectionType"])

      opts = lib["LibraryOptions"]
      label = "[#{lib['Name']}]"
      save = -> { ctx.emby.post("/Library/VirtualFolders/LibraryOptions", { "Id" => lib["ItemId"], "LibraryOptions" => opts }) }
      rules = []
      if wanted
        rules << Rule.new(area: "subtitles", title: "subtitle download languages", set: { "SubtitleDownloadLanguages" => wanted },
                          why: "Languages Emby downloads subtitles for.")
      end
      subtitles = !(wanted || opts["SubtitleDownloadLanguages"] || []).empty?
      if subtitles && !fetchers.empty?
        order = opts["SubtitleFetcherOrder"] || []
        rules << Rule.new(area: "subtitles", title: "subtitle downloaders",
                          set: { "SubtitleFetcherOrder" => order + (fetchers - order), "DisabledSubtitleFetchers" => [] },
                          ok_if: ->(s) { (fetchers - (s["DisabledSubtitleFetchers"] || [])).then { |on| !on.empty? && (on - order).empty? } },
                          show: ["SubtitleFetcherOrder"], why: "Enables the installed subtitle plugins for this library.")
      end
      check_rules(plan, rules + LIBRARY_RULES, opts, { cpu_only: ctx.cpu_only, subtitles: subtitles }, label: label, &save)
      plan.warn("subtitles", "#{label} downloads no subtitles. Pass --subtitle-langs (e.g. en,pt-br) to turn it on.") unless subtitles
    end
  end

  def self.check_users(ctx, plan)
    prefs = ctx.prefs
    users = ctx.emby.get("/Users") || []
    missing = prefs[:user_subs].keys - users.map { |u| u["Name"].downcase }
    die("--user-subs: no Emby user named '#{missing.first}'") unless missing.empty?

    users.each do |u|
      label = "[#{u['Name']}]"
      cfg = u["Configuration"]
      rules = []
      if prefs[:audio]
        rules << Rule.new(area: "audio", title: "preferred audio",
                          set: { "AudioLanguagePreference" => prefs[:audio], "PlayDefaultAudioTrack" => false },
                          why: "Picks the first track in this language list instead of the track the file flags as default " \
                               "(dual-audio releases usually flag the dub).")
      end
      langs, mode = prefs[:user_subs][u["Name"].downcase] || prefs[:all_subs]
      if langs
        set = { "SubtitleLanguagePreference" => langs }
        set["SubtitleMode"] = mode unless mode.empty?
        rules << Rule.new(area: "subtitles", title: "subtitle preference", set: set,
                          why: "Which subtitle language plays by default for this user.")
      end
      check_rules(plan, rules, cfg, {}, label: label) { ctx.emby.post("/Users/#{u['Id']}/Configuration", cfg) }

      pol = u["Policy"]
      next if pol["EnableContentDownloading"]

      unless ctx.opts[:allow_downloads]
        plan.warn("users", "#{label} cannot download media (pass --allow-downloads to enable).")
        next
      end
      rule = Rule.new(area: "users", title: "allow downloads", set: { "EnableContentDownloading" => true },
                      why: "Lets the user save items for offline playback in the apps.")
      check_rules(plan, [rule], pol, {}, label: label) { ctx.emby.post("/Users/#{u['Id']}/Policy", pol) }
    end
    plan.ok("audio", "Audio preferences untouched (use --original-audio to prefer original-language tracks)") unless prefs[:audio]
  end

  def self.check_plugins(ctx, plan)
    plugins = (ctx.emby.get("/Plugins") || []).map { |p| [p["Name"], p] }.to_h
    if (anime = plugins["Anime"])
      cfg = ctx.emby.get("/Plugins/#{anime['Id']}/Configuration")
      check_rules(plan, [ANIME_RULE], cfg, {}) { ctx.emby.post("/Plugins/#{anime['Id']}/Configuration", cfg) }
    end
    check_opensubtitles(ctx, plan) if plugins.key?("Open Subtitles")
  end

  def self.check_opensubtitles(ctx, plan)
    cfg = ctx.emby.get("/System/Configuration/opensubtitles") || {}
    if (user = ctx.opts[:opensubtitles_user])
      password = ctx.opts[:opensubtitles_password] || ENV["OPENSUBTITLES_PASSWORD"] ||
                 ask("opensubtitles.com password for #{user}: ", secret: true)
      # The plugin encrypts PasswordHash on save, same as the dashboard form.
      rule = Rule.new(area: "subtitles", title: "OpenSubtitles login", set: { "Username" => user, "PasswordHash" => password },
                      ok_if: ->(_) { false }, show: ["Username"], why: "Credentials for api.opensubtitles.com.")
      return check_rules(plan, [rule], cfg, {}) { ctx.emby.post("/System/Configuration/opensubtitles", cfg) }
    end
    if cfg["Username"].to_s.empty?
      plan.warn("subtitles", "Open Subtitles plugin has no login. Pass --opensubtitles-user, or set it in " \
                             "Dashboard > Plugins > Open Subtitles (a free opensubtitles.com account).")
    elsif cfg["Username"].include?("@")
      plan.warn("subtitles", "OpenSubtitles username is an email (#{cfg['Username']}). The API login only accepts the " \
                             "account username; re-run with --opensubtitles-user <username>.")
    end
    check_opensubtitles_log(ctx, plan)
  end

  # The last login failure vs. the last successful search in Emby's log tells whether the login works.
  def self.check_opensubtitles_log(ctx, plan)
    data = emby_data_dir(ctx)
    log_dir = ctx.info["LogPath"] || (data && File.join(data, "logs"))
    log = log_dir && read_text(File.join(log_dir, "embyserver.txt"))
    return unless log

    last_ok = log.rindex("api.opensubtitles.com/api/v1/subtitles") || -1
    last_bad = [log.rindex("OpenSubtitles authentication failed") || -1,
                log.rindex("Response from https://api.opensubtitles.com/api/v1/login") || -1].max
    if last_bad > last_ok
      plan.warn("subtitles", "The Emby log shows OpenSubtitles login failures. Re-enter the username (not email) " \
                             "and password with --opensubtitles-user.")
    elsif last_ok >= 0
      plan.ok("subtitles", "OpenSubtitles searches are succeeding")
    end
  end

  def self.check_tasks(ctx, plan)
    return unless ctx.cpu_only

    hour = ctx.opts[:quiet_hour]
    (ctx.emby.get("/ScheduledTasks") || []).each do |t|
      triggers = t["Triggers"] || []
      next unless HEAVY_TASKS.include?(t["Name"]) && !triggers.empty? && triggers.all? { |x| x["Type"] == "IntervalTrigger" }

      plan.fix("tasks", "'#{t['Name']}' schedule", "every N hours", format("daily at %02d:00", hour),
               "CPU-heavy task; run it when nobody is watching.") do
        ctx.emby.post("/ScheduledTasks/#{t['Id']}/Triggers", [{ "Type" => "DailyTrigger", "TimeOfDayTicks" => hour * 3600 * 10**7 }])
      end
    end
  end
end
