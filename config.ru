$stdout.sync = true
require "#{File.dirname(__FILE__)}/initializer"
require "#{File.dirname(__FILE__)}/syslog"
require "#{File.dirname(__FILE__)}/sphinx_api"
require "#{File.dirname(__FILE__)}/sphinx_ql"
require "#{File.dirname(__FILE__)}/web"
run Sinatra::Application