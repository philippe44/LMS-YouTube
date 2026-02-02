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
sub set_yt_dlp_writable {
	my $bin_path = shift;

	return 1 if $^O =~ /^MSWin/; # Windows doesn't need this

	unless (chmod(0755, $bin_path)) {
		$log->error("Failed to set write permission on $bin_path: $!");
		return 0;
	}

	$log->info("Set write permissions (0755) on $bin_path");
	return 1;
}

# Restore safe permissions on yt-dlp binary (after self-update)
# Returns: 1 on success, 0 on failure
sub set_yt_dlp_readonly {
	my $bin_path = shift;

	return 1 if $^O =~ /^MSWin/; # Windows doesn't need this

	unless (chmod(0555, $bin_path)) {
		$log->warn("Failed to restore safe permissions on $bin_path: $!");
		return 0;
	}

	$log->info("Restored safe permissions (0555) on $bin_path");
	return 1;
}


1;
