$LOAD_PATH << '.'
require 'logger'
require 'sinatra/base'
require 'lib/config_file'
require 'app/controllers/main_controller'

LOGGER=Logger.new(STDOUT)

map "#{ConfigFile[:base_path]}" do
  LOGGER.info("Mounting 'MainController' on #{ConfigFile[:base_path]}")
  run MainController
end