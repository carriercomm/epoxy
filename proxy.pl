#!/usr/bin/perl

=head1 LIQUIDWEB PROXY CGI


=head1 DESCRIPTION

This is a cgi intended to be run via Apache.  The purpose is to
allow a user to connect to a server for which DNS is either not
setup yet, or is invalid (i.e. it's migrating and propogation
has not occured yet).  The idea is that this connection be as
transparent to the user as possible. Obviously the url in the
location bar of their browser will show that something is different
but this is intended as a temporary location for the user to access
during a new create or migration.

The Format of a request is:

http://[hostname].ip.[ip].liquidweb.services/[uri]

=over 12

=item C<hostname>

the virtual hostname of the server

=item C<ip>

The ip address of a web server that is ready to become [hostname]

=item C<uri>

The requested documents on the server.

=back

=head1 EXAMPLE

If a user was migrating a website that is hosted at example.com to a server
that is listening on ip address 10.1.2.3 they could access the new site at:

http://example.com.ip.10.1.2.3/

The system is divided into two functional blocks that are invisible to the user.

In the code the first block you see is the block that handles binary POST
requests.  This is much closer to a strict proxy than a CGI. In this case
Apache handles just the connection to the client and the loading of environmental
variables (i.e. REQUEST_URI and http request headers).

The rest of requests are handled by the second code which use the PERL CGI to talk
to the client and LWP to talk to the "real" server.  The later does the vast
majority of the work load.  The former is used primarily for uploading media.

This software re-writes all urls embedded in the communications. It changes
them to the new format for communication back from the server and from the new
format for communications from the client.

=head1 CAVEATS

This sytem currently supports http 1.1 GET and POST. It does not currently
support OPTIONS HEAD PUT DELETE or TRACE.

=head1 SECURITY

Obviously we don't want to become a wide open anonymous proxy to the wide open world.

HTTP connections out of this server are limited to LW ips using firewall rules.

=head1 ACKNOWLEDGEMENTS

Thanks to the crew at Liquidweb for giving me a job so I could write stuff like this!

=head1 LICENSE

Licensed under the GNU GPL v3.

https://www.gnu.org/licenses/gpl.html

=head1 AUTHOR

Matt Holtz <mholtz@liquidweb.com>


=cut


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

# first step... what are they asking for. We can translate
# this into what we will ultimately proxy to.

my $http_host = $ENV{HTTP_HOST};

$http_host =~ m/(.*)\.ip\.(.*)\.proxy\.liquidweb\.services/;
my $hostname = $1;
my $ip = $2;
my $url = $ENV{REQUEST_URI};

if (!$hostname && !$ip) {
	# Someone is probing looking for things. Kick them over
	# to our website.
	print "Location: http://www.liquidweb.com/\r\n\r\n";
	exit;
}



my $input_content_type = $ENV{'CONTENT_TYPE'};


# these two subs are used in debugging only.
# I've left them in for now so I don't have to
# recreate them if a bug is found.

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

