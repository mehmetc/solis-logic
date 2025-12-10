require 'app/helpers/main_helper'

class MainController < Sinatra::Base
  helpers Sinatra::MainHelper

  configure do
    set :method_override, true # make a PUT, DELETE possible with the _method parameter
    set :show_exceptions, false
    set :raise_errors, false
    set :root, File.absolute_path("#{File.dirname(__FILE__)}/../../")
    set :views, (proc { "#{root}/app/views" })
    set :logging, true
    set :static, true
    set :public_folder, "#{root}/public"
  end

  get '/' do
    content_type :json
    all_logic_url.to_json
  end

  get '/ping' do
    content_type :json
    {
      "api": true
    }.to_json
  end

  get '/debug/memory' do
    require 'objspace'
    content_type :json
    GC.start
    counts = Hash.new(0)
    ObjectSpace.each_object { |o|
      begin
        counts[(o.class.name rescue o.class.to_s)] += 1
      rescue Exception => e
        puts e.message
      end
    }

    # Show top memory hogs
    top = counts.sort_by { |k, v| -v }.first(20)

    {
      memory_mb: `ps -o rss= -p #{Process.pid}`.to_i / 1024,
      objects: ObjectSpace.count_objects,
      heap_live: GC.stat[:heap_live_slots],
      total_allocated: GC.stat[:total_allocated_objects],
      top: top
    }.to_json
  end

  get '/*' do
    content_type :json
    Graphiti::with_context(load_context) do
      call_logic.to_json
    end
  end

  not_found do
    content_type :json
    message = body
    logger.error(message)
    message.to_json
  end

  error do
    content_type :json
    message = { status: 500, body: "error:  #{env['sinatra.error'].to_s}" }
    logger.error(message)
    message.to_json
  end
end