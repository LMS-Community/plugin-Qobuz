package Plugins::Qobuz::SmartMix;

use Slim::Utils::Log;
use Slim::Utils::Prefs;

use Plugins::SmartMix::Services;

my $log   = logger('plugin.qobuz');
my $prefs = preferences('plugin.qobuz');

sub getId {
	return ( $prefs->get('username') && $prefs->get('password_md5_hash') ) ? 'qobuz' : undef;
} 

sub getUrl {
	my $class = shift;
	
	# we can't handle the id - return a search handler instead
	return sub {
		$class->resolveUrl(@_);
	} if $class->getId(); 
}

sub resolveUrl {
	my ($class, $cb, $args) = @_;

	Plugins::Qobuz::API->search(sub {
		my $searchResult = shift;
		
		if (!$searchResult) {
			$cb->();
		}

		my $candidates = [];
		
		for my $track ( @{$searchResult->{tracks}->{items}} ) {
			next unless $track->{performer} && $track->{id} && $track->{title};
			
			my $artist = $track->{performer}->{name};
			
			$artist = $track->{album}->{artist}->{name} if !$artist && $track->{album} && $track->{album}->{artist};
			
			next unless $artist;

			next if $track->{released_at} > time || !$track->{streamable};
			
			push @$candidates, {
				title  => $track->{title},
				artist => $artist,
				url    => 'qobuz://' . $track->{id},
			};
		}

		$cb->( Plugins::SmartMix::Services->getUrlFromCandidates($candidates, $args) );

	}, $args->{title}, 'tracks');
}

# dealt with in Plugins::SmartMix::Services->getTrackIdFromUrl
sub urlToId {}

1;