package PVE::Tools;

use strict;
use POSIX;
use IO::Socket::INET;
use IO::Select;
use File::Basename;
use File::Path qw(make_path);
use IO::File;
use IPC::Open3;
use Fcntl qw(:DEFAULT :flock);
use base 'Exporter';
use URI::Escape;
use Encode;

our @EXPORT_OK = qw(
lock_file 
run_command 
file_set_contents 
file_get_contents
file_read_firstline
split_list
template_replace
safe_print
trim
extract_param
);

my $pvelogdir = "/var/log/pve";
my $pvetaskdir = "$pvelogdir/tasks";

mkdir $pvelogdir;
mkdir $pvetaskdir;

# flock: we use one file handle per process, so lock file
# can be called multiple times and succeeds for the same process.

my $lock_handles =  {};

sub lock_file {
    my ($filename, $timeout, $code, @param) = @_;

    my $res;

    $timeout = 10 if !$timeout;

    eval {

        local $SIG{ALRM} = sub { die "got timeout (can't lock '$filename')\n"; };

        alarm ($timeout);

        if (!$lock_handles->{$$}->{$filename}) {
            $lock_handles->{$$}->{$filename} = new IO::File (">>$filename") ||
                die "can't open lock file '$filename' - $!\n";
        }

        if (!flock ($lock_handles->{$$}->{$filename}, LOCK_EX|LOCK_NB)) {
            print STDERR "trying to aquire lock...";
            if (!flock ($lock_handles->{$$}->{$filename}, LOCK_EX)) {
                print STDERR " failed\n";
                die "can't aquire lock for '$filename' - $!\n";
            }
            print STDERR " OK\n";
        }
        alarm (0);

        $res = &$code(@param);
    };

    my $err = $@;

    alarm (0);

    if ($lock_handles->{$$}->{$filename}) {
        my $fh = $lock_handles->{$$}->{$filename};
        $lock_handles->{$$}->{$filename} = undef;
        close ($fh);
    }

    if ($err) {
        $@ = $err;
        return undef;
    }

    $@ = undef;

    return $res;
}

sub file_set_contents {
    my ($filename, $data, $perm)  = @_;

    $perm = 0644 if !defined($perm);

    my $tmpname = "$filename.tmp.$$";

    eval {
	my $fh = IO::File->new($tmpname, O_WRONLY|O_CREAT, $perm);
	die "unable to open file '$tmpname' - $!\n" if !$fh;
	die "unable to write '$tmpname' - $!\n" unless print $fh $data;
	die "closing file '$tmpname' failed - $!\n" unless close $fh;
    };
    my $err = $@;

    if ($err) {
	unlink $tmpname;
	die $err;
    }

    if (!rename($tmpname, $filename)) {
	my $msg = "close (rename) atomic file '$filename' failed: $!\n";
	unlink $tmpname;
	die $msg;	
    }
}

sub file_get_contents {
    my ($filename, $max) = @_;

    my $fh = IO::File->new($filename, "r") ||
	die "can't open '$filename' - $!\n";

    my $content = safe_read_from($fh, $max);

    close $fh;

    return $content;
}

sub file_read_firstline {
    my ($filename) = @_;

    my $fh = IO::File->new ($filename, "r");
    return undef if !$fh;
    my $res = <$fh>;
    chomp $res;
    $fh->close;
    return $res;
}

sub safe_read_from {
    my ($fh, $max, $oneline) = @_;

    $max = 32768 if !$max;

    my $br = 0;
    my $input = '';
    my $count;
    while ($count = sysread($fh, $input, 8192, $br)) {
	$br += $count;
	die "input too long - aborting\n" if $br > $max;
	if ($oneline && $input =~ m/^(.*)\n/) {
	    $input = $1;
	    last;
	}
    } 
    die "unable to read input - $!\n" if !defined($count);

    return $input;
}

