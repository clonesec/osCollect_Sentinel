require 'yaml'
require 'uri'
require 'json'
require 'net/http'
require 'mysql2'
require 'riddle'
require 'riddle/2.1.0'
require "#{File.dirname(__FILE__)}/syslog"
require "#{File.dirname(__FILE__)}/sphinx_api"
require 'eventmachine'
require 'faye'

class Fixnum
  def commas
    self.to_s =~ /([^\.]*)(\..*)?/
    int, dec = $1.reverse, $2 ? $2 : ""
    while int.gsub!(/(,|\.|^)(\d{3})(\d)/, '\1\2,\3')
    end
    int.reverse + dec
  end
end

trap(:INT) do
  puts "\ntrapped INTERRUPT signal: stopping EM reactor\n"
  EM.stop_event_loop if EM.reactor_running?
end

class Settings
  attr_accessor :adapter, :encoding, :reconnect, :pool, :socket, :database,
                :username, :password,
                :sphinxql_server, :sphinxql_port,
                :riddle_server, :riddle_port,
                :max_matches,
                :pubsub_uri,
                :do_channels_every, :channel_filter_time_frame

  def initialize(ahash)
    @adapter = ahash['adapter']
    @encoding = ahash['encoding']
    @reconnect = ahash['reconnect']
    @pool = ahash['pool']
    @socket = ahash['socket']
    @database = ahash['database']
    @username = ahash['username']
    @password = ahash['password']
    @sphinxql_server = ahash['sphinxql_server']
    @sphinxql_port = ahash['sphinxql_port']
    @riddle_server = ahash['riddle_server']
    @riddle_port = ahash['riddle_port']
    @pubsub_uri = ahash['pubsub_uri']
    @max_matches = ahash['max_matches']
    @do_channels_every = ahash['do_channels_every']
    @channel_filter_time_frame = ahash['channel_filter_time_frame']
  end
end

fn = File.dirname(File.expand_path(__FILE__)) + '/config/logcaster.yml'
config_hash = YAML::load(File.open(fn))
settings = Settings.new(config_hash)

begin
  db_conn = Mysql2::Client.new( encoding:   settings.encoding,
                                reconnect:  settings.reconnect,
                                socket:     settings.socket,
                                database:   settings.database,
                                username:   settings.username,
                                password:   settings.password,
                                flags:      Mysql2::Client::MULTI_STATEMENTS
  )
  syslog = Syslog.new(db_conn)
  syslog.fields_for_sources
  # create table for PubSub channels if needed:
  db_conn.query("CREATE TABLE IF NOT EXISTS `pubsub_channels` (
                  `id` int(11) NOT NULL AUTO_INCREMENT,
                  `name` varchar(255) COLLATE utf8_unicode_ci DEFAULT NULL,
                  `filter_params` text COLLATE utf8_unicode_ci,
                  `created_at` datetime NOT NULL,
                  `updated_at` datetime NOT NULL,
                  PRIMARY KEY (`id`),
                  UNIQUE KEY `index_channels_on_name` (`name`)
                ) ENGINE=InnoDB DEFAULT CHARSET=utf8 COLLATE=utf8_unicode_ci"
  )
rescue Exception => e
  puts "Exception:\n#{e.inspect}\n"
end

def publish(pub_uri, channel, log)
  uri = URI.parse(pub_uri)
  if log =~ />INFO< /
    alog = log.gsub('>INFO< ', '')
  else
    # reformat data for display
    alog = "#{log[1]} #{log[5]}\n"
    alog += "host=#{log[2]} program=#{log[3]} log_source=#{log[4]}"
    log[6..18].each { |l| alog += " #{l}" unless l.nil? || l.empty? }
    alog += " docid=#{log[0]}"
  end
  data = JSON.dump('channel' => channel, 'data' => alog.to_json)
  Net::HTTP.post_form(uri, :message => data)
end

def find_filter_params_for(channel, db_conn)
  sql = "SELECT filter_params FROM syslog.pubsub_channels WHERE name = '#{channel}' LIMIT 1"
  rows = db_conn.query(sql, as: :array)
  return nil if rows.size <= 0
  rows.each do |filter_params|
    params = YAML::load(filter_params[0])
    return params
  end
end

@channels = {}
@em_channel_timers = {}

def cancel_periodic_timer(channel)
  cancel_result = @em_channel_timers[channel].cancel # cancel periodic timer
  @em_channel_timers.delete(channel)
  puts "#{'_'*120}\n#{Time.now.utc} CANCELLED timer at #{Time.now.utc} for channel: #{channel}\n@em_channel_timers=#{@em_channel_timers.inspect}\n#{'_'*120}\n"
end

