package Plugins::YouTube::Utils;

use strict;
use feature 'state';
use warnings;
use Encode;

use Config;

use File::Spec::Functions;

use Slim::Utils::Log;

my $log = logger('plugin.youtube');

sub yt_dlp_binary {
	my $bin;	
	my $os = Slim::Utils::OSDetect::details();
	
	if ($os->{'os'} eq 'Linux') {

		if ($os->{'osArch'} =~ /x86_64/) {
			$bin = "yt-dlp_linux";
        } elsif ($os->{'binArch'} =~ /i386/) {
		} elsif ($os->{'osArch'} =~ /aarch64/) {
			$bin = "yt-dlp_linux_aarch64";
		} elsif ($os->{'binArch'} =~ /arm/) {
			$bin = "yt-dlp_linux_armv7l";
		} elsif ($os->{'binArch'} =~ /ppc|powerpc/) {
		} elsif ($os->{'binArch'} =~ /sparc/) {
		} elsif ($os->{'binArch'} =~ /mips/) {
		}
	
	}
	
	if ($os->{'os'} eq 'Darwin') {
		
		$bin = "yt-dlp_macos";
=comment		
		if ($os->{'osArch'} =~ /x86_64/) {
        } elsif ($os->{'osArch'} =~ /M1/) {
		}	
=cut		
		
	}

	if ($os->{'os'} eq 'Windows') {
		if ($os->{'osArch'} =~ /8664/) {
			$bin = "yt-dlp.exe";
		} else {	
			$bin = "yt-dlp_x86.exe";
		}	
	}	
	
	if ($os->{'os'} eq 'Unix') {
	
		if ($os->{'osName'} eq 'solaris') {
		}	
		
		if ($os->{'osName'} =~ /freebsd/) {
			$bin = "yt-dlp_freebsd14";
		}
			
	}	
	
	if ($os->{'os'} eq 'FreeBSD') {
		$bin = "yt-dlp_freebsd14";
	}
	
	$bin ||= 'yt-dlp';
	
	return $bin;
}

sub yt_dlp_bin {
	my $bin = shift || yt_dlp_binary();
	state $init;
	state $base;

	# add extra path. the plugin ships its yt-dlp binaries in Bin/,
	# which LMS doesn't include in getBinPaths by default, so add it.
	unless ($init) {
		$base = catdir(Slim::Utils::PluginManager->allPlugins->{'YouTube'}->{'basedir'}, 'Bin');
		Slim::Utils::Misc::addFindBinPaths($base);
		$init = 1;
	}

	# self heal: if the shipped binary lost its exec bit (unpacking with
	# unzip etc. drops permissions) findbin wont return it, and the old
	# code chmod'd the wrong path. resolve against the Bin/ dir first.
	my $shipped = catdir($base, $bin);
	if (-e $shipped && !-x $shipped) {
		$log->warn("$shipped not executable, fixing");
		chmod(0555, $shipped);
	}

	# use findbin in case there are other places
	$bin = Slim::Utils::Misc::findbin($bin);
	$bin = Slim::Utils::OSDetect::getOS->decodeExternalHelperPath($bin);

	return $bin;
}

sub yt_dlp_binaries {
	return qw ( yt-dlp_linux yt-dlp_linux_aarch64 yt-dlp_linux_armv7l yt-dlp_freebsd14 yt-dlp_macos yt-dlp.exe yt-dlp);
}

# Set writable permissions on yt-dlp binary (needed for self-update)
# Returns: 1 on success, 0 on failure
sub set_yt_dlp_writable { return main::ISWINDOWS || (-e $_[0] && chmod(0755, $_[0])) }
sub set_yt_dlp_readonly { return main::ISWINDOWS || (-e $_[0] && chmod(0555, $_[0])) }
1;
