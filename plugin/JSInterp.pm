#
# A really crude javascript interpretor which is (just barely)
# good enough to deal with youtube's lame signature obfuscation
# functions.
#
# A manual port of the Python code in youtube-dl on date 2015/3/3
# into Perl code:
#
#   https://github.com/rg3/youtube-dl/blob/master/youtube_dl/jsinterp.py
#
# Original python code was public domain.
# This Perl port is also placed into the public domain
#
# Author: Daniel P. Berrange <dan-ssods@berrange.com>
#

package Plugins::YouTube::JSInterp;

use strict;
use warnings;
use JSON::XS;

use Slim::Utils::Log;

my $log = logger('plugin.youtube');

my @_OPERATORS = (
    ['|', sub { my ($a, $b) = @_; return $a | $b }],
    ['^', sub { my ($a, $b) = @_; return $a ^ $b }],
    ['&', sub { my ($a, $b) = @_; return $a & $b }],
    ['>>', sub { my ($a, $b) = @_; return $a >> $b }],
    ['<<', sub { my ($a, $b) = @_; return $a << $b }],
    ['-', sub { my ($a, $b) = @_; return $a - $b }],
    ['+', sub { my ($a, $b) = @_; return $a + $b }],
    ['%', sub { my ($a, $b) = @_; return $a % $b }],
    ['/', sub { my ($a, $b) = @_; return $a / $b }],
    ['*', sub { my ($a, $b) = @_; return $a * $b }],
);

my @_ASSIGN_OPERATORS = map { [$_->[0] . '=', $_->[1]] } @_OPERATORS;
push @_ASSIGN_OPERATORS, ['=', sub { my ($a, $b) = @_; return $b }];

my $debug = 0;

sub new {
    my $class = shift;
    my $code = shift;
    my $objects = shift;

    my $self = {};

    $objects = {} unless defined $objects;

    $self->{code} = $code;
    $self->{functions} = {};
    $self->{objects} = $objects;

    bless $self, $class;

    return $self;
}


sub progress {
    my $self = shift;
    my $indent = shift;
    my $marker = shift;
    my $message = shift;

    my $prefix = $marker x ($indent + 1);

    print STDERR $prefix, " ", $message, "\n" if $debug;
}

sub interpret_statement {
    my ($self, $depth, $stmt, $local_vars, $allow_recursion) = @_;

    $allow_recursion = 10 unless defined $allow_recursion;
    #$allow_recursion = 100 unless defined $allow_recursion;
    $self->progress($depth, "--", "Statement '$stmt' $allow_recursion");

    die "Recursion limit reached" if $allow_recursion < 0;

    my $should_abort = 0;

    $stmt =~ s/^\s*//;

    my $expr;
    if ($stmt =~ /^var\s(.*)$/) {
	$expr = $1;
    } elsif ($stmt =~ /^return(?:\s+|$)(.*)$/) {
	$expr = $1;
	$should_abort = 1;
    } else {
	$expr = $stmt;
    }

    my $v = $self->interpret_expression($depth, $expr, $local_vars, $allow_recursion);

    return $v, $should_abort;
}