# if the client is sending a request that is
# multipart (i.e. a post that isn't just text)
# we handle it here.
if ($input_content_type && ($input_content_type =~ m/^multipart/)){
	$|=1;
	
	# the socket talks to the new web server.  The client is on STDIN
	my $socket = IO::Socket::INET->new(
		PeerAddr => $ip,
		PeerPort => 'http(80)',
		Proto => 'tcp',
	);

	my $socket_select = IO::Select->new();
	$socket_select->add($socket);
	my $stdin_fh = *STDIN;

	# send the beginnings of the request over
	
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

	# read in the request and edit any content to have our new urls format
	
	while (my $amount = read(STDIN,my $data,$content_length)){
		$data =~ s/\.ip\.$ip\.proxy\.liquidweb\.services//gi;
		$send_data .= $data;
		# $socket->send($data);
	}
	my $new_content_length = length($send_data);
	
	# content length may have changed because of the regex.
	# close out the headers section of the request and send
	# the actual data.
	
	$socket->send("Content-Length: $new_content_length\r\n");
	$socket->send ("Host: $hostname\r\n\r\n");
	$socket->send($send_data);

	# get the http_response
	# we should probably handle this better.
	
	my $http_response = <$socket>;
	$content_length=0;
	my $transfer_encoding;
	
	
	# reading in response headers.
	while (defined(my $data = <$socket>)  && ($socket_select->can_read(1))){
		last if $data eq "\r\n";
		# we are not going to do persistent connections in this iteration
		# so get rid of all that stuff before we send it back to the client.
		next if $data =~ m/keep-alive:/i;		

		if ($data =~ m/Connection: Keep-Alive/i) {
			print "Connection: close\r\n";
		}
		
		# we will save content length for later as it will change. Most of
		# the time we are using chunked transfers so content lenght is not
		# sent.
		elsif ($data =~ m/content-length: (.*)/i) {
			$content_length = $1;
		}
		# this is probably chunked as there are no other transfer encodings
		# currently specified.
		elsif ($data =~ m/transfer-encoding: (.*)/gi) {
			$transfer_encoding = $1;
		} else {
			# this is everything else in the headers. Re-write them with the
			# new urls if necessary.
			$data =~ s/$hostname/$hostname\.ip\.$ip\.proxy\.liquidweb\.services/gi;
			print $data;
		}
	}
	
	# if we do have a content length then we will have to change it after we
	# rewrite all the content with the new urls
	
	if ($content_length) {
		my $data;
		$socket->read($data,$content_length);
		$data =~ s/$hostname/$hostname\.ip\.$ip\.proxy\.liquidweb\.services/gi;
		$content_length = length($data);
		print "Content-length: $content_length\r\n\r\n";

		print $data;
		
	}
	
	# there should never be both chunked encoding and content lenght specified.
	# chunked encoding is used for communications where the actual data length
	# is not known until the end of it's creation (i.e. dymnamic connections)
	
	if ($transfer_encoding =~ m/chunked/i) {
		print "Transfer-Encoding: chunked\r\n\r\n";
		
		# read in the first line. This is how much data to read in this "chunk"
		# Then read that much data, re-write all it's urls and change the chunk
		# size and send the chunk and new chunk size back to the client.
		# Rinse - Repeat until we get a chunk size of 0 which means the transmission
		# is done.
		
		# Chunk sizes are all sent in hex without the 0x so we have to do those
		# conversions to integers on the fly.
		while (my $length = <$socket>) {
			my $data;
			if ($length eq "\r\n") {
				print $length;
			} else {
			
				my $read = $socket->read($data,hex($length));
				$data =~ s/$hostname/$hostname\.ip\.$ip\.proxy\.liquidweb\.services/gi;
				my $new_length = length($data);
				$length = sprintf("%x",$new_length);

				print "$length\r\n";
				print $data;
			}
		}
	}
	
	# We've told 
	
	exit;
	
}

# all other connections are handled here.

# CGI talks to the client via Apache.

my $q = CGI->new;

# above section we are straight proxying the connection. This section
# is a bit cleaner solution. Cookies are handled by proxying all the
# header info above.  

my $cookies = $q->http('HTTP_COOKIE');
my @cookies;
if ($cookies) {
	@cookies = split ';',$cookies;
}

# trick LWP into thinking that dns is setup the way we want it to be.
# this overrides dns for the hostname. otherwise LWP will connect to the
# "real" server after doing a dns lookup.

LWP::UserAgent::DNS::Hosts->register_host( $hostname => $ip);
LWP::UserAgent::DNS::Hosts->enable_override;



# LWP talks to the server.
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
	# we've already fooled the script with the dns spoofing above. We can use the hostname here.

	$req = HTTP::Request->new(
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

# modify the headers to the new url
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

# start the body portion. Modify that content.
print "\r\n";
if ($content_type =~ m/text/){
	$content =~ s/$hostname/$hostname\.ip\.$ip\.proxy\.liquidweb\.services/gi;
} else {
	$content =~ s/$hostname/$hostname\.ip\.$ip\.proxy\.liquidweb\.services/gi;
	binmode STDOUT;
}
print "$content";

