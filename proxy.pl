#!/usr/bin/perl
use strict;
use warnings;

use CGI;
use CGI::Upload;
use LWP::UserAgent::DNS::Hosts;
use Data::Dumper;
use LWP;
use HTTP::Cookies;
use URI::Escape;
use IO::Socket::INET;
use IO::Select;
use bigint;

my $http_host = $ENV{HTTP_HOST};

$http_host =~ m/(.*)\.ip\.(.*)\.proxy\.liquidweb\.services/;
my $hostname = $1;
my $ip = $2;
my $url = $ENV{REQUEST_URI};

if (!$hostname && !$ip) {
	# Someone is probing looking for things.
	print "Location: http://www.liquidweb.com/\n\n";
	exit;
}


# trick LWP into thinking that dns is setup the way we want it to be.
# this overrides dns for the hostname. otherwise LWP will connect to the
# "real" server.
LWP::UserAgent::DNS::Hosts->register_host( $hostname => $ip);
LWP::UserAgent::DNS::Hosts->enable_override;

my $input_content_type = $ENV{'CONTENT_TYPE'};

sub LogPrint{
	my $to_print=shift;
	open FILE,">>/var/www/logs/transaction_log";
	print FILE $to_print;
	close FILE;
}

sub Lprint{
	my $to_print=shift;
	LogPrint $to_print;
	print $to_print;
}


if ($input_content_type && ($input_content_type =~ m/^multipart/)){
	$|=1;
	my $socket = IO::Socket::INET->new(
		PeerAddr => $ip,
		PeerPort => 'http(80)',
		Proto => 'tcp',
	);
	my $stdin_select = IO::Select->new();
	$stdin_select->add(\*STDIN);
	my $socket_select = IO::Select->new();
	$socket_select->add($socket);
	my $stdin_fh = *STDIN;

	$socket->send("$ENV{REQUEST_METHOD} $ENV{REQUEST_URI} $ENV{SERVER_PROTOCOL}\r\n");
	$socket->send("Accept: $ENV{HTTP_ACCEPT}\r\n");
	$socket->send("Accept-Encoding: $ENV{HTTP_ACCEPT_ENCODING}\r\n");
	$socket->send("Accept-Language: $ENV{HTTP_ACCEPT_LANGUAGE}\r\n");
	if ($ENV{HTTP_CACHE_CONTROL}) {
		$socket->send("Cache-Control: $ENV{HTTP_CACHE_CONTROL}\r\n");

	}
	$socket->send("Referer: $ENV{HTTP_REFERER}\r\n");
	$socket->send("Content-type: $ENV{CONTENT_TYPE}\r\n");
	$socket->send("Connection: $ENV{HTTP_CONNECTION}\r\n");
	$socket->send("User-Agent: LW-Proxy/1.0\r\n");
	if ($ENV{HTTP_COOKIE}) {
		$socket->send("Cookie: $ENV{HTTP_COOKIE}\r\n");
	}
	my $content_length = $ENV{CONTENT_LENGTH};



	my $send_data;

	while (my $amount = read(STDIN,my $data,$content_length)){
		$data =~ s/\.ip\.$ip\.proxy\.liquidweb\.services//gi;
		$send_data .= $data;
		# $socket->send($data);
	}
	my $new_content_length = length($send_data);
	$socket->send("Content-Length: $new_content_length\r\n");
	$socket->send ("Host: $hostname\r\n\r\n");
	$socket->send($send_data);

	
	my $http_response = <$socket>;
	$content_length=0;
	my $transfer_encoding;
	
	
	# reading in response headers.
	while (defined(my $data = <$socket>)  && ($socket_select->can_read(1))){
		last if $data eq "\r\n";
		# todo - handle chunked encoding and content-lenght
		next if $data =~ m/keep-alive:/i;		

		if ($data =~ m/Connection: Keep-Alive/i) {
			Lprint "Connection: close\r\n";
		}
		elsif ($data =~ m/content-length: (.*)/i) {
			$content_length = $1;
		}
		elsif ($data =~ m/transfer-encoding: (.*)/gi) {
			$transfer_encoding = $1;
		} else {
			$data =~ s/$hostname/$hostname\.ip\.$ip\.proxy\.liquidweb\.services/gi;
			#$data =~ s/connection: keep-alive/connection: close/gi;
			Lprint $data;
		}
	}
	
	if ($content_length) {
		my $data;
		$socket->read($data,$content_length);
		$data =~ s/$hostname/$hostname\.ip\.$ip\.proxy\.liquidweb\.services/gi;
		$content_length = length($data);
		Lprint "Content-length: $content_length\r\n\r\n";

		Lprint $data;
		
	}
	if ($transfer_encoding =~ m/chunked/i) {
		Lprint "Transfer-Encoding: chunked\r\n\r\n";
		while (my $length = <$socket>) {
			#last unless hex($length);
			my $data;
			if ($length eq "\r\n") {
				Lprint $length;
			} else {
			
				my $read = $socket->read($data,hex($length));
				$data =~ s/$hostname/$hostname\.ip\.$ip\.proxy\.liquidweb\.services/gi;
				my $new_length = length($data);
				$length = sprintf("%x",$new_length);

				Lprint "$length\r\n";
				Lprint $data;
				#Lprint "\r\n";
			}
		}
		#print "0\r\n";
	}
	
	#sleep 5;
	exit;
	
}