sub run_command {
    my ($cmd, %param) = @_;

    my $old_umask;

    $cmd = [ $cmd ] if !ref($cmd);

    my $cmdstr = join (' ', @$cmd);

    my $errmsg;
    my $laststderr;
    my $timeout;
    my $oldtimeout;
    my $pid;

    eval {
	my $reader = IO::File->new();
	my $writer = IO::File->new();
	my $error  = IO::File->new();

	my $input;
	my $outfunc;
	my $errfunc;

	foreach my $p (keys %param) {
	    if ($p eq 'timeout') {
		$timeout = $param{$p};
	    } elsif ($p eq 'umask') {
		umask($param{$p});
	    } elsif ($p eq 'errmsg') {
		$errmsg = $param{$p};
		$errfunc = sub {
		    print STDERR "$laststderr\n" if $laststderr;
		    $laststderr = shift; 
		};
	    } elsif ($p eq 'input') {
		$input = $param{$p};
	    } elsif ($p eq 'outfunc') {
		$outfunc = $param{$p};
	    } elsif ($p eq 'errfunc') {
		$errfunc = $param{$p};
	    } else {
		die "got unknown parameter '$p' for run_command\n";
	    }
	}

	# try to avoid locale related issues/warnings
	my $lang = $param{lang} || 'C'; 
 
	my $orig_pid = $$;

	eval {
	    local $ENV{LC_ALL} = $lang;

	    # suppress LVM warnings like: "File descriptor 3 left open";
	    local $ENV{LVM_SUPPRESS_FD_WARNINGS} = "1";

	    $pid = open3($writer, $reader, $error, @$cmd) || die $!;
	};

	my $err = $@;

	# catch exec errors
	if ($orig_pid != $$) {
	    warn "ERROR: $err";
	    POSIX::_exit (1); 
	    kill ('KILL', $$); 
	}

	die $err if $err;

	local $SIG{ALRM} = sub { die "got timeout\n"; } if $timeout;
	$oldtimeout = alarm($timeout) if $timeout;

	print $writer $input if defined $input;
	close $writer;

	my $select = new IO::Select;
	$select->add($reader);
	$select->add($error);

	my $outlog = '';
	my $errlog = '';

	my $starttime = time();

	while ($select->count) {
	    my @handles = $select->can_read(1);

	    foreach my $h (@handles) {
		my $buf = '';
		my $count = sysread ($h, $buf, 4096);
		if (!defined ($count)) {
		    my $err = $!;
		    kill (9, $pid);
		    waitpid ($pid, 0);
		    die $err;
		}
		$select->remove ($h) if !$count;
		if ($h eq $reader) {
		    if ($outfunc) {
			eval {
			    $outlog .= $buf;
			    while ($outlog =~ s/^([^\010\r\n]*)(\r|\n|(\010)+|\r\n)//s) {
				my $line = $1;
				&$outfunc($line);
			    }
			};
			my $err = $@;
			if ($err) {
			    kill (9, $pid);
			    waitpid ($pid, 0);
			    die $err;
			}
		    } else {
			print $buf;
			*STDOUT->flush();
		    }
		} elsif ($h eq $error) {
		    if ($errfunc) {
			eval {
			    $errlog .= $buf;
			    while ($errlog =~ s/^([^\010\r\n]*)(\r|\n|(\010)+|\r\n)//s) {
				my $line = $1;
				&$errfunc($line);
			    }
			};
			my $err = $@;
			if ($err) {
			    kill (9, $pid);
			    waitpid ($pid, 0);
			    die $err;
			}
		    } else {
			print STDERR $buf;
			*STDERR->flush();
		    }
		}
	    }
	}

	&$outfunc($outlog) if $outfunc && $outlog;
	&$errfunc($errlog) if $errfunc && $errlog;

	waitpid ($pid, 0);
  
	if ($? == -1) {
	    die "failed to execute\n";
	} elsif (my $sig = ($? & 127)) {
	    die "got signal $sig\n";
	} elsif (my $ec = ($? >> 8)) {
	    if ($errmsg && $laststderr) {
		my $lerr = $laststderr;
		$laststderr = undef;
		die "$lerr\n";
	    }
	    die "exit code $ec\n";
	}

        alarm(0);
    };

    my $err = $@;

    alarm(0);

    print STDERR "$laststderr\n" if $laststderr;

    umask ($old_umask) if defined($old_umask);

    alarm($oldtimeout) if $oldtimeout;

    if ($err) {
	if ($pid && ($err eq "got timeout\n")) {
	    kill (9, $pid);
	    waitpid ($pid, 0);
	    die "command '$cmdstr' failed: $err";
	}

	if ($errmsg) {
	    die "$errmsg: $err";
	} else {
	    die "command '$cmdstr' failed: $err";
	}
    }
}

