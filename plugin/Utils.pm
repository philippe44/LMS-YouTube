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
	
	# add extra path
	unless ($init) {
		my $base = catdir(Slim::Utils::PluginManager->allPlugins->{'YouTube'}->{'basedir'}, 'Bin');
		Slim::Utils::Misc::addFindBinPaths(
			# catdir($base, 'armv7l'),
		);
		$init = 1;
	}	
	
	my ($exec) = grep { -e "$_/$bin" } Slim::Utils::Misc::getBinPaths;
	$exec = catdir($exec, $bin);
		
	if (!-x $exec) {
		$log->warn("$exec not executable - correcting");
		chmod (0555, $exec);
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

# cookies.txt (Netscape format) handed to yt-dlp with --cookies
sub cookies_file { return catfile(Slim::Utils::OSDetect::dirsFor('prefs'), 'youtube-cookies.txt') }

# returns the path if a usable cookies file exists, undef otherwise
sub cookies_bin {
	my $file = cookies_file();
	return (-s $file && -r $file) ? $file : undef;
}

# store pasted cookies, returns (1) on success or (0, error string)
sub save_cookies {
	my $text = shift;
	$text =~ s/\r\n?/\n/g;
	$text =~ s/^\s+|\s+$//g;
	return (0, 'no cookie lines found') unless $text =~ /^[^#\n]*\t[^\n]*\t/m || $text =~ /^#\s*(Netscape )?HTTP Cookie File/m;
	my $file = cookies_file();
	my $umask = umask(0077);
	my $fh;
	my $ok = open($fh, '>:raw', $file) && print($fh "$text\n") && close($fh);
	my $err = $!;
	umask($umask);
	return (0, "cannot write $file: $err") unless $ok;
	chmod(0600, $file) unless main::ISWINDOWS;
	return (1);
}

sub clear_cookies {
	my $file = cookies_file();
	return !-e $file || unlink($file);
}
1;
