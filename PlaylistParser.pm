package Plugins::Qobuz::PlaylistParser;

use strict;

use Plugins::Qobuz::API::Common;

my $cache = Plugins::Qobuz::API::Common->getCache();

sub read {
	my ($class, $fh, $base, $url) = @_;

	my ($id) = $url =~ m|qobuz://(.*)\.qbz|;
	my $tracks = [];
	if ($id) {
		$tracks = $cache->get("playlist_tracks${id}") || [];
	}

	return @$tracks;
}

1;