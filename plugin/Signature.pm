#
# Bridge between the plugin code and the javascript
# interpretor. It uses greps the javascript code to
# figure out the function used for unobfuscation
# and then uses the interpretor to get a callback
# that can be used to perform the unobfuscation. This
# is cached, so the plugin doesn't have to repeatedly
# download the javascript code for each song.
#
# Author: Daniel P. Berrange <dan-ssods@berrange.com>
#

package Plugins::YouTube::Signature;

use Plugins::YouTube::JSInterp;

my %players;


sub cache_player {
    my $uri = shift;
    my $code = shift;
	my $funcname;

    my $js = Plugins::YouTube::JSInterp->new($code);

=obsolete
	if ($code =~ /\.sig\|\|([a-zA-Z0-9\$]+)\(/) {
		$funcname = $1;
	} elsif ($code =~ /\bc\s*&&\s*d\.set\([^,]+\s*,\s*(?:encodeURIComponent\s*\()?\s*([a-zA-Z0-9\$]+)\(/) {
		$funcname = $1;
	} elsif ($code =~ /\bc\s*&&\s*d\.set\([^,]+\s*,\s*\([^)]*\)\s*\(\s*([a-zA-Z0-9\$]+)\(/) {
		$funcname = $1;
	} elsif ($code =~ /yt\.akamaized\.net\/\)\s*\|\|\s*.*?\s*c\s*&&\s*d\.set\([^,]+\s*,\s*(?:encodeURIComponent\s*\()?([a-zA-Z0-9\$]+)\(/) {
		$funcname = $1;
	} elsif ( $code =~ /(["\'])signature\1\s*,\s*([a-zA-Z0-9\$]+)\(/ ) {
		$funcname = $2;
=cut
	if ($code =~ /\b([a-zA-Z0-9\$]{2})\s*=\s*function\(\s*a\s*\)\s*\{\s*a\s*=\s*a\.split\(\s*""\s*\)/) {
		$funcname = $1
	} elsif ($code =~ /([a-zA-Z0-9\$]+)\s*=\s*function\(\s*a\s*\)\s*\{\s*a\s*=\s*a\.split\(\s*""\s*\)/) {
		$funcname = $1;
	} elsif ($code =~ /\b[cs]\s*&&\s*[adf]\.set\([^,]+\s*,\s*(?:encodeURIComponent\s*\()?\s*([a-zA-Z0-9\$]+)\(/) {
		$funcname = $1;
    } elsif ($code =~ /\b[a-zA-Z0-9]+\s*&&\s*[a-zA-Z0-9]+\.set\([^,]+\s*,\s*(?:encodeURIComponent\s*\()?\s*([a-zA-Z0-9\$]+)\(/) {
		$funcname = $1;
	} else {	
		die "Cannot find JS player signature function name in '" . $code . "'";	
	}		
			
    $players{$uri} = $js->callable($funcname);
}


sub has_player {
    my $uri = shift;

    return exists $players{$uri};
}


sub unobfuscate_signature {
    my $uri = shift;
    my $sig = shift;

    unless (has_player($uri)) {
	die "No player cached for $uri";
    }

    my $func = $players{$uri};

    return &$func($sig);
}

1;
