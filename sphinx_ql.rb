class SphinxQl
  attr_reader :conn, :indexes, :params, :query, :results, :doc_ids, :total, :total_found, :sphinx_time

  def initialize(conn, indexes, params, limit=1000)
    @sphinx = conn
    @indexes = indexes
    @params = params
    @params['query'] = '' if @params['query'].nil?
    @query = Riddle.escape(@params['query'])
    @limit = 1000 # sphinx default=20
    @results = [] # note: @sphinx.run returns an array of results hashes
    @total = 0 # count of matching docs that are retrievable
    @total_found = 0 # count of all matching docs, even those beyond max_matches(1,000)
  end

  def perform
    search = Riddle.escape(params[:query])
    generate_sphinx_select_query = Riddle::Query::Select.new
    # note: Sphinx default is "LIMIT 0,20" when not specified:
    search_query = generate_sphinx_select_query.matching(@query).from(@indexes).order_by('timestamp desc').limit(@limit).with_options(ranker: :none)
    @results = @sphinx.query(search_query.to_sql)
  end

  def matching_ids
    self.results.map {|m| m['id']}.join(", ")
  end

  def found_matches?
    self.results.size > 0
  end
end