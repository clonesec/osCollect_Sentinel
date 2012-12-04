# osCollect Sentinel node API application

## ![osCollect](http://www.clone-systems.com/images/log-collection-aggregation-reporting-open-source.png) for log collection and log aggregation

This is a sentinel/node application offering a fast search/retrieval API to the **syslog data within Sphinx and MySQL** via Nginx+Thin+Sinatra.


## Installation

(1) copy to an apps folder that is not within/under the oscollect folder, as
this is a standalone app that handles search requests from oscollect, and 
you don't want it deleted/changed on each deploy of the oscollect rails app.

Note that most nodes (using elsa to collect logs) will not have the osCollect rails app installed, as it's not needed, but 
each node does require the sentinel software to be installed as this provides the API that allows searching and the 
retrieval of node data.

ensure everything is installed on each node (i.e. where you have elsa node installed, you also need a sentinel installation):

```
sudo aptitude -y install curl wget nmap nbtscan
sudo aptitude -y install autoconf automake bison build-essential flex git-core libapr1-dev libaprutil1-dev libc6-dev libcurl4-openssl-dev libexpat1 libffi-dev libpcap-ruby libpcap0.8-dev libpcre3-dev libreadline6 libreadline6-dev libssl-dev libtool libxml2 libxml2-dev libxslt-dev libxslt1-dev libxslt1.1 libyaml-dev ncurses-dev openssl ssl-cert subversion zlib1g zlib1g-dev
```

```
sudo bash -s stable < <(curl -s https://raw.github.com/wayneeseguin/rvm/master/binscripts/rvm-installer)
```

```
sudo adduser oscollect rvm
```

... logout then login again

```
rvm --version
rvmsudo rvm get head
```

```
sudo nano /etc/rvmrc
... add: rvm_trust_rvmrcs_flag=1
```

```
rvm install ruby-1.9.3
```

```
rvm --default use 1.9.3
```

```
sudo nano /etc/environment
... add:
RAILS_ENV=production
RACK_ENV=production
```

... logout then login again

```
echo $RAILS_ENV
echo $RACK_ENV
ruby -v
gem -v
```

```
cd ~/apps ... or whatever the sentinel user's home directory is
gem install bundler --no-ri --no-rdoc
gem install foreman --no-ri --no-rdoc
gem list
```

(2) ensure the **RACK_ENV=production** is set in **~/.bashrc** and **/etc/environment**

(3) at this point, the oscollect_sentinel app needs to be **copied to the node** (via scp, rsync, etc.), and 
probably to the **oscollect user's home directory** ... i.e. /home/oscollect/apps/oscollect_sentinel seems appropriate

(4) ensure **.rvmrc** is using the correct gemset

```
cd /home/oscollect/apps/apps/oscollect_sentinel
rvm gemset name ... should be oscollect_sentinel
```

(5) install the gems for the sentinel app:

```
bundle install
```

(6) use Foreman to create the Upstart oscollect_sentinel workers starting with port 9000:

Note that Foreman's "-a" setting may not contain underscore's.

Also, it's easier to type just **sentinel**, so the following commands leave off "oscollect_" when appropriate.

```
rvmsudo bundle exec foreman export upstart /etc/init -a sentinel -d /home/oscollect/apps/oscollect_sentinel -u oscollect -c worker=2 -p 9000
```

... to start everything when server boots up do:

```
sudo nano /etc/init/sentinel.conf
... add to top of file:
start on runlevel [2345]
```

... to start sentinel workers:

```
sudo service sentinel start
```

(7) Nginx is used to load balance between the upstream sentinel Thin workers:

```
sudo nano /etc/nginx/nginx.conf
```

```
user www-data;
worker_processes  3;

error_log  /var/log/nginx/error.log;
pid        /var/run/nginx.pid;

events {
    worker_connections  2048;
    # multi_accept on;
}
worker_rlimit_nofile 2048;

http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;
    log_format    main  '$remote_addr - $remote_user [$time_local] $request '
                        '"$status" $body_bytes_sent "$http_referer" '
                        '"$http_user_agent" "$http_x_forwarded_for"';

    access_log	/var/log/nginx/access.log main;

    sendfile        on;

    keepalive_timeout  5;
    tcp_nodelay        on;

    gzip  on;
    gzip_disable "MSIE [1-6]\.(?!.*SV1)";

    upstream thin_cluster {
      server 127.0.0.1:9000;
      server 127.0.0.1:9001;
    }

    server {
      listen       8080;
      server_name  **your.servers.ip.address**;

      root /home/oscollect/apps/oscollect_sentinel/public;

      location / {
        proxy_set_header  X-Real-IP  $remote_addr;
        proxy_set_header  X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header Host $http_host;
        proxy_redirect off;

        if (-f $request_filename/index.html) {
          rewrite (.*) $1/index.html break;
        }
        if (-f $request_filename.html) {
          rewrite (.*) $1.html break;
        }
        if (!-f $request_filename) {
          proxy_pass http://thin_cluster;
          break;
        }
      }

      error_page   500 502 503 504  /50x.html;
      location = /50x.html {
        root html;
      }

    }

    # include /etc/nginx/conf.d/*.conf;
    # include /etc/nginx/sites-enabled/*;
}
```

(8) don't forget the following changes:

```
server_name  **your.servers.ip.address**;
```

... also, if you increase the number of sentinel Thin workers then add more of these:

```
server 127.0.0.1:9002; ... as many as needed
```

... as well as:

```
worker_processes  4; ... this number should exceed or match the number of _upstream thin_cluster_ servers entered above
```

(9) repeat steps (1) thru (8) for each elsa node that's collecting logs and that you want osCollect to search/retrieve those logs

Note that in the **Admin** feature of the osCollect rails web app there is a **Nodes** interface which allows you to add/edit new sentinel nodes.