sub split_list {
    my $listtxt = shift || '';

    $listtxt =~ s/[,;\0]/ /g;
    $listtxt =~ s/^\s+//;

    my @data = split (/\s+/, $listtxt);

    return @data;
}

sub trim {
    my $txt = shift;

    return $txt if !defined($txt);

    $txt =~ s/^\s+//;
    $txt =~ s/\s+$//;
    
    return $txt;
}

# simple uri templates like "/vms/{vmid}"
sub template_replace {
    my ($tmpl, $data) = @_;

    my $res = '';
    while ($tmpl =~ m/([^{]+)?({([^}]+)})?/g) {
	$res .= $1 if $1;
	$res .= ($data->{$3} || '-') if $2;
    }
    return $res;
}

sub safe_print {
    my ($filename, $fh, $data) = @_;

    return if !$data;

    my $res = print $fh $data;

    die "write to '$filename' failed\n" if !$res;
}

sub debmirrors {

    return {
	'at' => 'ftp.at.debian.org',
	'au' => 'ftp.au.debian.org',
	'be' => 'ftp.be.debian.org',
	'bg' => 'ftp.bg.debian.org',
	'br' => 'ftp.br.debian.org',
	'ca' => 'ftp.ca.debian.org',
	'ch' => 'ftp.ch.debian.org',
	'cl' => 'ftp.cl.debian.org',
	'cz' => 'ftp.cz.debian.org',
	'de' => 'ftp.de.debian.org',
	'dk' => 'ftp.dk.debian.org',
	'ee' => 'ftp.ee.debian.org',
	'es' => 'ftp.es.debian.org',
	'fi' => 'ftp.fi.debian.org',
	'fr' => 'ftp.fr.debian.org',
	'gr' => 'ftp.gr.debian.org',
	'hk' => 'ftp.hk.debian.org',
	'hr' => 'ftp.hr.debian.org',
	'hu' => 'ftp.hu.debian.org',
	'ie' => 'ftp.ie.debian.org',
	'is' => 'ftp.is.debian.org',
	'it' => 'ftp.it.debian.org',
	'jp' => 'ftp.jp.debian.org',
	'kr' => 'ftp.kr.debian.org',
	'mx' => 'ftp.mx.debian.org',
	'nl' => 'ftp.nl.debian.org',
	'no' => 'ftp.no.debian.org',
	'nz' => 'ftp.nz.debian.org',
	'pl' => 'ftp.pl.debian.org',
	'pt' => 'ftp.pt.debian.org',
	'ro' => 'ftp.ro.debian.org',
	'ru' => 'ftp.ru.debian.org',
	'se' => 'ftp.se.debian.org',
	'si' => 'ftp.si.debian.org',
	'sk' => 'ftp.sk.debian.org',
	'tr' => 'ftp.tr.debian.org',
	'tw' => 'ftp.tw.debian.org',
	'gb' => 'ftp.uk.debian.org',
	'us' => 'ftp.us.debian.org',
    };
}

