package PVE::Format;

use strict;
use warnings;

use POSIX qw(strftime round);

use base 'Exporter';
our @EXPORT_OK = qw(
render_timestamp
render_timestamp_gmt
render_duration
render_fraction_as_percentage
render_bytes
);

sub render_timestamp {
    my ($epoch) = @_;

    # ISO 8601 date format
    return strftime("%F %H:%M:%S", localtime($epoch));
}

sub render_timestamp_gmt {
    my ($epoch) = @_;

    # ISO 8601 date format, standard Greenwich time zone
    return strftime("%F %H:%M:%S", gmtime($epoch));
}

sub render_duration {
    my ($duration_in_seconds) = @_;

    my $text = '';
    my $rest = round($duration_in_seconds // 0);

    return "0s" if !$rest;

    my $step = sub {
	my ($unit, $unitlength) = @_;

	if ((my $v = int($rest/$unitlength)) > 0) {
	    $text .= " " if length($text);
	    $text .= "${v}${unit}";
	    $rest -= $v * $unitlength;
	}
    };

    $step->('w', 7*24*3600);
    $step->('d', 24*3600);
    $step->('h', 3600);
    $step->('m', 60);
    $step->('s', 1);

    return $text;
}

sub render_fraction_as_percentage {
    my ($fraction) = @_;

    return sprintf("%.2f%%", $fraction*100);
}

sub render_bytes {
    my ($value, $precision) = @_;

    my @units = qw(B KiB MiB GiB TiB PiB);

    my $max_unit = 0;
    if ($value > 1023) {
        $max_unit = int(log($value)/log(1024));
        $value /= 1024**($max_unit);
    }
    my $unit = $units[$max_unit];
    return sprintf "%." . ($precision || 2) . "f $unit", $value;
}

1;