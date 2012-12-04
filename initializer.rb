require 'sinatra'

# sudo nano /etc/environment and ~/.bashrc then add:
# RACK_ENV=production
env = ENV["RACK_ENV"]
# or:
# set :environment, :production

YAML::load(File.open('config/database.yml'))['production'].each do |key, value|
  # create "settings" ... see: http://www.sinatrarb.com/configuration.html:
  set key, value
end