sub kvmkeymaps {
    return {
	'dk'     => ['Danish', 'da', 'qwerty/dk-latin1.kmap.gz', 'dk', 'nodeadkeys'],
	'de'     => ['German', 'de', 'qwertz/de-latin1-nodeadkeys.kmap.gz', 'de', 'nodeadkeys' ],
	'de-ch'  => ['Swiss-German', 'de-ch', 'qwertz/sg-latin1.kmap.gz',  'ch', 'de_nodeadkeys' ], 
	'en-gb'  => ['United Kingdom', 'en-gb', 'qwerty/uk.kmap.gz' , 'gb', 'intl' ],
	'en-us'  => ['U.S. English', 'en-us', 'qwerty/us-latin1.kmap.gz',  'us', 'intl' ],
	'es'     => ['Spanish', 'es', 'qwerty/es.kmap.gz', 'es', 'nodeadkeys'],
	#'et'     => [], # Ethopia or Estonia ??
	'fi'     => ['Finnish', 'fi', 'qwerty/fi-latin1.kmap.gz', 'fi', 'nodeadkeys'],
	#'fo'     => ['Faroe Islands', 'fo', ???, 'fo', 'nodeadkeys'],
	'fr'     => ['French', 'fr', 'azerty/fr-latin1.kmap.gz', 'fr', 'nodeadkeys'],
	'fr-be'  => ['Belgium-French', 'fr-be', 'azerty/be2-latin1.kmap.gz', 'be', 'nodeadkeys'],
	'fr-ca'  => ['Canada-French', 'fr-ca', 'qwerty/cf.kmap.gz', 'ca', 'fr-legacy'],
	'fr-ch'  => ['Swiss-French', 'fr-ch', 'qwertz/fr_CH-latin1.kmap.gz', 'ch', 'fr_nodeadkeys'],
	#'hr'     => ['Croatia', 'hr', 'qwertz/croat.kmap.gz', 'hr', ??], # latin2?
	'hu'     => ['Hungarian', 'hu', 'qwertz/hu.kmap.gz', 'hu', undef],
	'is'     => ['Icelandic', 'is', 'qwerty/is-latin1.kmap.gz', 'is', 'nodeadkeys'],
	'it'     => ['Italian', 'it', 'qwerty/it2.kmap.gz', 'it', 'nodeadkeys'],
	'jp'     => ['Japanese', 'ja', 'qwerty/jp106.kmap.gz', 'jp', undef],
	'lt'     => ['Lithuanian', 'lt', 'qwerty/lt.kmap.gz', 'lt', 'std'],
	#'lv'     => ['Latvian', 'lv', 'qwerty/lv-latin4.kmap.gz', 'lv', ??], # latin4 or latin7?
	'mk'     => ['Macedonian', 'mk', 'qwerty/mk.kmap.gz', 'mk', 'nodeadkeys'],
	'nl'     => ['Dutch', 'nl', 'qwerty/nl.kmap.gz', 'nl', undef],
	#'nl-be'  => ['Belgium-Dutch', 'nl-be', ?, ?, ?],
	'no'   => ['Norwegian', 'no', 'qwerty/no-latin1.kmap.gz', 'no', 'nodeadkeys'], 
	'pl'     => ['Polish', 'pl', 'qwerty/pl.kmap.gz', 'pl', undef],
	'pt'     => ['Portuguese', 'pt', 'qwerty/pt-latin1.kmap.gz', 'pt', 'nodeadkeys'],
	'pt-br'  => ['Brazil-Portuguese', 'pt-br', 'qwerty/br-latin1.kmap.gz', 'br', 'nodeadkeys'],
	#'ru'     => ['Russian', 'ru', 'qwerty/ru.kmap.gz', 'ru', undef], # dont know?
	'si'     => ['Slovenian', 'sl', 'qwertz/slovene.kmap.gz', 'si', undef],
	#'sv'     => [], Swedish ?
	#'th'     => [],
	#'tr'     => [],
    };
}

sub extract_param {
    my ($param, $key) = @_;

    my $res = $param->{$key};
    delete $param->{$key};

    return $res;
}

sub next_vnc_port {

    for (my $p = 5900; $p < 6000; $p++) {

	my $sock = IO::Socket::INET->new (Listen => 5,
					  LocalAddr => 'localhost',
					  LocalPort => $p,
					  ReuseAddr => 1,
					  Proto     => 0);

	if ($sock) {
	    close ($sock);
	    return $p;
	}
    }

    die "unable to find free vnc port";
};

