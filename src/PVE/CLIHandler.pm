package PVE::CLIHandler;

use strict;
use warnings;
use Data::Dumper;

use PVE::Exception qw(raise raise_param_exc);
use PVE::RESTHandler;
use PVE::PodParser;

use base qw(PVE::RESTHandler);

my $cmddef;
my $exename;

my $expand_command_name = sub {
    my ($def, $cmd) = @_;

    if (!$def->{$cmd}) {
	my $expanded;
	for my $k (keys(%$def)) {
	    if ($k =~ m/^$cmd/) {
		if ($expanded) {
		    $expanded = undef; # more than one match
		    last;
		} else {
		    $expanded = $k;
		}
	    }
	}
	$cmd = $expanded if $expanded;
    }
    return $cmd;
};

__PACKAGE__->register_method ({
    name => 'help', 
    path => 'help',
    method => 'GET',
    description => "Get help about specified command.",
    parameters => {
    	additionalProperties => 0,
	properties => {
	    cmd => {
		description => "Command name",
		type => 'string',
		optional => 1,
	    },
	    verbose => {
		description => "Verbose output format.",
		type => 'boolean',
		optional => 1,
	    },
	},
    },
    returns => { type => 'null' },
    
    code => sub {
	my ($param) = @_;

	die "not initialized" if !($cmddef && $exename);

	my $cmd = $param->{cmd};

	my $verbose = defined($cmd) && $cmd; 
	$verbose = $param->{verbose} if defined($param->{verbose});

	if (!$cmd) {
	    if ($verbose) {
		print_usage_verbose();
	    } else {		
		print_usage_short(\*STDOUT);
	    }
	    return undef;
	}

	$cmd = &$expand_command_name($cmddef, $cmd);

	my ($class, $name, $arg_param, $uri_param) = @{$cmddef->{$cmd} || []};

	raise_param_exc({ cmd => "no such command '$cmd'"}) if !$class;


	my $str = $class->usage_str($name, "$exename $cmd", $arg_param, $uri_param, $verbose ? 'full' : 'short');
	if ($verbose) {
	    print "$str\n";
	} else {
	    print "USAGE: $str\n";
	}

	return undef;

    }});

sub print_pod_manpage {
    my ($podfn) = @_;

    die "not initialized" if !($cmddef && $exename);
    die "no pod file specified" if !$podfn;

    my $synopsis = "";
    
    $synopsis .= " $exename <COMMAND> [ARGS] [OPTIONS]\n\n";

    my $style = 'full'; # or should we use 'short'?
    my $oldclass;
    foreach my $cmd (sorted_commands()) {
	my ($class, $name, $arg_param, $uri_param) = @{$cmddef->{$cmd}};
	my $str = $class->usage_str($name, "$exename $cmd", $arg_param, 
				    $uri_param, $style);
	$str =~ s/^USAGE: //;

	$synopsis .= "\n" if $oldclass && $oldclass ne $class;
	$str =~ s/\n/\n /g;
	$synopsis .= " $str\n\n";
	$oldclass = $class;
    }

    $synopsis .= "\n";

    my $parser = PVE::PodParser->new();
    $parser->{include}->{synopsis} = $synopsis;
    $parser->parse_from_file($podfn);
}

sub print_usage_verbose {

    die "not initialized" if !($cmddef && $exename);

    print "USAGE: $exename <COMMAND> [ARGS] [OPTIONS]\n\n";

    foreach my $cmd (sort keys %$cmddef) {
	my ($class, $name, $arg_param, $uri_param) = @{$cmddef->{$cmd}};
	my $str = $class->usage_str($name, "$exename $cmd", $arg_param, $uri_param, 'full');
	print "$str\n\n";
    }
}

sub sorted_commands {   
    return sort { ($cmddef->{$a}->[0] cmp $cmddef->{$b}->[0]) || ($a cmp $b)} keys %$cmddef;
}

sub print_usage_short {
    my ($fd, $msg) = @_;

    die "not initialized" if !($cmddef && $exename);

    print $fd "ERROR: $msg\n" if $msg;
    print $fd "USAGE: $exename <COMMAND> [ARGS] [OPTIONS]\n";

    my $oldclass;
    foreach my $cmd (sorted_commands()) {
	my ($class, $name, $arg_param, $uri_param) = @{$cmddef->{$cmd}};
	my $str = $class->usage_str($name, "$exename $cmd", $arg_param, $uri_param, 'short');
	print $fd "\n" if $oldclass && $oldclass ne $class;
	print $fd "       $str";
	$oldclass = $class;
    }
}