sub interpret_expression {
    my ($self, $depth, $expr, $local_vars, $allow_recursion) = @_;

    $expr =~ s/^\s*//;
    $expr =~ s/\s*$//;

    $self->progress($depth, "--", "Expression '$expr'");

    return undef if $expr eq "";

    # Handle grouping of sub expressions with brackets
    if ($expr =~ /^\(/) {
	$self->progress($depth, "--", "Process grouping");
	my $parens_count = 0;
	while ($expr =~ /(\(|\))/g) {
	    if ($1 eq "(") {
		$parens_count++;
	    } else {
		$parens_count--;
		if ($parens_count == 0) {
		    my $sub_expr = substr $expr, 1, pos($expr) - 2;
		    my $remaining_expr = pos($expr) >= length($expr) ? "" : substr $expr, pos($expr) + 1;
		    $remaining_expr =~ s/^\s*//;
		    $remaining_expr =~ s/\s*$//;

		    $self->progress($depth, "--", "Subexpresson '$sub_expr'");
		    $self->progress($depth, "--", "Remain expresson '$remaining_expr'");

		    my $sub_result = $self->interpret_expression($depth, $sub_expr, $local_vars, $allow_recursion);
		    if ($remaining_expr eq "") {
			return $sub_result;
		    } else {
			$expr = JSON::XS->new->allow_nonref(1)->encode($sub_result) . $remaining_expr;
			#$expr = $sub_result . $remaining_expr;
			# XXXX json.dumps(sub_result)
			#$expr = $sub_result . $remaining_expr;
			$self->progress($depth, "--", "New experession '$expr'");
			last;
		    }
		}
	    }
	}
	if ($parens_count > 0) {
	    die "Premature end of parens in " . $expr;
	}
    }


    # Handle assignment / in place operators
    foreach my $oprec (@_ASSIGN_OPERATORS) {
	my $op = $oprec->[0];
	my $opfunc = $oprec->[1];

	if (!($expr =~ /
                ([a-zA-Z_\$][a-zA-Z0-9_\$]*)(?:\[([^\]]+?)\])?
                \s*\Q$op\E
                (.*)$
              /x)) {
	    next;
	}
	$self->progress($depth, "--", "Match assign op '$op'");
	my $out = $1;
	my $index = $2;
	my $expr = $3;

	my $right_val = $self->interpret_expression(
	    $depth, $expr, $local_vars, $allow_recursion - 1);

	if (defined $index) {
	    my $lvar = $local_vars->{$out};
	    my $idx = $self->interpret_expression(
		$depth, $index, $local_vars, $allow_recursion);
	    # XXX
	    #assert isinstance(idx, int)
	    my $cur = $lvar->[$idx];
	    my $val = &$opfunc($cur, $right_val);
	    $lvar->[$idx] = $val;
	    return $val;
	} else {
	    my $cur = $local_vars->{$out};
	    my $val = &$opfunc($cur, $right_val);
	    $local_vars->{$out} = $val;
	    return $val;
	}
    }

    # Handle plain numeric constants
    if ($expr =~ /^\d+(\.\d+)?$/) {
	$self->progress($depth, "--", "Match integer constant");
	return $expr + 0.0; # Force to number
    }

    # Handle plain variable accesses
    if ($expr =~ /^(?!if|return|true|false)([a-zA-Z_\$][a-zA-Z0-9_\$]*)$/) {
	$self->progress($depth, "--", "Match variable access");
	my $name = $1;
	return $local_vars->{$name};
    }

    my $rv = eval { JSON::XS->new->allow_nonref(1)->decode($expr) };
    if ($@) {
	$self->progress($depth, "--", "Decode error '$@'");
    } else {
	$self->progress($depth, "--", "Match JSON string / data structure");
	return $rv;
    };

    # Handle variable method invokation  foo.method()
    if ($expr =~ /
           ^([a-zA-Z_\$][a-zA-Z0-9_\$]*)\.([^(]+)(?:\(+([^()]*)\))?$
              /x) {
	my $variable = $1;
	my $member = $2;
	my $arg_str = $3;

	$self->progress($depth, "--", "Match var method '$variable' member '$member' args '" . (
	    defined $arg_str ? $arg_str : "") . "'");

	my $obj;
	if (exists $local_vars->{$variable}) {
	    $obj = $local_vars->{$variable};
	} else {
	    unless (exists $self->{objects}->{$variable}) {
		$self->{objects}->{$variable} = $self->extract_object($depth, $variable);
	    }
	    $obj = $self->{objects}->{$variable};
	}

	unless (defined $arg_str) {
	    # Member access
	    if ($member eq 'length') {
		return $#{$obj} + 1;
	    }
	    if (ref($obj) eq "HASH") {
		return $obj->{$member};
	    } else {
		return $obj->[$member];
	    }
	}

	die "malformed expression" unless $expr =~ /\)$/;

	# Function call
	my $argvals;
	if ($arg_str eq '') {
	    $argvals = [];
	} else {
	    $argvals = [];
	    foreach my $v (split /,/, $arg_str) {
		push @{$argvals}, $self->interpret_expression($depth, $v, $local_vars, $allow_recursion);
	    }
	}
	if ($member eq 'split') {
	    die "too many argvals ($argvals) for split" if scalar(@{$argvals}) != 1;
	    my $val = $argvals->[0];
	    my @list = split /\Q$val\E/, $obj;
	    return \@list;
	}

	if ($member eq 'join') {
	    die "too many argvals ($argvals) for join" if scalar(@{$argvals}) != 1;
	    return join($argvals->[0], @{$obj});
	}
	if ($member eq 'reverse') {
	    die "too many argvals ($argvals) for reverse" if scalar(@{$argvals}) != 0;
	    @{$obj} = reverse @{$obj};
	    return $obj
	}
	if ($member eq 'slice') {
	    die "too many argvals ($argvals) for slice" if scalar(@{$argvals}) != 1;
	    my $ret = [];
	    for (my $i = $argvals->[0]; $i <= $#{$obj} ; $i++) {
		push @{$ret}, $obj->[$i];
	    }
	    return $ret;
	}
	if ($member eq 'splice') {
	    die "expected a list for splice" if ref($obj) ne "ARRAY";
	    my ($index, $howMany) = @{$argvals};
	    my @ret = splice @{$obj}, $index, $howMany;
	    return \@ret;
	}

	my $func = $obj->{$member};
	$self->progress($depth, ">>", "$member.$variable(" . join(",", map { JSON::XS->new->allow_nonref(1)->encode($_) } @{$argvals}) . ")");
	my $ret = &$func(@{$argvals});
	$self->progress($depth, "<<", JSON::XS->new->allow_nonref(1)->encode($ret));
	return $ret;
    }

    # Handle array elemnt accesses
    if ($expr =~ /
            ([a-zA-Z_\$][a-zA-Z0-9_\$]*)\[(.+)\]$
            /x) {
	my $in = $1;
	my $idxexpr = $2;
	$self->progress($depth, "--", "Array '$in' '$idxexpr'");
	my $val = $local_vars->{$in};
	my $idx = $self->interpret_expression(
	    $depth, $idxexpr, $local_vars, $allow_recursion - 1);
	return $val->[$idx];
    }


    # Handle integer operators
    foreach my $oprec (@_OPERATORS) {
	my $op = $oprec->[0];
	my $opfunc = $oprec->[1];
	if (!($expr =~ /
             (.+?)\Q$op\E(.+)
               /x)) {
	    next;
	}
	$self->progress($depth, "--", "Match operator '$op'");
	my $xexpr = $1;
	my $yexpr = $2;
	my ($x, $abortx) = $self->interpret_statement(
	    $depth, $xexpr, $local_vars, $allow_recursion - 1);
	if ($abortx) {
	    die 'Premature left-side return of $op in $expr';
	}
	my ($y, $aborty) = $self->interpret_statement(
	    $depth, $yexpr, $local_vars, $allow_recursion - 1);
	if ($aborty) {
	    die 'Premature right-side return of $op in $expr';
	}
	return &$opfunc($x, $y);
    }


    # Handle function invokation
    if ($expr =~ /
          ^([a-zA-Z_\$][a-zA-Z0-9_\$]*)\(([a-zA-Z0-9_\$,]+)\)$
             /x) {
	my $fname = $1;
	my $args = $2;
	$self->progress($depth, "--", "Function '$fname' with '$args'");
	my @argvals;
	foreach my $argstr (split /,/, $args) {
	    if ($argstr =~ /^\d+$/) {
		push @argvals, int($argstr);
	    } else {
		push @argvals, $local_vars->{$argstr};
	    }
	}

	return $self->call_function($depth, $fname, @argvals);
    }

    die "Unsupported JS expression '$expr'";
}


