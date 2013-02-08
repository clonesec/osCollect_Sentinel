require 'ipaddr'

class Syslog
  attr_reader :syslog_conn, :fields, :results, :total_perm_indexes, :total_perm_records, :total_temp_indexes, :total_temp_records

  PROTOCOLS = Hash[1, 'ICMP', 6, 'TCP', 17, 'UDP']

  def initialize(syslog_conn)
    @syslog_conn = syslog_conn
    @fields = {}
    @results = []
    @total_perm_indexes = 0
    @total_perm_records = 0
    @total_temp_indexes = 0
    @total_temp_records = 0
  end

  def reset
    # calling this method allows this object and it's db connection to be reused
    @results = []
    @total_perm_indexes = 0
    @total_perm_records = 0
    @total_temp_indexes = 0
    @total_temp_records = 0
  end

  def program_to_program_id(program)
    reset
    return 1 if program.nil? || program.empty? # assuming 1=none in syslog.programs table
    @syslog_conn.query("SELECT `programs`.`id` FROM `programs` WHERE `programs`.`program` = '#{program}' LIMIT 1", as: :array).map {|id| id[0]}.join('')
  end

  def sources_to_class_ids(sources)
    reset
    source_values = sources.values
    source_values.delete('any')
    source_values.delete('Any')
    return [] if sources.nil? || sources.empty?
    sources_sql = "'" + source_values.join("','").gsub(' ', '_') + "'"
    @syslog_conn.query("SELECT `classes`.`id` FROM `classes` WHERE `classes`.`class` IN (#{sources_sql})", as: :array).map {|id| id[0]}
  end

  def indexes(only_temps=false)
    reset
    if only_temps
      @syslog_conn.query("SELECT `v_indexes`.`id` FROM `v_indexes`  WHERE `v_indexes`.`type` = 'temporary'", as: :array).map {|id| "temp_" + id[0].to_s}.join(", ")
    else
      @syslog_conn.query("SELECT CONCAT(SUBSTR(type, 1, 4), '_', id) AS name FROM `v_indexes`  WHERE `v_indexes`.`type` = 'temporary' OR (type='permanent' AND ISNULL(locked_by))", as: :array).map {|name| name[0]}.join(", ")
    end
  end

  def total_logs
    return
    # cls: way too slow:
    # sql = "SELECT count(*) from syslog_data.syslogs_archive_1 LIMIT 1"
    # @syslog_conn.query(sql, as: :array).map {|cnt| cnt[0]}.join('')
  end

  def total_log_counts_by_host_for_week(start_time, end_time)
    reset # this does @results = []
    results = @syslog_conn.query("SELECT host_id, sum(`host_stats`.count) as ht FROM host_stats where (timestamp >= '#{start_time}') AND (timestamp <= '#{end_time}') GROUP BY host_id ORDER BY ht desc;", as: :array)
    hosts = Hash.new(0) # will keep hosts unique
    results.each do |host|
      hosts[host[0]] += host[1] # [0]=ip [1]=count
    end
    @results = hosts.to_a
    @results
  end

  def total_log_counts_by_host_for_this_week(start_of_week)
    reset # this does @results = []
    results = @syslog_conn.query("SELECT host_id, sum(`host_stats`.count) as ht FROM host_stats where timestamp > '#{start_of_week}' GROUP BY host_id ORDER BY ht desc;", as: :array)
    hosts = Hash.new(0) # will keep hosts unique
    results.each do |host|
      hosts[host[0]] += host[1] # [0]=ip [1]=count
    end
    @results = hosts.to_a
    @results
  end

  def total_logs_per_host
    reset # this does @results = []
    results = @syslog_conn.query("SELECT host_id, sum(`host_stats`.count) as ht FROM host_stats GROUP BY host_id ORDER BY ht DESC;", as: :array)
    hosts = Hash.new(0) # will keep hosts unique
    results.each do |host|
      hosts[host[0]] += host[1] # [0]=ip [1]=count
    end
    @results = hosts.to_a
    @results
    # cls: way too slow:
    # results = []
    # # get syslog_data.syslogs_index_? table names:
    # sql = "SELECT table_name " +
    #       "FROM syslog.tables t1 JOIN table_types t2 ON (t1.table_type_id=t2.id) " +
    #       "WHERE t2.`table_type` = 'index'"
    # tables = @syslog_conn.query(sql, as: :array)
    # unless tables.size < 1
    #   sql = ""
    #   tables.each do |table|
    #     sql += "SELECT host_id, count(host_id) FROM #{table[0]} GROUP BY host_id;"
    #   end
    #   # sql.split(';').each_with_index do |s,x|
    #   #   puts "sql(#{x+1})=#{s.inspect}"
    #   # end
    #   results = @syslog_conn.query(sql, as: :array).map {|record| record}
    #   if @syslog_conn.respond_to?(:next_result)
    #     while @syslog_conn.next_result
    #       @syslog_conn.store_result.each do |sr|
    #         results << sr
    #       end
    #     end
    #   end
    # end
    # hosts = Hash.new(0) # will keep hosts unique
    # # tally each host, as a host may be in multiple index tables:
    # results.sort.each do |host|
    #   hosts[host[0]] += host[1]
    # end
    # @results = hosts.to_a
    # puts "@results(#{@results.class})=#{@results.inspect}"
    # @results
  end

  def fields_for_sources
    reset
    sql = "SELECT DISTINCT sources.class AS source, " +
          "fields.field AS name, fields.field_type AS type, fields.input_validation AS iv, " +
          "fcm.field_order AS position " +
          "FROM syslog.fields AS fields " +
          "JOIN syslog.fields_classes_map AS fcm ON (fields.id = fcm.field_id) " +
          "JOIN syslog.classes AS sources ON (fcm.class_id = sources.id) " +
          "ORDER BY source ASC, position ASC"
    @fields = {}
    @syslog_conn.query(sql, as: :hash, symbolize_keys: true).each do |f|
      next if f[:source].downcase == 'any'
      @fields[f[:source].downcase] = {} unless @fields.has_key?(f[:source].downcase)
      iv = f[:iv].nil? ? '' : f[:iv].downcase
      @fields[f[:source].downcase][f[:position]] = {name: f[:name], iv: iv}
    end
    @fields
  end

  def recent(limit)
    reset
    # get syslog_data.syslogs_index_? table names with most recent first:
    sql = "SELECT table_name, min_id, max_id " +
          "FROM syslog.tables t1 JOIN syslog.table_types t2 ON (t1.table_type_id=t2.id) " +
          "WHERE t2.`table_type` = 'index' " +
          "ORDER BY end DESC " +
          "LIMIT 1"
    table = @syslog_conn.query(sql, as: :array).map {|tn| tn[0]}.join('')
    sql = "SELECT #{table}.id, " +
          "DATE_FORMAT(FROM_UNIXTIME(timestamp), '%Y/%m/%d %H:%i:%s %a') AS datetimestamp, " +
          "INET_NTOA(host_id) AS host_ip, " +
          "pgms.program, classes.class, msg, " +
          "i0, i1, i2, i3, i4, i5, s0, s1, s2, s3, s4, s5 " +
          "FROM #{table} " +
          "LEFT JOIN syslog.programs pgms ON #{table}.program_id = pgms.id " +
          "LEFT JOIN syslog.classes classes ON #{table}.class_id = classes.id " +
          "ORDER BY timestamp DESC LIMIT #{limit}"
    # @results = @syslog_conn.query(sql, as: :array).map {|record| record}
    process_extra_fields(@syslog_conn.query(sql, as: :array))
  end

  def find_by_ids_in_all_syslogs_indexes(ids, docid_groupby_counts=nil, params=nil)
    reset
    return if ids.length <= 0
    # get syslog_data.syslogs_index_? table names with most recent first:
    sql = "SELECT table_name " +
          "FROM syslog.tables t1 JOIN table_types t2 ON (t1.table_type_id=t2.id) " +
          "WHERE t2.`table_type` = 'index' " +
          "ORDER BY end DESC"
    tables = @syslog_conn.query(sql, as: :array)
    unless tables.size < 1
      sql = ""
      tables.each do |table|
        sql +=  "SELECT #{table[0]}.id, " +
                "DATE_FORMAT(FROM_UNIXTIME(#{table[0]}.timestamp), '%Y/%m/%d %H:%i:%s %a') AS datetimestamp, " +
                "INET_NTOA(#{table[0]}.host_id) AS host_ip, " +
                "pgms.program, classes.class, #{table[0]}.msg, " +
                "i0, i1, i2, i3, i4, i5, s0, s1, s2, s3, s4, s5 " +
                "FROM #{table[0]} " +
                "LEFT JOIN syslog.programs pgms ON #{table[0]}.program_id = pgms.id " +
                "LEFT JOIN syslog.classes classes ON #{table[0]}.class_id = classes.id " +
                "WHERE #{table[0]}.id IN (#{ids}) " +
                "ORDER BY timestamp DESC;"
      end
    end
    results = @syslog_conn.query(sql, as: :array).map {|record| record}
    if @syslog_conn.respond_to?(:next_result)
      while @syslog_conn.next_result
        @syslog_conn.store_result.each do |sr|
          results << sr
        end
      end
    end
    if docid_groupby_counts.nil?
      process_extra_fields(results)
    else
      process_groupby_counts(results, docid_groupby_counts, params)
    end
  end

  def find_by_ids(ids)
    reset
    return if ids.length <= 0
    # get syslog_data.syslogs_index_? table names with most recent first:
    # SELECT table_name
    # FROM syslog.tables t1 JOIN table_types t2 ON (t1.table_type_id=t2.id) 
    # WHERE t2.`table_type` = 'index'
    # ORDER BY end DESC;
    # ati=[2..4, 1..1]
    # 1.9.3p125 :007 > ati.each { |ti| ids.select {|i| ti.include?(i) } }
    # 1.9.3p125 :008 > ids=[2,3,4,5]
    # 1.9.3p125 :009 > ati.each { |ti| ids.select {|i| ti.include?(i) } }
    # 1.9.3p125 :010 > ati.each { |ti| ti }
    # 1.9.3p125 :011 > ati.each { |ti| ids.select{|i| ti.include?(i)} }
    # 1.9.3p125 :012 > ids.select {|i| ti.include?(i) }
    # 1.9.3p125 :013 > ti=3..3
    # 1.9.3p125 :014 > ids.select {|i| ti.include?(i) }
    # FIXME handle multiple syslogs_index_x's somehow ?
    #       maybe need multi-statements to handle multiple syslogs_index_x
    table = "syslog_data.syslogs_index_1"
    # table = "syslog_data.syslogs_index_51288"
    sql = "SELECT #{table}.id, " +
          "DATE_FORMAT(FROM_UNIXTIME(timestamp), '%Y/%m/%d %H:%i:%s %a') AS datetimestamp, " +
          "INET_NTOA(host_id) AS host_ip, " +
          "pgms.program, classes.class, msg, " +
          "i0, i1, i2, i3, i4, i5, s0, s1, s2, s3, s4, s5 " +
          "FROM #{table} " +
          "LEFT JOIN syslog.programs pgms ON #{table}.program_id = pgms.id " +
          "LEFT JOIN syslog.classes classes ON #{table}.class_id = classes.id " +
          "WHERE #{table}.id IN (#{ids}) " +
          "ORDER BY timestamp DESC"
    # @results = @syslog_conn.query(sql, as: :array).map {|record| record}
    process_extra_fields(@syslog_conn.query(sql, as: :array))
  end

  def count
    @results.size
  end

  def totals
    @total_perm_indexes = @total_temp_indexes = 0
    @total_perm_records = @total_temp_records = 0
    results = @syslog_conn.query("SELECT type, records FROM `v_indexes` WHERE `v_indexes`.`type` = 'temporary' OR (type='permanent' AND ISNULL(locked_by))", as: :array)
    results.each do |v_index|
      @total_perm_indexes += 1 if v_index[0] == 'permanent'
      @total_perm_records += v_index[1] + 1 if v_index[0] == 'permanent'
      @total_temp_indexes += 1 if v_index[0] == 'temporary'
      @total_temp_records += v_index[1] + 1 if v_index[0] == 'temporary'
    end
  end

  private

  def process_groupby_counts(logs, docid_groupby_counts, params)
    # log[0] = doc_id
    # these must be converted to human readable format:
    #   log[1] = any.timestamp
    #   log[2] = any.host_id
    #   log[3] = any.program_id
    #   log[4] = any.class_id
    #   all ipv4/protocol attributes
    # docid_groupby_counts={50532=>[1203720780, 6606], 51470=>[2917974229, 634], 31002=>[846475896, 198]}
    logs.each do |log|
      alog = []
      alog << log[0] # alog[0] = doc_id
      alog << docid_groupby_counts[log[0]][0].to_s # alog[1] = @groupby
      alog << docid_groupby_counts[log[0]][1] # alog[2] = @count
      case params['groupby_source'].downcase
      when 'any' || 'none'
        case params['groupby_name'].downcase
        when 'timestamp'
          alog[1] = log[1]
        when 'host_id'
          alog[1] = log[2]
        when 'program_id'
          alog[1] = log[3]
        when 'class_id'
          alog[1] = log[4]
        end
      else
        # groupby_name: srcip
        # groupby_source: snort
        # groupby_attr_ip_type: ipv4
        # groupby_sphinx_attr_name: attr_i2
        # groupby_attr_position: 7
        col = params['groupby_attr_position'].to_i + 1
        unless log[col].nil? || log[col].to_s.strip.empty? || log[col].to_s.strip == '0'
          alog[1] = log[col].to_s
          alog[1] = PROTOCOLS[log[col]] if params['groupby_name'] == 'proto'
          alog[1] = ip_numeric_to_s(log[col]) if params['groupby_attr_ip_type'] == 'ipv4'
        end
      end
      @results << alog
    end
  end

  def process_extra_fields(logs)
    logs.each do |log|
      if ['any', 'none'].include?(log[4].downcase)
        @results << log
      else
        alog = []
        source_fields = @fields[log[4].downcase]
        # format log columns: i0-5 and s0-5, if present
        (0..17).each do |column|
          alog << log[column] unless column > 5
          if column > 5
            # log[6]=i0 to log[11]=i5 ... log[12]=s0 to log[17]=s5
            next if log[column].nil? || log[column].to_s.strip.empty? || log[column].to_s.strip == '0'
            log[column] = PROTOCOLS[log[column]] if source_fields[column-1][:name] == 'proto'
            log[column] = ip_numeric_to_s(log[column]) if source_fields[column-1][:iv] == 'ipv4'
            #       note: sig_sid=1:485:5 is gid:sid:rev ... we need the sid portion
            #       ... or:
            #       http://www.snortid.com/snortid.asp?QueryId=1%3A485
            #       http://www.snortid.com/snortid.asp?QueryId=1:485
            # (2) url: "http://whois.domaintools.com/%s"
            #       2012/09/11 21:16:03 Tuesday
            #       192.168.1.1,10.0.0.0,GET,ajax.googleapis.com,/ajax/libs/jqueryui/1.7.2/jquery-ui.min.js,http://slickdeals.net/,Mozilla/4.0 (compatible; MSIE 7.0; Windows NT 5.1; .NET CLR 2.0.50727; .NET CLR 3.0.4506.2152; .NET CLR 3.5.30729)|,com,googleapis.com,ajax.googleapis.com|200|46142|8583 
            #       host=127.0.0.1 program=url log_source=URL srcip=192.168.1.1 dstip=10.0.0.0 status_code=200 content_length=46142 country_code=8583 method=GET site=ajax.googleapis.com uri=/ajax/libs/jqueryui/1.7.2/jquery-ui.min.js referer=http://slickdeals.net/ user_agent=Mozilla/4.0 (compatible; MSIE 7.0; Windows NT 5.1; .NET CLR 2.0.50727; .NET CLR 3.0.4506.2152; .NET CLR 3.5.30729) domains=,com,googleapis.com,ajax.googleapis.com node=Willow (127.0.0.1) docid=258128
            #       ... grab site=ajax.googleapis.com then create lookup link:
            #       http://whois.domaintools.com/ajax.googleapis.com
            source_field_name = source_fields[column-1][:name]
            case source_field_name
            when 'eventid'
              lookup_url = "http://www.ultimatewindowssecurity.com/securitylog/encyclopedia/event.aspx?eventid=#{log[column].to_s}"
              html = "<a href=\"#{lookup_url}\" target=\"_blank\">" + source_field_name + '=' + log[column].to_s + "</a>"
            when 'sig_sid'
              gid_sid_rev = log[column].to_s.split(':')
              # gid_sid = gid_sid_rev[0] + ':' + gid_sid_rev[1]
              # lookup_url = "http://www.snortid.com/snortid.asp?QueryId=#{gid_sid}"
              sid = gid_sid_rev[1]
              lookup_url = "http://doc.emergingthreats.net/bin/view/Main/#{sid}"
              html = "<a href=\"#{lookup_url}\" target=\"_blank\">" + source_field_name + '=' + log[column].to_s + "</a>"
            when 'site'
              lookup_url = "http://whois.domaintools.com/#{log[column].to_s}"
              html = "<a href=\"#{lookup_url}\" target=\"_blank\">" + source_field_name + '=' + log[column].to_s + "</a>"
            else
              html = source_field_name + '=' + log[column].to_s
            end
            alog << html
          end
        end
        @results << alog
      end
    end
  end

  def ip_numeric_to_s(ip)
    ip.is_a?(Integer) ? IPAddr.new(ip, Socket::AF_INET) : IPAddr.new(ip.to_s)
  end

  def numeric?(object)
    true if Integer(object) rescue false
  end
end