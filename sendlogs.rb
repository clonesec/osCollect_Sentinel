require 'socket'
require 'timeout'
require 'eventmachine'

trap(:INT) do
  puts "\ntrapped INTERRUPT signal: stopping EM reactor\n"
  EM.stop_event_loop if EM.reactor_running?
end

def working_hours?(t)
  # noon-7pm EDT == 16:00-23:00 UTC
  t.hour > 15 && t.hour < 24
end

def send_14_logs
  working_hours = working_hours?(Time.now.utc)
  unless working_hours
    # puts "#{Time.now.utc} ... NOT sending logs coz working hours are #{working_hours}"
    return
  end
  client = TCPSocket.new('127.0.0.1', 56109)
  begin
    client.puts "Service_Control_Manager 7035: NT AUTHORITYSYSTEM: The COH_Mon service was successfully sent a start control."
    client.puts "SceCli 1102: Security policies were propagated with warning. 0x4b8 : An extended error has occurred. For best results in resolving this event, log on with a non-administrative account and search http://support.microsoft.com for \"Troubleshooting Event 1102's\"."
    client.puts "snort [1:2001415:5] ICMP Destination Unreachable Communication Administratively Prohibited [Classification: Misc activity] [Priority: 3] {ICMP} 192.168.1.1 -> 10.0.0.0"
    client.puts "url 192.168.1.1,10.0.0.0,GET,ajax.googleapis.com,/ajax/libs/jqueryui/1.7.2/jquery-ui.min.js,http://slickdeals.net/,Mozilla/4.0 (compatible; MSIE 7.0; Windows NT 5.1; .NET CLR 2.0.50727; .NET CLR 3.0.4506.2152; .NET CLR 3.5.30729)|,com,googleapis.com,ajax.googleapis.com|200|46142|8583"
    client.puts "GenericLog 30,11/16/10,12:25:04,DNS Update Request,10.0.0.1,hostname,,"
    client.puts "%FWSM-3-106010 Deny inbound tcp src OUTSIDE:2.116.180.66/3116 dst INSIDE:10.0.0.0/445"
    client.puts "%PIX-6-302014 Teardown TCP connection 2050472353 for outside:10.65.200.34/1252 to inside:10.0.0.0/135 duration 0:00:00 bytes 1476 TCP FINs"
    client.puts "bro_conn 1319824864.447838|g6XHk1uplZc|10.0.0.0|19427|80.175.58.76|80|tcp|..."
    client.puts "bro_dns 1318443095.831281|0L5Ro2iPit1|10.0.0.0|23657|69.22.154.225|53|udp|31608|e2932.c.akamaiedge.net|1|C_INTERNET|1|A|0|NOERROR|F|T|F|F|F|1|20.000000|23.0.124.9"
    client.puts "bro_http 1319824864.447838|g6XHk1uplZc|10.0.0.0|19427|80.175.58.76|80|GET|www.google.com|/|http://example.com|myagent|200|0|1000|..."
    client.puts "bro_smtp 1320612601.697404|SFiDYDwOSl8|10.0.0.0|45765|66.94.25.228|25|@woMgeVXDE|server.example.com|&lt;prvs=284e51a33=user@domain.com&gt;|&lt;user@example.com&gt;|Sun, 6 Nov 2011 14:50:00 -0600|user &lt;user@domain.com&gt;|'user@example.com' &lt;user@example.com&gt;|-|&lt;F3AC33A1A5033546890246040DCA32E303CDF29D5FE6@mailserver.domain.com&gt;|&lt;user@example.com&gt;|RE: some subject|-|from mailserver.domain.com ([10.0.0.0]) with mapi; Sun, 6 Nov 2011 14:50:01 -0600|from mailserver.domain.com ([10.0.0.0]) by mailserver.domain.com with ESMTP/TLS/RC4-MD5; 06 Nov 2011 14:50:01 -0600|250 2.0.0 10wk4g5v6k-1 Message accepted for delivery|192.168.1.1,10.0.0.0|-|F"
    client.puts "bro_smtp_entities 1320613389.303478|zQQiHb1x3fj|216.33.127.82|37295|10.0.0.0|25|@VqmVdbY2Mm3|CDocuments and SettingsckaiserLocal SettingsTemporary Internet FilesContent.IE535ZF226Areport[3].pdf|54399|application/pdf|-|-|-"
    client.puts "bro_ssl 1319824864.447838|g6XHk1uplZc|10.0.0.0|19427|80.175.58.76|443|TLSv10|TLS_RSA_WITH_RC4_128_MD5|-|48eacd8fda1a4f48188288ce09ba84d93b8b40aaafdeafd8bace5a1ba9f7c3ce|CN=www.forneymaterialstesting.com,OU=Comodo InstantSSL,OU=Online Sales,O=Forney Inc,streetAddress=One Adams Place,L=Seven Fields\,,ST=Pennsylvania,postalCode=16046,C=US|1286341200.000000|1381035599.000000|04918ecb442ca62e6e8f29272b9cff42|ok"
    client.puts "bro_notice 1318443067.534801|tZOKnx1pO1j|10.0.0.0|44780|198.87.182.145|80|HTTP::MD5|10.0.0.0 5074d0c1988df72c1be354f8b842021a http://msft.digitalrivercontent.net/01/108767003-10238044--NOA//office2010/X17-75238.exe|5074d0c1988df72c1be354f8b842021a|165.189.145.250|198.87.182.145|80|-|worker-2|Notice::ACTION_LOG|6|3600.000000|-|-|-|-|-|-|-|-|-"
    puts "#{Time.now.utc} sent 14 logs"
  rescue
    puts "error: #{$!}"
  ensure
    client.close
  end
end

EM.run do
  send_14_logs
  EM.add_periodic_timer(60) do
    send_14_logs
  end
end
