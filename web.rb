# require 'rubygems'
require 'sinatra'
require 'mysql2'
require 'json'
require 'riddle'
require 'riddle/2.1.0'
require 'yaml'
require 'redis'
require 'date'

def sphinx_connect
  # note: setting reconnect to true causes problems, i.e. the results vary for the same search?
  #       so let's connect/close for each search request (slower but yields consistent results)
  Mysql2::Client.new( encoding: 'utf8', reconnect: false, pool: 3,
                      host: settings.sphinxql_server, port: settings.sphinxql_port
  )
end

begin
  puts "initializing: web.rb ... good spot to count logs for the first time"
  syslog_conn = Mysql2::Client.new( encoding:   settings.encoding,
                                    reconnect:  settings.reconnect,
                                    socket:     settings.socket,
                                    database:   settings.database,
                                    username:   settings.username,
                                    password:   settings.password,
                                    flags:      Mysql2::Client::MULTI_STATEMENTS
  )
  # create an object to handle the retrieval of temps/data from syslog/syslog_data:
  syslog = Syslog.new(syslog_conn)
  syslog.fields_for_sources
  # create table for PubSub channels if needed:
  syslog_conn.query("CREATE TABLE IF NOT EXISTS `pubsub_channels` (
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

get '/weekly_log_counts_by_host/:start_time/:end_time' do
  # curl http://127.0.0.1:8080/weekly_log_counts_by_host/1359244800/1359849599
  errors = ""
  begin
    start_time = Time.at(params[:start_time].to_i).utc.strftime('%Y-%m-%d %H:%M:%S')
    end_time = Time.at(params[:end_time].to_i).utc.strftime('%Y-%m-%d %H:%M:%S')
    syslog.total_log_counts_by_host_for_week(start_time, end_time)
    return {errors: errors, results: syslog.results}.to_json
  rescue Exception => e
    puts "\nweb.rb: get '/weekly_log_counts_by_host' :"
    puts "error=#{e.inspect}\n"
    puts "backtrace=#{e.backtrace.inspect}\n"
    errors << "error=#{e.message}\n"
    errors << "backtrace=#{e.backtrace.inspect}\n"
    status 422
    return {errors: errors, results: []}.to_json
  end
end

get '/total_log_counts_by_host_for_this_week' do
  # curl http://127.0.0.1:8080/total_log_counts_by_host_for_this_week
  errors = ""
  begin
    now = Date.today
    sunday = now - now.wday
    start_of_week = sunday.strftime('%Y-%m-%d') + ' 00:00:00'
    syslog.total_log_counts_by_host_for_this_week(start_of_week)
    return {errors: errors, start_of_week: start_of_week, results: syslog.results}.to_json
  rescue Exception => e
    puts "\nweb.rb: get '/total_log_counts_by_host_for_this_week' :"
    puts "error=#{e.inspect}\n"
    puts "backtrace=#{e.backtrace.inspect}\n"
    errors << "error=#{e.message}\n"
    errors << "backtrace=#{e.backtrace.inspect}\n"
    status 422
    return {errors: errors, results: []}.to_json
  end
end

get '/total_log_counts_by_host' do
  # curl http://127.0.0.1:8080/total_log_counts_by_host
  errors = ""
  begin
    # require 'date'
    # now = Date.today
    # sunday = now - now.wday
    # sunday.strftime('%m/%d/%Y')
    # SELECT host_id, sum(`host_stats`.count) FROM host_stats where timestamp > '2000-12-16 00:00:00' GROUP BY host_id;
    # SELECT host_id, sum(`host_stats`.count) as ht FROM host_stats where timestamp > '2000-12-16 00:00:00' 
    # GROUP BY host_id ORDER BY ht desc;
    syslog.total_logs_per_host
    # node_name = settings.node_name.nil? ? 'unknown' : settings.node_name
    # # update host log counts in redis:
    # syslog.results.each do |host|
    #   redis = Redis.new(host: settings.redis_host, port: settings.redis_port, db: settings.redis_db)
    #   redis["oscollect:logs:node:#{node_name}:host:#{host[0]}"] = host[1]
    # end
    # redis.quit if redis
    return {errors: errors, results: syslog.results}.to_json
  rescue Exception => e
    puts "\nweb.rb: get '/hostcounts' :"
    puts "error=#{e.inspect}\n"
    puts "backtrace=#{e.backtrace.inspect}\n"
    errors << "error=#{e.message}\n"
    errors << "backtrace=#{e.backtrace.inspect}\n"
    status 422
    return {errors: errors, results: []}.to_json
  end
end

get '/total_logs' do
  # curl http://127.0.0.1:8080/total_logs
  errors = ""
  begin
    syslog.totals
    total = syslog.total_perm_records + syslog.total_temp_records
    # update total logs in redis:
    # redis = Redis.new(host: settings.redis_host, port: settings.redis_port, db: settings.redis_db)
    # node_name = settings.node_name.nil? ? 'unknown' : settings.node_name
    # redis["oscollect:logs:total:node:#{node_name}"] = total
    # redis.quit if redis
    return {errors: errors, total: total, results: []}.to_json
  rescue Exception => e
    puts "\nweb.rb: get '/counters' :"
    puts "error=#{e.inspect}\n"
    puts "backtrace=#{e.backtrace.inspect}\n"
    errors << "error=#{e.message}\n"
    errors << "backtrace=#{e.backtrace.inspect}\n"
    status 422
    return {errors: errors, total: 0, results: []}.to_json
  end
end

get '/info' do
  errors = ""
  begin
    # note: ps list was too long/wide to be useful:
    # processes = %x(ps ax -o "user time stime pid s pcpu pmem comm pri vsz rss cmd")
    # return {cpus: cpus, mem: mem, disk: disk, uptime: uptime, processes: processes}.to_json
    #
    # %x(cpus=`cat /proc/cpuinfo | grep processor | wc -l`; top bd00.50n2 | grep Cpu | tail -n $cpus | sed 's/.*Cpu(s)://g; s/us,.*//g')
    # note: the "n2" in the command "top bd00.50n2" does 2 iterations in "top" to ignore the
    #       cpu usage for the "top" command itself, which is why it's so slow (about 1 second):
    # cpus = %x(cpus=`cat /proc/cpuinfo | grep processor | wc -l`; top bd00.50n2 | grep Cpu | tail -n $cpus | sed 's/.*Cpu(s)://g; s/us,.*//g')
    # cpus.gsub!(':','=')
    # cpus.gsub!('%','')
    # cpus.gsub!(' ','')
    # cpus = cpus.split("\n")
    # cls: don't do cpu usage as it's just too slow
    mem = %x(free -lm)
    disk = %x(df -h)
    uptime = %x(uptime)
    syslog.totals
    total = syslog.total_perm_records + syslog.total_temp_records
    return {mem: mem, disk: disk, uptime: uptime, temps: syslog.total_temp_indexes, total_temps: syslog.total_temp_records, perms: syslog.total_perm_indexes, total_perms: syslog.total_perm_records, total: total}.to_json
  rescue Exception => e
    puts "\nweb.rb: get '/info' :"
    puts "error=#{e.inspect}\n"
    puts "backtrace=#{e.backtrace.inspect}\n"
    errors << "error=#{e.message}\n"
    errors << "backtrace=#{e.backtrace.inspect}\n"
    status 422
    return {errors: errors, count: 0, results: []}.to_json
  end
end

get '/browse' do
  errors = ""
  started = Time.now
  begin
    content_type :json
    errors = ""
    logs = []
    # note: issues arise using temp/perm indexes via sphinx to grab the latest log records, so let's just get them from the db instead
    logs = syslog.recent(settings.max_matches)
    return {warnings: '', errors: '', sphinx_time: 0, elapsed: (Time.now - started), total: 0, total_found: 0, count: syslog.count, results: syslog.results}.to_json
  rescue Mysql2::Error => e
    puts "web.rb: get '/browse' :"
    puts "Mysql2::Error errno=#{e.errno}"
    puts "Mysql2::Error error=#{e.error}"
    errors << "Mysql2 Error errno=#{e.errno}\n"
    errors << "error=#{e.error}"
    status 200
    return {errors: errors, elapsed: (Time.now - started), total: 0, total_found: 0, count: 0, results: []}.to_json
  end
end

post '/channel/:id' do # create/update
  # cls: PUT doesn't work via Typhoeus --> curl -X PUT -d "query=imac" http://appsudo.com:8080/channel/spud_muffin
  #      ... a PUT via Typhoeus gives a 411 content length header missing from nginx,
  #      so let's use POST as if it were a PUT ... this is not RESTful but it works
  # curl -X POST -d "query=imac" http://appsudo.com:8080/channel/spud_muffin
  content_type :json
  errors = ""
  started = Time.now
  begin
    puts "post /channel/#{params[:id]}\nparams:\n#{params.inspect}\n"
    serialized_params = YAML::dump(params)
    puts "serialized_params(#{serialized_params.class}):\n#{serialized_params.inspect}\n"
    escaped_serialized_params = syslog_conn.escape(serialized_params)
    puts "escaped_serialized_params(#{escaped_serialized_params.class}):\n#{escaped_serialized_params.inspect}\n"
    sql = "REPLACE INTO `pubsub_channels` SET name = '/livelogs/#{params[:id]}', " +
          "filter_params = \"#{escaped_serialized_params}\", " +
          "created_at = CURRENT_TIMESTAMP, updated_at = CURRENT_TIMESTAMP"
    puts "sql:\n#{sql.inspect}\n"
    syslog_conn.query(sql)
    # params_again = YAML::load(serialized_params)
    # return {errors: errors, elapsed: (Time.now - started),
    #         serialized_params: serialized_params, serialized_params_class: serialized_params.class,
    #         params_again: params_again, params_again_class: params_again.class,
    #         params_again_groupby_source: params_again['groupby_source'],
    #         results: []
    # }.to_json
    return {errors: errors, elapsed: (Time.now - started), id: params[:id], results: []}.to_json
  rescue Mysql2::Error => e
    puts "web.rb: put '/channel' (create/update) :"
    puts "Mysql2::Error errno=#{e.errno}"
    puts "Mysql2::Error error=#{e.error}"
    errors << "Mysql2 Error errno=#{e.errno}\n"
    errors << "error=#{e.error}"
    status 200
    return {errors: errors, elapsed: (Time.now - started), results: []}.to_json
  rescue Exception => e
    puts "web.rb: put '/channel' (create/update) :"
    puts "error=#{e.inspect}\n"
    puts "backtrace=#{e.backtrace.inspect}\n"
    errors << "error=#{e.message}\n"
    errors << "backtrace=#{e.backtrace.inspect}\n"
    status 200
    return {errors: errors, elapsed: (Time.now - started), results: []}.to_json
  end
end

delete '/channel/:id' do # delete
  # curl -X DELETE http://appsudo.com:9000/channel/spud_muffin
  errors = ""
  started = Time.now
  begin
    content_type :json
    errors = ""
    puts "web.rb: delete '/channel' (delete) :\nparams:\n#{params.inspect}\n"
    sql = "DELETE FROM `pubsub_channels` WHERE name = '/livelogs/#{params[:id]}' LIMIT 1"
    puts "sql:\n#{sql.inspect}\n"
    syslog_conn.query(sql)
    return {errors: errors, elapsed: (Time.now - started), id: params[:id], results: []}.to_json
  rescue Mysql2::Error => e
    puts "web.rb: delete '/channel' (delete) :"
    puts "Mysql2::Error errno=#{e.errno}"
    puts "Mysql2::Error error=#{e.error}"
    errors << "Mysql2 Error errno=#{e.errno}\n"
    errors << "error=#{e.error}"
    status 200
    return {errors: errors, elapsed: (Time.now - started), results: []}.to_json
  rescue Exception => e
    puts "web.rb: delete '/channel' (delete) :"
    puts "error=#{e.inspect}\n"
    puts "backtrace=#{e.backtrace.inspect}\n"
    errors << "error=#{e.message}\n"
    errors << "backtrace=#{e.backtrace.inspect}\n"
    status 200
    return {errors: errors, elapsed: (Time.now - started), results: []}.to_json
  end
end

post '/groupby' do
  errors = ""
  started = Time.now
  begin
    content_type :json
    errors = ""
    sphinx_search = SphinxApi.new(settings, syslog, params) # note: uses settings.max_matches from config/database.yml
    sphinx_search.perform
    syslog.find_by_ids_in_all_syslogs_indexes(sphinx_search.matching_ids, sphinx_search.docid_groupby_counts, params) if sphinx_search.found_matches?
    return {warnings: sphinx_search.warnings, errors: sphinx_search.errors, sphinx_time: sphinx_search.sphinx_time, elapsed: (Time.now - started), total: sphinx_search.total, total_found: sphinx_search.total_found, count: sphinx_search.total, results: syslog.results}.to_json
  rescue Mysql2::Error => e
    puts "web.rb: post '/groupby' :"
    puts "Mysql2::Error errno=#{e.errno}"
    puts "Mysql2::Error error=#{e.error}"
    errors << "Mysql2 Error errno=#{e.errno}\n"
    errors << "error=#{e.error}"
    status 200
    return {errors: errors, elapsed: (Time.now - started), total: 0, total_found: 0, count: 0, results: []}.to_json
  rescue Exception => e
    puts "\nweb.rb: post '/groupby' :"
    puts "error=#{e.inspect}\n"
    puts "backtrace=#{e.backtrace.inspect}\n"
    errors << "error=#{e.message}\n"
    errors << "backtrace=#{e.backtrace.inspect}\n"
    status 200
    return {errors: errors, elapsed: (Time.now - started), total: 0, total_found: 0, count: 0, results: []}.to_json
  end
end

post '/alerts' do
  # curl -X POST -d "query=1102" http://appsudo.com:9000/alerts
  content_type :json
  errors = ""
  started = Time.now
  begin
    sphinx_search = SphinxApi.new(settings, syslog, params) # note: uses settings.max_matches from config/database.yml
    sphinx_search.perform
    ids = sphinx_search.found_matches? ? sphinx_search.matching_ids : []
    return {warnings: sphinx_search.warnings, errors: sphinx_search.errors, sphinx_time: sphinx_search.sphinx_time, elapsed: (Time.now - started), total: sphinx_search.total, total_found: sphinx_search.total_found, count: ids.length, results: ids}.to_json
  rescue Exception => e
    puts "\nweb.rb: post '/alerts' :"
    puts "error=#{e.inspect}\n"
    errors << "error=#{e.message}\n"
    errors << "backtrace=#{e.backtrace.inspect}\n"
    status 200
    return {errors: errors, elapsed: (Time.now - started), total: 0, total_found: 0, count: 0, results: []}.to_json
  end
end

post '/search' do
  # test via: curl -X POST -d "query=imac" http://50.116.50.120:9000/search
  content_type :json
  errors = ""
  started = Time.now
  begin
    sphinx_search = SphinxApi.new(settings, syslog, params) # note: uses settings.max_matches from config/database.yml
    sphinx_search.perform
    syslog.find_by_ids_in_all_syslogs_indexes(sphinx_search.matching_ids) if sphinx_search.found_matches?
    return {warnings: sphinx_search.warnings, errors: sphinx_search.errors, sphinx_time: sphinx_search.sphinx_time, elapsed: (Time.now - started), total: sphinx_search.total, total_found: sphinx_search.total_found, count: syslog.count, results: syslog.results}.to_json
  rescue Mysql2::Error => e
    puts "web.rb: post '/search' :"
    puts "Mysql2::Error errno=#{e.errno}"
    puts "Mysql2::Error error=#{e.error}"
    errors << "Mysql2 Error errno=#{e.errno}\n"
    errors << "error=#{e.error}"
    status 200
    return {errors: errors, elapsed: (Time.now - started), total: 0, total_found: 0, count: 0, results: []}.to_json
  rescue Exception => e
    puts "\nweb.rb: post '/search' :"
    puts "error=#{e.inspect}\n"
    errors << "error=#{e.message}\n"
    errors << "backtrace=#{e.backtrace.inspect}\n"
    status 200
    return {errors: errors, elapsed: (Time.now - started), total: 0, total_found: 0, count: 0, results: []}.to_json
  end
end

post '/sphinxql_search' do
  # test via: curl -X POST -d "query=imac" http://50.116.50.120:9000/sphinxql_search
  content_type :json
  started = Time.now
  begin
    errors = []
    sphinx_conn = sphinx_connect
    sphinx_search = SphinxQl.new(sphinx_conn, syslog.indexes, params)
    sphinx_search.perform
    unless sphinx_search.found_matches?
      ended = Time.now
      return {errors: errors, elapsed: (ended - started), count: 0, results: []}.to_json
    end
    # cls: need multi-statements to handle multiple syslogs_index_? ...
    sql = "SELECT tempindex.id, tempindex.timestamp, tempindex.host_id, pgms.program, " +
          "classes.class, tempindex.msg " +
          "FROM syslog_data.syslogs_index_1 tempindex " +
          "LEFT JOIN syslog.programs pgms ON tempindex.program_id = pgms.id " +
          "LEFT JOIN syslog.classes classes ON tempindex.class_id = classes.id " +
          "WHERE tempindex.id IN (#{sphinx_search.matching_ids}) " +
          "ORDER BY tempindex.timestamp DESC"
    syslog_data_results = syslog_conn.query(sql, as: :array).map {|record| record}
    ended = Time.now
    return {errors: errors, elapsed: (ended - started), count: syslog_data_results.size, results: syslog_data_results}.to_json
  rescue Mysql2::Error => e
    ended = Time.now
    puts "Mysql2::Error errno=#{e.errno}"
    puts "Mysql2::Error error=#{e.error}"
    errors << "Mysql2::Error errno=#{e.errno}"
    errors << "error=#{e.error}"
    status 422
    return {errors: errors, elapsed: (ended - started), count: 0, results: []}.to_json
  ensure
    # only needed for SphinxQL:
    sphinx_conn.close if sphinx_conn
  end
end

# get '/browse-old' do
#   begin
#     sphinx_conn = sphinx_connect
#     content_type :json
#     errors = []
#     results = []
#     started = Time.now
#     sql = "SELECT `v_indexes`.`id` FROM `v_indexes`  WHERE `v_indexes`.`type` = 'temporary'"
#     temps = syslog_conn.query(sql, as: :array).map {|id| "temp_" + id[0].to_s}.join(", ")
#     generate_sphinx_select_query = Riddle::Query::Select.new
#     # note: Sphinx default is "LIMIT 0,20" when not specified:
#     search_query = generate_sphinx_select_query.from(temps).order_by('timestamp desc').limit(1000).with_options(ranker: :none)
#     results = sphinx_conn.query(search_query.to_sql)
#     unless results.size > 0 
#       ended = Time.now
#       return {errors: errors, elapsed: (ended - started), sphinx_query: search_query.to_sql, count: 0, results: []}.to_json
#     end
#     matching_ids = results.map {|m| m['id']}.join(", ")
#     sql = "SELECT tempindex.id, " +
#           "DATE_FORMAT(FROM_UNIXTIME(tempindex.timestamp), '%Y/%m/%d %H:%i:%s %W') AS datetimestamp, " +
#           "tempindex.host_id, pgms.program, " +
#           "classes.class, tempindex.msg " +
#           "FROM syslog_data.syslogs_index_1 tempindex " +
#           "LEFT JOIN syslog.programs pgms ON tempindex.program_id = pgms.id " +
#           "LEFT JOIN syslog.classes classes ON tempindex.class_id = classes.id " +
#           "WHERE tempindex.id IN (#{matching_ids}) " +
#           "ORDER BY tempindex.timestamp DESC"
#     syslog_data_results = syslog_conn.query(sql, as: :array).map {|record| record}
#     ended = Time.now
#     return {errors: errors, elapsed: (ended - started), sphinx_query: search_query.to_sql, count: syslog_data_results.size, results: syslog_data_results}.to_json
#   rescue Mysql2::Error => e
#     ended = Time.now
#     puts "Mysql2::Error errno=#{e.errno}"
#     puts "Mysql2::Error error=#{e.error}"
#     errors << "Mysql2::Error errno=#{e.errno}"
#     errors << "error=#{e.error}"
#     status 422
#     return {errors: errors, elapsed: (ended - started), sphinx_query: search_query.to_sql, count: 0, results: []}.to_json
#   ensure
#     sphinx_conn.close if sphinx_conn
#   end
# end
