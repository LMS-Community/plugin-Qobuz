package Plugins::Qobuz::SmartMix;

use Slim::Utils::Log;
use Slim::Utils::Prefs;

use Plugins::SmartMix::Services;

my $log   = logger('plugin.qobuz');
my $prefs = preferences('plugin.qobuz');

sub getId {
	my ($class, $client) = @_;
	
	return unless $client;
	
	return unless Slim::Utils::PluginManager->isEnabled('Plugins::Qobuz::Plugin');

	return if $prefs->get('disable_Qobuz');
	
	return ( $prefs->get('username') && $prefs->get('password_md5_hash') ) ? 'Qobuz' : undef;
} 

sub getUrl {
	my $class = shift;
	my ($id, $client) = @_;
	
	# we can't handle the id - return a search handler instead
	return sub {
		$class->resolveUrl(@_);
	} if $class->getId($client); 
}

sub resolveUrl {
	my ($class, $cb, $args) = @_;

	Plugins::Qobuz::API->search(sub {
		my $searchResult = shift;
		
		if (!$searchResult) {
			$cb->();
		}

		my $candidates = [];
		my $searchArtist = $args->{artist};
		
		for my $track ( @{$searchResult->{tracks}->{items}} ) {
			next unless $track->{performer} && $track->{id} && $track->{title};
			
			my $artist = '';
			
			$artist = $track->{album}->{artist}->{name} if $track->{album} && $track->{album}->{artist};
			$artist = $track->{performer}->{name} if $artist !~ /\Q$searchArtist\E/i;
			
			next unless $artist;

			next if $track->{released_at} > time || (!$track->{streamable} && !$prefs->get('playSamples'));
			
			push @$candidates, {
				title  => $track->{title},
				artist => $artist,
				url    => Plugins::Qobuz::ProtocolHandler->getUrl($track),
			};
		}

		$cb->( Plugins::SmartMix::Services->getUrlFromCandidates($candidates, $args) );

	}, $args->{title}, 'tracks', undef, 1);
}

# dealt with in Plugins::SmartMix::Services->getTrackIdFromUrl
sub urlToId {}

1;