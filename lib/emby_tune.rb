# frozen_string_literal: true

require "etc"
require "io/console"
require "ipaddr"
require "json"
require "net/http"
require "open3"
require "openssl"
require "optparse"
require "socket"
require "tmpdir"
require "uri"
require "zlib"

# emby-tune: audit an Emby server (plus Deluge and the Linux disks it reads from) and apply
# settings that are known to help low-power hosts such as a Raspberry Pi. Ruby 2.7+, stdlib only.
module EmbyTune
  VERSION = "0.3.0"
  AREAS = %w[emby deluge os perms].freeze
end

require_relative "emby_tune/support"
require_relative "emby_tune/emby_client"
require_relative "emby_tune/emby_settings"
require_relative "emby_tune/disks"
require_relative "emby_tune/deluge"
require_relative "emby_tune/permissions"
require_relative "emby_tune/benchmark"