sub extract_object {
    my ($self, $depth, $objname) = @_;
    my $obj = {};

    $self->progress($depth, "--", "Extract '$objname'");

    if (!($self->{code} =~  /
            (?:var\s+)?
             \Q$objname\E
             \s*=\s*\{
             \s*(([a-zA-Z\$0-9]+\s*:\s*function\(.*?\)\s*\{.*?\}(?:,\s*)?)*)
            \}\s*;
              /x)) {
	die "Could not extract JS object '$objname'";
    }
    my $fields = $1;

    # Currently, it only supports function definitions
    while ($fields =~ /
            ([a-zA-Z\$0-9]+)\s*:\s*function
            \(([a-z,]+)\){([^}]+)}
              /xg) {
	my $key = $1;
	my $args = $2;
	my $code = $3;
	my @argnames = split /,/, $args;
	$obj->{$key} = $self->build_function($depth, \@argnames, $code);
    }
    return $obj;
}


sub extract_function {
    my ($self, $depth, $funcname) = @_;
    $self->progress($depth, "--", "Extract $funcname");
	my $args;
    my $code;
	
	$log->debug("JS function: $funcname $self->{code}");

# Python version : (?:function\s+%s|[{;,]%s\s*=\s*function|var\s+%s\s*=\s*function)\s*	

	if (($self->{code} =~ /(?:function\s+\Q$funcname\E|[{;,]\s*\Q$funcname\E\s*=\s*function|var\s+\Q$funcname\E\s*=\s*function)\s*
                \(([^)]*)\)\s*
                \{([^}]+)\}/x)) {
		$args = $1;
		$code = $2;
	} else {
		$log->error("Could not find JS function: $funcname");
		die "Could not find JS function '$funcname'";
    }

    $self->progress($depth, "%%", $code);
    $self->progress($depth, "--", "Got $args with code $code");
    my @argnames = split /,/, $args;
    return $self->build_function($depth, \@argnames, $code);
}


sub get_function {
    my ($self, $depth, $funcname) = @_;

    unless (exists $self->{functions}->{$funcname}) {
	$self->{functions}->{$funcname} = $self->extract_function($depth, $funcname);
    }
    return $self->{functions}->{$funcname};
}


sub call_function {
    my ($self, $depth, $funcname, @args) = @_;

    $self->progress($depth, ">>", "$funcname(" . join(",", map { JSON::XS->new->allow_nonref(1)->encode($_) } @args) . ")");
    my $func = $self->get_function($depth, $funcname);
    my $ret = &$func(@args);
    $self->progress($depth, "<<", JSON::XS->new->allow_nonref(1)->encode($ret));
    return $ret;
}


sub run {
    my ($self, $funcname, @args) = @_;

    return $self->call_function(0, $funcname, @args);
}


sub callable {
    my ($self, $funcname) = @_;

    return $self->get_function(0, $funcname);
}

sub build_function {
    my ($self, $depth, $argnames, $code) = @_;
    return sub {
	my @args = @_;
	my %local_vars;
	$self->progress($depth, "==", "arg names=" . join(",", @{$argnames}));
	foreach my $argname (@{$argnames}) {
	    $local_vars{$argname} = shift @args;
	}
	$self->progress($depth, "--", "Run '$code'");
	my ($ret, $abort);
	foreach my $stmt (split /;/, $code) {
	    ($ret, $abort) = $self->interpret_statement($depth + 1, $stmt, \%local_vars);
	    last if $abort;
	}
	return $ret;
    };
}

1;