def perform_filter_for(channel, settings, syslog, db_conn)
  started_at = Time.now.utc
  count = @channels.has_key?(channel) ? @channels[channel] : 0
  puts "#{'_'*120}\n#{Time.now.utc} FIRED timer for channel: #{channel} count: #{count}\n@em_channel_timers=#{@em_channel_timers.inspect}\n#{'_'*120}\n"
  if @em_channel_timers.has_key?(channel) && count <= 0
    cancel_periodic_timer(channel)
    puts "#{Time.now.utc} channel count is 0: so cancel timer and return\n#{'_'*120}\n"
    return
  end
  time_end = Time.now.utc
  seconds_ago = settings.channel_filter_time_frame
  time_start = time_end - seconds_ago # match logs from now to seconds ago
  errors = ""
  # begin
    params = find_filter_params_for(channel, db_conn)
    unless params
      cancel_periodic_timer(channel)
      msg = ">INFO< Error: no filter criteria found for channel: \'#{channel}\'\n" +
            "Perhaps this channel was deleted, so no further messages/logs will be sent.\n" +
            "Please review your live logs channels and filter criteria."
      publish(settings.pubsub_uri, channel, msg)
      puts "#{Time.now.utc} channel filter criteris not found: so cancel timer, send error msg, and return\n#{'_'*120}\n"
      return
    end
    params['from_timestamp'] = time_start.to_i
    params['to_timestamp'] = time_end.to_i
    sphinx_search = SphinxApi.new(settings, syslog, params)
    sphinx_search.perform
    syslog.find_by_ids_in_all_syslogs_indexes(sphinx_search.matching_ids) if sphinx_search.found_matches?
    syslog.results.reverse_each do |log|
      publish(settings.pubsub_uri, channel, log)
    end
    publish(settings.pubsub_uri, channel, ">INFO< " + sphinx_search.warnings) unless sphinx_search.warnings.nil? || sphinx_search.warnings.empty?
    publish(settings.pubsub_uri, channel, ">INFO< " + sphinx_search.errors) unless sphinx_search.errors.nil? || sphinx_search.errors.empty?
    info =  ">INFO< <span style=\"color:darkgray\">#{Time.now.utc}\n" +
            "Results for time period: #{time_start} - #{time_end}\n" +
            "search time: #{sphinx_search.sphinx_time}" +
            "   matches: #{sphinx_search.total_found.commas}   displaying: #{syslog.count.commas}</span>"
    publish(settings.pubsub_uri, channel, info)
    puts "#{Time.now.utc} timer finished for channel #{channel}: elapsed=#{(Time.now.utc - started_at)}\n#{'_'*120}\n"
  # rescue Mysql2::Error => e
  #   puts "web.rb: post '/search' :"
  #   puts "Mysql2::Error errno=#{e.errno}"
  #   puts "Mysql2::Error error=#{e.error}"
  #   errors << "Mysql2 Error errno=#{e.errno}\n"
  #   errors << "error=#{e.error}"
  # rescue Exception => e
  #   puts "\nweb.rb: post '/search' :"
  #   puts "error=#{e.inspect}\n"
  #   errors << "error=#{e.message}\n"
  #   errors << "backtrace=#{e.backtrace.inspect}\n"
  # end
end

def process_channels(settings, syslog, db_conn)
  @channels.each do |channel, count|
    if @em_channel_timers.has_key?(channel) && count <= 0
      cancel_periodic_timer(channel)
      next # channel
    end
    next if @em_channel_timers.has_key?(channel) # periodic timer is already set for this channel, so do nothing
    params = find_filter_params_for(channel, db_conn)
    next unless params # no filter criteria for this channel, so ignore this channel and try the next one
    # add a periodic timer for this channel
    if count > 0
      @em_channel_timers[channel] = EM.add_periodic_timer(settings.do_channels_every) do
        perform_filter_for(channel, settings, syslog, db_conn)
      end
    end
  end
end

EM.run do
  pubsub = Faye::Client.new(settings.pubsub_uri)
  # subscribe to channel '/livelogs/channels' to get a list of the currently subscribed channels
  pubsub.subscribe('/livelogs/channels') do |channels|
    @channels = channels
    # Remember that 'elsa node' only inserts/indexes new logs every minute+,
    # which gives us a minute+ to process all channels with subscribers.
    # Within a minute we should be able to process 120 filtered channels, given
    # each filter/search may take 0.5 seconds (60/.5=120) ... this seems like
    # enough capacity for an app with only a few users like osCollect.
    process_channels(settings, syslog, db_conn)
    puts "#{'_'*120}\n#{Time.now.utc} SUBSCRIBE '/livelogs/channels' message received\n@channels=#{channels.inspect}\n@em_channel_timers=#{@em_channel_timers.inspect}\n#{'_'*120}\n"
  end
end