# NOTE: NFS syscall can't be interrupted, so alarm does 
# not work to provide timeouts.
# from 'man nfs': "Only SIGKILL can interrupt a pending NFS operation"
# So the spawn external 'df' process instead of using
# Filesys::Df (which uses statfs syscall)
sub df {
    my ($path, $timeout) = @_;

    my $cmd = [ 'df', '-P', '-B', '1', $path];

    my $res = {
	total => 0,
	used => 0,
	avail => 0,
    };

    my $parser = sub {
	my $line = shift;
	if (my ($fsid, $total, $used, $avail) = $line =~
	    m/^(\S+.*)\s+(\d+)\s+(\d+)\s+(\d+)\s+\d+%\s.*$/) {
	    $res = {
		total => $total,
		used => $used,
		avail => $avail,
	    };
	}
    };
    eval { run_command($cmd, timeout => $timeout, outfunc => $parser); };
    warn $@ if $@;

    return $res;
}

# UPID helper
# We use this to uniquely identify a process.
# An 'Unique Process ID' has the following format: 
# "UPID:$node:$pid:$pstart:$startime:$dtype:$id:$user"

sub upid_encode {
    my $d = shift;

    return sprintf("UPID:%s:%08X:%08X:%08X:%s:%s:%s:", $d->{node}, $d->{pid}, 
		   $d->{pstart}, $d->{starttime}, $d->{type}, $d->{id}, 
		   $d->{user});
}

sub upid_decode {
    my ($upid, $noerr) = @_;

    my $res;
    my $filename;

    # "UPID:$node:$pid:$pstart:$startime:$dtype:$id:$user"
    if ($upid =~ m/^UPID:([A-Za-z][[:alnum:]\-]*[[:alnum:]]+):([0-9A-Fa-f]{8}):([0-9A-Fa-f]{8}):([0-9A-Fa-f]{8}):([^:\s]+):([^:\s]*):([^:\s]+):$/) {
	$res->{node} = $1;
	$res->{pid} = hex($2);
	$res->{pstart} = hex($3);
	$res->{starttime} = hex($4);
	$res->{type} = $5;
	$res->{id} = $6;
	$res->{user} = $7;

	my $subdir = substr($4, 7, 8);
	$filename = "$pvetaskdir/$subdir/$upid";

    } else {
	return undef if $noerr;
	die "unable to parse worker upid '$upid'\n";
    }

    return wantarray ? ($res, $filename) : $res;
}

sub upid_open {
    my ($upid) = @_;

    my ($task, $filename) = upid_decode($upid); 

    my $dirname = dirname($filename);
    make_path($dirname);

    my $wwwid = getpwnam('www-data') ||
	die "getpwnam failed";

    my $perm = 0640;
 
    my $outfh = IO::File->new ($filename, O_WRONLY|O_CREAT|O_EXCL, $perm) ||
	die "unable to create output file '$filename' - $!\n";
    chown $wwwid, $outfh;

    return $outfh;
};

sub upid_read_status {
    my ($upid) = @_;

    my ($task, $filename) = upid_decode($upid);
    my $fh = IO::File->new($filename, "r");
    return "unable to open file - $!" if !$fh;
    my $maxlen = 1024;
    sysseek($fh, -$maxlen, 2);
    my $readbuf = '';
    my $br = sysread($fh, $readbuf, $maxlen);
    close($fh);
    if ($br) {
	return "unable to extract last line"
	    if $readbuf !~ m/\n?(.+)$/;
	my $line = $1;
	if ($line =~ m/^TASK OK$/) {
	    return 'OK';
	} elsif ($line =~ m/^TASK ERROR: (.+)$/) {
	    return $1;
	} else {
	    return "unexpected status";
	}
    }
    return "unable to read tail (got $br bytes)";
}

# useful functions to store comments in config files 
sub encode_text {
    my ($text) = @_;

    # all control and hi-bit characters, and ':'
    my $unsafe = "^\x20-\x39\x3b-\x7e";
    return uri_escape(Encode::encode("utf8", $text), $unsafe);
}

sub decode_text {
    my ($data) = @_;

    return Encode::decode("utf8", uri_unescape($data));
}


1;