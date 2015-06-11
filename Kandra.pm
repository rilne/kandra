#!/usr/bin/perl

package Kandra;

use Carp;
use strict;

require Exporter;
our @ISA = qw(Exporter);
our @EXPORT = qw(replace);

my %temp =
(
	'block'   => ['<!',    '>'],
	'format'  => ['<!%',   '>'],
	'stub'    => ['<!=',   '>'],
	'pattern' => ['<!\\+', '>'],
	'var'     => ['{',     '}'],
);

my $formats =
{
	'idt' => \&form_indent,
}

my $pre_regex =
	qr{
		(?:
			([{])	 |	# is var (1)
			(?:
				( <! 	# front code (2)
					(?:  [+] |
						([%])|	# is form zone (3)
						([=])	# is stub (4)
					)?
				)
				([|]?)	# format option (5)
			)
		)
		(/?)		# end tag (6)
		(?(1)|\s*)	# allow spaces unless var
		(?(2)|		# sep must not have name
		([A-Za-z0-9_:-]+) # name (7)
		)
		(?: [?] ([0-9]+) )? # optional depth mod (8)
		(?(1)|\s*)	# allow spaces unless var
		(?(1)
		(?:
			[}]
		)	|
		(?:
			([|]?)	# format option (9)
			>
		))
	}xms;

my $regexes = {};

for((	['var_regex',	0,	'var'	 ],
		['blk_regex',	1,	'block'	 ],
		['pat_regex',	1,	'pattern'],
		['frm_regex',	1,	'format' ],
		['stb_regex',	0,	'stub'	 ],))
{
	my ($regex_name, $regex_form, $regex_store) = @{$_};
	my ($left, $right) = @{$temp{$regex_store}};

	$regexes->{$regex_name} =
		(($regex_form)?
			(qr{
				$left

					([a-zA-Z0-9_:-]+)	[?] 	([0-9]+) 	(?:[:]([0-9]))?

				$right
					(.*?)
				$left
				/	\1 					[?]		\2			(?(3)[:]\3)
				$right
				}xms):
			(qr{
				$left ([,]|[a-zA-Z0-9_:-]+) [?] ([-]?[0-9]+) $right
			}xms ));
}

sub replace
{ return inner_replace(process(shift),[shift],[{}],[0]); }


sub process
{
	my ($text) = @_;
	my ($depth,$f_depth) = (0,0);
	$text =~ s{$pre_regex}{
				process_intern($1,$2,$3,$4,$5,$6,$7,$8,$9,\$depth,\$f_depth)
							}gexms;
	$text =~ s{
		(?:
			(?: [\n][\r]? [ \t]* <!@> 	)	|
			(?: <!@@> \s* 				)
		)
			}{}gxms;
	#print $text."\n\n";
	return $text;
}

sub process_intern
{
	my ($is_var, $front_code, $is_form, $is_stub,
		$front_form, $is_close, $name, $depth_mod,
		$rear_form, $depth_ref, $f_depth_ref) = @_;
	my ($front,$rear) = ('','');

	if($front_form)
	{ $front = '<!@>'; }

	if($rear_form)
	{ $rear = '<!@@>'; }

	if($is_var)
	{
		return '{'.$name.'?'.
					(($depth_mod)?
						(${$depth_ref} - $depth_mod):
						(${$depth_ref})).
					'}';
	}
	elsif($is_stub)
	{
		return "$front$front_code$name?".
					(($depth_mod)?
						(${$depth_ref} - $depth_mod):
						(${$depth_ref})).
					">$rear";
	}
	elsif($is_form)
	{
		if($is_close)
		{
			${$f_depth_ref}--;
			return "$front$front_code/$name?${$depth_ref}:${$f_depth_ref}>$rear";
		}
		else
		{
			my $temp = ${$f_depth_ref}++;
			return "$front$front_code$name?${$depth_ref}:$temp>$rear";
		}
	}
	elsif($is_close)
	{
		${$depth_ref}--;
		return "$front$front_code/$name?".
					#TODO: wtf? not sure what ($front eq '<!') is for.
					(($depth_mod && ($front eq '<!'))?
						(do{
							${$depth_ref} -= $depth_mod;
							${$depth_ref}}):
						(${$depth_ref})).
					">$rear";
		#return "$front$front_code/$name?${$depth_ref}>$rear";
	}
	else
	{
		my $temp = ${$depth_ref}++;
		return "$front$front_code$name?".
					#TODO: wtf? not sure what ($front eq '<!') is for.
					(($depth_mod && ($front eq '<!'))?
						(do{
							${$depth_ref} += $depth_mod;
							$temp}):
						($temp)).
					">$rear";
		#return "$front$front_code$name?$temp>$rear";
	}
}

