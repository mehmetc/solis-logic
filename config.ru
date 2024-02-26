$LOAD_PATH << '.'
require 'active_support/all'
require 'logger'
require 'solis'
require 'sinatra/base'

LOGGER=Logger.new(STDOUT)

raise 'Please set SERVICE_ROLE environment parameter' unless ENV.include?('SERVICE_ROLE')
$SERVICE_ROLE=ENV['SERVICE_ROLE'].downcase.to_sym
puts "setting SERVICE_ROLE=#{$SERVICE_ROLE}"

require 'app/controllers/main_controller'

map "#{Solis::ConfigFile[:services][$SERVICE_ROLE][:base_path]}" do
  LOGGER.info("Mounting 'MainController' on #{Solis::ConfigFile[:services][$SERVICE_ROLE][:base_path]}")
  run MainController
end