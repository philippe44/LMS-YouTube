package Plugins::YouTube::Utils;

use strict;
use warnings;
use Encode;

use Config;

use File::Spec::Functions;

use Slim::Utils::Log;

my $log   = logger('plugin.youtube');

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
		$bin = "yt-dlp.exe";
	}	
	
	if ($os->{'os'} eq 'Unix') {
	
		if ($os->{'osName'} eq 'solaris') {
		}	
		
		if ($os->{'osName'} =~ /freebsd/) {
		}
			
	}	
	
	if ($os->{'os'} eq 'FreeBSD') {
	}
	
	$bin ||= 'yt-dlp';
	
	return $bin;
}

sub yt_dlp_bin {
	my $bin = shift || yt_dlp_binary();
	
	$bin = Slim::Utils::Misc::findbin($bin) || catdir(Slim::Utils::PluginManager->allPlugins->{'YouTube'}->{'basedir'}, 'bin', $bin);
	$bin = Slim::Utils::OSDetect::getOS->decodeExternalHelperPath($bin);
			
	if (!-x $bin) {
		$log->warn("$bin not executable, correcting");
		chmod (0555, $bin);
	}
	
	return $bin;
}	

sub yt_dlp_binaries {
	return qw ( yt-dlp_linux yt-dlp_linux_aarch64 yt-dlp_macos yt-dlp.exe yt-dlp);
}

sub yt_dlp_path {
	my $bin = shift;
	return Slim::Utils::OSDetect::getOS->decodeExternalHelperPath( Slim::Utils::Misc::findbin($bin) );
}

1;
