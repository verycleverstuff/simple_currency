require 'open-uri'
require 'timeout'
require 'crack/xml'

module CurrencyConvertible

  def method_missing(method, *args, &block)
    return CurrencyConvertible::Proxy.new(self,method.to_s) if method.to_s.length == 3 # Presumably a currency ("eur", "gbp"...)
    super(method,*args,&block)
  end

  class Proxy
    attr_reader :numeric
    attr_accessor :cache
    
    @@cache = {}
    
    def initialize(numeric,currency)
      @numeric = numeric
      @currency = currency
      @exchange_date = Time.now.send(:to_date)
    end

    def method_missing(method, *args, &block)
      if !(method.to_s =~ /^to_(utc|int|str|ary)/) && method.to_s =~/^to_/ && method.to_s.length == 6
        return _to(method.to_s.gsub('to_',''))
      end
      @numeric.send(method, *args, &block)
    end

    # Historical exchange lookup
    def at(exchange = nil)
      begin
        @exchange_date = exchange.send(:to_date)
      rescue
        raise "Must use 'at' with a time or date object"
      end
      self
    end

    def +(other)
      return @numeric + other unless other.is_a? CurrencyConvertible::Proxy
      converted = other.send(:"to_#{@currency}")
      @numeric + converted
    end

    def -(other)
      return @numeric - other unless other.is_a? CurrencyConvertible::Proxy
      converted = other.send(:"to_#{@currency}")
      @numeric - converted
    end

    private

    def _to(target)
      raise unless @currency

      return 0.0 if @numeric == 0 # Obviously

      return @numeric if @currency == target

      original = @currency

      amount = @numeric

      # Check if there's a cached exchange rate for today
      return cached_amount(original, target, amount) if cached_rate(original, target)

      # If not, perform calls to APIs, deal with caches...
      result = exchange(original, target, amount.abs)

      # Cache methods
      #cache_currency_methods(original, target)

      result
    end

    # Main method (called by _to) which calls Xavier API
    # and returns a nice result.
    #
    def exchange(original, target, amount)
      negative = (@numeric < 0)

      rate = call_xavier_api(original, target)
     #
      # Get the result and round it to 2 decimals
      result = sprintf("%.2f", amount * rate).to_f

      return -(result) if negative
      result
    end

    # Calls Xavier API to perform the exchange with a specific date.
    # This method is called when using :at method, like this:
    #
    #   30.eur.at(1.year.ago).to_usd
    
    def call_xavier_api(original, target)

      # Check if there is any cached XML for the specified date
      if @@cache.include?("#{original}_#{target}_#{stringified_exchange_date}") then
        parsed_response = @@cache["xaviermedia_#{stringified_exchange_date}"]
      end

      unless parsed_response # Unless there is a cached XML response, ask for it
        retries = 10
        not_found_retries=10
        xml_response = nil
        begin
          # Returns the raw response or
          # raises OpenURI::HTTPError when no data available
          Timeout::timeout(1) { xml_response = make_call(@exchange_date) || nil }
        rescue Timeout::Error
          retries -= 1
          retries > 0 ? sleep(0.42) && retry : raise
        rescue OpenURI::HTTPError # Try to fetch one day and 2 days earlier
          not_found_retries -= 1
          if not_found_retries >= 0
            @exchange_date = (Time.parse(@exchange_date.to_s) - 86400).send(:to_date)
            retry
          else
            raise NotFoundError.new("404 Not Found")
          end
        rescue SocketError
          raise NotFoundError.new("Socket Error")
        end

        return nil unless xml_response && parsed_response = Crack::XML.parse(xml_response)["xavierresponse"]["exchange_rates"]["fx"]

        @@cache["xaviermedia_#{stringified_exchange_date}"] = parsed_response
        puts @@cache
      end

      calculate_rate(parsed_response, original, target)
    end

    def make_call(date)
      args = [date.year, date.month.to_s.rjust(2, '0'), date.day.to_s.rjust(2,'0')]
      api_url = "http://api.finance.xaviermedia.com/api/#{args.join('/')}.xml"
      URI.parse(api_url).open.read
    end

    def calculate_rate(parsed_response, original, target)
      # Calculate the exchange rate from the XML
      if parsed_response.first['basecurrency'].downcase == original
        rate = parse_rate(parsed_response, target)
      elsif parsed_response.first['basecurrency'].downcase == target
        rate = 1 / parse_rate(parsed_response, original)
      else
        original_rate = parse_rate(parsed_response, original)
        target_rate = parse_rate(parsed_response, target)
        rate = target_rate / original_rate
      end
      cache_rate(original, target, rate)
      rate
    end


    def parse_rate(parsed_response, currency)
      rate = parsed_response.select{|element| element["currency_code"].downcase == currency}
      raise CurrencyNotFoundException, "#{currency} is not a valid currency" unless rate && rate.is_a?(Array) && rate.first
      raise NoRatesFoundException, "no exchange rate found for #{currency}" unless rate.first['rate'] && rate.first['rate'].to_f > 0
      rate.first['rate'].to_f
    end

    ##
    # Cache helper methods (only useful in a Rails app)
    ##

    # Returns a suitable string-like date (like "25-8-2010"),
    # aware of possible @exchange_date set by :at method
    #
    def stringified_exchange_date
      value = (@exchange_date || Time.now.send(:to_date))
      [value.month, value.year].join('-')
    end

    # Writes rate to the cache.
    #
    def cache_rate(original, target, rate)
      @@cache["#{original}_#{target}_#{stringified_exchange_date}"] = rate
    end

    # Tries to either get rate or calculate the inverse rate from cache.
    #
    # First looks for an "usd_eur_25-8-2010" entry in the cache,
    # and if it does not find it, it looks for "eur_usd_25-8-2010" and
    # inverts it.
    #
    def cached_rate(original, target)
      if @@cache.include?("#{original}_#{target}_#{stringified_exchange_date}") then
        rate = @@cache["#{original}_#{target}_#{stringified_exchange_date}"]
      end
    end

    # Checks if there's a cached rate and calculates the result
    # from the amount (or returns nil).
    #
    def cached_amount(original, target, amount)
      if rate = cached_rate(original, target)
        result = (amount * rate).to_f
        return result = (result * 100).round.to_f / 100
      end
      nil
    end
  end

end

  ##
  # Custom Exceptions
  ##
   
  class CurrencyNotFoundException < StandardError
  end

  class NoRatesFoundException < StandardError
  end

  class NotFoundError < StandardError
  end


