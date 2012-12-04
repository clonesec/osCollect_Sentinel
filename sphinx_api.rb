require 'riddle'
require 'riddle/2.1.0'

class SphinxApi
  attr_reader :indexes, :params, :select, :query, :results, :doc_ids, :docid_groupby_counts,
              :total, :total_found, :sphinx_time, :warnings, :errors

  def initialize(settings, syslog, params, temp_indexes_only=false)
    begin
      @sphinx = Riddle::Client.new(settings.riddle_server, settings.riddle_port)
      @sphinx.group_clause = ''
      @sphinx.sort_mode = :extended
      @sphinx.sort_by = 'timestamp DESC'
      @sphinx.rank_mode = :none
      @sphinx.match_mode = :extended
      @sphinx.limit = settings.max_matches # sphinx default=20
    rescue Exception => e
      puts "e=#{e.inspect}"
      raise e
    end
    @syslog = syslog
    @uniqify_ored_attrs = 0
    @params = params
    puts "\n#{'_'*120}\n#{Time.now.utc} -> SphinxApi#initialize:\n@params=#{@params.inspect}"
    @exclude_host_ips = @params['exclude_host_ip_range']
    # groupby_name: srcip
    # groupby_source: bro_conn
    # groupby_attr_ip_type: ipv4
    # groupby_sphinx_attr_name: attr_i0
    # groupby_attr_position: 5
    @group_by = @params['groupby_sphinx_attr_name']
    @indexes = @syslog.indexes(temp_indexes_only)
    puts "@indexes=#{@indexes.inspect}"
    @from_timestamp = @params['from_timestamp'].nil? ? 0 : @params['from_timestamp'].to_i
    @to_timestamp = @params['to_timestamp'].nil? ? 0 : @params['to_timestamp'].to_i
    @from_host = @params['from_host'].nil? ? 0 : @params['from_host'].to_i
    @to_host = @params['to_host'].nil? ? 0 : @params['to_host'].to_i
    @sources = @params['sources'].nil? ? [] : @syslog.sources_to_class_ids(@params['sources'])
    @params['filter_fields'] = {} if @params['filter_fields'].nil?
    @params['match_fields'] = {} if @params['match_fields'].nil?
    @params['query'] = '' if @params['query'].nil?
    # note: escaping the "!" or "-" (not symbols) means they don't work in a sphinx search:
    # @query = Riddle.escape(@params['query'])
    @query = @params['query']
    @select = '*'
    @results = [] # note: @sphinx.run returns an array of results hashes
    @total = 0 # count of matching docs that are retrievable
    @total_found = 0 # count of all matching docs, even those beyond max_matches(1,000)
  end

  def perform
    set_filter_range_for_excluded_host_ips unless (@exclude_host_ips.nil? || @exclude_host_ips.empty?)
    set_group_by unless (@group_by.nil? || (@group_by == ''))
    set_filter_range_for_timestamp unless (@from_timestamp == 0) && (@to_timestamp == 0)
    set_filter_range_for_host_ip unless (@from_host == 0) && (@to_host == 0)
    set_filter_for_sources unless @params['sources'].nil?
    set_filters_for_fields unless @params['filter_fields'].nil?
    @query = process_query_match_fields
    @sphinx.append_query(@query, @indexes)
    @results = @sphinx.run # note: '.run' clears the queue afterwards
    @doc_ids = []
    @docid_groupby_counts = {}
    @total = 0
    @total_found = 0
    @warnings = ""
    @errors = ""
    @sphinx_time = 0
    @results.each do |result|
      @warnings << result[:warning] unless result[:warning].nil?
      @errors << result[:error] unless result[:error].nil?
      unless result[:matches].empty?
        @doc_ids << result[:matches].map { |m| m[:doc] }
        unless (@group_by.nil? || (@group_by == ''))
          result[:matches].each do |match|
            @docid_groupby_counts[match[:doc]] = [ match[:attributes]['@groupby'], match[:attributes]['@count'] ]
          end
        end
        @total += result[:total] unless result[:total].nil?
        @total_found += result[:total_found] unless result[:total_found].nil?
        @sphinx_time += result[:time] unless result[:time].nil?
        # cls: are these useful:
        # puts "words=#{result[:words].inspect}"
        # puts "status=#{result[:status].inspect}"
      end
    end
    puts "#{Time.now.utc} -> SphinxApi#perform: ended with these results:"
    puts "\ttotal=#{@total.inspect} total_found=#{@total_found.inspect} sphinx_time=#{@sphinx_time.inspect}"
    puts "\twarnings=#{@warnings.inspect}\n\terrors=#{@errors.inspect}\n#{'_'*120}\n"
  end

  def matching_ids
    return '' if @doc_ids.empty?
    @doc_ids[0].join(", ") # return a string of comma separated doc id's
  end

  def found_matches?
    matching_ids.length > 0
  end

  def ao_symbol(ao)
    ao == 'or' ? '|' : '&'
  end

  def process_query_match_fields
    q = (@params['query'].nil? || @params['query'].empty?) ? '' : @params['query']
    @params['match_fields'].each do |key, field|
      q += " #{ao_symbol(field['ao'])} (@#{field['sphinx_name']} #{field['value']})"
    end
    q.strip!
    q[0..1] = '' if ['& ', '| '].include?(q[0..1]) # remove leading and/or operator
    # cls: escaping "!" or "-" (not) means they are ignored ... solution?
    # q = Riddle.escape(q)
    puts ">>> process_query_match_fields: q=#{q.inspect}"
    q
  end

  def set_group_by
    puts ">>> set_group_by:\n@sources(#{@sources.class})=#{@sources.inspect}\n@group_by=#{@group_by.inspect}"
    return if @group_by.empty?
    # sphinx.group_distinct = 'class_id'
    @sphinx.group_by = @group_by
    @sphinx.group_function = :attr
    # @sphinx.group_clause = '@group DESC'
    @sphinx.group_clause = '@count DESC'
  end

  def set_filter_for_sources
    puts ">>> set_filter_for_sources:\n@sources(#{@sources.class})=#{@sources.inspect}"
    return if @sources.empty?
    filter = Riddle::Client::Filter.new("class_id", @sources)
    puts "\tfilter.query_message=#{filter.query_message.inspect}"
    @sphinx.filters << filter
  end

  def set_filter_range_for_timestamp
    puts ">>> set_filter_range_for_timestamp:\n#{(@from_timestamp..@to_timestamp).inspect}"
    filter = Riddle::Client::Filter.new("timestamp", @from_timestamp..@to_timestamp)
    puts "\tfilter.query_message=#{filter.query_message.inspect}"
    @sphinx.filters << filter
  end

  def set_filter_range_for_excluded_host_ips
    puts ">>> set_filter_range_for_excluded_host_ips:"
    # @exclude_host_ips(Hash)={"0"=>{"from"=>"1203709588", "to"=>"1203709588"}, "1"=>{"from"=>"846475896", "to"=>"846476031"}}
    @exclude_host_ips.each do |key, ip_range|
      puts "\tip_range(#{ip_range.class})=#{ip_range.inspect}"
      filter = Riddle::Client::Filter.new("host_id", ip_range['from'].to_i..ip_range['to'].to_i, true)
      @sphinx.filters << filter
    end
  end

  def set_filter_range_for_host_ip
    puts ">>> set_filter_range_for_host_ip:\n#{(@from_host..@to_host).inspect}"
    filter = Riddle::Client::Filter.new("host_id", @from_host..@to_host)
    puts "\tfilter.query_message=#{filter.query_message.inspect}"
    @sphinx.filters << filter
  end

  def set_filters_for_fields
    puts ">>> set_filters_for_fields:"
    @params['filter_fields'].each do |key, field|
      case field['source'].downcase
      when 'any'
        # cls: program's are single values
        process_an_any_source field, field['value']
      else
        process_a_specific_source field, field['value'].to_i
      end
    end
    @sphinx.select = @select
  end

  def set_value_for_filter(oper, field_value)
    if oper == '<='
      return 0..field_value.to_i
    elsif oper == '>='
      return field_value.to_i..4294967295
    else
      return [field_value]
    end
  end

  def set_select_for_or_filter(sphinx_attr, oper, field_value, or_attr, exclude)
    if exclude
      @select << ', (NOT ' + "#{sphinx_attr}=#{field_value}" + ") AS #{or_attr}"
    else
      @select << ', (' + "#{sphinx_attr} #{oper} #{field_value}" + ") AS #{or_attr}"
    end
  end

  def process_an_any_source(field, field_value)
    puts ">>> process_an_any_source:"
    sphinx_attr = field['sphinx_name']
    if sphinx_attr == 'program_id'
      field_value = @syslog.program_to_program_id(field['value'])
      field_value = nil if (field_value == '') || field_value.nil? || field_value.empty?
      field_value = 9999999999 if field['ao'] == 'and' && field_value.nil? # ensure a value for AND's
    end
    exclude = (field['operator'] == '!=') ? true : false
    if field['ao'] == 'or'
      or_attr = "#{sphinx_attr}_#{@uniqify_ored_attrs}"
      set_select_for_or_filter(sphinx_attr, field['operator'], field_value, or_attr, exclude)
      filter = Riddle::Client::Filter.new(or_attr, [0,1]) # [0,1]=[false,true]=OR
      @uniqify_ored_attrs += 1
      puts "\t>>> OR <<< or_attr=#{or_attr.inspect} | value=#{field_value.inspect} | exclude=#{exclude.inspect}\n@select=#{@select.inspect}"
    else
      value_array_or_range = set_value_for_filter(field['operator'], field_value)
      filter = Riddle::Client::Filter.new(sphinx_attr, value_array_or_range, exclude)
      puts "\t>>> AND <<< sphinx_attr=#{sphinx_attr.inspect} | value_array_or_range=#{value_array_or_range.inspect} | exclude=#{exclude.inspect}"
    end
    @sphinx.filters << filter
  end

  def process_a_specific_source(field, field_value)
    puts ">>> process_a_specific_source:"
    sphinx_attr = "attr_#{field['sphinx_name']}"
    exclude = (field['operator'] == '!=') ? true : false
    if field['ao'] == 'or'
      or_attr = "#{sphinx_attr}_#{@uniqify_ored_attrs}"
      set_select_for_or_filter(sphinx_attr, field['operator'], field_value, or_attr, exclude)
      filter = Riddle::Client::Filter.new(or_attr, [0,1]) # [0,1]=[false,true]=OR
      @uniqify_ored_attrs += 1
      puts "\t>>> OR <<< or_attr=#{or_attr.inspect} | value=#{field_value.inspect} | exclude=#{exclude.inspect}\n@select=#{@select.inspect}"
    else
      value_array_or_range = set_value_for_filter(field['operator'], field_value)
      filter = Riddle::Client::Filter.new(sphinx_attr, value_array_or_range, exclude)
      puts "\t>>> AND <<< sphinx_attr=#{sphinx_attr.inspect} | value_array_or_range=#{value_array_or_range.inspect} | exclude=#{exclude.inspect}"
    end
    @sphinx.filters << filter
  end

  # def self.highlight_words(client, msg, search)
  #   # Riddle::Query.snippets can't handle a single quote near a slash, so this helps:
  #   msg = msg.gsub(/'/, '*$%*')
  #   begin
  #     snippet = ''
  #     client.query(Riddle::Query.snippets(Riddle.escape(msg), 'temp_1', Riddle.escape(search))).each do |m|
  #       snippet = m['snippet'].gsub('<b>', '<strong>').gsub('</b>', '</strong>')
  #     end
  #     return snippet.gsub('*$%*', "'")
  #   rescue Exception => e
  #     return msg.gsub('*$%*', "'")
  #   end
  # end
end