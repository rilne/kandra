#!/usr/bin/perl

package Kandra;

use Carp;
use strict;

use File::Slurp;

require Exporter;
our @ISA = qw(Exporter);
our @EXPORT = qw(replace);

my %temp =
(
	'block'   => ['<!',    '>'],
	'stub'    => ['<!=',   '>'],
	'pattern' => ['<![+]', '>'],
	'var'     => ['{',     '}'],
);

my $pre_regex =
	qr{
		(?:
			([{])	 |			# is var (1)
			(?:
				( <! 			# front code (2)
					(?:  [+] |
						([=])	# is stub (3)
					)?
				)
				([|]?)			# format option (4)
				(/?)			# end tag (5)
			)
		)
		(?(1)|\s*)				# allow spaces unless var
		([A-Za-z0-9_:.-]*)		# name (6)
		(?: [?] ([0-9]+) )?		# optional depth mod (7)
		(?(1)|\s*)				# allow spaces unless var
		(?(1)
		(?:
			[}]
		)	|
		(?:
			([|]?)				# format option (8)
			(?:(/)([^>]+))?>	# list delimiter option (9,10)
		))
	}xms;

my $regexes = {};

for((	['var_regex',	0,	'var'	 ],
		['blk_regex',	1,	'block'	 ],
		['pat_regex',	1,	'pattern'],
		['stb_regex',	0,	'stub'	 ],))
{
	my ($regex_name, $regex_form, $regex_store) = @{$_};
	my ($left, $right) = @{$temp{$regex_store}};

	$regexes->{$regex_name} =
		(($regex_form)?
			(qr{
				$left
					([a-zA-Z0-9_:-]+)	[?] 	([0-9]+)
				$right
					(.*?)
				$left
				/	(?:\1)?				[?]		\2		 (?:/([^>][^>]?))?
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
	my ($depth,$f_depth) = (0);
	$text =~ s{$pre_regex}{
				process_intern($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,\$depth)
							}gexms;
	$text =~ s{
		(?:
			(?: [\n][\r]? [ \t]* <!@> 	)	|
			(?: <!@@> \s* 				)
		)
			}{}gxms;
	write_file('processed',$text);
	return $text;
}

sub process_intern
{
	my ($is_var, $front_code, $is_stub,
		$front_form, $is_close, $name, $depth_mod,
		$rear_form, $has_comma, $comma,
		$depth_ref) = @_;
	my ($front,$rear) = ('','');

	if    ($front_form) { $front = '<!@>';	}
	unless($rear_form)	{ $rear  = '<!@@>';	}

	#print "$name at depth: ${$depth_ref}, mod $depth_mod\n";

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
	elsif($is_close)
	{
		${$depth_ref}--;
		return "$front$front_code/$name?".
					(($depth_mod && ($front_code eq '<!'))?
						(do{
							${$depth_ref} += $depth_mod;
							${$depth_ref}}):
						(${$depth_ref})).
					"$has_comma$comma>$rear";
		#return "$front$front_code/$name?${$depth_ref}>$rear";
	}
	else
	{
		my $temp = ${$depth_ref}++;
		return "$front$front_code$name?".
					(($depth_mod && ($front_code eq '<!'))?
						(do{
							${$depth_ref} -= $depth_mod;
							$temp}):
						($temp)).
					">$rear";
		#return "$front$front_code$name?$temp>$rear";
	}
}

sub inner_replace
{
	my ($text,$lookup,$patterns,$true_depth) = @_;
	my $local = clone_hash($patterns->[-1]);
	#print "local: $local\n";
	my (	$blk_regex,	$var_regex,	$pat_regex,	$frm_regex,	$stb_regex,	$methods) =
	@{$regexes
		}{	'blk_regex','var_regex','pat_regex','frm_regex','stb_regex','methods'};
	#print "recursing at depth $true_depth->[-1].\n";
	$text =~ s{$pat_regex}{
				pat_strip($0,$1,$2,$3,
					extend($true_depth),
					extend($patterns,$local))}gexms;
	#print "finished stripping patterns at depth $true_depth->[-1].\n";
	$text =~ s{$stb_regex}{
				stb_replace($0,$1,$2,
					extend($true_depth),extend($lookup),
					extend($patterns,$local))}gexms;
	#print "finished replacing stubs at depth $true_depth->[-1].\n";
	$text =~ s{$blk_regex}{
				blk_replace($0,$1,$2,$3,$4,
					extend($true_depth),extend($lookup),
					extend($patterns,$local))}gexms;
	#print "finished replacing blocks at depth $true_depth->[-1].\n";
	$text =~ s{$var_regex}{
				var_replace($0,$1,$2,
					extend($true_depth),extend($lookup))}gexms;
	#print "finished replacing variables at depth $true_depth->[-1].\n";
	return () unless $text;
	return $text;
}

sub pat_strip
{
	my ($full,$name,$depth,$text,$true_depth,$patterns) = @_;
	return $full if $depth != $true_depth->[-1];
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
	my ($full,$name,$depth,$true_depth,$lookup,$patterns) = @_;
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
						inner_replace($pat_text,
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
					return inner_replace($pat_text,
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
		return $full;
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
	my ($full,$name,$depth,$text,$comma,$true_depth,$lookup,$patterns) = @_;

	write_file("$name"."?$depth",$text);

	my $comma_full= {','=>', ',',,'=>',',';'=>",\n",';;'=>';'}->{$comma} // $comma;

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
					return join($comma_full, map
					{inner_replace($text,
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
				return inner_replace($text,
							extend($lookup,$local_lookup->{$name}),$patterns,
								extend($true_depth, $true_depth->[-1] + 1));
			}
			else
			{
				#print "entering block $name a specified number of times.\n";
				return join($comma_full, map
					{inner_replace($text,extend($lookup,{}),$patterns,
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
		#print "skipping $name"."?$depth at depth ".$true_depth->[-1]."\n";
		return $full;
	}
}
	
	# only one way to fill variables, really.
	# 'variable' => value
	
	sub var_replace
	{
		my ($full,$name,$depth,$true_depth,$lookup) = @_;
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
			return $full;
		}	
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