sub inner_replace
{
	my ($self,$text,$lookup,$patterns,$true_depth) = @_;
	my $local = clone_hash($patterns->[-1]);
	#print "local: $local\n";
	my (	$blk_regex,	$var_regex,	$pat_regex,	$frm_regex,	$stb_regex, $sep_regex,	$methods) =
	@{$regexes
		}{	'blk_regex','var_regex','pat_regex','frm_regex','stb_regex','sep_regex','methods'};
	#print "recursing at depth $true_depth->[-1].\n";
	$text =~ s{$pat_regex}{
		$self->pat_strip($1,$2,$4,
			extend($true_depth),
			extend($patterns,$local))}gexms;
	#print "finished stripping patterns at depth $true_depth->[-1].\n";
	$text =~ s{$stb_regex}{
		$self->stb_replace($1,$2,
			extend($true_depth),extend($lookup),
			extend($patterns,$local))}gexms;
	#print "finished replacing stubs at depth $true_depth->[-1].\n";
	$text =~ s{}
	$text =~ s{$blk_regex}{
		$self->blk_replace($1,$2,$4,
			extend($true_depth),extend($lookup),
			extend($patterns,$local))}gexms;
	#print "finished replacing blocks at depth $true_depth->[-1].\n";
	$text =~ s{$var_regex}{
		$self->var_replace($1,$2,
			extend($true_depth),extend($lookup))}gexms;
	#print "finished replacing variables at depth $true_depth->[-1].\n";
	$text =~ s{$frm_regex}{
		$self->frm_replace($1,$2,$3,$4,
			extend($true_depth),extend($lookup),
			extend($patterns,$local))}gexms;
	#print "finished formatting at depth $true_depth->[-1].\n";
	return $text;
}

sub pat_strip
{
	my ($self,$name,$depth,$text,$true_depth,$patterns) = @_;
	return '<!+'."$name?$depth>$text".'<!+/'."$name?$depth>" if $depth != $true_depth->[-1];
	#print "pattern: $name depth: $depth expected_depth: $expected_depth\n";
	$patterns->[-1]->{$name} = [$depth,$text];
	return '';
}

# two ways to fill stubs:
# 'stub' => [ pattern, { /snip/ } ]
# enters stub once using given pattern and replacement hash.
# 'stub' => [ [ pattern, { /snip/ } ], ...]
# enters the stub once for each sub array, using given pattern
# and replacement hash, in the order given.

sub stb_replace
{
	my ($self,$name,$depth,$true_depth,$lookup,$patterns) = @_;
	if($depth <= $true_depth->[-1])
	{
		#print "entered $name\n";
		for(1..($true_depth->[-1] - $depth))
		{
			pop @{$lookup};
			pop @{$true_depth};
			pop @{$patterns};
		}
		my $local_lookup 	= $lookup->[-1];
		my $local_patterns 	= $patterns->[-1];

		if(	exists	($local_lookup->{$name})			&&
			ref 	($local_lookup->{$name}) eq 'ARRAY' &&
			scalar(@{$local_lookup->{$name}}))
		{
			if(ref $local_lookup->{$name}->[0] eq 'ARRAY')
			{
				return join('', map
				{
					my ($pat_name,$hash) = @{$_};
					if(exists $local_patterns->{$pat_name})
					{
						my ($pat_depth,$pat_text) =
							@{$local_patterns->{$pat_name}};
						$self->inner_replace($pat_text,
						extend($lookup,$hash),$patterns,
						extend($true_depth, $pat_depth + 1))
					}
					else { '' }
				} @{$lookup->{$name}});
			}
			else
			{
				my ($pat_name,$hash) = @{$local_lookup->{$name}};
				if(exists $local_patterns->{$pat_name})
				{
					my ($pat_depth,$pat_text) =
						@{$local_patterns->{$pat_name}};
					return $self->inner_replace($pat_text,
						extend($lookup,$hash),$patterns,
						extend($true_depth, $pat_depth + 1));
				}
				else { return ''; }
			}
		}
		else
		{
			return '';
		}
	}
	else
	{
		return '<!='."$name?$depth>";
	}
}