my $q = CGI->new;

my $cookies = $q->http('HTTP_COOKIE');
my @cookies;
if ($cookies) {
	@cookies = split ';',$cookies;
}




my $ua = LWP::UserAgent->new;

my $cookiejar = HTTP::Cookies->new();

foreach my $cookie (@cookies){
	my $name;
	my $value;
	($name,$value) = split '=',$cookie;
	$cookiejar->set_cookie(0,$name,$value,'/',$hostname,80,0,0,86400,0);
}
$ua->cookie_jar( $cookiejar);



my $method = $ENV{'REQUEST_METHOD'};
my $req;
my $res;
if ($method eq 'GET'){
	$req = HTTP::Request->new(
# we've already fooled the script with the dns spoofing above. We can use the hostname here.

		GET => "http://$hostname$url",
		[Host => $hostname],
		) || die $@;
}

if ($method eq 'POST'){
	my $content="";
	foreach my $key ( keys %{$q->{param}}){
		# uri_escape has issues with excaping things with '-'
		# in them.	
		# \Q escapes everythign after.
		my $param=uri_escape("\Q" . $q->param($key) . "\E");
		$content.="$key=$param&";
	}
	chop $content;
#	$res = $ua->post("http://$hostname$url",$q->{param});
	$req = HTTP::Request->new(
		"POST",
		"http://$hostname$url",
		[Host => $hostname],
		$content,
		) || die $@;
	$req->{'_content'} = $content;
	$req->content_type("application/x-www-form-urlencoded");
}
my $referrer;
if ($referrer= $ENV{'HTTP_REFERER'}){
	# change the referrer back to how it would look...
	$referrer =~ s/\.ip\.$ip\.proxy\.liquidweb\.services//gi;
	$req->referrer($referrer);
}

$res = $ua->request($req) || die $@;

$cookiejar->extract_cookies($res);
my $content_type = $res->{'_headers'}->{'content-type'};
my $content = $res->{'_content'} ;


foreach my $key (keys %{$res->{'_headers'}}){
	my $header = $res->{'_headers'}->{$key};
	

	if (ref($header) eq 'ARRAY'){
		foreach my $entry (@$header){
			$entry =~ s/$hostname/$hostname\.ip\.$ip\.proxy\.liquidweb\.services/gi;
			print "$key: $entry\n";
		}
	} else {
		$header =~ s/$hostname/$hostname\.ip\.$ip\.proxy\.liquidweb\.services/gi;
		print "$key: $header\n";
	}
}

print "\n";
if ($content_type =~ m/text/){
	$content =~ s/$hostname/$hostname\.ip\.$ip\.proxy\.liquidweb\.services/gi;
} else {
	$content =~ s/$hostname/$hostname\.ip\.$ip\.proxy\.liquidweb\.services/gi;
	binmode STDOUT;
}
print "$content";