my $print_bash_completion = sub {
    my ($cmddef, $simple_cmd, $bash_command, $cur, $prev) = @_;

    my $debug = 0;

    return if !(defined($cur) && defined($prev) && defined($bash_command));
    return if !defined($ENV{COMP_LINE});
    return if !defined($ENV{COMP_POINT});

    my $cmdline = substr($ENV{COMP_LINE}, 0, $ENV{COMP_POINT});
    print STDERR "\nCMDLINE: $ENV{COMP_LINE}\n" if $debug;

    # fixme: shell quoting??
    my @args = split(/\s+/, $cmdline);
    my $pos = scalar(@args) - 2;
    $pos += 1 if $cmdline =~ m/\s+$/;

    print STDERR "CMDLINE:$pos:$cmdline\n" if $debug;

    return if $pos < 0;

    my $print_result = sub {
	foreach my $p (@_) {
	    print "$p\n" if $p =~ m/^$cur/;
	}
    };

    my $cmd;
    if ($simple_cmd) {
	$cmd = $simple_cmd;
    } else {
	if ($pos == 0) {
	    &$print_result(keys %$cmddef);
	    return;
	}
	$cmd = $args[1];
    }

    my $def = $cmddef->{$cmd};
    return if !$def;

    print STDERR "CMDLINE1:$pos:$cmdline\n" if $debug;

    my $skip_param = {};

    my ($class, $name, $arg_param, $uri_param) = @$def;
    $arg_param //= [];
    $uri_param //= {};

    map { $skip_param->{$_} = 1; } @$arg_param;
    map { $skip_param->{$_} = 1; } keys %$uri_param;

    my $fpcount = scalar(@$arg_param);

    my $info = $class->map_method_by_name($name);

    my $schema = $info->{parameters};
    my $prop = $schema->{properties};

    my $print_parameter_completion = sub {
	my ($pname) = @_;
	my $d = $prop->{$pname};
	if ($d->{completion}) {
	    my $vt = ref($d->{completion});
	    if ($vt eq 'CODE') {
		my $res = $d->{completion}->($cmd, $pname, $cur);
		&$print_result(@$res);
	    }
	} elsif ($d->{type} eq 'boolean') {
	    &$print_result('0', '1');
	} elsif ($d->{enum}) {
	    &$print_result(@{$d->{enum}});
	}
    };

    # positional arguments
    $pos += 1 if $simple_cmd;
    if ($fpcount && $pos <= $fpcount) {
	my $pname = $arg_param->[$pos -1];
	&$print_parameter_completion($pname);
	return;
    }

    my @option_list = ();
    foreach my $key (keys %$prop) {
	next if $skip_param->{$key};
	push @option_list, "--$key";
    }

    if ($cur =~ m/^-/) {
	&$print_result(@option_list);
	return;
    }

    if ($prev =~ m/^--?(.+)$/ && $prop->{$1}) {
	my $pname = $1;
	&$print_parameter_completion($pname);
	return;
    }

    &$print_result(@option_list);
};

sub verify_api {
    my ($class) = @_;

    # simply verify all registered methods
    PVE::RESTHandler::validate_method_schemas();
}

sub generate_pod_manpage {
    my ($class, $podfn) = @_;

    no strict 'refs'; 
    $cmddef = ${"${class}::cmddef"};

    $exename = $class;
    $exename =~ s/^.*:://;

    if (!defined($podfn)) {
	my $cpath = "$class.pm";
	$cpath =~ s/::/\//g;
	foreach my $p (@INC) {
	    my $testfn = "$p/$cpath";
	    if (-f $testfn) {
		$podfn = $testfn;
		last;
	    }
	}
    }

    die "unable to find source for class '$class'" if !$podfn;

    print_pod_manpage($podfn);
}

sub handle_cmd {
    my ($def, $cmdname, $cmd, $args, $pwcallback, $podfn, $preparefunc) = @_;

    $cmddef = $def;
    $exename = $cmdname;

    $cmddef->{help} = [ __PACKAGE__, 'help', ['cmd'] ];

    if (!$cmd) { 
	print_usage_short (\*STDERR, "no command specified");
	exit (-1);
    } elsif ($cmd eq 'verifyapi') {
	PVE::RESTHandler::validate_method_schemas();
	return;
    } elsif ($cmd eq 'printmanpod') {
	print_pod_manpage($podfn);
	return;
    } elsif ($cmd eq 'bashcomplete') {
	&$print_bash_completion($cmddef, 0, @$args);
	return;
    }

    &$preparefunc() if $preparefunc;

    $cmd = &$expand_command_name($cmddef, $cmd);

    my ($class, $name, $arg_param, $uri_param, $outsub) = @{$cmddef->{$cmd} || []};

    if (!$class) {
	print_usage_short (\*STDERR, "unknown command '$cmd'");
	exit (-1);
    }

    my $prefix = "$exename $cmd";
    my $res = $class->cli_handler($prefix, $name, \@ARGV, $arg_param, $uri_param, $pwcallback);

    &$outsub($res) if $outsub;
}

sub handle_simple_cmd {
    my ($def, $args, $pwcallback, $podfn) = @_;

    my ($class, $name, $arg_param, $uri_param, $outsub) = @{$def};
    die "no class specified" if !$class;

    if (scalar(@$args) >= 1) {
	if ($args->[0] eq 'help') {
	    my $str = "USAGE: $name help\n";
	    $str .= $class->usage_str($name, $name, $arg_param, $uri_param, 'long');
	    print STDERR "$str\n\n";
	    return;
	} elsif ($args->[0] eq 'bashcomplete') {
	    shift @$args;
	    &$print_bash_completion({ $name => $def }, $name, @$args);
	    return;
	} elsif ($args->[0] eq 'verifyapi') {
	    PVE::RESTHandler::validate_method_schemas();
	    return;
	} elsif ($args->[0] eq 'printmanpod') {
	    my $synopsis = " $name help\n\n";
	    my $str = $class->usage_str($name, $name, $arg_param, $uri_param, 'long');
	    $str =~ s/^USAGE://;
	    $str =~ s/\n/\n /g;
	    $synopsis .= $str;

	    my $parser = PVE::PodParser->new();
	    $parser->{include}->{synopsis} = $synopsis;
	    $parser->parse_from_file($podfn);
	    return;
	}
    }

    my $res = $class->cli_handler($name, $name, \@ARGV, $arg_param, $uri_param, $pwcallback);

    &$outsub($res) if $outsub;
}

1;
