package Plugins::Qobuz::LastMix;

use strict;

use base qw(Plugins::LastMix::Services::Base);

use Slim::Utils::Prefs;

my $prefs = preferences('plugin.qobuz');

sub isEnabled {
	my ($class, $client) = @_;

	return unless $client;

	return unless Slim::Utils::PluginManager->isEnabled('Plugins::Qobuz::Plugin');

	require Plugins::Qobuz::API::Common;
	return Plugins::Qobuz::API::Common->hasAccount() ? 'Qobuz' : undef;
}

sub lookup {
	my ($class, $client, $cb, $args) = @_;

	$class->client($client) if $client;
	$class->cb($cb) if $cb;
	$class->args($args) if $args;

	Plugins::Qobuz::Plugin::getAPIHandler($client)->search(sub {
		my $searchResult = shift;

		if (!$searchResult) {
			$class->cb->();
		}

		my $candidates = [];
		my $searchArtist = $class->args->{artist};

		my %tracks;

		for my $track ( @{ Plugins::Qobuz::API::Common->filterPlayables($searchResult->{tracks}->{items}) } ) {
			next unless $track->{performer} && $track->{id} && $track->{title};

			my $artist = '';

			$artist = $track->{album}->{artist}->{name} if $track->{album} && $track->{album}->{artist};
			$artist = $track->{performer}->{name} if $artist !~ /\Q$searchArtist\E/i && $track->{performer}->{name} =~ /\Q$searchArtist\E/i;
			$artist = $track->{composer}->{name} if $artist !~ /\Q$searchArtist\E/i && $track->{composer}->{name} =~ /\Q$searchArtist\E/i;

			next unless $artist;

			my $url = Plugins::Qobuz::API::Common->getUrl($client, $track);

			$tracks{$url} = $track;

			push @$candidates, {
				title  => $track->{title},
				artist => $artist,
				url    => $url,
			};
		}

		my $track = $class->extractTrack($candidates);

		Plugins::Qobuz::API::Common->precacheTrack($tracks{$track}) if $tracks{$track};

		$class->cb->($track);
	}, $class->args->{title}, 'tracks', {
		_dontPreCache => 1,
		limit => 20,
	});
}

sub protocol { 'qobuz' }


1;