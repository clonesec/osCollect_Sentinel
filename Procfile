# to setup production starting with port 9000 and using the RACK_ENV setting in ~/.bashrc and /etc/environment:
# rvmsudo bundle exec foreman export upstart /etc/init -a sentinel -d /home/cleesmith/apps/oscollect_sentinel -u cleesmith -c worker=2 -p 9000

worker: bundle exec thin start -R config.ru -e $RACK_ENV -p $PORT

# quick test of worker using port 9000:
# http://50.116.50.120:9000//search.json/imac

# quick test using nginx :
# http://50.116.50.120:8080//search.json/imac