# three different ways to use blocks:
# 'block' => some_integer
# which enters the block some_integer number of times (or 0, if negative)
# 'block' => { /snip/ }
# which enters the block once with the given replacement hash
# 'block' => [ { /snip/ }, ... ]
# which enters the block with each replacement hash in the array,
# in the order given.

sub blk_replace
{
	my ($self,$name,$depth,$text,$true_depth,$lookup,$patterns) = @_;
	if($depth <= $true_depth->[-1])
	{
		#print "entered $name\n";
		for(1..($true_depth->[-1] - $depth))
		{
			pop @{$lookup};
			pop @{$true_depth};
			pop @{$patterns};
		}
		my $local_lookup = $lookup->[-1];

		if(exists $local_lookup->{$name})
		{
			if(ref ($local_lookup->{$name}) eq 'ARRAY')
			{
				if(scalar @{$local_lookup->{$name}})
				{
					#print "replacing block $name with an array\n";
					return join('', map
					{$self->inner_replace($text,
						extend($lookup,$_),$patterns,
						extend($true_depth, $true_depth->[-1] + 1))}
						@{$local_lookup->{$name}});
				}
				else
				{
					return '';
				}
			}
			elsif(ref $local_lookup->{$name} eq 'HASH')
			{
				#print "replacing block $name with hash\n";
				return $self->inner_replace($text,
							extend($lookup,$local_lookup->{$name}),$patterns,
								extend($true_depth, $true_depth->[-1] + 1));
			}
			else
			{
				#print "entering block $name a specified number of times.\n";
				return join('', map
					{$self->inner_replace($text,extend($lookup,{}),$patterns,
						extend($true_depth, $true_depth->[-1] + 1))}
					(1..($local_lookup->{$name})));
			}
		}
		else
			{
				return '';
			}
		}
		else
		{
			return '<!'."$name?$depth>$text".'<!/'."$name?$depth>";
		}
	}
	
	# only one way to fill variables, really.
	# 'variable' => value
	
	sub var_replace
	{
		my ($self,$name,$depth,$true_depth,$lookup) = @_;
		if($depth <= $true_depth->[-1])
		{
			#print "entered $name\n";
			for(1..($true_depth->[-1] - $depth))
			{
				pop @{$lookup};
				pop @{$true_depth};
			}
			
			my $local_lookup 	= $lookup->[-1];
			
			if(exists $local_lookup->{$name})
			{
				return $local_lookup->{$name};
			}
			else
			{
				print "warn: variable $name not found at depth $true_depth->[-1]\n";
				print "lookup is: " . join(',', (map { "$_ => $local_lookup->{$_}" } (keys %{$local_lookup}))) . "\n";;
				return '';
			}	
		}
		else
		{
			return '{'."$name?$depth".'}';
		}	
	}
	
	sub frm_replace
	{
		my ($self,$name,$depth,$f_depth,$text,$true_depth,$lookup,$patterns) = @_;
		return '<!!'."$name?$depth:$f_depth>$text".'<!!/'."$name?$depth:$f_depth>" 
			if $depth != $true_depth->[-1];
		#print "format: $name depth: $depth expected_depth: $expected_depth\n";
		if(exists $objects{refaddr $self}->{'methods'}->{$name})
		{
			return &{$objects{refaddr $self}->{'methods'}->{$name}}(
				$self->inner_replace($text,$lookup,$patterns,$true_depth));
		}
		else
		{
			return $self->inner_replace($text,$lookup,$patterns,$true_depth);
		}
	}
	
	sub form_indent
	{
		my ($text) = @_;
		my $depth = 0;
		$text =~ s{^[ \t]*(.*?)(<!\[(?:(?:[:]([0-9]+))|\+|(-))>)?$}{
		do{
			my $temp=(! $2)?($depth):(
				($3)?($depth + $3):(
					($4)?(--$depth):($depth++)));
			"".join('',map {"\t"} (1..$temp))."$1"
		}}gexms;
		return $text;
	}
	
	sub extend # inline copy + push for array refs.
	{
		return [(map {$_} @{shift @_}),@_];
	}
	
	sub clone_hash
	{
		my $hash = shift @_;
		return {map {$_ => $hash->{$_}} keys %{$hash}};
	}

1;
