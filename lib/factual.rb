# A Ruby Lib for using Facutal API 
#
# For more information, visit http://github.com/factual/ruby-factual, 
# and {Factual Developer Tools}[http://www.factual.com/devtools]
#
# Author:: Forrest Cao (mailto:forrest@factual.com)
# Copyright:: Copyright (c) 2010 {Factual Inc}[http://www.factual.com].
# License:: MIT

require 'rubygems'
require 'net/http'
require 'json'
require 'cgi'

module Factual
  # The start point of using Factual API
  class Api

    # To initialize a Factual::Api, you will have to get an API Key from {Factual Developer Tools}[http://www.factual.com/developers/api_key]
    #
    # Params: opts as a hash
    # * <tt>opts[:api_key]</tt> required
    # * <tt>opts[:debug]</tt>   optional, default is false. If you set it as true, it will print the Factual Api Call URLs on the screen
    # * <tt>opts[:domain]</tt>  optional, default value is www.factual.com (only configurable by Factual employees) 
    # 
    # Sample: 
    #   api = Factual::Api.new(:api_key => MY_API_KEY, :debug => true)
    def initialize(opts)
      @api_key = opts[:api_key]
      @version = 2
      @domain  = opts[:domain] || 'www.factual.com'
      @debug   = opts[:debug]

      @adapter = Adapter.new(@api_key, @version, @domain, @debug)
    end

    # Get a Factual::Table object by table_key
    #
    # Sample: 
    #   api.get_table('g9R1u2')
    def get_table(table_key)
      Table.new(table_key, @adapter)
    end

    # Get the token of a {shadow account}[http://wiki.developer.factual.com/f/shadow_input.png], it is a partner-only feature.
    def get_token(unique_id)
      return @adapter.get_token(unique_id)
    end
  end

  # This class holds the metadata of a Factual table. The filter and sort methods are to filter and/or sort
  # the table data before calling a find_one or each_row.
  class Table
    attr_accessor :name, :key, :description, :rating, :source, :creator, :total_row_count, :created_at, :updated_at, :fields, :geo_enabled, :downloadable
    attr_accessor :page_size, :page
    attr_reader   :adapter # :nodoc:

    def initialize(table_key, adapter) # :nodoc:
      @table_key = table_key
      @adapter   = adapter
      @schema    = adapter.schema(@table_key)
      @key       = table_key
      @page_size = Adapter::DEFAULT_LIMIT
      @page      = 1

     [:name, :description, :rating, :source, :creator, :total_row_count, :created_at, :updated_at, :fields, :geo_enabled, :downloadable].each do |attr|
       k = camelize(attr)
       self.send("#{attr}=", @schema[k]) 
     end

     @fields_lookup = {}
     @fields.each do |f|
       fid = f['id']
       field_ref = @schema["fieldRefs"][fid.to_s]
       f['field_ref'] = field_ref
       @fields_lookup[field_ref] = f
     end
    end

    # Define the paging, it can be chained before +find_one+ or +each_row+, +each_row+ makes more sense though.
    # The default page size is 20. And there is a {API limitation policy}[http://wiki.developer.factual.com/ApiLimit] need to be followed.
    #
    # The params are:
    # * page_num: the page number
    # * page_size_hash (optional): { :size => <page_size> }
    #
    # Samples:
    #   table.page(2).each_row { |row| ... } # for each row of the 2nd page
    #   table.page(2, :size => 10).each_row { |row| ... } # for each row of the 2nd page, when page size is 10
    def page(page_num, page_size_hash=nil)
      @page_size = page_size_hash[:size] || @page_size if page_size_hash
      @page = page_num.to_i if page_num.to_i > 0

      return self
    end

    # Define table search queries, it can be chained before +find_one+ or +each_row+.
    # 
    # The params can be:
    # * A query string
    # * An array of query strings
    #
    # Samples:
    #   table.serach('starbucks').find_one # one query
    #   table.search('starbucks', 'burger king').find_one # multiple queries
    def search(*queries)
      @searches = queries.compact.empty? ? nil : queries
      return self
    end

    # Define table filters, it can be chained before +find_one+ or +each_row+.
    # 
    # The params can be:
    # * simple hash for equal filter
    # * nested hash with filter operators
    #
    # Samples:
    #   table.filter(:state => 'CA').find_one # hash
    #   table.filter(:state => 'CA', :city => 'LA').find_one # multi-key hash
    #   table.filter(:state => {"$has" => 'A'}).find_one  # nested hash
    #   table.filter(:state => {"$has" => 'A'}, :city => {"$ew" => 'A'}).find_one # multi-key nested hashes
    #   
    # For more detail inforamtion about filter syntax, please look up at {Server API Doc for Filter}[http://wiki.developer.factual.com/Filter]
    def filter(filters)
      @filters = filters
      return self
    end

    # Define table sorts, it can be chained before +find_one+ or +each_row+.
    # 
    # The params can be:
    # * a hash with single key
    # * single-key hashes, only the first 2 sorts will work. (secondary sort will be supported in next release of Factual API)
    #
    # Samples:
    #   table.sort(:state => 1).find_one  # hash with single key
    #   table.sort({:state => 1}, {:abbr => -1}).find_one # single-key hashes
    # For more detail inforamtion about sort syntax, please look up at {Server API Doc for Sort (TODO)}[http://wiki.developer.factual.com/Sort]
    def sort(*sorts)
      @sorts = sorts
      return self
    end

    # Find the first row (a Factual::Row object) of the table with filters and/or sorts.
    #
    # Samples:
    # * <tt>table.filter(:state => 'CA').find_one</tt>
    # * <tt>table.filter(:state => 'CA').sort(:city => 1).find_one</tt>
    # * <tt>table.filter(:state => 'CA').search('starbucks').sort(:city => 1).find_one</tt>
    def find_one
      resp = @adapter.read_table(@table_key, 
          :filters   => @filters, 
          :searches  => @searches, 
          :sorts     => @sorts, 
          :page_size => 1)
      row_data = resp["data"].first

      if row_data.is_a?(Array)
        subject_key = row_data.shift
        return Row.new(self, subject_key, row_data)
      else
        return nil
      end
    end

    # An iterator on each row (a Factual::Row object) of the filtered and/or sorted table data
    #
    # Samples:
    #   table.filter(:state => 'CA').search('starbucks').sort(:city => 1).each do |row|
    #     puts row.inspect
    #   end
    def each_row
      resp = @adapter.read_table(@table_key, 
          :filters   => @filters, 
          :searches  => @searches, 
          :sorts     => @sorts, 
          :page_size => @page_size, 
          :page      => @page)

      @total_rows = resp["total_rows"]
      rows = resp["data"]

      rows.each do |row_data|
        subject_key = row_data.shift
        row = Row.new(self, subject_key, row_data) 
        yield(row) if block_given?
      end
    end

    # Suggest values for a row, it can be used to create a row, or edit an existing row
    #
    # Parameters:
    #  * +values_hash+ 
    #  * values in hash, field_refs as keys
    #  * +opts+ 
    #  * <tt>opts[:source]</tt> the source of an input, can be a URL or something else
    #  * <tt>opts[:comments]</tt> the comments of an input
    #
    # Returns:
    #   { "subjectKey" => <subject_key>, "exists" => <true|false> }
    #   subjectKey: a Factual::Row object can be initialized by a subjectKey, e.g. Factual::Row.new(@table, subject_key)
    #   exists: if "exists" is true, it means an existing row is edited, otherwise, a new row added
    #
    # Sample:
    #   table.input :two_letter_abbrev => 'NE', :state => 'Nebraska'
    #   table.input({:two_letter_abbrev => 'NE', :state => 'Nebraska'}, {:source => 'http://website.com', :comments => 'cornhusker!'})
    def input(values_hash, opts={})
      values = values_hash.collect do |field_ref, value|
        field = @fields_lookup[field_ref.to_s]
        raise Factual::ArgumentError.new("Wrong field ref.") unless field
        
        { :fieldId => field['id'], :value => value}
      end

      hash = opts.merge({ :values => values })

      ret = @adapter.input(@table_key, hash)
      return ret
    end

    # Suggest values for a row with a token, it is similar to input, but merely for shadow accounts input, it is a parter-only feature.
    #
    # Parameters:
    #  * +token+ 
    #  * +values_hash+ 
    #  * +opts+ 
    #
    # Returns:
    #   { "subjectKey" => <subject_key>, "exists" => <true|false> }
    #   subjectKey: a Factual::Row object can be initialized by a subjectKey, e.g. Factual::Row.new(@table, subject_key)
    #   exists: if "exists" is true, it means an existing row is edited, otherwise, a new row added
    #
    # Sample:
    #   table.input "8kTXTBWBpNFLybFiDmApS9pnQyw2YkM4qImH2XpbC6AG1ixkZFCKKbx2Jk0cGl8Z", :two_letter_abbrev => 'NE', :state => 'Nebraska'
    #   table.input("8kTXTBWBpNFLybFiDmApS9pnQyw2YkM4qImH2XpbC6AG1ixkZFCKKbx2Jk0cGl8Z", {:two_letter_abbrev => 'NE', :state => 'Nebraska'}, {:source => 'http://website.com', :comments => 'cornhusker!'})
    def input_with_token(token, values_hash, opts={})
      return input(values_hash, opts.merge({ :token => token }))
    end

    private

    def camelize(str)
      s = str.to_s.split("_").collect{ |w| w.capitalize }.join
      s[0].chr.downcase + s[1..-1]
    end
  end

  # This class holds the subject_key, subject (in array) and facts (Factual::Fact objects) of a Factual Subject. 
  #
  # The subject_key and subject array can be accessable directly from attributes, and you can get a fact by <tt>row[field_ref]</tt>.
  class Row
    attr_reader :subject_key, :subject

    def initialize(table, subject_key, row_data=[]) # :nodoc:
      @subject_key = subject_key

      @table       = table
      @fields      = @table.fields
      @table_key   = @table.key
      @adapter     = @table.adapter

      if row_data.empty? && subject_key
        single_row_mode = true
        row_data = @adapter.read_row(@table_key, subject_key) 
      end

      idx_offset = single_row_mode ? 1 : 0;

      @subject     = []
      @fields.each_with_index do |f, idx|
        next unless f["isPrimary"]
        @subject << row_data[idx + idx_offset]
      end

      @facts_hash  = {}
      @fields.each_with_index do |f, idx|
        next if f["isPrimary"]
        @facts_hash[f["field_ref"]] = Fact.new(@table, @subject_key, f, row_data[idx + idx_offset])
      end
    end

    # Get a Factual::Fact object by field_ref
    #
    # Sample: 
    #   city_info = table.filter(:state => 'CA').find_one
    #   city_info['city_name']
    def [](field_ref)
      @facts_hash[field_ref]
    end
  end

  # This class holds the subject_key, value, field_ref field (field metadata in hash). The input method is for suggesting a new value for the fact.  
  class Fact
    attr_reader :value, :subject_key, :field_ref, :field 

    def initialize(table, subject_key, field, value) # :nodoc:
      @value = value 
      @field = field
      @subject_key = subject_key

      @table_key = table.key
      @adapter   = table.adapter
    end

    def field_ref # :nodoc:
      @field["field_ref"]
    end

    # To input a new value to the fact
    #
    # Parameters:
    #  * +value+ 
    #  * <tt>opts[:source]</tt> the source of an input, can be a URL or something else
    #  * <tt>opts[:comments]</tt> the comments of an input
    #
    # Sample:
    #   fact.input('new value', :source => 'http://website.com', :comments => 'because it is new value.'
    def input(value, opts={})
      return false if value.nil?

      hash = opts.merge({
        :subjectKey => @subject_key.first,
        :values     => [{
          :fieldId    => @field['id'],
          :value      => value }]
      })

      @adapter.input(@table_key, hash)
      return true
    end

    # Just return the value
    def to_s
      @value
    end

    # Just return the value
    def inspect
      @value
    end
  end


  class Response
    def initialize(obj)
      @obj = obj
    end

    def [](*keys)
      begin
        ret = @obj
        keys.each do |key|
          ret = ret[key]
        end

        if ret.is_a?(Hash)
          return Response.new(ret)
        else
          return ret
        end
      rescue Exception => e
        Factual::ResponseError.new("Unexpected API response")
      end
    end
  end

  class Adapter # :nodoc:
    CONNECT_TIMEOUT = 30
    DEFAULT_LIMIT   = 20

    def initialize(api_key, version, domain, debug=false)
      @domain = domain
      @base   = "/api/v#{version}/#{api_key}"
      @debug  = debug
    end

    def api_call(url)
      api_url = @base + url
      puts "[Factual API Call] http://#{@domain}#{api_url}" if @debug

      json = "{}"
      begin
        Net::HTTP.start(@domain, 80) do |http|
          response = http.get(api_url)
          json     = response.body
        end
      rescue Exception => e
        raise ApiError.new(e.to_s + " when getting " + api_url)
      end

      obj  = JSON.parse(json)
      resp = Factual::Response.new(obj)
      raise ApiError.new(resp["error"]) if resp["status"] == "error"
      return resp
    end

    def schema(table_key)
      url  = "/tables/#{table_key}/schema.json"
      resp = api_call(url)

      return resp["schema"]
    end

    def read_row(table_key, subject_key)
      url  = "/tables/#{table_key}/read.jsaml?subject_key=#{subject_key}"
      resp = api_call(url)

      row_data = resp["response", "data", 0] || []
      row_data.unshift # remove the subject_key
      return row_data
    end

    def read_table(table_key, options={})
      filters   = options[:filters]
      sorts     = options[:sorts]
      searches  = options[:searches]
      page_size = options[:page_size]
      page      = options[:page]

      limit = page_size.to_i 
      limit = DEFAULT_LIMIT unless limit > 0
      offset = (page.to_i - 1) * limit
      offset = 0 unless offset > 0

      filters  = (filters || {}).merge( "$search" => searches) if searches

      filters_query = "&filters=" + CGI.escape(filters.to_json) if filters

      if sorts
        sorts = sorts[0] if sorts.length == 1
        sorts_query = "&sort=" + sorts.to_json
      end

      url  = "/tables/#{table_key}/read.jsaml?limit=#{limit}&offset=#{offset}" 
      url += filters_query.to_s + sorts_query.to_s
      resp = api_call(url)

      return resp["response"]
    end

    def get_token(unique_id)
      url  = "/sessions/get_token?uniqueId=#{unique_id}"
      resp = api_call(url)

      return resp["string"]
    end

    def input(table_key, params)
      token = params.delete(:token)
      query_string = params.to_a.collect do |k,v| 
        v_string = (v.is_a?(Hash) || v.is_a?(Array)) ? v.to_json : v.to_s
        CGI.escape(k.to_s) + '=' + CGI.escape(v_string) 
      end.join('&')

      url  = "/tables/#{table_key}/input.js?" + query_string
      url += "&token=" + token if token
      resp = api_call(url)

      return resp['response']
    end
  end

  # Exception classes for Factual Errors  
  class ApiError < StandardError; end
  class ArgumentError < StandardError; end
  class ResponseError < StandardError; end
end
