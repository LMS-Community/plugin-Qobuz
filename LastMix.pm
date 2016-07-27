package Plugins::Qobuz::LastMix;

use strict;

use base qw(Plugins::LastMix::Services::Base);

use Slim::Utils::Prefs;

my $prefs = preferences('plugin.qobuz');

sub isEnabled {
	my ($class, $client) = @_;
	
	return unless $client;
	
	return unless Slim::Utils::PluginManager->isEnabled('Plugins::Qobuz::Plugin');
	
	return ( $prefs->get('username') && $prefs->get('password_md5_hash') ) ? 'Qobuz' : undef;
} 

sub lookup {
	my ($class, $client, $cb, $args) = @_;
	
	$class->client($client) if $client;
	$class->cb($cb) if $cb;
	$class->args($args) if $args;

	Plugins::Qobuz::API->search(sub {
		my $searchResult = shift;
		
		if (!$searchResult) {
			$class->cb->();
		}

		my $candidates = [];
		my $searchArtist = $class->args->{artist};
		
		for my $track ( @{$searchResult->{tracks}->{items}} ) {
			next unless $track->{performer} && $track->{id} && $track->{title};
			
			my $artist = '';
			
			$artist = $track->{album}->{artist}->{name} if $track->{album} && $track->{album}->{artist};
			$artist = $track->{performer}->{name} if $artist !~ /\Q$searchArtist\E/i && $track->{performer}->{name} =~ /\Q$searchArtist\E/i;
			$artist = $track->{composer}->{name} if $artist !~ /\Q$searchArtist\E/i && $track->{composer}->{name} =~ /\Q$searchArtist\E/i;
			
			next unless $artist;

			next if $track->{released_at} > time || (!$track->{streamable} && !$prefs->get('playSamples'));
			
			push @$candidates, {
				title  => $track->{title},
				artist => $artist,
				url    => Plugins::Qobuz::ProtocolHandler->getUrl($track),
			};
		}

		$class->cb->( $class->extractTrack($candidates) );
	}, $class->args->{title}, 'tracks');
}

sub protocol { 'qobuz' }


1;
