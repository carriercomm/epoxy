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

if ($input_content_type && ($input_content_type =~ m/^multipart/)){
	$|=1;
	my $socket = IO::Socket::INET->new(
		PeerAddr => $ip,
		PeerPort => 'http(80)',
		Proto => 'tcp',
	);
	
	$socket->send("$ENV{REQUEST_METHOD} $ENV{REQUEST_URI} $ENV{SERVER_PROTOCOL}\n");
	$socket->send("Accept: $ENV{HTTP_ACCEPT}\n");
	$socket->send("Accept-Encoding: $ENV{HTTP_ACCEPT_ENCODING}\n");
	$socket->send("Accept-Language: $ENV{HTTP_ACCEPT_LANGUAGE}\n");
	if ($ENV{HTTP_CACHE_CONTROL}) {
		$socket->send("Cache-Control: $ENV{HTTP_CACHE_CONTROL}\n");

	}
	
	$socket->send("Referer: $ENV{HTTP_REFERER}\n");
	$socket->send("Content-type: $ENV{CONTENT_TYPE}\n");
	$socket->send("Content-Length: $ENV{CONTENT_LENGTH}\n");
	$socket->send("Connection: close\n");
	$socket->send("User-Agent: LW-Proxy/1.0\n");
	if ($ENV{HTTP_COOKIE}) {
		LogPrint("Cookie: $ENV{HTTP_COOKIE}\n");
		$socket->send("Cookie: $ENV{HTTP_COOKIE}\n");
	}
	
	$socket->send ("Host: $hostname\n\n");
	while (<>){
		s/$hostname/$hostname\.ip\.$ip\.proxy\.liquidweb\.services/gi;
		$socket->send($_);
	}
	my $http_response = <$socket>;
	while (<$socket>){
		s/$hostname/$hostname\.ip\.$ip\.proxy\.liquidweb\.services/gi;
		print $_;
	}
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
	$referrer =~ s/\.ip\.$ip\.proxy\.liquidweb\.services//g;
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
			LogPrint("$key: " . Dumper($entry));
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
	binmode STDOUT;
}
print "$content";

