# epoxy
CGI based proxy for rewriting entire sites on the fly.

You must configure apache to rewrite all urls to point to this proxy.
URLs are encoded so that DNS does not need to be functioning for the 
site in order to view it.

Currently only supports GET and POST. 

No plans to add PUT or DELETE support.

Apache rewrites we used were in this format:

<Directory />
RewriteEngine On
RewriteCond %{REQUEST_FILENAME} !-f
#RewriteCond %{REQUEST_FILENAME} !-d
RewriteRule ^.*$ /cgi-bin/proxy.pl  [L]

    Options FollowSymLinks
    AllowOverride None
</Directory>

The URL encoding scheme is:
http://[VirtualHostName].ip.[IPOfServerToProxyTo].proxy.liquidweb.services/


