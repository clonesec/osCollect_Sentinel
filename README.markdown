# osCollect Sentinel node API application

## ![osCollect](http://www.clone-systems.com/images/log-collection-aggregation-reporting-open-source.png) for log collection and log aggregation

This is a sentinel/node application offering a fast search/retrieval API to the **syslog data within Sphinx and MySQL** via Nginx+Thin+Sinatra.


## Installation

(1) ensure everything is installed on each node (i.e. where you have elsa node installed, you also need a sentinel installation):

```
sudo aptitude -y install curl wget nmap nbtscan
sudo aptitude -y install autoconf automake bison build-essential flex git-core libapr1-dev libaprutil1-dev libc6-dev libcurl4-openssl-dev libexpat1 libffi-dev libpcap-ruby libpcap0.8-dev libpcre3-dev libreadline6 libreadline6-dev libssl-dev libtool libxml2 libxml2-dev libxslt-dev libxslt1-dev libxslt1.1 libyaml-dev ncurses-dev openssl ssl-cert subversion zlib1g zlib1g-dev
```

```
sudo bash -s stable < <(curl -s https://raw.github.com/wayneeseguin/rvm/master/binscripts/rvm-installer)
```

(2) you may use the same user as the osCollect web app when installed on the same server

(3) create the sentinel app via git clone from github

```
cd /home/oscollect/apps
git clone git://github.com/clonesec/osCollect_Sentinel.git oscollect_sentinel
```


(4) ensure **.rvmrc** is using the correct gemset

```
cd /home/oscollect/apps/oscollect_sentinel
rvm gemset name ... should be oscollect_sentinel
```

(5) install the gems for the sentinel app:

```
bundle install
```

(6) use Foreman to create the Upstart oscollect_sentinel workers starting with port 9000:

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

(7) install Nginx

```
sudo aptitude install nginx
```

(8) Nginx is used to load balance between the upstream sentinel Thin workers

```
sudo nano /etc/nginx/nginx.conf
```

ensure the nginx.conf is similar to:

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

Note that in the **Admin** feature of the osCollect rails web app there is a **Inputs** interface which allows you to add/edit new sentinel nodes.
