module Redtastic
  class Model
    class << self
      # Recording

      def increment(params)
        key_data = fill_keys_for_update(params)
        if @_type == :unique
          argv = []
          argv << params[:unique_id]
          Redtastic::ScriptManager.msadd(key_data[0], argv)
        else
          if params[:by].present?
            increment_by = params[:by]
          else
            increment_by = 1
          end
          Redtastic::ScriptManager.hmincrby(key_data[0], key_data[1].unshift(increment_by))
        end
      end

      def decrement(params)
        key_data = fill_keys_for_update(params)
        if @_type == :unique
          argv = []
          argv << params[:unique_id]
          Redtastic::ScriptManager.msrem(key_data[0], argv)
        else
          if params[:by].present?
            decrement_by = params[:by]
          else
            decrement_by = 1
          end
          Redtastic::ScriptManager.hmincrby(key_data[0], key_data[1].unshift(-1*decrement_by))
        end
      end

      # Retrieving

      def find(params)
        keys = []
        argv = []

        # Construct the key's timestamp from inputed date parameters
        timestamp = ''
        timestamp += "#{params[:year]}"
        timestamp += "-#{zeros(params[:month])}" if params[:month].present?
        timestamp += "-W#{params[:week]}"        if params[:week].present?
        timestamp += "-#{zeros(params[:day])}"   if params[:day].present?
        params.merge!(timestamp: timestamp)

        # Handle multiple ids
        ids = param_to_array(params[:id])

        ids.each do |id|
          params[:id] = id
          keys << key(params)
          argv << index(id)
        end

        if @_type == :unique
          unique_argv = []
          unique_argv << params[:unique_id]
          result = Redtastic::ScriptManager.msismember(keys, unique_argv)
        else
          result = Redtastic::ScriptManager.hmfind(keys, argv)
        end

        # If only for a single id, just return the value rather than an array
        if result.size == 1
          result[0]
        else
          result
        end
      end

      def aggregate(params)
        key_data  = fill_keys_and_dates(params)
        keys      = key_data[0]

        # If interval is present, we return a hash including the total as well as a data point for each interval.
        # Example: Visits.aggregate(start_date: 2014-01-05, end_date: 2013-01-06, id: 1, interval: :days)
        # {
        #    visits: 2
        #    days: [
        #      {
        #        created_at: 2014-01-05,
        #        visits: 1
        #      },
        #      {
        #        created_at: 2014-01-06,
        #        visits: 1
        #      }
        #    ]
        # }
        if params[:interval].present? && @_resolution.present?
          if @_type == :unique
            argv = []
            argv << key_data[1].shift # Only need the # of business ids (which is 1st element) from key_data[1]
            argv << temp_key
            if params[:attributes].present?
              attributes = param_to_array(params[:attributes])
              attributes.each do |attribute|
                keys << attribute_key(attribute)
                argv << 1
              end
            end
            data_points = Redtastic::ScriptManager.union_data_points_for_keys(keys, argv)
          else
            data_points = Redtastic::ScriptManager.data_points_for_keys(keys, key_data[1])
          end

          result = HashWithIndifferentAccess.new
          dates  = key_data[2]
          # The data_points_for_keys lua script returns an array of all the data points, with one exception:
          # the value at index 0 is the total across all the data points, so we pop it off of the data points array.
          result[model_name]         = data_points.shift
          result[params[:interval]]  = []

          data_points.each_with_index do |data_point, index|
            point_hash                 = HashWithIndifferentAccess.new
            point_hash[model_name]     = data_point
            point_hash[:date]          = dates[index]
            result[params[:interval]]  << point_hash
          end
          result
        else
          # If interval is not present, we just return the total as an integer
          if @_type == :unique
            argv = []
            argv << temp_key
            if params[:attributes].present?
              attributes = param_to_array(params[:attributes])
              attributes.each do |attribute|
                keys << attribute_key(attribute)
                argv << 1
              end
            end
            Redtastic::ScriptManager.msunion(keys, argv)
          else
            key_data[1].shift # Remove the number of ids from the argv array (don't need it in the sum method)
            Redtastic::ScriptManager.sum(keys, key_data[1]).to_i
          end
        end
      end

      private

        def type(type_name)
          types = [:counter, :unique, :mosaic]
          fail "#{type_name} is not a valid type" unless types.include?(type_name)
          @_type = type_name
        end

        def resolution(resolution_name)
          resolutions = [:days, :weeks, :months, :years]
          fail "#{resolution_name} is not a valid resolution" unless resolutions.include?(resolution_name)
          @_resolution = resolution_name
        end

        def fill_keys_for_update(params)
          keys = []
          argv = []

          # Handle multiple keys
          ids = param_to_array(params[:id])

          ids.each do |id|
            params[:id] = id
            if params[:timestamp].present?
              # This is for an update, so we want to build a key for each resolution that is applicable to the model
              scoped_resolutions.each do |resolution|
                keys << key(params, resolution)
                argv << index(id)
              end
            else
              keys << key(params)
              argv << index(id)
            end
          end
          [keys, argv]
        end

        def fill_keys_and_dates(params)
          keys  = []
          dates = []
          argv  = []
          ids   = param_to_array(params[:id])

          argv << ids.size
          start_date = Date.parse(params[:start_date]) if params[:start_date].is_a?(String)
          end_date   = Date.parse(params[:end_date])   if params[:end_date].is_a?(String)

          if params[:interval].present?
            interval = params[:interval]
          else
            interval = @_resolution
          end

          current_date = start_date
          while current_date <= end_date
            params[:timestamp] = current_date
            dates << formatted_timestamp(current_date, interval)
            ids.each do |id|
              params[:id] = id
              keys << key(params, interval)
              argv << index(id)
            end
            current_date = current_date.advance(interval => +1)
          end
          [keys, argv, dates]
        end

        def key(params, interval = nil)
          key = ''
          key += "#{Redtastic::Connection.namespace}:" if Redtastic::Connection.namespace.present?
          key += "#{model_name}"
          if params[:timestamp].present?
            timestamp = params[:timestamp]
            timestamp = formatted_timestamp(params[:timestamp], interval) if interval.present?
            key += ":#{timestamp}"
          end
          if @_type == :counter
            key += ":#{bucket(params[:id])}"
          else
            key += ":#{params[:id]}" if params[:id].present?
          end
          key
        end

        def formatted_timestamp(timestamp, interval)
          timestamp = Date.parse(timestamp) if timestamp.is_a?(String)
          case interval
          when :days
            timestamp.strftime('%Y-%m-%d')
          when :weeks
            week_number = timestamp.cweek
            result = timestamp.strftime('%Y')
            result + "-W#{week_number}"
          when :months
            timestamp.strftime('%Y-%m')
          when :years
            timestamp.strftime('%Y')
          end
        end

        def bucket(id)
          @_type == :counter ? id.to_i / 1000 : id
        end

        def index(id)
          id.to_i % 1000
        end

        def zeros(number)
          if number < 10
            "0#{number}"
          else
            number
          end
        end

        def model_name
          name.underscore
        end

        def scoped_resolutions
          case @_resolution
          when :days
            [:days, :weeks, :months, :years]
          when :weeks
            [:weeks, :months, :years]
          when :months
            [:months, :years]
          when :years
            [:years]
          else
            []
          end
        end

        def param_to_array(param)
          result = []
          param.is_a?(Array) ? result = param : result << param
        end

        def temp_key
          seed = Array.new(8) { [*'a'..'z'].sample }.join
          "temp:#{seed}"
        end

        def attribute_key(attribute)
          key = ''
          key += "#{Redtastic::Connection.namespace}:" if Redtastic::Connection.namespace.present?
          key + attribute.to_s
        end
    end
  end
end
