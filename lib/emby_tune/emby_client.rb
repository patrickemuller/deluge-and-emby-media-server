# frozen_string_literal: true

# Talking to Emby: the HTTP client, the LAN-only URL, credentials, and the context every check gets.
module EmbyTune
  CGNAT = IPAddr.new("100.64.0.0/10")

  class HTTPError < StandardError
    attr_reader :code

    def initialize(code, path)
      @code = code
      super("HTTP #{code} for #{path}")
    end
  end

  class Emby
    VERBS = { get: Net::HTTP::Get, post: Net::HTTP::Post, delete: Net::HTTP::Delete }.freeze

    def initialize(url, token)
      @base = "#{url.chomp('/')}/emby"
      @token = token
    end

    def get(path, params = nil)
      req(:get, path, params: params)
    end

    def post(path, body = nil)
      req(:post, path, body: body)
    end

    def logout
      post("/Sessions/Logout")
    rescue StandardError
      nil
    end

    def self.login(url, username, password)
      host = Socket.gethostname
      auth = %(Emby UserId="", Client="emby-tune", Device="#{host}", DeviceId="emby-tune-#{host}", Version="#{VERSION}")
      body = new(url, nil).req(:post, "/Users/AuthenticateByName", body: { "Username" => username, "Pw" => password },
                                                                   headers: { "X-Emby-Authorization" => auth })
      EmbyTune.die("that user is not an Emby administrator") unless body.dig("User", "Policy", "IsAdministrator")
      body["AccessToken"]
    end

    def req(verb, path, body: nil, params: nil, headers: {}, timeout: 60)
      uri = URI(@base + path)
      uri.query = URI.encode_www_form(params) if params && !params.empty?
      request = VERBS.fetch(verb).new(uri)
      request["X-Emby-Token"] = @token if @token
      request["Content-Type"] = "application/json"
      request["Accept"] = "application/json"
      request["Accept-Encoding"] = "identity" # Emby's deflate responses lack the zlib header Net::HTTP expects
      headers.each { |k, v| request[k] = v }
      request.body = JSON.generate(body) unless body.nil?
      res = Net::HTTP.start(uri.host, uri.port, open_timeout: 15, read_timeout: timeout) { |h| h.request(request) }
      raise HTTPError.new(res.code.to_i, path) unless res.is_a?(Net::HTTPSuccess)
      return nil if res.body.nil? || res.body.empty?

      JSON.parse(res.body)
    rescue JSON::ParserError
      res.body
    end
  end

  # prefs: user choices from the command line, validated against Emby's language list.
  Ctx = Struct.new(:opts, :emby, :info, :local, :cpu_only, :libraries, :library_paths, :prefs, keyword_init: true)

  def self.public_ip?(addr)
    ip = IPAddr.new(addr.split("%").first)
    !(ip.private? || ip.loopback? || ip.link_local? || (ip.ipv4? && CGNAT.include?(ip)))
  end

  # The URL comes from the user's internal host. Public addresses are refused: the API key
  # would cross the internet over plain HTTP.
  def self.emby_url(opts)
    host = opts[:host].to_s.strip
    host = ask("Internal IP of your Emby server (find it with `hostname -I` on that machine, e.g. 192.168.1.50): ") if host.empty?
    die("an internal IP or hostname is required (--host)") if host.empty?
    host = host.sub(%r{\Ahttps?://}, "").split("/").first
    if host.count(":") == 1
      host, port = host.split(":")
      opts[:port] = Integer(port)
    end
    addrs = begin
      Addrinfo.getaddrinfo(host, opts[:port], nil, :STREAM).map(&:ip_address).uniq
    rescue SocketError
      die("cannot resolve '#{host}'")
    end
    public = addrs.select { |a| public_ip?(a) }.sort
    unless public.empty?
      die("'#{host}' is a public address (#{public.join(', ')}). Use the server's internal LAN address " \
          "(192.168.x.x, 10.x.x.x, 172.16-31.x.x) or a VPN address; this tool talks to Emby over plain HTTP.")
    end
    opts[:url] = "http://#{host.include?(':') ? "[#{host}]" : host}:#{opts[:port]}"
  end

  def self.api_token(opts, url)
    token = opts[:api_key] || ENV.fetch("EMBY_API_KEY", "")
    return token unless token.empty?

    user = opts[:username] || ENV.fetch("EMBY_USERNAME", "")
    if user.empty?
      puts "Connecting to Emby at #{url}"
      token = ask("Emby API key (Dashboard > Advanced > API Keys), or Enter to log in as an admin user: ", secret: true)
      return token unless token.empty?

      user = ask("Admin username: ")
    end
    password = ENV.fetch("EMBY_PASSWORD", "")
    password = ask("Password for #{user}: ", secret: true) if password.empty?
    token = Emby.login(url, user, password)
    opts[:logout] = -> { Emby.new(url, token).logout }
    token
  rescue HTTPError => e
    die("login failed (#{e.code}); check the username and password")
  end

  def self.build_ctx(opts)
    url = emby_url(opts)
    emby = Emby.new(url, api_token(opts, url))
    info = begin
      emby.get("/System/Info")
    rescue HTTPError => e
      die("Emby rejected the credentials (#{e.code}); an admin API key or admin user is required")
    end
    libraries = emby.get("/Library/VirtualFolders") || []
    paths = libraries.flat_map { |lib| lib["Locations"] || [] }
    Ctx.new(opts: opts, emby: emby, info: info, libraries: libraries, library_paths: paths,
            local: RUBY_PLATFORM.include?("linux") && paths.any? { |p| File.directory?(p) },
            cpu_only: detect_cpu_only(emby))
  rescue SystemCallError, SocketError, Net::OpenTimeout => e
    die("cannot reach Emby at #{url}: #{e.message}")
  end

  def self.detect_cpu_only(emby)
    codecs = emby.get("/Encoding/CodecInformation/Video")
    codecs.is_a?(Array) ? codecs.none? { |c| c["IsHardwareCodec"] } : nil
  rescue StandardError
    nil
  end

  # Emby's data folder on this host. /System/Info omits paths for API-key callers, so fall back to the deb default.
  def self.emby_data_dir(ctx)
    return nil unless ctx.local

    [ctx.info["ProgramDataPath"], "/var/lib/emby"].compact.find { |p| File.directory?(p) }
  end
end
