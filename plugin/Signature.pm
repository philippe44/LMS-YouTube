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

    my $js = Plugins::YouTube::JSInterp->new($code);

	if ($code !~ /\.sig\|\|([a-zA-Z0-9\$]+)\(/) {
	die "Cannot find JS player signature function name in '" . $code . "'";
    }

    my $funcname = $1;

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
