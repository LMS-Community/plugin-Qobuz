package Text::Levenshtein;

use strict;
use Exporter;
use vars qw($VERSION @ISA @EXPORT @EXPORT_OK %EXPORT_TAGS);

$VERSION     = '0.04';
@ISA         = qw(Exporter);
@EXPORT      = ();
@EXPORT_OK   = qw(&distance &fastdistance);
%EXPORT_TAGS = ();


sub _min
{
	return $_[0] < $_[1]
		? $_[0] < $_[2] ? $_[0] : $_[2]
		: $_[1] < $_[2] ? $_[1] : $_[2];
}


sub distance
{
	my ($s,@t)=@_;

	my $n=length($s);
	my @result;

	foreach my $t (@t) {
		if ($s eq $t) {
			push @result, 0;
			next;
		}
		my @d;
		my $cost=0;

		my $m=length($t);
		push @result,$m and next unless $n;
		push @result,$n and next unless $m;

		$d[0][0]=0;
		foreach my $i (1 .. $n) {
			if ($i != $n && substr($s,$i) eq substr($t,$i)) {
				push @result,$i;next;
			}
			$d[$i][0]=$i;
		}
		foreach my $j (1 .. $m) {
			if ($j != $m && substr($s,$j) eq substr($t,$j)) {
				push @result,$j;next;
			}
			$d[0][$j]=$j;
		}

		for my $i (1 .. $n) {
			my $s_i=substr($s,$i-1,1);
			for my $j (1 .. $m) {
				$d[$i][$j]=&_min($d[$i-1][$j]+1,
					 $d[$i][$j-1]+1,
					 $d[$i-1][$j-1]+($s_i eq substr($t,$j-1,1) ? 0 : 1) )
			}
		}

		push @result,$d[$n][$m];
	}

	if (wantarray) {return @result} else {return $result[0]}
}

sub fastdistance
{
	my $word1 = shift;
	my $word2 = shift;

	return 0 if $word1 eq $word2;
	my @d;

	my $len1 = length $word1;
	my $len2 = length $word2;

	$d[0][0] = 0;
	for (1 .. $len1) {
		$d[$_][0] = $_;
		return $_ if $_!=$len1 && substr($word1,$_) eq substr($word2,$_);
	}
	for (1 .. $len2) {
		$d[0][$_] = $_;
		return $_ if $_!=$len2 && substr($word1,$_) eq substr($word2,$_);
	}

	for my $i (1 .. $len1) {
		my $w1 = substr($word1,$i-1,1);
		for (1 .. $len2) {
			$d[$i][$_] = _min($d[$i-1][$_]+1, $d[$i][$_-1]+1, $d[$i-1][$_-1]+($w1 eq substr($word2,$_-1,1) ? 0 : 1));
		}
	}
	return $d[$len1][$len2];
}
	
1;

__END__

=head1 NAME

Text::Levenshtein - An implementation of the Levenshtein edit distance

=head1 SYNOPSIS

 use Text::Levenshtein qw(distance);

 print distance("foo","four");
 # prints "2"

 print fastdistance("foo","four");
 # prints "2" faster

 my @words=("four","foo","bar");
 my @distances=distance("foo",@words);

 print "@distances";
 # prints "2 0 3"
 

=head1 DESCRIPTION

This module implements the Levenshtein edit distance.
The Levenshtein edit distance is a measure of the degree of proximity between two strings.
This distance is the number of substitutions, deletions or insertions ("edits") 
needed to transform one string into the other one (and vice versa).
When two strings have distance 0, they are the same.
A good point to start is: <http://www.merriampark.com/ld.htm>

&fastdistance can be called with two scalars and is faster in most cases.

See also Text::LevenshteinXS on CPAN if you do not require a perl-only implementation.  It
is extremely faster in nearly all cases.

See also Text::WagnerFischer on CPAN for a configurable edit distance, i.e. for
configurable costs (weights) for the edits.


=head1 AUTHOR

Copyright 2002 Dree Mistrut <F<dree@friul.it>>

This package is free software and is provided "as is" without express
or implied warranty.  You can redistribute it and/or modify it under 
the same terms as Perl itself.

=cut
