class RequestCounter
  def initialize(app, max_requests: 100)
    @app = app
    @max = max_requests
    @count = 0
  end

  def call(env)
    @count += 1
    response = @app.call(env)

    # Signal worker to exit gracefully after response is sent
    if @count >= @max
      Thread.new { sleep 0.1; Process.kill('TERM', Process.pid) }
    end

    response
  end

  def self.cluster?
    workers = 0
    if File.exist?('./config/puma.rb')
      puma_config = File.read('./config/puma.rb')
      matched = puma_config.match(/^workers *(\d*)/)
      if matched && matched.size > 1
        workers = matched[1].to_i
      end
    end

    workers > 1
  end
end